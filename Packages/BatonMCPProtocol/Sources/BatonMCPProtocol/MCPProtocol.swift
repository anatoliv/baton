import Foundation

// The MCP transport protocol layer — JSON-RPC envelopes, the security-hardened HTTP/1.1
// request parser, response framing, and the constant-time token compare. Fourth leaf of the
//  module split: pure (`Foundation` only), zero app dependencies. The MCP *server*
// (BatonMCPServer, which ties into MusicModel) stays in the app and re-exports this module.

// MARK: - Constants

/// Protocol/version constants and hard limits for the Baton MCP server. Mirrors the
/// hardening of Tonebox's in-app server (1 MB request cap, current MCP revision).
public enum BatonMCPConstants {
    /// The MCP protocol revision Baton speaks. Matches Tonebox's server.
    public static let protocolVersion = "2025-06-18"
    /// Server identity reported in `initialize`.
    public static let serverName = "baton"

    /// The app version reported to agents — in `initialize`'s `serverInfo.version` and as
    /// `app.version` in the `mcp.json` discovery file.
    ///
    /// Read from the host bundle, not hardcoded. A literal here does not track releases: it
    /// said "0.1.0" for seven of them, so every MCP client was told Baton was 0.1.0 while the
    /// app shipped 0.6.x. Still Foundation-only, so this module keeps its zero app dependencies.
    public static var serverVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? unknownVersion
    }

    /// Reported when there's no host bundle version to read (e.g. a bare test runner). Deliberately
    /// not a real-looking version, so a misconfiguration is obvious rather than silently plausible.
    public static let unknownVersion = "0.0.0"
    /// Reject any single HTTP request body larger than this (defensive; the tool
    /// payloads are tiny).
    public static let maxRequestBytes = 1_048_576 // 1 MB
    /// First port to try; the server walks upward if it's taken.
    public static let defaultPort: UInt16 = 8787
    /// How many consecutive ports to try before giving up.
    public static let portScanRange = 16
    /// UserDefaults key holding the persisted bearer token.
    public static let tokenDefaultsKey = "baton.mcp.token"
    /// Resource URIs.
    public static let nowPlayingURI = "baton://now-playing"
    public static let queueURI = "baton://queue"
}

// MARK: - JSON-RPC

/// A parsed JSON-RPC 2.0 request (or notification, when `id` is nil).
public struct JSONRPCRequest {
    public let id: Any? // String, Int, or NSNull — echoed verbatim in the response.
    public let method: String
    public let params: [String: Any]
    /// A notification (no `id`) expects no response.
    public var isNotification: Bool { id == nil }

