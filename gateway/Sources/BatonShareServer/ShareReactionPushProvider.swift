import BatonShareKit
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum APNsProviderFailure: Error { case invalid, transport, deadline }

struct APNsResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "APNsResponse(redacted)" }
    var debugDescription: String { description }
    let status: Int
    let body: Data
    let negotiatedHTTP2: Bool
}

/// Never stringify a request: its path and authorization contain protected material.
protocol APNsTransport: Sendable {
    /// Must cap response at 4096 bytes and settle/cancel all I/O before returning.
    func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> APNsResponse
}

/// Injectable privileged companion component; the public executable never constructs it.
/// Credentials are supplied in memory by a separately reviewed protected loader, never argv.
actor APNsReactionPushProvider: ReactionPushProvider {
    private let key: P256.Signing.PrivateKey
    private let keyID: String
    private let teamID: String
    private let topics: [String: PushEnvironment]
    private let transport: any APNsTransport
    private let clock: @Sendable () -> Date
    private var token: (issuedAt: Int64, value: String)?

    init(key: P256.Signing.PrivateKey, keyID: String, teamID: String,
         topics: [String: PushEnvironment], transport: any APNsTransport,
         clock: @escaping @Sendable () -> Date = { Date() }) throws {
        guard keyID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              !topics.isEmpty, topics.count <= 4,
              topics.keys.allSatisfy({ $0.range(of: "^[A-Za-z0-9.-]{1,255}$", options: .regularExpression) != nil })
        else { throw APNsProviderFailure.invalid }
        self.key = key; self.keyID = keyID; self.teamID = teamID
        self.topics = topics; self.transport = transport; self.clock = clock
    }

    func send(_ lease: ReactionPushLease) async throws -> ReactionPushResult {
        let milliseconds = clock().timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int64.max) else {
            throw APNsProviderFailure.invalid
        }
        let now = Int64(milliseconds)
        guard lease.deadline > now, lease.expiration > now else { return .discarded }
        guard !Task.isCancelled else { throw CancellationError() }
        guard topics[lease.topic] == lease.environment, (1 ... 1024).contains(lease.token.count),
              let id = UUID(uuidString: lease.jobID), lease.payload.count <= 4096,
              lease.collapseID.utf8.count <= 64 else { return .providerPaused }
        let host = lease.environment == .production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        let device = lease.token.map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(device)")!)
        request.httpMethod = "POST"; request.httpBody = lease.payload
        request.setValue("bearer " + (try authorization(now: now / 1000)), forHTTPHeaderField: "authorization")
        request.setValue(lease.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(lease.expiration / 1000), forHTTPHeaderField: "apns-expiration")
        request.setValue(id.uuidString.lowercased(), forHTTPHeaderField: "apns-id")
        request.setValue(lease.collapseID, forHTTPHeaderField: "apns-collapse-id")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let timeout = min(20, Double(lease.deadline - now) / 1000)
        let response = try await transport.perform(request, timeout: timeout)
        // A response without actual h2 metrics is uncertain, even if its status says 200.
        guard response.negotiatedHTTP2, response.body.count <= 4096 else {
            return .retry(delayMilliseconds: 900_000)
        }
        return .classify(status: response.status, body: response.body)
    }

    private func authorization(now: Int64) throws -> String {
        // Reuse for 50 minutes; a backwards clock must not produce a future-issued token.
        if let token, now >= token.issuedAt, now - token.issuedAt < 3000 { return token.value }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: .sortedKeys)
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": now], options: .sortedKeys)
        let input = Base64URL.encode(header) + "." + Base64URL.encode(claims)
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        let value = input + "." + Base64URL.encode(signature)
        token = (now, value); return value
    }
}

/// Ephemeral TLS-default URLSession, no cookies/cache, redirects denied, bounded streaming
/// body and per-attempt resource deadline. Completion arrives only after I/O has settled.
/// FoundationNetworking may not supply h2 metrics: absence fails closed, never counts success.
struct URLSessionAPNsTransport: APNsTransport {
    // Only synthetic test protocols inject here; production always uses the default TLS stack.
    let protocolClass: URLProtocol.Type?
    init(protocolClass: URLProtocol.Type? = nil) { self.protocolClass = protocolClass }
    func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> APNsResponse {
        guard (0 ... 20).contains(timeout), timeout > 0, request.url?.scheme == "https",
              ["api.push.apple.com", "api.sandbox.push.apple.com"].contains(request.url?.host ?? ""),
              request.url?.port == nil, request.url?.user == nil, request.url?.password == nil,
              request.url?.query == nil, request.url?.fragment == nil,
              request.httpMethod == "POST", (request.httpBody?.count ?? 4097) <= 4096 else {
            throw APNsProviderFailure.invalid
        }
        let attempt = APNsSessionAttempt(timeout: timeout, protocolClass: protocolClass)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { attempt.start(request, continuation: $0) }
        }, onCancel: { attempt.cancel() })
    }
}

private final class APNsSessionAttempt: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let protocolClass: URLProtocol.Type?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<APNsResponse, any Error>?
    private var cancelled = false
    // Delegate callbacks are serialized by the session's single operation queue.
    private var bytes = Data()
    private var status: Int?
    private var http2 = false
    init(timeout: TimeInterval, protocolClass: URLProtocol.Type?) {
        self.timeout = timeout; self.protocolClass = protocolClass
    }
    func start(_ request: URLRequest, continuation: CheckedContinuation<APNsResponse, any Error>) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        if let protocolClass { config.protocolClasses = [protocolClass] }
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request); self.task = task; task.resume()
    }
    func cancel() { lock.lock(); cancelled = true; task?.cancel(); lock.unlock() }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler: completionHandler)
    }
    private func answer(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Provider authority comes only from its injected bearer. TLS still uses system trust.
        if challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust" {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= 4096 else { completionHandler(.cancel); return }
        status = response.statusCode; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= 4096 - bytes.count else { dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        http2 = metrics.transactionMetrics.count == 1 && metrics.transactionMetrics.first?.networkProtocolName == "h2"
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if error != nil || status == nil { continuation?.resume(throwing: APNsProviderFailure.transport) }
        else { continuation?.resume(returning: APNsResponse(status: status!, body: bytes, negotiatedHTTP2: http2)) }
    }
}

/// One externally retained dispatcher, sequential work, bounded idle polling. No Task is
/// spawned automatically by initialization; caller owns cancellation and lifecycle.
extension ReactionPushDispatcher {
    func runUntilCancelled(idleMilliseconds: UInt64 = 1000) async throws {
        guard (250 ... 60_000).contains(idleMilliseconds) else { throw APNsProviderFailure.invalid }
        guard !schedulerRunning else { throw APNsProviderFailure.invalid }
        schedulerRunning = true; defer { schedulerRunning = false }
        while !Task.isCancelled {
            if try await !runOnce() { try await Task.sleep(nanoseconds: idleMilliseconds * 1_000_000) }
        }
    }
}
