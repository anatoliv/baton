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
    /// Serves forever. `handle` receives one parsed request and returns the raw
    /// HTTP response bytes to write back.
    func serve(port: UInt16, handle: @escaping @Sendable (HTTPRequestMessage) async -> Data) throws
}

/// Renders a response the way both transports send it.
func httpResponse(status: String, body: String) -> Data {
    let payload = Data(body.utf8)
    let head = """
    HTTP/1.1 \(status)\r
    Content-Type: application/json\r
    Content-Length: \(payload.count)\r
    Connection: close\r
    \r\n
    """
    return Data(head.utf8) + payload
}

#if canImport(Network)

/// Apple: NWListener, the same primitive the app's MCP server uses.
struct NetworkTransport: ServerTransport {
    func serve(port: UInt16, handle: @escaping @Sendable (HTTPRequestMessage) async -> Data) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            receive(connection, buffer: Data(), handle: handle)
        }
        listener.start(queue: .main)
        dispatchMain()
    }

    private func receive(
        _ connection: NWConnection, buffer: Data,
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || (isComplete && buffer.isEmpty) {
                connection.cancel()
                return
            }
            switch HTTPRequestMessage.parse(buffer) {
            case .incomplete:
                receive(connection, buffer: buffer, handle: handle)
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
    func serve(port: UInt16, handle: @escaping @Sendable (HTTPRequestMessage) async -> Data) throws {
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
                    await Self.handleConnection(clientFD, handle: handle)
                }
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()
        dispatchMain()
    }

    private static func handleConnection(
        _ fd: Int32, handle: @escaping @Sendable (HTTPRequestMessage) async -> Data
    ) async {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)

        while true {
            let bytes = read(fd, &chunk, chunk.count)
            if bytes <= 0 { return }
            buffer.append(contentsOf: chunk[0 ..< bytes])

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