    public init(id: Any?, method: String, params: [String: Any]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum JSONRPCError {
    public static let parseError = -32_700
    public static let invalidRequest = -32_600
    public static let methodNotFound = -32_601
    public static let invalidParams = -32_602
    public static let internalError = -32_603
}

/// Builds JSON-RPC response envelopes as `[String: Any]` dictionaries ready for
/// `JSONSerialization`.
public enum JSONRPC {
    public static func result(id: Any?, _ result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    public static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    /// A server-initiated notification (no `id`) — e.g. `notifications/resources/updated`.
    public static func notification(method: String, params: [String: Any]? = nil) -> [String: Any] {
        var out: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { out["params"] = params }
        return out
    }

    /// Serialize a JSON object to compact UTF-8 data. Never throws in practice — the
    /// dictionaries built here are always JSON-legal — but falls back to an empty
    /// object rather than crashing.
    public static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

// MARK: - HTTP request parsing

/// A minimally-parsed HTTP/1.1 request read off an `NWConnection`. Only what the MCP
/// transport needs: method, path, a few headers, and the body.
public struct HTTPRequestMessage: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String] // lower-cased keys
    public let body: Data

    public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Extracts the bearer token from `Authorization: Bearer <token>` only. The `?token=`
    /// query form was dropped so the secret can't leak into logs/referrers/history.
    public var bearerToken: String? {
        guard let auth = headers["authorization"] else { return nil }
        let parts = auth.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    public var acceptsEventStream: Bool {
        (headers["accept"] ?? "").lowercased().contains("text/event-stream")
    }

    public var sessionID: String? { headers["mcp-session-id"] }

    /// Parse a full request from raw bytes. Returns nil if headers are incomplete
    /// (caller keeps reading) — or `.some(nil)` semantics are avoided by returning
    /// `.incomplete`.
    public enum ParseResult: Sendable {
        case complete(HTTPRequestMessage)
        case incomplete
        case tooLarge
        case malformed
    }

    public static func parse(_ buffer: Data) -> ParseResult {
        // Find the CRLFCRLF header/body separator.
        guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > BatonMCPConstants.maxRequestBytes { return .tooLarge }
            return .incomplete
        }
        let headerData = buffer.subdata(in: buffer.startIndex ..< headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .malformed }
        var lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return .malformed }
        let method = String(requestParts[0]).uppercased()
        let rawTarget = String(requestParts[1])

        // Split path?query.
        var path = rawTarget
        var query: [String: String] = [:]
        if let qIdx = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[rawTarget.startIndex ..< qIdx])
            let queryString = String(rawTarget[rawTarget.index(after: qIdx)...])
            for pair in queryString.split(separator: "&") where !pair.isEmpty {
                // Keep empty subsequences so "=", "=v", and "k=" parse without
                // trapping on kv[0] (a bare "=" previously crashed pre-auth).
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let rawKey = kv[0]
                guard !rawKey.isEmpty else { continue } // skip "=value" with no key
                let key = rawKey.removingPercentEncoding ?? String(rawKey)
                let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex ..< colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Reject chunked transfer encoding explicitly (unsupported) rather than
        // silently treating it as a zero-length body. (Fuller read-deadline and a
        // 501 response are ; here we only need to not misparse it.)
        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            return .malformed
        }
        // Determine body length; wait for the whole body before completing.
        // Content-Length must be a non-negative integer within the cap: a negative
        // value previously passed the `> maxRequestBytes` check and then built an
        // inverted Data range (`bodyStart ..< bodyStart-1`), trapping pre-auth.
        let bodyStart = headerEndRange.upperBound
        let available = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .malformed }
            contentLength = n
        } else {
            contentLength = 0
        }
        if contentLength > BatonMCPConstants.maxRequestBytes { return .tooLarge }
        if available < contentLength { return .incomplete }
        let body = buffer.subdata(in: bodyStart ..< buffer.index(bodyStart, offsetBy: contentLength))

        return .complete(HTTPRequestMessage(
            method: method, path: path, query: query, headers: headers, body: body
        ))
    }
}

// MARK: - HTTP response building

/// Small helpers for framing HTTP/1.1 responses (single-shot JSON and SSE headers).
public enum HTTPResponse {
    /// A complete `Connection: close` JSON response.
    public static func json(_ object: [String: Any], status: String = "200 OK", sessionID: String? = nil) -> Data {
        let body = JSONRPC.data(object)
        return raw(body, contentType: "application/json", status: status, sessionID: sessionID)
    }

    /// An empty response (used for accepted notifications → 202).
    public static func empty(status: String) -> Data {
        raw(Data(), contentType: "application/json", status: status)
    }

    public static func raw(_ body: Data, contentType: String, status: String, sessionID: String? = nil) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if let sessionID { head += "Mcp-Session-Id: \(sessionID)\r\n" }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    /// The headers for an SSE stream (kept open; events written incrementally). The
    /// stream stays alive until the client disconnects.
    public static func sseHeaders(sessionID: String? = nil) -> Data {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        if let sessionID { head += "Mcp-Session-Id: \(sessionID)\r\n" }
        head += "Connection: keep-alive\r\n\r\n"
        return Data(head.utf8)
    }

    /// Frames one JSON object as an SSE `data:` event.
    public static func sseEvent(_ object: [String: Any]) -> Data {
        let json = String(data: JSONRPC.data(object), encoding: .utf8) ?? "{}"
        return Data("data: \(json)\n\n".utf8)
    }
}

// MARK: - Token compare

public enum BatonMCPAuth {
    /// Constant-time token comparison — avoids leaking length/prefix via timing.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    /// Generates a ~256-bit random token, hex-encoded.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0 ... 255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
