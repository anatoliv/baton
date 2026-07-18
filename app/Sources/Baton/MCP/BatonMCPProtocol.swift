import Foundation

// MARK: - Constants

/// Protocol/version constants and hard limits for the Baton MCP server. Mirrors the
/// hardening of Tonebox's in-app server (1 MB request cap, current MCP revision).
enum BatonMCPConstants {
    /// The MCP protocol revision Baton speaks. Matches Tonebox's server.
    static let protocolVersion = "2025-06-18"
    /// Server identity reported in `initialize`.
    static let serverName = "baton"
    static let serverVersion = "0.1.0"
    /// Reject any single HTTP request body larger than this (defensive; the tool
    /// payloads are tiny).
    static let maxRequestBytes = 1_048_576 // 1 MB
    /// First port to try; the server walks upward if it's taken.
    static let defaultPort: UInt16 = 8787
    /// How many consecutive ports to try before giving up.
    static let portScanRange = 16
    /// UserDefaults key holding the persisted bearer token.
    static let tokenDefaultsKey = "baton.mcp.token"
    /// Resource URIs.
    static let nowPlayingURI = "baton://now-playing"
    static let queueURI = "baton://queue"
}

// MARK: - JSON-RPC

/// A parsed JSON-RPC 2.0 request (or notification, when `id` is nil).
struct JSONRPCRequest {
    let id: Any? // String, Int, or NSNull — echoed verbatim in the response.
    let method: String
    let params: [String: Any]
    /// A notification (no `id`) expects no response.
    var isNotification: Bool { id == nil }
}

enum JSONRPCError {
    static let parseError = -32_700
    static let invalidRequest = -32_600
    static let methodNotFound = -32_601
    static let invalidParams = -32_602
    static let internalError = -32_603
}

/// Builds JSON-RPC response envelopes as `[String: Any]` dictionaries ready for
/// `JSONSerialization`.
enum JSONRPC {
    static func result(id: Any?, _ result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    /// A server-initiated notification (no `id`) — e.g. `notifications/resources/updated`.
    static func notification(method: String, params: [String: Any]? = nil) -> [String: Any] {
        var out: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { out["params"] = params }
        return out
    }

    /// Serialize a JSON object to compact UTF-8 data. Never throws in practice — the
    /// dictionaries built here are always JSON-legal — but falls back to an empty
    /// object rather than crashing.
    static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

// MARK: - HTTP request parsing

/// A minimally-parsed HTTP/1.1 request read off an `NWConnection`. Only what the MCP
/// transport needs: method, path, a few headers, and the body.
struct HTTPRequestMessage {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String] // lower-cased keys
    let body: Data

    /// Extracts the bearer token from `Authorization: Bearer <token>` or the
    /// `?token=` query param (the latter for discovery-style GETs).
    var bearerToken: String? {
        if let auth = headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return query["token"]
    }

    var acceptsEventStream: Bool {
        (headers["accept"] ?? "").lowercased().contains("text/event-stream")
    }

    var sessionID: String? { headers["mcp-session-id"] }

    /// Parse a full request from raw bytes. Returns nil if headers are incomplete
    /// (caller keeps reading) — or `.some(nil)` semantics are avoided by returning
    /// `.incomplete`.
    enum ParseResult {
        case complete(HTTPRequestMessage)
        case incomplete
        case tooLarge
        case malformed
    }

    static func parse(_ buffer: Data) -> ParseResult {
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
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = kv[0].removingPercentEncoding ?? String(kv[0])
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

        // Determine body length; wait for the whole body before completing.
        let bodyStart = headerEndRange.upperBound
        let available = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
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
enum HTTPResponse {
    /// A complete `Connection: close` JSON response.
    static func json(_ object: [String: Any], status: String = "200 OK", sessionID: String? = nil) -> Data {
        let body = JSONRPC.data(object)
        return raw(body, contentType: "application/json", status: status, sessionID: sessionID)
    }

    /// An empty response (used for accepted notifications → 202).
    static func empty(status: String) -> Data {
        raw(Data(), contentType: "application/json", status: status)
    }

    static func raw(_ body: Data, contentType: String, status: String, sessionID: String? = nil) -> Data {
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
    static func sseHeaders(sessionID: String? = nil) -> Data {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        if let sessionID { head += "Mcp-Session-Id: \(sessionID)\r\n" }
        head += "Connection: keep-alive\r\n\r\n"
        return Data(head.utf8)
    }

    /// Frames one JSON object as an SSE `data:` event.
    static func sseEvent(_ object: [String: Any]) -> Data {
        let json = String(data: JSONRPC.data(object), encoding: .utf8) ?? "{}"
        return Data("data: \(json)\n\n".utf8)
    }
}

// MARK: - Token compare

enum BatonMCPAuth {
    /// Constant-time token comparison — avoids leaking length/prefix via timing.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    /// Generates a ~256-bit random token, hex-encoded.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0 ... 255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
