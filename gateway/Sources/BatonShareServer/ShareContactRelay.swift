import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Fixed loopback transport; no credential forwarding, redirects, caching or payload logs.
enum ShareContactRelay {
    enum Preparation {
        case refused(ShareResponse)
        case ready(UInt16, String, Data)
    }
    static var unavailable: ShareResponse {
        .error(503, "contact_unavailable", "Private contact is unavailable. Try again later.",
               headers: ["Cache-Control": "private, no-store"])
    }
    /// Literal AF_INET loopback avoids DNS, URLSession proxy discovery and redirects.
    ///
    /// The exchange blocks in poll(2) for up to 5 s, so it runs on a thread of its own and the
    /// caller is resumed when it ends. On the cooperative pool, a few relays at once held the
    /// threads the rest of the service, and the worker's callback into it, need.
    static func forward(port: UInt16, path: String, body: Data) async throws -> ShareResponse {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try exchange(port: port, path: path, body: body) })
            }
            thread.name = "baton-share-contact-relay"
            thread.start()
        }
    }

    private static func exchange(port: UInt16, path: String, body: Data) throws -> ShareResponse {
        #if os(Linux)
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw RelayFailure.unavailable }
        defer { close(descriptor) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw RelayFailure.unavailable }
        #if canImport(Darwin)
        var one: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw RelayFailure.unavailable }
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw RelayFailure.unavailable }
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw RelayFailure.unavailable }
        }
        let head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let wire = Data(head.utf8) + body
        var sent = 0
        while sent < wire.count {
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            #if os(Linux)
            let flags = Int32(MSG_NOSIGNAL)
            #else
            let flags: Int32 = 0
            #endif
            let count = wire.withUnsafeBytes { bytes in send(descriptor, bytes.baseAddress!.advanced(by: sent), wire.count - sent, flags) }
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw RelayFailure.unavailable }
            sent += count
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var parsed: (Int, Int, Int)?
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw RelayFailure.unavailable }
            received.append(contentsOf: buffer.prefix(count))
            guard received.count <= 65536 + 8192 else { throw RelayFailure.unavailable }
            if parsed == nil {
                if let boundary = received.range(of: Data("\r\n\r\n".utf8)) {
                    guard boundary.lowerBound <= 8192, let text = String(data: received[..<boundary.lowerBound], encoding: .utf8) else { throw RelayFailure.unavailable }
                    let lines = text.components(separatedBy: "\r\n")
                    let status = lines[0].split(separator: " ")
                    guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])), let code = Int(status[1]), [200, 400, 403, 503].contains(code) else { throw RelayFailure.unavailable }
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2 else { throw RelayFailure.unavailable }
                        let key = parts[0].lowercased()
                        guard headers[key] == nil else { throw RelayFailure.unavailable }
                        headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                    guard headers["transfer-encoding"] == nil, headers["location"] == nil,
                          headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
                          let size = Int(headers["content-length"] ?? ""), (0...65536).contains(size) else { throw RelayFailure.unavailable }
                    parsed = (code, boundary.upperBound, size)
                } else if received.count > 8192 { throw RelayFailure.unavailable }
            }
            if let (code, offset, size) = parsed, received.count >= offset + size {
                guard received.count == offset + size else { throw RelayFailure.unavailable }
                let payload = Data(received[offset...])
                guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else { throw RelayFailure.unavailable }
                return ShareResponse(status: code, body: payload)
            }
        }
    }
    private enum RelayFailure: Error { case unavailable }
    private static func wait(_ descriptor: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw RelayFailure.unavailable }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, Int32((deadline - now) / 1_000_000 + 1))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, item.revents & events != 0 else { throw RelayFailure.unavailable }
            return
        }
    }

}

extension ShareService {
    func prepareContactRelay(_ request: HTTPRequestMessage) -> ShareContactRelay.Preparation {
        let hidden = ShareResponse.error(404, "not_found", "No such route.", headers: ["Cache-Control": "private, no-store"])
        let prefix = "/v1/share/contact/private/"
        let purpose = ["enroll": "enroll", "verify": "verify", "withdraw": "withdraw", "status": "status", "access": "caseAccess"]
        let endpoint = String(request.path.dropFirst(prefix.count))
        guard let port = config.contactBridge?.relayPort, let scope = purpose[endpoint],
              request.method == "POST", request.query.isEmpty, request.body.count <= 65536,
              request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json",
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return .refused(hidden) }
        guard let owner = sharer(bearer: request.bearerToken) else {
            return .refused(.error(401, "unauthorized", "Installation authorization required.", headers: ["Cache-Control": "private, no-store"]))
        }
        let fields: Set<String> = endpoint == "enroll" ? ["authorization", "address", "consent", "include"]
            : ["verify", "access"].contains(endpoint) ? ["authorization", "code"] : ["authorization"]
        guard Set(object.keys) == fields, let grant = object["authorization"] as? String,
              grant.count == 43, Base64URL.decode(grant)?.count == 32 else { return .refused(hidden) }
        do {
            guard let row = try store.database.query("SELECT installation FROM contact_authorizations WHERE digest=? AND purpose=? AND expires>?", [
                .text(ShareHash.secretDigest(grant)), .text(scope), .int(now)]).first,
                  row["installation"]?.text == owner.digest else { return .refused(hidden) }
        } catch { return .refused(ShareContactRelay.unavailable) }
        guard limiter.allow("contactRelay:" + owner.digest, limit: 100, per: 3600, now: now) else {
            return .refused(.error(429, "rate_limited", "Try again later.", headers: ["Cache-Control": "private, no-store"]))
        }
        guard activeContactRelays < 8 else { return .refused(ShareContactRelay.unavailable) }
        activeContactRelays += 1
        // Read-only grant binding here. Only private readback durably consumes it.
        return .ready(port, "/" + endpoint, request.body)
    }
}
