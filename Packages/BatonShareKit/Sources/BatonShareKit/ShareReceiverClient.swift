import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ShareReceiverResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol ShareReceiverTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ShareReceiverResponse
    func send(_ request: URLRequest, maximumBytes: Int, maximumErrorBytes: Int) async throws -> ShareReceiverResponse
}

extension ShareReceiverTransport {
    /// Custom transports retain source compatibility and a semantic error bound. The owned
    /// URLSession transport additionally applies this limit before receiving the whole body.
    public func send(_ request: URLRequest, maximumBytes: Int, maximumErrorBytes: Int) async throws -> ShareReceiverResponse {
        guard maximumErrorBytes > 0 else { throw ShareReceiverClient.Failure.tooLarge }
        let response = try await send(request, maximumBytes: maximumBytes)
        guard (200...299).contains(response.status) || response.body.count <= maximumErrorBytes else { throw ShareReceiverClient.Failure.tooLarge }
        return response
    }
}

/// The recipient never needs a Navidrome account, install secret, cookie or persisted key.
public struct ShareReceiverClient: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case incomplete, unknown, expired, capped, unavailable, network, invalidData, tooLarge
    }

    public struct Details: Equatable, Sendable {
        public let share: PublicShare
        public let metadata: ShareMetadata
    }

    public let base: URL
    private let transport: any ShareReceiverTransport

    public init(base: URL = ShareLink.defaultBase,
                transport: any ShareReceiverTransport = BoundedShareReceiverTransport()) throws {
        guard let p = URLComponents(url: base, resolvingAgainstBaseURL: false),
              p.user == nil, p.password == nil, p.query == nil, p.fragment == nil,
              p.path.isEmpty || p.path == "/",
              (p.scheme == "https" && ShareLink.hosts.contains(p.host?.lowercased() ?? "") && (p.port == nil || p.port == 443))
                || (p.scheme == "http" && ["127.0.0.1", "::1", "[::1]", "localhost"].contains(p.host ?? ""))
        else { throw Failure.invalidData }
        self.base = base
        self.transport = transport
    }

    public func details(_ invitation: ShareInvitation, platform: String, reportOpen: Bool = true) async throws -> Details {
        guard invitation.kind == .song else { throw Failure.invalidData }
        let data = try await request(invitation.id, suffix: "", maximumBytes: 196_608,
                                     query: reportOpen ? [URLQueryItem(name: "via", value: "app"),
                                             URLQueryItem(name: "platform", value: platform == "ios" ? "ios" : "macos")] : [])
        let share: PublicShare
        do { share = try JSONDecoder().decode(PublicShare.self, from: data) }
        catch { throw Failure.invalidData }
        guard share.status == .ready || share.status == .pending else { throw Failure.expired }
        guard (ShareCrypto.headerLength + ShareCrypto.tagLength ... ShareLimits.standard.maxAudioBytes).contains(share.audioBytes),
              ShareDate.date(share.expiresAt) != nil else { throw Failure.invalidData }
        guard let key = invitation.key else {
            if share.status == .ready { await event(invitation.id, PlayerEvent(type: .decryptFailed, reason: "missing_key")) }
            throw Failure.incomplete
        }
        let metadata: ShareMetadata
        do {
            if let preview = share.preview, share.encryptedMeta == nil {
                metadata = try preview.validated()
            } else if share.preview == nil, let encoded = share.encryptedMeta,
                      let sealed = Data(base64Encoded: encoded), sealed.count <= 65_536 {
                let opened = try ShareCrypto.open(sealed, key: key, purpose: .meta)
                metadata = try JSONDecoder().decode(ShareMetadata.self, from: opened).validated()
            } else { throw Failure.invalidData }
        } catch let error as ShareCrypto.Failure {
            await event(invitation.id, PlayerEvent(type: .decryptFailed, reason: error == .authentication ? "auth" : "format"))
            throw Failure.incomplete
        } catch { throw Failure.invalidData }
        return Details(share: share, metadata: metadata)
    }

    public func audio(_ invitation: ShareInvitation, expectedBytes: Int) async throws -> Data {
        guard let key = invitation.key else { throw Failure.incomplete }
        guard (36 ... ShareLimits.standard.maxAudioBytes).contains(expectedBytes) else { throw Failure.tooLarge }
        let sealed = try await request(invitation.id, suffix: "/audio", maximumBytes: expectedBytes)
        guard sealed.count == expectedBytes else { throw Failure.invalidData }
        do {
            let opened = try ShareCrypto.open(sealed, key: key, purpose: .audio)
            guard !opened.isEmpty, opened.count <= ShareLimits.standard.maxAudioBytes else { throw Failure.tooLarge }
            return opened
        } catch let error as ShareCrypto.Failure {
            await event(invitation.id, PlayerEvent(type: .decryptFailed, reason: error == .authentication ? "auth" : "format"))
            throw Failure.incomplete
        }
    }

    public func artwork(_ invitation: ShareInvitation, encrypted: Bool) async throws -> Data {
        let rawLimit = ShareLimits.standard.maxArtBytes
        let data = try await request(invitation.id, suffix: "/art", maximumBytes: encrypted ? rawLimit + 4096 : rawLimit)
        guard encrypted else { return data }
        guard let key = invitation.key else { throw Failure.incomplete }
        let opened: Data
        do { opened = try ShareCrypto.open(data, key: key, purpose: .art) }
        catch { throw Failure.incomplete }
        guard opened.count <= rawLimit else { throw Failure.tooLarge }
        return opened
    }

    public func react(_ id: String, reaction: ReactionRequest) async throws {
        let body = try JSONEncoder().encode(reaction.validated())
        _ = try await request(id, suffix: "/reactions", maximumBytes: 16_384, method: "POST", body: body)
    }

    public func event(_ id: String, _ event: PlayerEvent) async {
        guard (try? event.props()) != nil, let body = try? JSONEncoder().encode(event) else { return }
        _ = try? await request(id, suffix: "/events", maximumBytes: 16_384, method: "POST", body: body)
    }

    private func request(_ id: String, suffix: String, maximumBytes: Int, method: String = "GET",
                         body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        guard ShareLink.isValidID(id) else { throw Failure.invalidData }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = "/v1/share/p/\(id)\(suffix)"
        parts.queryItems = query.isEmpty ? nil : query
        parts.fragment = nil
        guard let url = parts.url else { throw Failure.invalidData }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: ShareReceiverResponse
        do { response = try await transport.send(request, maximumBytes: maximumBytes) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as Failure { throw failure }
        catch { throw Failure.network } // Never retain a URL-bearing transport exception.
        guard response.body.count <= maximumBytes else { throw Failure.tooLarge }
        switch response.status {
        case 200 ... 299: return response.body
        case 404: throw Failure.unknown
        case 410:
            let code = (try? JSONDecoder().decode(ShareErrorBody.self, from: response.body))?.code
            throw code == "play_cap" ? Failure.capped : Failure.expired
        default: throw Failure.unavailable
        }
    }
}

