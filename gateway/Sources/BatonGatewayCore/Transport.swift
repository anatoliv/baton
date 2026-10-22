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
/// Deliberately narrow: only a `PUT` to a file route, or a book submission (a prepared novel is
/// larger than the 1 MB the ordinary path accepts). Everything else — including a `GET` of a
/// file, which has no body — goes the ordinary way, so the streaming path exists for exactly the
/// case that needs it and nothing else inherits its behaviour by accident.
public func isStreamingUpload(_ request: StreamingUpload.Request) -> Bool {
    request.method == "PUT" && (request.path.hasPrefix("/v1/files/") || BookRoutes.isBookUpload(request))
}

/// Which requests a transport streams to disk. The gateway's answer is `isStreamingUpload`; the
/// share service (`baton-share`) passes its own, for the one route where it takes a song.
public typealias StreamingPredicate = @Sendable (StreamingUpload.Request) -> Bool

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
                         extraHeaders: [String: String] = [:], representedLength: Int? = nil) -> Data {
    var head = "HTTP/1.1 \(status)\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Content-Length: \(representedLength.flatMap { $0 >= 0 ? $0 : nil } ?? payload.count)\r\n"
    for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) where name.lowercased() != "content-length" {
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
    let streamsBody: StreamingPredicate
    let log: @Sendable (String) -> Void

    public init(stagingDirectory: URL,
                maximumBodyBytes: Int = FileStore.defaultMaximumFileBytes,
                streamsBody: @escaping StreamingPredicate = isStreamingUpload,
                log: @escaping @Sendable (String) -> Void = RequestLog.standardOutput) {
        self.stagingDirectory = stagingDirectory
        self.maximumBodyBytes = maximumBodyBytes
        self.streamsBody = streamsBody
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
                        defer { sink.cancel() }
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
            if let head = StreamingUpload.peekHead(buffer), streamsBody(head) {
                let sink = StreamingUpload(stagingDirectory: stagingDirectory,
                                           maximumBodyBytes: maximumBodyBytes)
                switch sink.consume(buffer) {
                case .needMore:
                    receive(connection, buffer: Data(), sink: sink, started: started, handle: handle, upload: upload)
                case let .complete(url, request):
                    Task {
                        defer { sink.cancel() }
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

/// Linux: a plain blocking accept loop, one thread per connection. The
/// gateway serves a household, not a datacenter — a thread-per-connection model
/// is the right amount of machinery, and keeps the dependency list empty.
///
/// Compiled on Apple platforms too, where `DefaultTransport` is the Network one and this is
/// reached only by its tests. That is deliberate: this is the code that runs in production, and
/// leaving it behind an `#else` meant a Mac could not so much as typecheck it.
/// Derived from the accepted socket, never an HTTP header or claimed hostname.
/// The current listener is IPv4; only the kernel-reported 127/8 peer is trusted.
/// Unsupported address families and failed peer lookup remain unknown and denied.
public enum ConnectionPeer: Sendable, Equatable {
    case unknown, loopback, other

    static func socketPeer(_ fd: Int32) -> ConnectionPeer {
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &size)
            }
        }
        guard result == 0, address.sin_family == sa_family_t(AF_INET),
              size >= socklen_t(MemoryLayout<sockaddr_in>.size) else { return .unknown }
        return UInt32(bigEndian: address.sin_addr.s_addr) >> 24 == 127 ? .loopback : .other
    }
}

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
    /// How many connections may be in flight at once.
    ///
    /// A thread per connection is only bounded if something bounds it, and what used to bound it
    /// was the cooperative pool running out, which is the defect rather than the design. Past
    /// this many, a connection is answered `503` and closed rather than queued: a gateway for a
    /// household never reaches it, and a client that does is better told than left hanging.
    let maximumConcurrentConnections: Int
    let loopbackOnly: Bool
    let responseCapacity: ResponseCapacity?
    let reserveResponseBytes: @Sendable (HTTPRequestMessage) -> Int
    let streamsBody: StreamingPredicate
    /// Asked once an upload's head has arrived and before it reserves staging space (TBX-1000000496
    /// D-15). `.refuse` answers there and then; `.admit` lets it stream, and its `release` runs
    /// once when that connection ends, however it ends, so the admitter can count uploads in
    /// flight. Without it, anyone could reserve the staging ceiling from a declared
    /// `Content-Length` alone, before the handler ever saw who was asking.
    let admitsUpload: UploadAdmitter
    /// The most an upload may take from its head to its last byte, or nil for no limit. The read
    /// timeout is per read, so a peer sending a byte now and then otherwise holds its reservation
    /// for as long as it likes. Checked after each read, so it can overrun by one read timeout.
    let uploadDeadline: TimeInterval?
    let log: @Sendable (String) -> Void

    public enum UploadAdmission: Sendable {
        case refuse(Data)
        case admit(release: @Sendable () -> Void)
        public static let admitted = UploadAdmission.admit(release: {})
    }
    public typealias UploadAdmitter = @Sendable (StreamingUpload.Request) -> UploadAdmission

    public init(stagingDirectory: URL,
                maximumBodyBytes: Int = FileStore.defaultMaximumFileBytes,
                readTimeout: TimeInterval = 15,
                maximumConcurrentConnections: Int = 128,
                loopbackOnly: Bool = false,
                responseCapacity: ResponseCapacity? = nil,
                reserveResponseBytes: @escaping @Sendable (HTTPRequestMessage) -> Int = { _ in 0 },
                streamsBody: @escaping StreamingPredicate = isStreamingUpload,
                admitsUpload: @escaping UploadAdmitter = { _ in .admitted },
                uploadDeadline: TimeInterval? = nil,
                log: @escaping @Sendable (String) -> Void = RequestLog.standardOutput) {
        self.stagingDirectory = stagingDirectory
        self.maximumBodyBytes = maximumBodyBytes
        self.streamsBody = streamsBody
        self.admitsUpload = admitsUpload
        self.uploadDeadline = uploadDeadline
        self.readTimeout = readTimeout
        self.maximumConcurrentConnections = max(1, maximumConcurrentConnections)
        self.loopbackOnly = loopbackOnly
        self.responseCapacity = responseCapacity
        self.reserveResponseBytes = reserveResponseBytes
        self.log = log
    }

    /// Nonqueueing admission BEFORE a handler can allocate a large response. The caller reserves
    /// its worst-case retained payload, serializer copy and headers, not a client-claimed size.
    /// A reservation survives handler return and is released only after transmission/cancellation.
    public final class ResponseCapacity: @unchecked Sendable {
        private let lock = NSLock()
        private var used = 0
        public let maximumBytes: Int
        public let writeTimeout: TimeInterval
        public init(maximumBytes: Int, writeTimeout: TimeInterval = 60) {
            self.maximumBytes = max(1, maximumBytes)
            self.writeTimeout = max(0.1, min(60, writeTimeout))
        }
        func take(_ bytes: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard bytes > 0, bytes <= maximumBytes - used else { return false }
            used += bytes
            return true
        }
        func release(_ bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            used -= bytes
        }
    }

    /// How many connection threads are alive, so the cap above can mean something.
    final class LiveConnections: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        /// Takes a slot, or reports that the cap is already reached.
        func take(limit: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard count < limit else { return false }
            count += 1
            return true
        }
        func release() {
            lock.lock()
            count -= 1
            lock.unlock()
        }
    }

    /// A listening socket a test can shut down. `serve` parks on `dispatchMain()` and never
    /// returns, which is right for a daemon and impossible to drive from a test.
    public struct Listener: Sendable {
        public let fileDescriptor: Int32
        public let port: UInt16
        public func stop() { close(fileDescriptor) }
    }

    public typealias PeerHandler = @Sendable (HTTPRequestMessage, ConnectionPeer) async -> Data

    public func serve(
        port: UInt16,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) throws {
        try serve(port: port, handle: handle, upload: upload, peerHandle: nil)
    }

    public func serve(
        port: UInt16,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data,
        peerHandle: PeerHandler?
    ) throws {
        _ = try start(port: port, handle: handle, upload: upload, peerHandle: peerHandle)
        dispatchMain()
    }

    /// Bind, listen, and accept on a background thread. Returns once the socket is listening.
    ///
    /// Pass port 0 to be given a free one; the `Listener` reports which.
    @discardableResult
    public func start(
        port: UInt16,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data,
        peerHandle: PeerHandler? = nil
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
        address.sin_addr = in_addr(s_addr: loopbackOnly ? inet_addr("127.0.0.1") : INADDR_ANY)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound >= 0 else {
            close(listenFD)
            throw GatewayError.socket("bind(:\(port)) failed. Is the port taken?")
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
        let connectionCap = maximumConcurrentConnections
        let live = LiveConnections()
        let sink = log
        let streams = streamsBody
        let admits = admitsUpload
        let uploadLimit = uploadDeadline
        let responseLimit = responseCapacity
        let reservation = reserveResponseBytes
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
                // A thread of this connection's own, not a task on the cooperative pool
                // (TBX-5346, TBX-5325, TBX-5308 S-F13).
                //
                // `handleConnection` reads with a blocking `read(2)`. Run inside `Task.detached`
                // that read held one of the cooperative pool's threads (about one per core)
                // for as long as it blocked, so roughly processor-count silent peers left
                // nothing to run the next connection on, and every other detached task in the
                // process stopped with them: the device link's actor jobs, the expiry timers,
                // the next `/health`. `SO_RCVTIMEO` (below) bounded how long that lasted; it
                // could not stop it happening. Owning the thread is what stops it happening,
                // because a thread that is ours is allowed to block and nothing is queued
                // behind it.
                //
                // The cost is a real thread per live connection, which is why there is a cap.
                guard live.take(limit: connectionCap) else {
                    // Say so rather than dropping the connection silently: a bare reset is
                    // indistinguishable from a gateway that has died.
                    Self.setTimeout(clientFD, SO_SNDTIMEO, 1)
                    Self.write(clientFD, httpErrorResponse(status: "503 Service Unavailable",
                                                           message: "too many connections"))
                    close(clientFD)
                    continue
                }
                let worker = Thread {
                    defer { live.release() }
                    Self.handleConnection(
                        clientFD, stagingDirectory: staging, maximumBodyBytes: bodyCap,
                        readTimeout: deadline, streamsBody: streams,
                        admitsUpload: admits, uploadDeadline: uploadLimit, log: sink,
                        responseCapacity: responseLimit, reserveResponseBytes: reservation,
                        handle: handle, upload: upload, peerHandle: peerHandle
                    )
                }
                worker.name = "baton-gateway-connection"
                worker.stackSize = 512 * 1024
                worker.start()
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()
        return Listener(fileDescriptor: listenFD, port: boundPort)
    }

    /// Synchronous on purpose: it runs on a thread of its own, where blocking is what threads
    /// are for. The two things that stay `async` are `handle` and `upload`, because that is
    /// where the gateway's actors are; `awaiting` puts each of those on the cooperative pool and
    /// waits here for the answer.
    static func handleConnection(
        _ fd: Int32,
        stagingDirectory: URL,
        maximumBodyBytes: Int,
        readTimeout: TimeInterval,
        streamsBody: StreamingPredicate = isStreamingUpload,
        admitsUpload: UploadAdmitter = { _ in .admitted },
        uploadDeadline: TimeInterval? = nil,
        log: @escaping @Sendable (String) -> Void,
        responseCapacity: ResponseCapacity? = nil,
        reserveResponseBytes: @escaping @Sendable (HTTPRequestMessage) -> Int = { _ in 0 },
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data,
        peerHandle: PeerHandler? = nil
    ) {
        defer { close(fd) }
        setReadTimeout(fd, readTimeout)
        let started = Date()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var sink: StreamingUpload?
        var uploadEnds: Date?
        var releaseAdmission: (@Sendable () -> Void)?
        defer { releaseAdmission?() }
        // A connection that dies mid-upload must not leave its partial file behind.
        defer { sink?.cancel() }

        func answer(_ response: Data, method: String, path: String, userAgent: String?, timeout: TimeInterval? = nil) {
            write(fd, response, timeout: timeout)
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
                if let uploadEnds, Date() > uploadEnds {
                    sink.cancel()
                    answer(httpErrorResponse(status: "408 Request Timeout", message: "the upload took too long"),
                           method: sink.parsedRequest?.method ?? "PUT", path: sink.parsedRequest?.path ?? "/v1/files/",
                           userAgent: sink.parsedRequest?.header("user-agent"))
                    lingerAfterEarlyAnswer(fd)
                    return
                }
                switch sink.consume(slice) {
                case .needMore:
                    continue
                case let .complete(url, request):
                    answer(awaiting { await upload(request, url) },
                           method: request.method, path: request.path,
                           userAgent: request.header("user-agent"))
                    return
                case let .rejected(status, message):
                    answer(httpErrorResponse(status: status, message: message),
                           method: sink.parsedRequest?.method ?? "PUT",
                           path: sink.parsedRequest?.path ?? "/v1/files/",
                           userAgent: sink.parsedRequest?.header("user-agent"))
                    lingerAfterEarlyAnswer(fd)
                    return
                }
            }

            buffer.append(slice)

            // Decide, once the head has arrived, whether this belongs on the streaming path.
            if let head = StreamingUpload.peekHead(buffer), streamsBody(head) {
                switch admitsUpload(head) {
                case let .refuse(refusal):
                    answer(refusal, method: head.method, path: head.path, userAgent: head.header("user-agent"))
                    lingerAfterEarlyAnswer(fd)
                    return
                case let .admit(release):
                    releaseAdmission = release
                }
                let started = StreamingUpload(stagingDirectory: stagingDirectory,
                                              maximumBodyBytes: maximumBodyBytes)
                sink = started
                uploadEnds = uploadDeadline.map { Date().addingTimeInterval($0) }
                switch started.consume(buffer) {
                case .needMore:
                    continue
                case let .complete(url, request):
                    answer(awaiting { await upload(request, url) },
                           method: request.method, path: request.path,
                           userAgent: request.header("user-agent"))
                    return
                case let .rejected(status, message):
                    answer(httpErrorResponse(status: status, message: message),
                           method: head.method, path: head.path,
                           userAgent: head.header("user-agent"))
                    lingerAfterEarlyAnswer(fd)
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
                let bytes = reserveResponseBytes(request)
                let capacity = bytes > 0 ? responseCapacity : nil
                if let capacity, !capacity.take(bytes) {
                    answer(httpResponse(status: "503 Service Unavailable", contentType: "application/json",
                                        payload: Data(#"{"code":"capacity","error":"Too many active transfers. Try again shortly."}"#.utf8),
                                        extraHeaders: ["Cache-Control": "private, no-store", "Retry-After": "1"]),
                           method: request.method, path: request.path, userAgent: request.headers["user-agent"], timeout: 1)
                    return
                }
                // Clearing the response precedes releasing admission, including when the peer
                // disconnects. No large Data may outlive the reserved sending connection.
                var response = Data()
                defer { response = Data(); capacity?.release(bytes) }
                let peer = ConnectionPeer.socketPeer(fd)
                response = awaiting {
                    if let peerHandle { return await peerHandle(request, peer) }
                    return await handle(request)
                }
                answer(response, method: request.method, path: request.path,
                       userAgent: request.headers["user-agent"], timeout: capacity?.writeTimeout)
                return
            }
        }
    }

    /// Runs one async step on the cooperative pool and waits here for its answer.
    ///
    /// The read loop is deliberately synchronous now and runs on a thread this
    /// transport owns, so blocking it costs nothing anybody else is waiting on. `handle` and
    /// `upload` stay `async` because that is where the gateway's actors live, and they belong on
    /// the pool. This is the seam between the two, and it is the whole of the "own
    /// synchronization" the earlier note worried about.
    private static func awaiting(_ operation: @escaping @Sendable () async -> Data) -> Data {
        let answer = Box()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            answer.value = await operation()
            finished.signal()
        }
        finished.wait()
        return answer.value
    }

    /// One `Data` handed from the task above back to the thread below.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var value: Data {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// After answering an upload before its body has all arrived: stop sending, then read and
    /// discard what is still on its way for a bounded while before the close. Closing with unread
    /// data resets the connection, and nginx (request buffering off) then fails its next write
    /// upstream with EPIPE and answers 502 in place of the 401, 404, 408 or 413 (TBX-1000000496
    /// D-15; seen through nginx 1.31.6 in the share-player walk). Ends at the peer's own close,
    /// after `seconds`, or after `maximumBytes`, whichever comes first.
    static func lingerAfterEarlyAnswer(_ fd: Int32, seconds: TimeInterval = 5, maximumBytes: Int = 32 << 20) {
        _ = shutdown(fd, Int32(SHUT_WR))
        setReadTimeout(fd, 0.5)
        let end = ProcessInfo.processInfo.systemUptime + seconds
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var drained = 0
        while ProcessInfo.processInfo.systemUptime < end, drained < maximumBytes {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            drained += count
        }
    }

    /// `SO_RCVTIMEO`, so a silent peer cannot hold this connection (and the thread running it)
    /// open for ever.
    ///
    /// Still here after TBX-5346 moved the read off the cooperative pool, and still the thing
    /// that ends a silent connection: owning the thread means one silent peer no longer costs
    /// anybody else anything, but it does not make the peer go away.
    private static func setReadTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        setTimeout(fd, SO_RCVTIMEO, seconds)
    }

    /// `SO_RCVTIMEO` or `SO_SNDTIMEO`, in seconds. Both take a `timeval`.
    static func setTimeout(_ fd: Int32, _ option: Int32, _ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let whole = seconds.rounded(.down)
        var timeout = timeval(tv_sec: Int(whole),
                              tv_usec: .init((seconds - whole) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes every byte — a single `write` may be partial on a socket.
    static func write(_ fd: Int32, _ data: Data, timeout: TimeInterval? = nil) {
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        let originalFlags = deadline == nil ? -1 : fcntl(fd, F_GETFL, 0)
        if deadline != nil {
            guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else { return }
        }
        defer { if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags) } }
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                if let deadline {
                    let left = deadline - ProcessInfo.processInfo.systemUptime
                    guard left > 0 else { return }
                    // SO_SNDTIMEO alone is not an absolute deadline for a partial blocking
                    // send. Poll a nonblocking socket, with the same monotonic deadline on
                    // every iteration. Neither slow progress nor EINTR resets that clock.
                    var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&event, 1, Int32(max(1, min(1000, left * 1000))))
                    if ready < 0 && errno == EINTR { continue }
                    if ready == 0 { continue }
                    guard ready > 0, event.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { return }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return }
                }
                let count = deadline == nil ? remaining : min(remaining, 65_536)
                // `send` with MSG_NOSIGNAL rather than `write`, so a peer that has gone away
                // surfaces as EPIPE here instead of as a signal that kills the process
                // (TBX-5308, S-F4). The flag is Linux-only; on Apple the `signal` call in
                // `start` is what carries the guarantee, which is why that call is not
                // conditional and why no `SO_NOSIGPIPE` is set here — the Mac tests then
                // exercise exactly the mechanism Linux ships with.
                #if canImport(Glibc)
                let written = send(fd, pointer, count, Int32(MSG_NOSIGNAL))
                #else
                let written = send(fd, pointer, count, 0)
                #endif
                if written < 0 && (errno == EINTR || (deadline != nil && (errno == EAGAIN || errno == EWOULDBLOCK))) { continue }
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
