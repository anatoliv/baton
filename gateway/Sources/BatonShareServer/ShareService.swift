import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
import Foundation

/// The `baton-share` HTTP surface (spec §4). Every route, its checks, and the events it records.
///
/// **One lock, held for the whole of a request.** The store is a single SQLite connection and the
/// service sees a handful of requests a second; serializing them costs nothing measurable and
/// removes every question about two requests racing over one share's counters or cap. Blob bytes
/// never pass through the lock in production: nginx serves them (`X-Accel-Redirect`).
public final class ShareService: @unchecked Sendable {
    public let config: ShareConfiguration
    let store: ShareStore
    let salt: DailySalt
    let limiter = RateLimiter()
    let page: SharePage
    let mixtapePage: MixtapePage
    var attestationVerifier: AppAttestVerifier?
    // Only the internal, explicitly injected prototype initializer enables this bridge.
    // Ordinary configuration creates no fresh push tables, collects no tokens and sends
    // nothing. Existing protected tables attach with key-free/default-off cleanup only.
    var reactionPushStore: ReactionPushStore?
    var reactionPushAdmission: (any ReactionPushRegistrationAdmission)?
    private(set) var reactionPushEnqueueFailed = false
    private let lock = NSLock()
    private let clock: @Sendable () -> Date

    public init(config: ShareConfiguration, salt: DailySalt = DailySalt(),
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.config = config
        self.salt = salt
        self.clock = clock
        store = try ShareStore(root: config.dataDirectory)
        try store.database.execute(Self.attestationSchema)
        attestationVerifier = try config.appAttest.map(AppAttestVerifier.init(config:))
        page = try SharePage(config: config)
        mixtapePage = try MixtapePage(config: config)
        if try ReactionPushStore.hasExistingStorage(in: store.database) {
            reactionPushStore = try ReactionPushStore(database: store.database)
            try attachReactionPushLifecycle()
        }
    }

    convenience init(config: ShareConfiguration, reactionPushPolicy: ReactionPushPolicy,
                     registrationAdmission: (any ReactionPushRegistrationAdmission)? = nil,
                     clock: @escaping @Sendable () -> Date = { Date() }) throws {
        try self.init(config: config, clock: clock)
        reactionPushAdmission = registrationAdmission
        reactionPushStore = try ReactionPushStore(database: store.database, policy: reactionPushPolicy)
        try attachReactionPushLifecycle()
    }

    private func attachReactionPushLifecycle() throws {
        try reactionPushStore?.installShareLifecycleHooks()
        try reactionPushStore?.sweepShareLifecycle(nowMilliseconds: pushMilliseconds(now))
    }

    public var stagingDirectory: URL { store.stagingDirectory }

    var now: Int64 { Int64(clock().timeIntervalSince1970) }

    /// Which requests the transport streams to disk: an upload of a share's audio, art or card.
    public static func streamsBody(_ head: StreamingUpload.Request) -> Bool {
        guard head.method == "PUT" else { return false }
        if head.path.hasPrefix("/v1/share/shares/") { return true }
        let parts = head.path.split(separator: "/").map(String.init)
        return parts.count == 6 && Array(parts.prefix(3)) == ["v1", "share", "mixtapes"]
            && parts[4] == "tracks" && ShareLink.isValidID(parts[3]) && ShareMixtapeCrypto.isCanonicalTrackID(parts[5])
    }

    // MARK: - Entry points

    public func handle(_ request: HTTPRequestMessage, peer: ConnectionPeer = .unknown) -> ShareResponse {
        lock.lock()
        defer { lock.unlock() }
        do {
            if request.path == "/v1/share/admin/enforcement" || request.path.hasPrefix("/v1/share/admin/enforcement/") {
                return try enforcementRoute(request, peer: peer)
            }
            return try route(request)
        } catch let error as ShareValidationError {
            return .error(400, "invalid", error.description)
        } catch let failure as EnforcementFailure {
            switch failure {
            case .invalid: return .error(400, "invalid", "Invalid operator request.")
            case .notFound: return .error(404, "not_found", "No such route.")
            case .conflict: return .error(409, "conflict", "The reviewed operation has changed. Create a new plan.")
            case .scopeTooLarge: return .error(409, "scope", "The operation exceeds the configured scope bound.")
            case .quota: return .error(503, "quota", "Preservation requires available quota. Review storage before trying again.")
            }
        } catch is AppAttestError {
            return .error(401, "app_attest_invalid", "App integrity verification failed. Try again from Baton.")
        } catch {
            return .error(500, "internal", "Something went wrong on our side.")
        }
    }