/// A fresh ephemeral, unauthenticated, no-redirect request with a limit enforced while receiving.
public struct BoundedShareReceiverTransport: ShareReceiverTransport {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    public init() { makeConfiguration = { .ephemeral } }
    init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.makeConfiguration = makeConfiguration
    }
    /// The whole-transfer budget. A caller that chose one keeps it (a mixtape track upload asks
    /// for 300 s); otherwise a small reply keeps 60 s and a song-sized download gets 300 s, so a
    /// slow link is not refused every song. The request's own timeout still bounds a stall.
    static func resourceTimeout(configured: TimeInterval, maximumBytes: Int) -> TimeInterval {
        guard configured >= URLSessionConfiguration.ephemeral.timeoutIntervalForResource else { return configured }
        return maximumBytes > 1_000_000 ? 300 : 60
    }
    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> ShareReceiverResponse {
        try await sendLimited(request, maximumBytes: maximumBytes, maximumErrorBytes: nil)
    }
    public func send(_ request: URLRequest, maximumBytes: Int, maximumErrorBytes: Int) async throws -> ShareReceiverResponse {
        guard maximumErrorBytes > 0 else { throw ShareReceiverClient.Failure.tooLarge }
        return try await sendLimited(request, maximumBytes: maximumBytes, maximumErrorBytes: maximumErrorBytes)
    }
    private func sendLimited(_ request: URLRequest, maximumBytes: Int, maximumErrorBytes: Int?) async throws -> ShareReceiverResponse {
        guard maximumBytes > 0 else { throw ShareReceiverClient.Failure.tooLarge }
        let delegate = LimitedShareRequest(maximumBytes: maximumBytes, maximumErrorBytes: maximumErrorBytes, configuration: makeConfiguration())
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await delegate.send(request)
        } onCancel: { delegate.cancel() }
    }
}

private final class LimitedShareRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let maximumErrorBytes: Int?
    private var receiveMaximum: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShareReceiverResponse, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var bytes = Data()
    private var status = 0
    private var failure: Error?
    private var cancelled = false

    init(maximumBytes: Int, maximumErrorBytes: Int?, configuration: URLSessionConfiguration) {
        self.maximumBytes = maximumBytes; self.maximumErrorBytes = maximumErrorBytes
        receiveMaximum = maximumBytes; self.configuration = configuration
    }

    func send(_ request: URLRequest) async throws -> ShareReceiverResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let config = configuration
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.httpShouldSetCookies = false
            config.timeoutIntervalForResource = BoundedShareReceiverTransport.resourceTimeout(
                configured: config.timeoutIntervalForResource, maximumBytes: maximumBytes)
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // TLS uses the system's server-trust check. All account/client-certificate challenges
        // are refused: a received share must never consult owner credentials or prompt for them.
        if challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust" {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if let response = response as? HTTPURLResponse {
            status = response.statusCode
            receiveMaximum = (200...299).contains(status) ? maximumBytes : (maximumErrorBytes ?? maximumBytes)
        }
        if response.expectedContentLength > receiveMaximum { failure = ShareReceiverClient.Failure.tooLarge }
        let allowed = failure == nil && status != 0
        lock.unlock()
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if data.count > receiveMaximum - bytes.count {
            failure = ShareReceiverClient.Failure.tooLarge
            lock.unlock(); dataTask.cancel(); return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure: Error? = self.failure ?? (cancelled ? CancellationError() : error)
        let response = ShareReceiverResponse(status: status, body: bytes)
        self.task = nil; self.session = nil; bytes = Data()
        lock.unlock()
        session.invalidateAndCancel()
        if let failure { continuation?.resume(throwing: failure) }
        else { continuation?.resume(returning: response) }
    }
}
