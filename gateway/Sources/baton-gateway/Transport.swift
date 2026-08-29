import BatonGatewayCore
import BatonMCPProtocol
import Foundation
#if canImport(Network)
import Network
#elseif canImport(Glibc)
import Glibc
#endif

/// The one platform-specific thing in the gateway: accepting TCP connections.
/// Apple platforms use Network.framework; Linux uses POSIX sockets, so the
/// service runs next to Navidrome on a home server rather than only on a Mac.
///
/// Everything above this line — parsing, auth, routing, the agent loop — is the
/// same code on both.
protocol ServerTransport {
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
func isStreamingUpload(_ request: StreamingUpload.Request) -> Bool {
    request.method == "PUT" && request.path.hasPrefix("/v1/files/")
}

/// The staging area for uploads in flight. Beside the store rather than in `/tmp`, so a commit is
/// a rename within one filesystem — which is what makes it atomic — rather than a copy across two.
let uploadStagingDirectory: URL = filesDirectory.appendingPathComponent("staging", isDirectory: true)

/// Renders a response the way both transports send it.
func httpResponse(status: String, body: String) -> Data {
    httpResponse(status: status, contentType: "application/json", payload: Data(body.utf8))
}

/// The same, for a body that is not text — serving a stored file back.
///
/// **Known limit, stated rather than hidden:** the payload is held in memory to send it, so a
/// download of a 64 MB file briefly costs 64 MB. Uploads stream to disk because that is the
/// direction where an unbounded body arrives from outside; a download is bounded by what this
/// gateway already chose to store. Streaming the response needs a send path that takes a file
/// rather than `Data`, on both transports, and that is worth doing separately rather than
/// bundling it in here.
func httpResponse(status: String, contentType: String, payload: Data,
                  extraHeaders: [String: String] = [:]) -> Data {
    var head = "HTTP/1.1 \(status)\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Content-Length: \(payload.count)\r\n"
    for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
        head += "\(name): \(value)\r\n"
    }
    head += "Connection: close\r\n\r\n"
    return Data(head.utf8) + payload
}

#if canImport(Network)

/// Apple: NWListener, the same primitive the app's MCP server uses.
struct NetworkTransport: ServerTransport {
    func serve(
        port: UInt16,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            receive(connection, buffer: Data(), sink: nil, handle: handle, upload: upload)
        }
        listener.start(queue: .main)
        dispatchMain()
    }

    private func receive(
        _ connection: NWConnection, buffer: Data, sink: StreamingUpload?,
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
                    receive(connection, buffer: Data(), sink: sink, handle: handle, upload: upload)
                case let .complete(url, request):
                    Task { send(connection, await upload(request, url)) }
                case let .rejected(status, message):
                    send(connection, httpResponse(status: status, body: #"{"error":"\#(message)"}"#))
                }
                return
            }

            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.isEmpty { connection.cancel(); return }

            // Decide, once the head has arrived, whether this belongs on the streaming path.
            if let head = StreamingUpload.peekHead(buffer), isStreamingUpload(head) {
                let sink = StreamingUpload(stagingDirectory: uploadStagingDirectory,
                                           maximumBodyBytes: FileStore.defaultMaximumFileBytes)
                switch sink.consume(buffer) {
                case .needMore:
                    receive(connection, buffer: Data(), sink: sink, handle: handle, upload: upload)
                case let .complete(url, request):
                    Task { send(connection, await upload(request, url)) }
                case let .rejected(status, message):
                    send(connection, httpResponse(status: status, body: #"{"error":"\#(message)"}"#))
                }
                return
            }

            switch HTTPRequestMessage.parse(buffer) {
            case .incomplete:
                receive(connection, buffer: buffer, sink: nil, handle: handle, upload: upload)
            case .tooLarge, .malformed:
                send(connection, httpResponse(status: "400 Bad Request", body: #"{"error":"bad request"}"#))
            case .complete(let request):
                Task {
                    let response = await handle(request)
                    send(connection, response)
                }
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

typealias DefaultTransport = NetworkTransport

#else

/// Linux: a plain blocking accept loop, one detached task per connection. The
/// gateway serves a household, not a datacenter — a thread-per-connection model
/// is the right amount of machinery, and keeps the dependency list empty.
struct POSIXTransport: ServerTransport {
    func serve(
        port: UInt16,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) throws {
        let listenFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
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
        guard bound >= 0 else { throw GatewayError.socket("bind(:\(port)) failed — is the port taken?") }
        guard listen(listenFD, 32) >= 0 else { throw GatewayError.socket("listen() failed") }

        // The accept loop must NOT run on the main thread: request handling hops
        // to the main actor, and a blocking loop there starves it — the server
        // accepts connections and then answers none of them. Park main with
        // dispatchMain() (as the Apple path does) and accept on a thread.
        let thread = Thread {
            while true {
                let clientFD = accept(listenFD, nil, nil)
                guard clientFD >= 0 else { continue }
                Task.detached {
                    await Self.handleConnection(clientFD, handle: handle, upload: upload)
                }
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()
        dispatchMain()
    }

    private static func handleConnection(
        _ fd: Int32,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data,
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data
    ) async {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var sink: StreamingUpload?
        // A connection that dies mid-upload must not leave its partial file behind.
        defer { sink?.cancel() }

        while true {
            let bytes = read(fd, &chunk, chunk.count)
            if bytes <= 0 { return }
            let slice = Data(chunk[0 ..< bytes])

            if let sink {
                switch sink.consume(slice) {
                case .needMore:
                    continue
                case let .complete(url, request):
                    write(fd, await upload(request, url))
                    return
                case let .rejected(status, message):
                    write(fd, httpResponse(status: status, body: #"{"error":"\#(message)"}"#))
                    return
                }
            }

            buffer.append(slice)

            // Decide, once the head has arrived, whether this belongs on the streaming path.
            if let head = StreamingUpload.peekHead(buffer), isStreamingUpload(head) {
                let started = StreamingUpload(stagingDirectory: uploadStagingDirectory,
                                              maximumBodyBytes: FileStore.defaultMaximumFileBytes)
                sink = started
                switch started.consume(buffer) {
                case .needMore:
                    continue
                case let .complete(url, request):
                    write(fd, await upload(request, url))
                    return
                case let .rejected(status, message):
                    write(fd, httpResponse(status: status, body: #"{"error":"\#(message)"}"#))
                    return
                }
            }

            switch HTTPRequestMessage.parse(buffer) {
            case .incomplete:
                continue // keep reading
            case .tooLarge, .malformed:
                write(fd, httpResponse(status: "400 Bad Request", body: #"{"error":"bad request"}"#))
                return
            case .complete(let request):
                let response = await handle(request)
                write(fd, response)
                return
            }
        }
    }

    /// Writes every byte — a single `write` may be partial on a socket.
    private static func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Glibc.write(fd, pointer, remaining)
                if written <= 0 { return }
                pointer += written
                remaining -= written
            }
        }
    }
}

typealias DefaultTransport = POSIXTransport

#endif

enum GatewayError: Error, CustomStringConvertible {
    case socket(String)
    var description: String {
        switch self {
        case .socket(let detail): detail
        }
    }
}