    public func handleUpload(_ request: StreamingUpload.Request, file: URL) -> ShareResponse {
        lock.lock()
        defer { lock.unlock() }
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            return try upload(request, file: file)
        } catch let error as ShareValidationError {
            return .error(400, "invalid", error.description)
        } catch {
            return .error(500, "internal", "Something went wrong on our side.")
        }
    }

    @discardableResult
    public func sweep() throws -> ShareStore.SweepResult {
        lock.lock()
        defer { lock.unlock() }
        let now = self.now
        try sweepAttestation(now: now)
        try reactionPushStore?.sweepShareLifecycle(nowMilliseconds: pushMilliseconds(now))
        return try store.sweep(now: now, limits: config.limits)
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequestMessage) throws -> ShareResponse {
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let method = request.method.uppercased()
        let who = ShareRequester(headers: request.headers)
        if let response = try mixtapeRoute(request, parts: parts, who: who) { return response }

        func only(_ allowed: [String], _ body: () throws -> ShareResponse) rethrows -> ShareResponse {
            guard allowed.contains(method) else {
                return .error(405, "method", "Method not allowed.", headers: ["Allow": allowed.joined(separator: ", ")])
            }
            return try body()
        }

        switch parts.count {
        case 1 where parts[0] == "health":
            return only(["GET"]) { .json(["ok": true]) }
        case 2 where parts[0] == "m" && request.path == "/m/" + parts[1]:
            return try only(["GET"]) { try mixtapePlayerPage(id: parts[1], who: who) }
        case 3 where parts[0] == "m" && parts[1] == "_" && request.path == "/m/_/" + parts[2]:
            return only(["GET"]) { mixtapePage.asset(parts[2]) }
        case 2 where parts[0] == "s":
            return try only(["GET"]) { try playerPage(id: parts[1], who: who) }
        case 3 where parts[0] == "s" && parts[1] == "_":
            return only(["GET"]) { page.asset(named: parts[2]) }
        default:
            break
        }

        guard parts.count >= 3, parts[0] == "v1", parts[1] == "share" else {
            return .error(404, "not_found", "No such route.")
        }
        let rest = Array(parts.dropFirst(2))
        switch (rest.first, rest.count) {
        case ("config", 1):
            return only(["GET"]) {
                var result = ShareConfig(enabled: config.enabled, limits: config.limits)
                result.appAttest = config.appAttest?.policy
                if config.enabled && config.mixtapesEnabled { result.mixtapes = 1 }
                if config.enabled, let push = reactionPushStore, push.policy.enabled,
                   reactionPushAdmission != nil {
                    result.reactionPush = ReactionPushAdvertisement(version: 1,
                        topics: push.policy.topics.mapValues(\.rawValue))
                }
                return .json(result)
            }
        case ("attestation", 2):
            return try attestationRoute(request, action: rest[1], who: who)
        case ("owner", 3) where rest[1] == "push-devices":
            return try only(["PUT", "DELETE"]) { try reactionPushRegistration(request, deviceID: rest[2]) }
        case ("shares", 1):
            return try only(["GET", "POST"]) {
                method == "POST" ? try create(request, who: who) : try list(request)
            }
        case ("shares", 2):
            return try only(["PATCH", "DELETE"]) {
                method == "PATCH" ? try patch(request, id: rest[1]) : try revoke(request, id: rest[1])
            }
        case ("shares", 3) where rest[2] == "finalize":
            return try only(["POST"]) { try finalize(request, id: rest[1]) }
        case ("shares", 3) where ShareStore.BlobKind(rawValue: rest[2]) != nil:
            // Uploads never reach here: the transport streams every PUT under this prefix.
            return only(["PUT"]) { .error(400, "invalid", "Upload with a Content-Length.") }
        case ("p", 2):
            return try only(["GET"]) { try publicInfo(request, id: rest[1], who: who) }
        case ("p", 3) where ShareStore.BlobKind(rawValue: rest[2]) != nil:
            return try only(["GET"]) {
                try blob(request, id: rest[1], kind: ShareStore.BlobKind(rawValue: rest[2])!, who: who)
            }
        case ("p", 3) where rest[2] == "events":
            return try only(["POST"]) { try event(request, id: rest[1], who: who) }
        case ("p", 3) where rest[2] == "reactions":
            return try only(["POST"]) { try react(request, id: rest[1], who: who) }
        case ("admin", 2) where rest[1] == "stats":
            return try only(["GET"]) { try adminStats(request, who: who) }
        default:
            return .error(404, "not_found", "No such route.")
        }
    }

    // MARK: - Sharer auth

    struct Sharer {
        let digest: String
        let id: String
    }

    /// The presented install secret, if it is shaped like one (spec §1). The shape check keeps a
    /// stray header from minting a sharer.
    func sharer(bearer: String?) -> Sharer? {
        guard let secret = bearer, (32 ... 128).contains(secret.count), Base64URL.decode(secret) != nil
        else { return nil }
        return Sharer(digest: ShareHash.secretDigest(secret), id: ShareHash.sharerID(secret: secret))
    }

    private let unauthorized = ShareResponse.error(401, "unauthorized", "Missing or malformed install secret.")
    private let notFound = ShareResponse.error(404, "not_found", "No such share.")

    /// The share, if it exists and belongs to this sharer. Someone else's share is `nil`, so it
    /// answers 404 exactly like an id that never existed.
    func owned(_ id: String, by sharer: Sharer) throws -> ShareRecord? {
        guard ShareLink.isValidID(id), let record = try store.share(id: id),
              record.sharerDigest == sharer.digest, !record.isMixtape
        else { return nil }
        return record
    }

    // MARK: - Create (§4.1)

    func create(_ request: HTTPRequestMessage, who: ShareRequester) throws -> ShareResponse {
        guard let sharer = sharer(bearer: request.bearerToken) else { return unauthorized }
        if let denial = try enforcementCreateDenial(sharer) { return denial }
        guard config.enabled else {
            return .error(503, "share_disabled", "Sharing is paused for now. Try again later.")
        }
        let body: CreateShareRequest
        do {
            body = try JSONDecoder().decode(CreateShareRequest.self, from: request.body)
        } catch {
            return .error(400, "invalid", "The request body is not a share request.")
        }
        let valid = try body.validated(limits: config.limits)
        let integrity = try verifyCreate(request, sharer: sharer)
        if let replay = integrity.replay { return replay }
        return try store.database.transaction {
            let response = try createAuthorized(valid, sharer: sharer, who: who, verified: integrity.verified != nil)
            if response.status == 201, let verified = integrity.verified {
                try commitVerifiedCreate(verified, response: response, digest: sharer.digest)
            }
            return response
        }
    }

    func createAuthorized(_ valid: CreateShareRequest, sharer: Sharer, who: ShareRequester, verified: Bool) throws -> ShareResponse {
        if let denial = try enforcementCreateDenial(sharer) { return denial }
        let now = self.now
        let dayStart = now - now % 86400
        let network = salt.hash(["network", who.address], now: now)

        let isNew = try !store.sharerExists(digest: sharer.digest)
        if isNew, !limiter.peek("new:\(network)", limit: config.limits.newSharersPerNetworkPerDay, per: 86400, now: now) {
            return rateLimited("new_sharer", now: now)
        }
        guard try store.sharesCreated(byDigest: sharer.digest, since: dayStart) < config.limits.createsPerSharerPerDay
        else { return rateLimited("sharer_daily", now: now) }
        guard try store.liveShares(byDigest: sharer.digest) < config.limits.liveSharesPerSharer
        else { return rateLimited("sharer_live", now: now) }
        guard limiter.allow("create:\(network)", limit: config.limits.createsPerNetworkPerDay, per: 86400, now: now)
        else { return rateLimited("network_daily", now: now) }
        guard try store.quotaBytes() + Int64(valid.audioBytes) <= config.limits.quotaBytes else {
            return .error(503, "busy", "Sharing is busy right now. Try again later.")
        }

        if isNew {
            _ = limiter.allow("new:\(network)", limit: config.limits.newSharersPerNetworkPerDay, per: 86400, now: now)
            try store.insertSharer(digest: sharer.digest, sharerID: sharer.id, platform: valid.client.platform, now: now)
        }

        var id = Base64URL.encode(ShareCrypto.newKey())
        while try store.share(id: id) != nil { id = Base64URL.encode(ShareCrypto.newKey()) }
        let record = ShareRecord(
            id: id, sharerDigest: sharer.digest, sharerID: sharer.id, status: .pending, createdAt: now,
            expiresAt: now + Int64(valid.expiresInSeconds), playCap: valid.playCap, isPrivate: valid.isPrivate,
            preview: valid.preview, encryptedMeta: valid.encryptedMeta, audioBytes: valid.audioBytes,
            audioSHA256: valid.audioSHA256, audioStored: false, artType: nil, cardType: nil, storedBytes: 0,
            stats: ShareStats(), reviewPreservationConsent: valid.reviewPreservationConsent)
        try store.insert(record)

        var props: [String: PropValue] = [
            "integrity": .string(verified ? "app_attest" : "unverified"),
            "platform": .string(valid.client.platform), "appVersion": .string(valid.client.appVersion),
            "expirySeconds": .int(valid.expiresInSeconds), "mode": .string(valid.isPrivate ? "private" : "public"),
            "playCap": .int(valid.playCap), "hasNote": .bool(!(valid.preview?.note.isEmpty ?? true)),
        ]
        if let bucket = valid.effectiveDurationBucket { props["durationBucket"] = .string(bucket.rawValue) }
        if isNew { props["newSharer"] = .bool(true) }
        try store.record(event: "share_created", at: now, shareID: id, sharerID: sharer.id, props: props)
        for failure in valid.recentFailures ?? [] {
            try store.record(event: "share_failed", at: now, sharerID: sharer.id,
                             props: ["reason": .string(failure.reason), "platform": .string(valid.client.platform)])
        }

        let base = "/v1/share/shares/\(id)"
        return .json(CreateShareResponse(
            id: id, url: page.shareURL(id: id),
            expiresAt: ShareDate.string(Date(timeIntervalSince1970: TimeInterval(record.expiresAt))),
            uploads: .init(audio: "\(base)/audio", art: "\(base)/art", card: "\(base)/card")), status: 201)
    }

    private func rateLimited(_ scope: String, now: Int64) -> ShareResponse {
        try? store.record(event: "rate_limited", at: now, props: ["scope": .string(scope)])
        let retry = scope.hasSuffix("minute") ? 60 : 86400 - Int(now % 86400)
        return .error(429, "rate_limited", "Too many shares for now. Try again later.",
                      headers: ["Retry-After": String(retry)])
    }

    // MARK: - Uploads (§4.1)

    func upload(_ request: StreamingUpload.Request, file: URL) throws -> ShareResponse {
        if request.path.hasPrefix("/v1/share/mixtapes/") { return try uploadMixtape(request, file: file) }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count == 5, let kind = ShareStore.BlobKind(rawValue: parts[4]) else {
            return .error(404, "not_found", "No such route.")
        }
        guard let sharer = sharer(bearer: request.bearerToken) else { return unauthorized }
        guard let record = try owned(parts[3], by: sharer) else { return notFound }
        if let denial = try enforcementWriteDenial(record) { return denial }
        guard record.status == .pending else {
            return .error(409, "state", "This share is already \(record.status.rawValue).")
        }
        let size = request.contentLength
        let head = try readHead(file)
        let contentType: String

        switch kind {
        case .audio:
            guard !record.audioStored else { return .error(409, "state", "The audio is already uploaded.") }
            guard size == record.audioBytes else {
                return .error(400, "invalid", "audio: \(size) bytes, but the share declared \(record.audioBytes).")
            }
            do {
                _ = try ShareCrypto.layout(headerBytes: head, totalLength: size)
            } catch {
                return .error(400, "invalid", "audio: not a BSH1 stream.")
            }
            guard try sha256(file) == record.audioSHA256 else {
                return .error(422, "checksum", "audio: the bytes do not match audioSHA256.")
            }
            contentType = "application/octet-stream"
        case .art:
            guard record.artType == nil else { return .error(409, "state", "The artwork is already uploaded.") }
            if record.isPrivate {
                guard size <= config.limits.maxArtBytes + 4096,
                      (try? ShareCrypto.layout(headerBytes: head, totalLength: size)) != nil
                else { return .error(400, "invalid", "art: a private share's artwork must be sealed.") }
                contentType = "application/octet-stream"
            } else {
                guard size <= config.limits.maxArtBytes else {
                    return .error(413, "too_large", "art: at most \(config.limits.maxArtBytes) bytes.")
                }
                guard let type = Self.imageType(head) else {
                    return .error(400, "invalid", "art: JPEG or PNG only.")
                }
                contentType = type
            }
        case .card:
            guard !record.isPrivate else {
                return .error(400, "invalid", "card: a private share has no preview card.")
            }
            guard record.cardType == nil else { return .error(409, "state", "The card is already uploaded.") }
            guard size <= config.limits.maxCardBytes else {
                return .error(413, "too_large", "card: at most \(config.limits.maxCardBytes) bytes.")
            }
            guard let type = Self.imageType(head) else { return .error(400, "invalid", "card: JPEG or PNG only.") }
            contentType = type
        }

        guard try store.quotaBytes() + Int64(kind == .audio ? 0 : size) <= config.limits.quotaBytes else {
            return .error(503, "busy", "Sharing is busy right now. Try again later.")
        }
        try store.adopt(staged: file, id: record.id, kind: kind)
        try store.markStored(id: record.id, kind: kind, contentType: contentType, bytes: Int64(size))
        return .json(["ok": true])
    }

    static func imageType(_ head: [UInt8]) -> String? {
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        return nil
    }

    func readHead(_ file: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return [UInt8](try handle.read(upToCount: ShareCrypto.headerLength) ?? Data())
    }

    func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = ShareHash.Running()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
    }

    // MARK: - Finalize, list, patch, revoke (§4.1)

    func finalize(_ request: HTTPRequestMessage, id: String) throws -> ShareResponse {
        guard let sharer = sharer(bearer: request.bearerToken) else { return unauthorized }
        guard let record = try owned(id, by: sharer) else { return notFound }
        if let denial = try enforcementWriteDenial(record) { return denial }
        guard record.status == .pending else {
            return .error(409, "state", "This share is already \(record.status.rawValue).")
        }
        guard record.audioStored else { return .error(409, "state", "Upload the audio first.") }
        try store.setStatus(id: id, .ready)
        try store.record(event: "share_finalized", at: now, shareID: id, sharerID: sharer.id,
                         props: ["audioBytes": .int(record.audioBytes)])
        return .json(try summary(try store.share(id: id)!))
    }

    func list(_ request: HTTPRequestMessage) throws -> ShareResponse {
        guard let sharer = sharer(bearer: request.bearerToken) else { return unauthorized }
        return try enforcementOwnerList(store.shares(byDigest: sharer.digest))
    }

    func patch(_ request: HTTPRequestMessage, id: String) throws -> ShareResponse {
        guard let sharer = sharer(bearer: request.bearerToken) else { return unauthorized }
        guard var record = try owned(id, by: sharer) else { return notFound }
        if let denial = try enforcementWriteDenial(record) { return denial }
        guard record.status == .pending || record.status == .ready else {
            return .error(409, "state", "This share has \(record.status.rawValue).")
        }
        let body: PatchShareRequest
        do {
            body = try JSONDecoder().decode(PatchShareRequest.self, from: request.body)
        } catch {
            return .error(400, "invalid", "The request body is not a share change.")
        }
        let now = self.now
        if let extend = body.extendBySeconds {
            guard (1 ... config.limits.maxExpirySeconds).contains(extend) else {
                throw ShareValidationError("extendBySeconds", "must be from 1 to \(config.limits.maxExpirySeconds)")
            }
            record.expiresAt = min(record.expiresAt + Int64(extend), now + Int64(config.limits.maxExpirySeconds))
            try store.setExpiry(id: id, record.expiresAt)
            try store.record(event: "share_extended", at: now, shareID: id, sharerID: sharer.id)
        }
        if let cap = body.playCap {
            guard (1 ... config.limits.maxPlayCap).contains(cap) else {
                throw ShareValidationError("playCap", "must be from 1 to \(config.limits.maxPlayCap)")
            }
            try store.setPlayCap(id: id, cap)
        }
        return .json(try summary(try store.share(id: id)!))
    }

    func revoke(_ request: HTTPRequestMessage, id: String) throws -> ShareResponse {
        guard let sharer = sharer(bearer: request.bearerToken) else { return unauthorized }
        guard let record = try owned(id, by: sharer) else { return notFound }
        if record.status == .pending || record.status == .ready {
            try store.tombstone(id: id, as: .revoked, now: now)
            try store.record(event: "share_revoked", at: now, shareID: id, sharerID: sharer.id)
        }
        return .noContent
    }

    func summary(_ record: ShareRecord) throws -> ShareSummary {
        var stats = record.stats
        stats.listeners = try store.listeners(id: record.id)
        return ShareSummary(
            id: record.id, status: record.status,
            createdAt: ShareDate.string(Date(timeIntervalSince1970: TimeInterval(record.createdAt))),
            expiresAt: ShareDate.string(Date(timeIntervalSince1970: TimeInterval(record.expiresAt))),
            playCap: record.playCap, preview: record.preview, stats: stats,
            reactions: try store.reactions(shareID: record.id))
    }

    // MARK: - Public (§4.2)

    /// What a friend's request finds: the share if it can still be played, or why not.
    enum PublicState: Equatable {
        case unknown
        case pending(ShareRecord)
        case ready(ShareRecord)
        case ended(ShareRecord, code: String)

        var record: ShareRecord? {
            switch self {
            case .unknown: nil
            case let .pending(r), let .ready(r), let .ended(r, _): r
            }
        }
    }

    /// Looks a share up for a public route, expiring it on the spot if the sweeper has not got
    /// there yet: a link must stop working at its stated time, not up to ten minutes later.
    func publicState(_ id: String) throws -> PublicState {
        guard ShareLink.isValidID(id), let record = try store.share(id: id), !record.isMixtape else { return .unknown }
        if try store.isEnforced(record) { return .ended(endedEnforcementRecord(record), code: "expired") }
        let now = self.now
        switch record.status {
        case .ready where record.expiresAt <= now:
            try store.tombstone(id: id, as: .expired, now: now)
            try store.record(event: "share_expired", at: now, shareID: id, sharerID: record.sharerID)
            return .ended(try store.share(id: id) ?? record, code: "expired")
        case .pending where record.expiresAt <= now:
            return .unknown
        case .ready:
            return record.isCapped ? .ended(record, code: "play_cap") : .ready(record)
        case .pending:
            return .pending(record)
        case .expired:
            return .ended(record, code: "expired")
        case .revoked:
            // To the friend, revoked reads exactly as expired: in the page, its data and every
            // public status code. "Revoked" would tell them the sender took it back (plan §3).
            // Only the sharer's own routes say revoked.
            return .ended(record, code: "expired")
        }
    }

    func visitor(_ who: ShareRequester, shareID: String) -> String {
        salt.hash(["visitor", who.address, who.userAgent, shareID], now: now)
    }

    func playerPage(id: String, who: ShareRequester) throws -> ShareResponse {
        let state = try publicState(id)
        if let record = state.record, try !store.isEnforced(record) {
            let now = self.now
            if let app = ClientClass.crawler(userAgent: who.userAgent) {
                try store.record(event: "link_unfurled", at: now, shareID: id, sharerID: record.sharerID,
                                 props: ["app": .string(app)])
            } else {
                let label: String = switch state {
                case .ready: "ready"
                case .pending: "pending"
                case let .ended(_, code): code
                case .unknown: "unknown"
                }
                if case .ready = state { try store.increment(id: id, .opens) }
                try store.record(event: "page_opened", at: now, shareID: id, sharerID: record.sharerID,
                                 visitor: visitor(who, shareID: id),
                                 props: ["device": .string(ClientClass.device(userAgent: who.userAgent)),
                                         "state": .string(label)])
            }
        }
        return page.render(state)
    }

    func publicInfo(_ request: HTTPRequestMessage, id: String, who: ShareRequester) throws -> ShareResponse {
        let state = try publicState(id)
        switch state {
        case .unknown:
            return notFound
        case let .ended(_, code):
            return .error(410, code, "This share has ended.")
        case let .pending(record), let .ready(record):
            if request.query["via"] == "app" {
                let platform = request.query["platform"].flatMap { ShareClientInfo.platforms.contains($0) ? $0 : nil }
                try store.record(event: "opened_in_app", at: now, shareID: id, sharerID: record.sharerID,
                                 visitor: visitor(who, shareID: id),
                                 props: ["platform": .string(platform ?? "other")])
            }
            return .json(publicShare(record))
        }
    }

    func publicShare(_ record: ShareRecord) -> PublicShare {
        PublicShare(status: record.status, preview: record.preview, encryptedMeta: record.encryptedMeta,
                    audioBytes: record.audioBytes, hasArt: record.artType != nil, hasCard: record.cardType != nil,
                    expiresAt: ShareDate.string(Date(timeIntervalSince1970: TimeInterval(record.expiresAt))))
    }

    func blob(_ request: HTTPRequestMessage, id: String, kind: ShareStore.BlobKind,
              who: ShareRequester) throws -> ShareResponse {
        let state = try publicState(id)
        let record: ShareRecord
        switch (state, kind) {
        case (.unknown, _), (.pending, _):
            return notFound
        case let (.ended(_, code), .audio):
            return .error(410, code, "This share has ended.")
        case let (.ended(ended, code), _) where code == "play_cap":
            // Art and the card stay visible on a capped share, so the page can still show what it was.
            record = ended
        case let (.ended(_, code), _):
            return .error(410, code, "This share has ended.")
        case let (.ready(ready), _):
            record = ready
        }

        let contentType: String
        var headers = ["X-Content-Type-Options": "nosniff"]
        switch kind {
        case .audio:
            guard record.audioStored else { return notFound }
            let range = request.headers["range"]
            let counts = range == nil || range!.replacingOccurrences(of: " ", with: "").hasPrefix("bytes=0-")
            if counts {
                let now = self.now
                try store.increment(id: id, .fetches)
                try store.record(event: "audio_fetched", at: now, shareID: id, sharerID: record.sharerID,
                                 visitor: visitor(who, shareID: id))
                if record.stats.fetches + 1 == record.playCap {
                    try store.record(event: "share_capped", at: now, shareID: id, sharerID: record.sharerID)
                }
            }
            contentType = "application/octet-stream"
            headers["Cache-Control"] = "private, no-store"
        case .art:
            guard let type = record.artType else { return notFound }
            contentType = type
            headers["Cache-Control"] = "private, max-age=300"
        case .card:
            guard let type = record.cardType else { return notFound }
            contentType = type
            headers["Cache-Control"] = "public, max-age=300"
        }

        switch config.blobDelivery {
        case .accel:
            headers["X-Accel-Redirect"] = "\(config.accelPrefix)/\(id)/\(kind.rawValue)"
            return ShareResponse(status: 200, contentType: contentType, headers: headers)
        case .direct:
            guard let bytes = try? Data(contentsOf: store.blobURL(id: id, kind: kind)) else { return notFound }
            return ShareResponse(status: 200, contentType: contentType, body: bytes, headers: headers)
        }
    }

    func event(_ request: HTTPRequestMessage, id: String, who: ShareRequester) throws -> ShareResponse {
        if ShareLink.isValidID(id), let record = try store.share(id: id), try store.isEnforced(record) {
            return .error(410, "expired", "This share has ended.")
        }
        guard case let .ready(record) = try publicState(id) else {
            // A beacon for a share that has just ended, or a capped one: accepted and dropped, so
            // a player that finishes a song after the cap is hit does not log an error.
            return .noContent
        }
        let event: PlayerEvent
        do {
            event = try JSONDecoder().decode(PlayerEvent.self, from: request.body)
        } catch {
            return .error(400, "invalid", "Not a player event.")
        }
        let props = try event.props()
        let now = self.now
        let visitor = visitor(who, shareID: id)
        guard limiter.allow("event:\(visitor)", limit: config.limits.eventsPerVisitorPerMinute, per: 60, now: now) else {
            return rateLimited("events_minute", now: now)
        }
        switch event.type {
        case .playStarted: try store.increment(id: id, .plays)
        case .played30s: try store.increment(id: id, .listened30)
        case .playCompleted: try store.increment(id: id, .completed)
        default: break
        }
        try store.record(event: event.type.rawValue, at: now, shareID: id, sharerID: record.sharerID,
                         visitor: visitor, props: props)
        return .noContent
    }

    func react(_ request: HTTPRequestMessage, id: String, who: ShareRequester) throws -> ShareResponse {
        guard case let .ready(record) = try publicState(id) else {
            return .error(410, "expired", "This share has ended.")
        }
        let reaction: ReactionRequest
        do {
            reaction = try JSONDecoder().decode(ReactionRequest.self, from: request.body).validated()
        } catch let error as ShareValidationError {
            throw error
        } catch {
            return .error(400, "invalid", "Not a reaction.")
        }
        let now = self.now
        let visitor = visitor(who, shareID: id)
        guard try store.reactionCount(shareID: id, visitor: visitor, since: now - now % 86400)
            < config.limits.reactionsPerVisitorPerDay
        else { return rateLimited("reactions_daily", now: now) }
        var notificationFailed = false
        try store.database.transaction {
            try store.addReaction(shareID: id, reaction, visitor: visitor, at: now)
            try store.record(event: "reaction_sent", at: now, shareID: id, sharerID: record.sharerID, visitor: visitor,
                             props: ["emoji": .string(reaction.emoji), "hasName": .bool(!(reaction.name ?? "").isEmpty),
                                     "hasReply": .bool(!(reaction.reply ?? "").isEmpty)])
            // Queue saturation/disabled collection simply adds no notification. An optional
            // queue error rolls back its own writes without losing an otherwise valid reaction.
            // Failure to roll back/release or commit still fails the database transaction.
            if let push = reactionPushStore {
                try store.database.execute("SAVEPOINT reaction_notification")
                do {
                    _ = try push.enqueueWithinReactionTransaction(owner: record.sharerDigest, shareID: id,
                        shareExpiresAt: try pushMilliseconds(record.expiresAt), now: try pushMilliseconds(now))
                    try store.database.execute("RELEASE reaction_notification")
                } catch {
                    try store.database.execute("ROLLBACK TO reaction_notification")
                    try store.database.execute("RELEASE reaction_notification")
                    notificationFailed = true
                }
            }
        }
        reactionPushEnqueueFailed = notificationFailed
        return .noContent
    }

    private func pushMilliseconds(_ seconds: Int64) throws -> Int64 {
        guard seconds >= 0, seconds <= Int64.max / 1000 else { throw ReactionPushFailure.invalid }
        return seconds * 1000
    }

    /// Fresh admission under the same service lock; provider I/O happens after this returns.
    /// Production still needs protected registration admission, provider and activation wiring.
    func makeReactionPushDispatcher(provider: any ReactionPushProvider) -> ReactionPushDispatcher {
        ReactionPushDispatcher(provider: provider,
            prepare: { [weak self] in try self?.prepareReactionPush() },
            admit: { [weak self] lease in try self?.admitReactionPush(lease) ?? false },
            finish: { [weak self] lease, result in try self?.finishReactionPush(lease, result: result) })
    }

    private func prepareReactionPush() throws -> ReactionPushLease? {
        lock.lock(); defer { lock.unlock() }
        guard config.enabled, let push = reactionPushStore else { return nil }
        return try push.lease(now: pushMilliseconds(now))
    }

    func admitReactionPush(_ lease: ReactionPushLease) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard config.enabled, let push = reactionPushStore,
              try push.isCurrentLease(lease, now: pushMilliseconds(now)),
              let record = try store.share(id: lease.shareID), record.sharerDigest == lease.owner,
              record.status == .ready, record.expiresAt > now, try !store.isEnforced(record)
        else { return false }
        return true
    }

    private func finishReactionPush(_ lease: ReactionPushLease, result: ReactionPushResult) throws {
        lock.lock(); defer { lock.unlock() }
        try reactionPushStore?.complete(lease, result: result, now: pushMilliseconds(now))
    }

    // MARK: - Admin (§4.3)

    func adminStats(_ request: HTTPRequestMessage, who: ShareRequester) throws -> ShareResponse {
        // Through the proxy, the route does not exist. Only a caller on the host itself sees it.
        guard !who.viaProxy, let token = config.adminToken,
              BatonMCPAuth.constantTimeEquals(request.bearerToken ?? "", token)
        else { return .error(404, "not_found", "No such route.") }
        let days = min(max(Int(request.query["days"] ?? "7") ?? 7, 1), config.limits.retentionDays)
        // `offset` ends the window that many days ago, so a caller can ask for the period before
        // this one and compare like with like (distinct sharers cannot be subtracted).
        let offset = min(max(Int(request.query["offset"] ?? "0") ?? 0, 0), config.limits.retentionDays)
        let until = now - Int64(offset) * 86400
        let report = try ShareReport.build(store: store, since: until - Int64(days) * 86400, until: until,
                                           quotaBytes: config.limits.quotaBytes)
        return .json(report)
    }
}


