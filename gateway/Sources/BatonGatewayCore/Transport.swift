import BatonMCPProtocol
import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The one platform-specific thing in the gateway: accepting TCP connections.
/// Apple platforms use Network.framework; Linux uses POSIX sockets, so the
/// service runs next to Navidrome on a home server rather than only on a Mac.
///
/// Everything above this line — parsing, auth, routing, the agent loop — is the
/// same code on both.
///
/// **In the core target rather than beside `main.swift`, and that move is the point.**
/// The POSIX transport is what actually runs in production, and it used to live in the
/// executable behind `#else` — so on a Mac it was not merely untested, it was not
/// *compiled*. Two P0-class defects lived there for that reason (SIGPIPE killing the
/// process, no read deadline). Here it compiles on both platforms and a test can drive a
/// real socket against it, which is how the fixes below are shown to work at all.
public protocol ServerTransport: Sendable {
    /// Serves forever.
    ///
    /// `handle` receives one fully-parsed request and returns the raw HTTP response bytes.
    /// `upload` is the exception: a request the router claims for the streaming path never
    /// reaches `handle`, because its body may be tens of megabytes and `HTTPRequestMessage`
    /// buffers whatever it parses. Instead the body is written to disk as it arrives and the
    /// handler is given the file. See `StreamingUpload`.
    func serve(
        port: UInt16,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) throws
}

/// Whether this request is one the streaming path should take, decided from the head alone.
///
/// Deliberately narrow: only a `PUT` to a file route. Everything else — including a `GET` of a
/// file, which has no body — goes the ordinary way, so the streaming path exists for exactly the
/// case that needs it and nothing else inherits its behaviour by accident.
public func isStreamingUpload(_ request: StreamingUpload.Request) -> Bool {
    request.method == "PUT" && request.path.hasPrefix("/v1/files/")
}

// MARK: - Responses

/// Renders a response the way both transports send it.
public func httpResponse(status: String, body: String) -> Data {
    httpResponse(status: status, contentType: "application/json", payload: Data(body.utf8))
}

/// An error body that is JSON whatever the message contains (TBX-5308, S-F26).
///
/// The old form interpolated the message into a JSON literal, and the one caller that mattered
/// passed `String(describing: error)` for a provider failure — free-form text that reliably
/// carries quotes and newlines. The phone then failed to decode the body and showed a generic
/// message, so "your credit balance is too low" never reached anybody. Serialised, not
/// interpolated: the message survives exactly as written.
public func httpErrorResponse(status: String, message: String) -> Data {
    httpResponse(status: status, body: jsonObject(["error": message]))
}

/// One JSON object as a string, without hand-rolled escaping.
public func jsonObject(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return #"{"error":"could not encode the response"}"# }
    return text
}

/// The same, for a body that is not text — serving a stored file back.
///
/// **Known limit, stated rather than hidden:** the payload is held in memory to send it, so a
/// download of a 64 MB file briefly costs 64 MB. Uploads stream to disk because that is the
/// direction where an unbounded body arrives from outside; a download is bounded by what this
/// gateway already chose to store. Streaming the response needs a send path that takes a file
/// rather than `Data`, on both transports, and that is worth doing separately rather than
/// bundling it in here.
public func httpResponse(status: String, contentType: String, payload: Data,
                         extraHeaders: [String: String] = [:]) -> Data {
    var head = "HTTP/1.1 \(status)\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Content-Length: \(payload.count)\r\n"
    for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
        head += "\(safeHeaderValue(name)): \(safeHeaderValue(value))\r\n"
    }
    head += "Connection: close\r\n\r\n"
    return Data(head.utf8) + payload
}

/// A header value that cannot become a second header (TBX-5308, S-F26).
///
/// `X-Baton-Name` is echoed back from whatever an upload stored, and the head is assembled by
/// string concatenation, so a value carrying CR or LF used to emit two lines. The parser trimmed
/// with `.whitespaces`, which is space and tab only, so a bare LF walked straight through it.
///
/// Control characters are removed rather than escaped — there is no escape for them in a header
/// value, and a file name has no use for one. The length cap is here for the same reason the
/// upload has a header cap: nothing about a name should be able to grow a response head.
public func safeHeaderValue(_ value: String, limit: Int = 1024) -> String {
    let cleaned = String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
    return cleaned.count <= limit ? cleaned : String(cleaned.prefix(limit))
}

// MARK: - Apple

#if canImport(Network)

