import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A share, sealed and ready to upload: everything the composer hands the client.
///
/// Built by `PreparedShare.make`, which is the one place a song and its details become the
/// bytes and the request the protocol expects (spec §2–§4). The apps add only what is theirs:
/// fetching the audio from Navidrome, the waveform, the artwork, the card.
public struct PreparedShare: Sendable {
    public let key: Data
    public let request: CreateShareRequest
    public let sealedAudio: Data
    /// JPEG or PNG in public mode; sealed under `art` in private mode.
    public let art: Data?
    /// The 1200×630 preview card, public mode only.
    public let card: Data?

    public static func make(audio: Data, metadata: ShareMetadata, isPrivate: Bool,
                            expiresInSeconds: Int, playCap: Int, client: ShareClientInfo,
                            artwork: Data? = nil, card: Data? = nil,
                            recentFailures: [ShareFailureReport] = [],
                            reviewPreservationConsent: String? = nil,
                            limits: ShareLimits = .standard,
                            key: Data = ShareCrypto.newKey()) throws -> PreparedShare {
        let meta = try metadata.validated(limits: limits)
        let sealed = try ShareCrypto.seal(audio, key: key, purpose: .audio)
        guard sealed.count <= limits.maxAudioBytes else {
            throw ShareValidationError("audio", "is \(sealed.count) bytes sealed; the limit is \(limits.maxAudioBytes)")
        }
        var encryptedMeta: String?
        var art = artwork
        if isPrivate {
            encryptedMeta = try ShareCrypto.seal(JSONEncoder().encode(meta), key: key, purpose: .meta)
                .base64EncodedString()
            art = try artwork.map { try ShareCrypto.seal($0, key: key, purpose: .art) }
        }
        let request = CreateShareRequest(
            expiresInSeconds: expiresInSeconds, playCap: playCap,
            preview: isPrivate ? nil : meta, encryptedMeta: encryptedMeta,
            durationBucket: isPrivate ? DurationBucket(seconds: meta.durationSeconds) : nil,
            audioBytes: sealed.count, audioSHA256: ShareHash.sha256Hex(sealed), client: client,
            recentFailures: recentFailures.isEmpty ? nil : Array(recentFailures.prefix(ShareLimits.maxRecentFailures)),
            reviewPreservationConsent: reviewPreservationConsent)
        return PreparedShare(key: key, request: try request.validated(limits: limits), sealedAudio: sealed,
                             art: art, card: isPrivate ? nil : card)
    }
}

/// The sharer's side of the HTTP API (spec §4.1), for both apps.
///
/// Stateless apart from its base URL and install secret, which the app keeps in the Keychain.
/// It never sees the share key except to append it to the link it returns.
public struct ShareClient: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The service answered with an error body: `code` is the spec's machine code (§4.4).
        case service(status: Int, code: String, message: String)
        case transport(String)
        case unexpected(Int)

        /// What to queue as `recentFailures` on the next create, when the share never got there.
        public var reportReason: String {
            switch self {
            case let .service(_, code, _) where code == "busy" || code == "share_disabled": "quota"
            case let .service(_, code, _) where code == "too_large": "too_large"
            case .transport: "network"
            default: "other"
            }
        }
    }

    public let base: URL
    public let secret: String
    let session: URLSession

    public init(base: URL = ShareLink.defaultBase, secret: String, session: URLSession = .shared) {
        self.base = base
        self.secret = secret
        self.session = session
    }

    /// A new install secret (spec §1): 32 random bytes, base64url.
    public static func newSecret() -> String {
        Base64URL.encode(ShareCrypto.newKey() + ShareCrypto.newKey())
    }

    public func config() async throws -> ShareConfig {
        try await send("GET", "/v1/share/config", authenticated: false)
    }

    /// Create, upload, finalize: the whole of sending a share. Returns the link to hand a friend,
    /// and the summary to keep locally (with the key, so "copy link again" works later).
    public func share(_ prepared: PreparedShare,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> (link: URL, summary: ShareSummary) {
        let created: CreateShareResponse = try await send("POST", "/v1/share/shares",
                                                          body: try JSONEncoder().encode(prepared.request))
        progress?(0.05)
        let _: [String: Bool] = try await send("PUT", created.uploads.audio, body: prepared.sealedAudio,
                                               contentType: "application/octet-stream")
        progress?(0.9)
        if let art = prepared.art {
            let _: [String: Bool] = try await send("PUT", created.uploads.art, body: art,
                                                   contentType: "application/octet-stream")
        }
        if let card = prepared.card {
            let _: [String: Bool] = try await send("PUT", created.uploads.card, body: card,
                                                   contentType: "application/octet-stream")
        }
        let summary: ShareSummary = try await send("POST", "/v1/share/shares/\(created.id)/finalize")
        progress?(1)
        guard let url = URL(string: created.url) else { throw Failure.unexpected(0) }
        return (ShareLink(id: created.id, key: prepared.key).url(base: Self.origin(of: url)), summary)
    }

    public func list() async throws -> [ShareSummary] {
        let list: ShareList = try await send("GET", "/v1/share/shares")
        return list.shares
    }

    public func extend(_ id: String, bySeconds seconds: Int) async throws -> ShareSummary {
        try await send("PATCH", "/v1/share/shares/\(id)",
                       body: try JSONEncoder().encode(PatchShareRequest(extendBySeconds: seconds)))
    }

    public func setPlayCap(_ id: String, _ cap: Int) async throws -> ShareSummary {
        try await send("PATCH", "/v1/share/shares/\(id)", body: try JSONEncoder().encode(PatchShareRequest(playCap: cap)))
    }

    public func revoke(_ id: String) async throws {
        _ = try await raw("DELETE", "/v1/share/shares/\(id)", body: nil, contentType: nil, authenticated: true)
    }

    // MARK: - HTTP

    static func origin(of url: URL) -> URL {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.url ?? url
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data? = nil,
                                    contentType: String = "application/json",
                                    authenticated: Bool = true) async throws -> T {
        let data = try await raw(method, path, body: body, contentType: body == nil ? nil : contentType,
                                 authenticated: authenticated)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.unexpected(200)
        }
    }

    private func raw(_ method: String, _ path: String, body: Data?, contentType: String?,
                     authenticated: Bool) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base) else { throw Failure.transport("bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = body.map { $0.count > 1_000_000 ? 300 : 30 } ?? 30
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if authenticated { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unexpected(0) }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let body = try? JSONDecoder().decode(ShareErrorBody.self, from: data) {
                throw Failure.service(status: http.statusCode, code: body.code, message: body.error)
            }
            throw Failure.unexpected(http.statusCode)
        }
        return data
    }
}