extension ShareService {
    func mixtapePlayerPage(id: String, who: ShareRequester) throws -> ShareResponse {
        guard config.mixtapesEnabled else { return mixtapePage.render(id: nil, state: "unsupported") }
        guard ShareLink.isValidID(id), let record = try store.share(id: id), record.isMixtape else {
            return mixtapePage.render(id: nil, state: "unknown")
        }
        guard config.enabled, try !store.isEnforced(record), record.expiresAt > now,
              record.status == .ready || record.status == .pending else { return mixtapePage.render(id: id, state: "expired") }
        let state = record.status == .pending ? "pending" : "ready"
        if let app = ClientClass.crawler(userAgent: who.userAgent) {
            try store.record(event: "link_unfurled", at: now, shareID: id, sharerID: record.sharerID, props: ["app": .string(app)])
        } else {
            if record.status == .ready { try store.increment(id: id, .opens) }
            try store.record(event: "page_opened", at: now, shareID: id, sharerID: record.sharerID, visitor: visitor(who, shareID: id),
                             props: ["device": .string(ClientClass.device(userAgent: who.userAgent)), "state": .string(state)])
        }
        let preview = record.preview.map { MixtapePreview(title: $0.title, from: $0.from, note: $0.note) }
        return mixtapePage.render(id: id, state: state, preview: preview)
    }
}