/// Apple: NWListener, the same primitive the app's MCP server uses.
public struct NetworkTransport: ServerTransport {
    // Sendable through the protocol: every stored property is a value or a `@Sendable` closure.
    let stagingDirectory: URL
    let maximumBodyBytes: Int
    let log: @Sendable (String) -> Void

    public init(stagingDirectory: URL,
                maximumBodyBytes: Int = FileStore.defaultMaximumFileBytes,
                log: @escaping @Sendable (String) -> Void = RequestLog.standardOutput) {
        self.stagingDirectory = stagingDirectory
        self.maximumBodyBytes = maximumBodyBytes
        self.log = log
    }

    public func serve(
        port: UInt16,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            receive(connection, buffer: Data(), sink: nil, started: Date(), handle: handle, upload: upload)
        }
        listener.start(queue: .main)
        dispatchMain()
    }

    private func receive(
        _ connection: NWConnection, buffer: Data, sink: StreamingUpload?, started: Date,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
            // A connection that dies mid-upload must not leave its partial file behind.
            if error != nil || (isComplete && data == nil) {
                sink?.cancel()
                connection.cancel()
                return
            }

            // Already on the streaming path: feed it and nothing else.
            if let sink {
                switch sink.consume(data ?? Data()) {
                case .needMore:
                    receive(connection, buffer: Data(), sink: sink, started: started, handle: handle, upload: upload)
                case let .complete(url, request):
                    Task {
                        let response = await upload(request, url)
                        logUpload(request, response, started: started)
                        send(connection, response)
                    }
                case let .rejected(status, message):
                    let response = httpErrorResponse(status: status, message: message)
                    logUpload(sink.parsedRequest, response, started: started)
                    send(connection, response)
                }
                return
            }

            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.isEmpty { connection.cancel(); return }

            // Decide, once the head has arrived, whether this belongs on the streaming path.
            if let head = StreamingUpload.peekHead(buffer), isStreamingUpload(head) {
                let sink = StreamingUpload(stagingDirectory: stagingDirectory,
                                           maximumBodyBytes: maximumBodyBytes)
                switch sink.consume(buffer) {
                case .needMore:
                    receive(connection, buffer: Data(), sink: sink, started: started, handle: handle, upload: upload)
                case let .complete(url, request):
                    Task {
                        let response = await upload(request, url)
                        logUpload(request, response, started: started)
                        send(connection, response)
                    }
                case let .rejected(status, message):
                    let response = httpErrorResponse(status: status, message: message)
                    logUpload(head, response, started: started)
                    send(connection, response)
                }
                return
            }

            switch HTTPRequestMessage.parse(buffer) {
            case .incomplete:
                receive(connection, buffer: buffer, sink: nil, started: started, handle: handle, upload: upload)
            case .tooLarge, .malformed:
                send(connection, httpErrorResponse(status: "400 Bad Request", message: "bad request"))
            case .complete(let request):
                Task {
                    let response = await handle(request)
                    logRequest(request, response, started: started)
                    send(connection, response)
                }
            }
        }
    }

    private func logRequest(_ request: HTTPRequestMessage, _ response: Data, started: Date) {
        RequestLog.write(method: request.method, path: request.path, response: response,
                         userAgent: request.headers["user-agent"], started: started, to: log)
    }

    private func logUpload(_ request: StreamingUpload.Request?, _ response: Data, started: Date) {
        RequestLog.write(method: request?.method ?? "PUT", path: request?.path ?? "/v1/files/",
                         response: response, userAgent: request?.header("user-agent"),
                         started: started, to: log)
    }

    private func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

public typealias DefaultTransport = NetworkTransport

#else

public typealias DefaultTransport = POSIXTransport

#endif

// MARK: - POSIX

/// Linux: a plain blocking accept loop, one detached task per connection. The
/// gateway serves a household, not a datacenter — a thread-per-connection model
/// is the right amount of machinery, and keeps the dependency list empty.
///
/// Compiled on Apple platforms too, where `DefaultTransport` is the Network one and this is
/// reached only by its tests. That is deliberate: this is the code that runs in production, and
/// leaving it behind an `#else` meant a Mac could not so much as typecheck it.
public struct POSIXTransport: ServerTransport {
    let stagingDirectory: URL
    let maximumBodyBytes: Int
    /// How long one `read` on an accepted socket may block before the connection is dropped
    /// (TBX-5308, S-F13).
    ///
    /// **Per read, not per request**, which is what makes it safe for a slow 64 MB upload on poor
    /// Wi-Fi: a client that keeps sending resets the clock with every chunk. What it ends is a
    /// connection that says nothing at all, which before this held a cooperative-pool thread for
    /// as long as the peer cared to keep the socket open, needing no token to do it. The
    /// 25-second `/v1/device/poll` hold is unaffected: that is the gateway waiting to *write*.
    let readTimeout: TimeInterval
    let log: @Sendable (String) -> Void

