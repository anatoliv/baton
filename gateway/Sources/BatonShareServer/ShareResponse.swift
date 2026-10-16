import BatonGatewayCore
import BatonShareKit
import Foundation

/// A response before it is rendered to bytes. Kept as a value so tests assert on status, headers
/// and body directly rather than re-parsing HTTP.
public struct ShareResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, contentType: String = "application/json", body: Data = Data(),
                headers: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }

    public var data: Data {
        httpResponse(status: "\(status) \(Self.reason(status))", contentType: contentType, payload: body,
                     extraHeaders: headers, representedLength: headers["Content-Length"].flatMap(Int.init))
    }

    /// JSON, never cached: every JSON answer here describes state that changes.
    public static func json<T: Encodable>(_ value: T, status: Int = 200, headers: [String: String] = [:]) -> ShareResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        var all = headers
        all["Cache-Control"] = "no-store"
        return ShareResponse(status: status, body: body, headers: all)
    }

    public static func error(_ status: Int, _ code: String, _ message: String,
                             headers: [String: String] = [:]) -> ShareResponse {
        json(ShareErrorBody(error: message, code: code), status: status, headers: headers)
    }

    public static let noContent = ShareResponse(status: 204, headers: ["Cache-Control": "no-store"])

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 206: "Partial Content"
        case 416: "Range Not Satisfiable"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 410: "Gone"
        case 413: "Content Too Large"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
