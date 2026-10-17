import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Optional private contact from the originating installation. No contact/case persistence.
public final class ShareContactClient: @unchecked Sendable {
    public enum Failure: Error, Equatable { case unavailable, invalid, unauthorized }
    public struct Status: Decodable, Sendable { public let status: String }
    public struct Notice: Decodable, Sendable {
        public let instructions: String
        public let location: String
        public let action: String
    }
    private struct Grant: Decodable { let authorization: String }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private let base: URL
    private let secret: String
    private let session: URLSession
    private let ownsSession: Bool
    public init(base: URL = ShareLink.defaultBase, secret: String, session: URLSession? = nil) {
        self.base = base
        self.secret = secret
        ownsSession = session == nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    public func status() async throws -> Status { try await perform("status", purpose: "status", body: [:]) }
    public func enroll(address: String, include: [String]) async throws -> Status {
        guard address.count <= 254, include.count <= 200 else { throw Failure.invalid }
        return try await perform("enroll", purpose: "enroll", include: include,
                                 body: ["address": address, "consent": "contact-v1", "include": include])
    }
    public func verify(code: String) async throws -> Status {
        try valid(code)
        return try await perform("verify", purpose: "verify", body: ["code": code])
    }
    public func withdraw() async throws -> Status { try await perform("withdraw", purpose: "withdraw", body: [:]) }
    public func access(code: String) async throws -> Notice {
        try valid(code)
        return try await perform("access", purpose: "caseAccess", body: ["code": code])
    }
    private func valid(_ code: String) throws {
        guard code.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw Failure.invalid }
    }
    private func perform<T: Decodable>(_ endpoint: String, purpose: String, include: [String] = [],
                                       body: [String: Any]) async throws -> T {
        guard base.scheme == "https", ["batonmusic.app", "baton.tonebox.io"].contains(base.host ?? ""),
              base.port == nil || base.port == 443, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, base.path.isEmpty || base.path == "/" else { throw Failure.invalid }
        let grant: Grant = try await request("/v1/share/contact/authorization", body: ["purpose": purpose, "include": include])
        var privateBody = body
        privateBody["authorization"] = grant.authorization
        return try await request("/v1/share/contact/private/" + endpoint, body: privateBody)
    }
    private func request<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: path, relativeTo: base) else { throw Failure.invalid }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
            guard http.statusCode == 200, data.count <= 65536 else {
                throw http.statusCode == 401 || http.statusCode == 403 ? Failure.unauthorized : Failure.unavailable
            }
            guard let result = try? JSONDecoder().decode(T.self, from: data) else { throw Failure.unavailable }
            return result
        } catch let failure as Failure { throw failure }
        catch { throw Failure.unavailable } // Never display transport/provider payloads.
    }
}