    public init(stagingDirectory: URL,
                maximumBodyBytes: Int = FileStore.defaultMaximumFileBytes,
                readTimeout: TimeInterval = 15,
                log: @escaping @Sendable (String) -> Void = RequestLog.standardOutput) {
        self.stagingDirectory = stagingDirectory
        self.maximumBodyBytes = maximumBodyBytes
        self.readTimeout = readTimeout
        self.log = log
    }

    /// A listening socket a test can shut down. `serve` parks on `dispatchMain()` and never
    /// returns, which is right for a daemon and impossible to drive from a test.
    public struct Listener: Sendable {
        public let fileDescriptor: Int32
        public let port: UInt16
        public func stop() { close(fileDescriptor) }
    }

    public func serve(
        port: UInt16,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) throws {
        _ = try start(port: port, handle: handle, upload: upload)
        dispatchMain()
    }

    /// Bind, listen, and accept on a background thread. Returns once the socket is listening.
    ///
    /// Pass port 0 to be given a free one; the `Listener` reports which.
    @discardableResult
    public func start(
        port: UInt16,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) throws -> Listener {
        // Disarm SIGPIPE before a single byte is written (TBX-5308, S-F4).
        //
        // Writing to a socket whose peer has closed raises SIGPIPE, and its default disposition
        // *terminates the process*. A phone that cancels a download, a curl that is Ctrl-C'd, or a
        // client that gives up on a slow agent turn took the whole gateway down with it, from an
        // unauthenticated connection. `MSG_NOSIGNAL` on the write below covers the same hazard on
        // Linux and is what turns a dead peer into an ordinary `EPIPE`; this call is what covers
        // every other write in the process, and it is the half that also protects the Apple build,
        // where `MSG_NOSIGNAL` does not exist. Process-wide, and nothing here wants the default.
        signal(SIGPIPE, SIG_IGN)

        let listenFD = socket(AF_INET, streamSocketType, 0)
        guard listenFD >= 0 else { throw GatewayError.socket("socket() failed") }

        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound >= 0 else {
            close(listenFD)
            throw GatewayError.socket("bind(:\(port)) failed — is the port taken?")
        }
        guard listen(listenFD, 32) >= 0 else {
            close(listenFD)
            throw GatewayError.socket("listen() failed")
        }

        var boundPort = port
        if port == 0 {
            var reported = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &reported) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(listenFD, $0, &length)
                }
            }
            if ok == 0 { boundPort = UInt16(bigEndian: reported.sin_port) }
        }

        // The accept loop must NOT run on the main thread: request handling hops
        // to the main actor, and a blocking loop there starves it — the server
        // accepts connections and then answers none of them. Park main with
        // dispatchMain() (as the Apple path does) and accept on a thread.
        let staging = stagingDirectory
        let bodyCap = maximumBodyBytes
        let deadline = readTimeout
        let sink = log
        let thread = Thread {
            while true {
                let clientFD = accept(listenFD, nil, nil)
                if clientFD < 0 {
                    // A signal or an aborted handshake is ordinary; a closed or invalid listener
                    // means this loop is done. Anything else gets a breath rather than a spin —
                    // the old `continue` turned a transient EMFILE into a busy loop.
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    if errno == EBADF || errno == EINVAL || errno == ENOTSOCK { return }
                    usleep(50_000)
                    continue
                }
                // This detached task's blocking `read(fd, ...)` in `handleConnection` still
                // occupies a thread from Swift's cooperative pool for as long as the read blocks
                // (TBX-5325, TBX-5308 S-F13). Left as-is rather than moved to a dedicated thread
                // per connection: `SO_RCVTIMEO` bounds every such read to `readTimeout` (15 s in
                // production), which turns the failure mode from "silent connections exhaust the
                // pool for as long as they stay open" — the actual incident, unbounded — into
                // "at most (processor count) connections cost the pool up to 15 s each before the
                // deadline reclaims them". That is a real cost under a burst of slow clients, but
                // it is not the unbounded one this card closed, and a per-connection dedicated
                // thread is a bigger change (the read loop would need to stop being `async` and
                // bridge into the two calls that still need to be — `handle` and `upload` — with
                // its own synchronization) for a gain that only matters once someone is already
                // seeing pool exhaustion at the current bound. Worth doing before this gateway
                // serves more than a household's few devices at once; not before.
                Task.detached {
                    await Self.handleConnection(
                        clientFD, stagingDirectory: staging, maximumBodyBytes: bodyCap,
                        readTimeout: deadline, log: sink, handle: handle, upload: upload
                    )
                }
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()
        return Listener(fileDescriptor: listenFD, port: boundPort)
    }

    static func handleConnection(
        _ fd: Int32,
        stagingDirectory: URL,
        maximumBodyBytes: Int,
        readTimeout: TimeInterval,
        log: @escaping @Sendable (String) -> Void,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) async {
        defer { close(fd) }
        setReadTimeout(fd, readTimeout)
        let started = Date()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var sink: StreamingUpload?
        // A connection that dies mid-upload must not leave its partial file behind.
        defer { sink?.cancel() }

        func answer(_ response: Data, method: String, path: String, userAgent: String?) {
            write(fd, response)
            RequestLog.write(method: method, path: path, response: response,
                             userAgent: userAgent, started: started, to: log)
        }

        while true {
            let bytes = read(fd, &chunk, chunk.count)
            if bytes < 0 && errno == EINTR { continue }
            // A read that times out (EAGAIN under SO_RCVTIMEO) lands here with the peer's own
            // close, and both mean the same thing to us: this connection has nothing more to say.
            if bytes <= 0 { return }
            let slice = Data(chunk[0 ..< bytes])

            if let sink {
                switch sink.consume(slice) {
                case .needMore:
                    continue
                case let .complete(url, request):
                    answer(await upload(request, url), method: request.method, path: request.path,
                           userAgent: request.header("user-agent"))
                    return
                case let .rejected(status, message):
                    answer(httpErrorResponse(status: status, message: message),
                           method: sink.parsedRequest?.method ?? "PUT",
                           path: sink.parsedRequest?.path ?? "/v1/files/",
                           userAgent: sink.parsedRequest?.header("user-agent"))
                    return
                }
            }

            buffer.append(slice)

            // Decide, once the head has arrived, whether this belongs on the streaming path.
            if let head = StreamingUpload.peekHead(buffer), isStreamingUpload(head) {
                let started = StreamingUpload(stagingDirectory: stagingDirectory,
                                              maximumBodyBytes: maximumBodyBytes)
                sink = started
                switch started.consume(buffer) {
                case .needMore:
                    continue
                case let .complete(url, request):
                    answer(await upload(request, url), method: request.method, path: request.path,
                           userAgent: request.header("user-agent"))
                    return
                case let .rejected(status, message):
                    answer(httpErrorResponse(status: status, message: message),
                           method: head.method, path: head.path,
                           userAgent: head.header("user-agent"))
                    return
                }
            }

            switch HTTPRequestMessage.parse(buffer) {
            case .incomplete:
                continue // keep reading
            case .tooLarge, .malformed:
                answer(httpErrorResponse(status: "400 Bad Request", message: "bad request"),
                       method: "?", path: "/", userAgent: nil)
                return
            case .complete(let request):
                let response = await handle(request)
                answer(response, method: request.method, path: request.path,
                       userAgent: request.headers["user-agent"])
                return
            }
        }
    }

    /// `SO_RCVTIMEO`, so a silent peer cannot hold this connection (and the pool thread running
    /// it) open for ever.
    private static func setReadTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let whole = seconds.rounded(.down)
        var timeout = timeval(tv_sec: Int(whole),
                              tv_usec: .init((seconds - whole) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes every byte — a single `write` may be partial on a socket.
    static func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                // `send` with MSG_NOSIGNAL rather than `write`, so a peer that has gone away
                // surfaces as EPIPE here instead of as a signal that kills the process
                // (TBX-5308, S-F4). The flag is Linux-only; on Apple the `signal` call in
                // `start` is what carries the guarantee, which is why that call is not
                // conditional and why no `SO_NOSIGPIPE` is set here — the Mac tests then
                // exercise exactly the mechanism Linux ships with.
                #if canImport(Glibc)
                let written = send(fd, pointer, remaining, Int32(MSG_NOSIGNAL))
                #else
                let written = send(fd, pointer, remaining, 0)
                #endif
                if written <= 0 { return }
                pointer += written
                remaining -= written
            }
        }
    }
}

/// `SOCK_STREAM` is an `Int32` on Darwin and a `__socket_type` on Glibc.
#if canImport(Glibc)
private let streamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let streamSocketType = SOCK_STREAM
#endif

public enum GatewayError: Error, CustomStringConvertible {
    case socket(String)
    public var description: String {
        switch self {
        case .socket(let detail): detail
        }
    }
}
