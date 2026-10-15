import BatonShareKit
import Crypto
import CoreFoundation
import Foundation

enum ReactionPushFailure: Error { case disabled, invalid, capacity, rateLimited, keyUnavailable }
enum PushEnvironment: String, Sendable { case sandbox, production }

/// No runtime key generation, credential reuse, token collection or provider activation.
struct ReactionPushPolicy: Sendable {
    var enabled: Bool
    let key: Data?
    let topics: [String: PushEnvironment]
    let devicesPerOwner: Int
    let queueLimit: Int
    let totalDevices: Int
    let protectedBytes: Int
    let registrationTTL: Int64 = 30 * 86400 * 1000
    let jobTTL: Int64 = 3600 * 1000
    let coalesceDelay: Int64 = 60 * 1000
    let leaseDuration: Int64 = 30 * 1000
    let maxAttempts = 4

    init(enabled: Bool = false, key: Data? = nil, topics: [String: PushEnvironment] = [:],
         devicesPerOwner: Int = 4, queueLimit: Int = 1000,
         totalDevices: Int = 5000, protectedBytes: Int = 4_194_304) throws {
        guard (1 ... 8).contains(devicesPerOwner), (1 ... 10000).contains(queueLimit),
              (1 ... 100000).contains(totalDevices), (256 ... 134_217_728).contains(protectedBytes),
              topics.count <= 4,
              topics.keys.allSatisfy({ $0.range(of: "^[A-Za-z0-9.-]{1,255}$", options: .regularExpression) != nil })
        else { throw ReactionPushFailure.invalid }
        if enabled {
            guard key?.count == 32, !topics.isEmpty else { throw ReactionPushFailure.keyUnavailable }
        }
        self.enabled = enabled; self.key = key; self.topics = topics
        self.devicesPerOwner = devicesPerOwner; self.queueLimit = queueLimit
        self.totalDevices = totalDevices; self.protectedBytes = protectedBytes
    }
}

struct ReactionPushLease: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let jobID: String
    let leaseID: String
    let owner: String
    let deviceID: String
    let revision: String
    let generation: Int64
    let registeredAt: Int64
    let shareID: String
    let topic: String
    let environment: PushEnvironment
    let token: Data
    let deadline: Int64
    let expiration: Int64
    var description: String { "ReactionPushLease(redacted)" }
    var debugDescription: String { description }
    var payload: Data {
        // No key, title, emoji, name, reply or recipient identity.
        try! JSONSerialization.data(withJSONObject: [
            "aps": ["alert": "Someone reacted to your shared song."],
            "baton": ["v": 1, "route": "shared-links", "shareID": shareID],
        ])
    }
    var collapseID: String { "reaction-" + ShareHash.sha256Hex(Data((owner + shareID).utf8)).prefix(40) }
}

enum ReactionPushResult: Equatable, Sendable {
    case accepted // APNs accepted; does not mean delivered/displayed/read.
    case inactive(timestampMilliseconds: Int64)
    case invalidToken
    case retry(delayMilliseconds: Int64)
    case providerPaused
    case discarded

    /// Response bytes never become logs/errors; unknown or oversized bodies fail conservatively.
    static func classify(status: Int, body: Data) -> Self {
        guard body.count <= 4096 else { return .providerPaused }
        if status == 200 { return .accepted }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reason = json?["reason"] as? String
        if status == 410 {
            guard ["Unregistered", "ExpiredToken"].contains(reason ?? ""),
                  let number = json?["timestamp"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue < Double(Int64.max),
                  number.doubleValue.rounded() == number.doubleValue
            else { return .discarded }
            return .inactive(timestampMilliseconds: number.int64Value)
        }
        if status == 400, reason == "BadDeviceToken" { return .invalidToken }
        if status == 429, reason == "TooManyRequests" { return .retry(delayMilliseconds: 60_000) }
        if (500 ... 599).contains(status) { return .retry(delayMilliseconds: 900_000) }
        // Credential/topic/payload/provider-token-rate errors require an explicit fix/resume.
        if [400, 403, 404, 405, 413, 429].contains(status) { return .providerPaused }
        return .discarded
    }
}

/// Synchronous and unlocked, like ShareStore. The caller serializes every operation with the
/// SAME service lock/connection when integrated. No provider I/O or callback is made here.
final class ReactionPushStore {
    let database: SQLiteDatabase
    var policy: ReactionPushPolicy

    init(database: SQLiteDatabase, policy: ReactionPushPolicy = try! ReactionPushPolicy()) throws {
        self.database = database; self.policy = policy
        try database.execute("""
        CREATE TABLE IF NOT EXISTS reaction_push_devices(
          owner TEXT NOT NULL, device_id TEXT NOT NULL, revision TEXT NOT NULL,
          token_hash TEXT NOT NULL, sealed_token TEXT NOT NULL, topic TEXT NOT NULL,
          environment TEXT NOT NULL, registered_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
          PRIMARY KEY(owner,device_id));
        CREATE UNIQUE INDEX IF NOT EXISTS reaction_push_token ON reaction_push_devices(token_hash,topic,environment);
        CREATE TABLE IF NOT EXISTS reaction_push_jobs(
          id TEXT PRIMARY KEY, owner TEXT NOT NULL, device_id TEXT NOT NULL, revision TEXT NOT NULL,
          share_id TEXT NOT NULL, generation INTEGER NOT NULL, due_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL, attempts INTEGER NOT NULL, lease_id TEXT, lease_until INTEGER,
          UNIQUE(owner,device_id,revision,share_id));
        CREATE INDEX IF NOT EXISTS reaction_push_due ON reaction_push_jobs(due_at);
        CREATE TABLE IF NOT EXISTS reaction_push_meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS reaction_push_registration_updates(
          owner TEXT PRIMARY KEY, day INTEGER NOT NULL, updates INTEGER NOT NULL, expires_at INTEGER NOT NULL);
        """)
    }

    /// Fresh public service initialization must not create a token schema. Existing protected
    /// state is attached only for key-free cleanup, including a default-off restart.
    static func hasExistingStorage(in database: SQLiteDatabase) throws -> Bool {
        try database.scalar("""
          SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN
          ('reaction_push_devices','reaction_push_jobs','reaction_push_meta','reaction_push_registration_updates')
          """) > 0
    }

    /// Install only when attached to ShareService's real state tables. These triggers run in
    /// the same SQLite transaction as revoke/expiry/delete or operator apply; rollback restores
    /// both state and queued work. Restoration/unsuspension never recreates cancelled jobs.
    func installShareLifecycleHooks() throws {
        try database.execute("""
        CREATE TRIGGER IF NOT EXISTS reaction_push_cancel_ended_share
          AFTER UPDATE OF status ON shares WHEN NEW.status!='ready'
          BEGIN DELETE FROM reaction_push_jobs WHERE share_id=NEW.id; END;
        CREATE TRIGGER IF NOT EXISTS reaction_push_cancel_deleted_share
          AFTER DELETE ON shares
          BEGIN DELETE FROM reaction_push_jobs WHERE share_id=OLD.id; END;
        CREATE TRIGGER IF NOT EXISTS reaction_push_cancel_inserted_hold
          AFTER INSERT ON share_enforcement WHEN NEW.disabled=1
          BEGIN DELETE FROM reaction_push_jobs WHERE share_id=NEW.share_id; END;
        CREATE TRIGGER IF NOT EXISTS reaction_push_cancel_updated_hold
          AFTER UPDATE OF disabled ON share_enforcement WHEN NEW.disabled=1
          BEGIN DELETE FROM reaction_push_jobs WHERE share_id=NEW.share_id; END;
        CREATE TRIGGER IF NOT EXISTS reaction_push_cancel_inserted_suspension
          AFTER INSERT ON sharer_enforcement WHEN NEW.suspended=1
          BEGIN DELETE FROM reaction_push_jobs WHERE owner=NEW.digest; END;
        CREATE TRIGGER IF NOT EXISTS reaction_push_cancel_updated_suspension
          AFTER UPDATE OF suspended ON sharer_enforcement WHEN NEW.suspended=1
          BEGIN DELETE FROM reaction_push_jobs WHERE owner=NEW.digest; END;
        """)
    }

    /// No key/enable/provider is needed to expire protected material or cancel unavailable
    /// shares. Old rows also get cleaned after upgrading from a pre-hook implementation.
    func sweepShareLifecycle(nowMilliseconds: Int64) throws {
        try validTime(nowMilliseconds)
        try database.transaction {
            try sweep(now: nowMilliseconds)
            try database.run("""
              DELETE FROM reaction_push_jobs WHERE NOT EXISTS (
                SELECT 1 FROM shares s WHERE s.id=reaction_push_jobs.share_id
                  AND s.sharer_digest=reaction_push_jobs.owner AND s.status='ready' AND s.expires_at>?
                  AND NOT EXISTS(SELECT 1 FROM share_enforcement e WHERE e.share_id=s.id AND e.disabled=1)
                  AND NOT EXISTS(SELECT 1 FROM sharer_enforcement e WHERE e.digest=s.sharer_digest AND e.suspended=1)
              )
              """, [.int(nowMilliseconds / 1000)])
        }
    }

    private func enabled() throws -> SymmetricKey {
        guard policy.enabled else { throw ReactionPushFailure.disabled }
        guard let key = policy.key, key.count == 32 else { throw ReactionPushFailure.keyUnavailable }
        return SymmetricKey(data: key)
    }
    private func validTime(_ now: Int64) throws {
        guard now >= 0, now < Int64.max - policy.registrationTTL else { throw ReactionPushFailure.invalid }
    }
    private func ownerValid(_ owner: String) -> Bool {
        owner.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
    private func aad(owner: String, device: String, revision: String, topic: String, environment: String) -> Data {
        Data([owner, device, revision, topic, environment].joined(separator: "|").utf8)
    }

    /// Caller must authenticate owner before this API. Registration/rotation retires old jobs.
    @discardableResult
    func register(owner: String, deviceID: String, token: Data, topic: String,
                  environment: PushEnvironment, now: Int64) throws -> String {
        let key = try enabled(); try validTime(now)
        guard ownerValid(owner), UUID(uuidString: deviceID)?.uuidString == deviceID,
              (1 ... 1024).contains(token.count), policy.topics[topic] == environment
        else { throw ReactionPushFailure.invalid }
        return try database.transaction {
            try sweep(now: now)
            let day = now / 86_400_000
            if try database.scalar("SELECT updates FROM reaction_push_registration_updates WHERE owner=? AND day=?", [.text(owner), .int(day)]) >= 64 {
                throw ReactionPushFailure.rateLimited
            }
            let current = try database.scalar("SELECT COUNT(*) FROM reaction_push_devices WHERE owner=? AND device_id=?", [.text(owner), .text(deviceID)])
            if current == 0, try database.scalar("SELECT COUNT(*) FROM reaction_push_devices") >= policy.totalDevices {
                throw ReactionPushFailure.capacity
            }
            let previousBytes = try database.scalar("SELECT COALESCE(SUM(LENGTH(sealed_token)),0) FROM reaction_push_devices WHERE owner=? AND device_id=?", [.text(owner), .text(deviceID)])
            let sealedBytes = ((token.count + 28 + 2) / 3) * 4
            if try database.scalar("SELECT COALESCE(SUM(LENGTH(sealed_token)),0) FROM reaction_push_devices") - previousBytes + Int64(sealedBytes) > Int64(policy.protectedBytes) {
                throw ReactionPushFailure.capacity
            }
            if try database.scalar("SELECT COUNT(*) FROM reaction_push_registration_updates WHERE owner=?", [.text(owner)]) == 0,
               try database.scalar("SELECT COUNT(*) FROM reaction_push_registration_updates") >= Int64(policy.totalDevices * 2) {
                throw ReactionPushFailure.capacity
            }
            if current == 0, try database.scalar("SELECT COUNT(*) FROM reaction_push_devices WHERE owner=?", [.text(owner)]) >= policy.devicesPerOwner {
                throw ReactionPushFailure.capacity
            }
            let hash = ShareHash.sha256Hex(token)
            let old = try database.query("SELECT owner,device_id FROM reaction_push_devices WHERE token_hash=? AND topic=? AND environment=?",
                                         [.text(hash), .text(topic), .text(environment.rawValue)])
            for row in old {
                if let owner = row["owner"]?.text, let device = row["device_id"]?.text { try removeDeviceWithinTransaction(owner: owner, deviceID: device) }
            }
            try removeDeviceWithinTransaction(owner: owner, deviceID: deviceID)
            let revision = UUID().uuidString
            let sealed = try AES.GCM.seal(token, using: key,
                authenticating: aad(owner: owner, device: deviceID, revision: revision, topic: topic, environment: environment.rawValue))
            guard let ciphertext = sealed.combined else { throw ReactionPushFailure.keyUnavailable }
            try database.run("INSERT INTO reaction_push_devices VALUES(?,?,?,?,?,?,?,?,?)", [
                .text(owner), .text(deviceID), .text(revision), .text(hash), .text(ciphertext.base64EncodedString()),
                .text(topic), .text(environment.rawValue), .int(now), .int(now + policy.registrationTTL),
            ])
            try database.run("INSERT INTO reaction_push_registration_updates VALUES(?,?,1,?) ON CONFLICT(owner) DO UPDATE SET updates=CASE WHEN day=excluded.day THEN updates+1 ELSE 1 END,day=excluded.day,expires_at=excluded.expires_at",
                             [.text(owner), .int(day), .int((day + 1) * 86_400_000)])
            return revision
        }
    }

    /// Available even when collection is disabled: explicit opt-out always removes material.
    func optOut(owner: String, deviceID: String) throws {
        try database.transaction { try removeDeviceWithinTransaction(owner: owner, deviceID: deviceID) }
    }
    private func removeDeviceWithinTransaction(owner: String, deviceID: String) throws {
        try database.run("DELETE FROM reaction_push_jobs WHERE owner=? AND device_id=?", [.text(owner), .text(deviceID)])
        try database.run("DELETE FROM reaction_push_devices WHERE owner=? AND device_id=?", [.text(owner), .text(deviceID)])
    }

    /// MUST be called inside the caller's reaction/event transaction; intentionally no nested
    /// transaction. Capacity saturation drops notification work, not the accepted reaction.
    @discardableResult
    func enqueueWithinReactionTransaction(owner: String, shareID: String, shareExpiresAt: Int64, now: Int64) throws -> Int {
        guard policy.enabled else { return 0 }
        _ = try enabled(); try validTime(now)
        guard ownerValid(owner), ShareLink.isValidID(shareID) else { throw ReactionPushFailure.invalid }
        guard shareExpiresAt > now else { return 0 }
        // This remains part of the caller's reaction transaction. Do not coalesce fresh
        // work into a dead retention window, or let expired rows consume queue capacity.
        try database.run("DELETE FROM reaction_push_jobs WHERE expires_at<=?", [.int(now)])
        let devices = try database.query("SELECT device_id,revision FROM reaction_push_devices WHERE owner=? AND expires_at>? LIMIT ?",
                                         [.text(owner), .int(now), .int(Int64(policy.devicesPerOwner))])
        var added = 0
        for device in devices {
            guard let id = device["device_id"]?.text, let revision = device["revision"]?.text else { continue }
            let parameters: [SQLValue] = [.text(owner), .text(id), .text(revision), .text(shareID)]
            let existing = try database.run("UPDATE reaction_push_jobs SET generation=generation+1 WHERE owner=? AND device_id=? AND revision=? AND share_id=?", parameters)
            if existing > 0 { added += 1; continue }
            if try database.scalar("SELECT COUNT(*) FROM reaction_push_jobs") >= policy.queueLimit { continue }
            let expires = min(shareExpiresAt, now + policy.jobTTL)
            try database.run("INSERT INTO reaction_push_jobs VALUES(?,?,?,?,?,1,?,?,0,NULL,NULL)", [
                .text(UUID().uuidString)] + parameters + [.int(min(now + policy.coalesceDelay, expires)), .int(expires)])
            added += 1
        }
        return added
    }

    func cancel(shareID: String) throws { try database.run("DELETE FROM reaction_push_jobs WHERE share_id=?", [.text(shareID)]) }
    func sweep(now: Int64) throws {
        try database.run("DELETE FROM reaction_push_registration_updates WHERE expires_at<=?", [.int(now)])
        // A crashed/lost-response attempt is uncertain, not proof of non-delivery. Fence its
        // old lease and delay recovery at least fifteen minutes, preserving bounded attempts.
        try database.run("UPDATE reaction_push_jobs SET due_at=MAX(due_at,lease_until+900000),lease_id=NULL,lease_until=NULL WHERE lease_until<=?", [.int(now)])
        try database.run("DELETE FROM reaction_push_devices WHERE expires_at<=?", [.int(now)])
        try database.run("DELETE FROM reaction_push_jobs WHERE expires_at<=? OR (attempts>=? AND lease_id IS NULL) OR NOT EXISTS(SELECT 1 FROM reaction_push_devices d WHERE d.owner=reaction_push_jobs.owner AND d.device_id=reaction_push_jobs.device_id AND d.revision=reaction_push_jobs.revision)", [.int(now), .int(Int64(policy.maxAttempts))])
    }

    /// No feature-off lease recovery/send. Existing protected rows are still swept/opted out.
    func lease(now: Int64) throws -> ReactionPushLease? {
        guard policy.enabled else { return nil }
        let key = try enabled(); try validTime(now)
        return try database.transaction { () -> ReactionPushLease? in
            try sweep(now: now)
            if try database.scalar("SELECT COALESCE(MAX(value),0) FROM reaction_push_meta WHERE key='paused'") > 0 { return nil }
            // Filter before LIMIT: an obsolete topic/environment must not block unrelated
            // eligible jobs. Its protected rows keep their existing bounded expiry.
            let topics = policy.topics.sorted { $0.key < $1.key }
            guard !topics.isEmpty else { return nil }
            let allowed = topics.map { _ in "(d.topic=? AND d.environment=?)" }.joined(separator: " OR ")
            let topicParameters: [SQLValue] = topics.flatMap { [.text($0.key), .text($0.value.rawValue)] }
            guard let row = try database.query("""
              SELECT j.*,d.sealed_token,d.topic,d.environment,d.registered_at FROM reaction_push_jobs j
              JOIN reaction_push_devices d ON d.owner=j.owner AND d.device_id=j.device_id AND d.revision=j.revision
              WHERE j.due_at<=? AND (j.lease_until IS NULL OR j.lease_until<=?) AND (\(allowed))
              ORDER BY j.due_at,j.id LIMIT 1
              """, [.int(now), .int(now)] + topicParameters).first,
                  let job = row["id"]?.text, let owner = row["owner"]?.text, let device = row["device_id"]?.text,
                  let revision = row["revision"]?.text, let shareID = row["share_id"]?.text,
                  let topic = row["topic"]?.text, let environmentRaw = row["environment"]?.text,
                  let environment = PushEnvironment(rawValue: environmentRaw),
                  policy.topics[topic] == environment,
                  let sealedText = row["sealed_token"]?.text
            else { return nil }
            guard let sealed = Data(base64Encoded: sealedText) else { throw ReactionPushFailure.keyUnavailable }
            let token: Data
            do { token = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key,
                  authenticating: aad(owner: owner, device: device, revision: revision, topic: topic, environment: environmentRaw)) }
            catch { throw ReactionPushFailure.keyUnavailable }
            let leaseID = UUID().uuidString
            let deadline = min(now + policy.leaseDuration, row["expires_at"]?.int ?? now)
            try database.run("UPDATE reaction_push_jobs SET lease_id=?,lease_until=?,attempts=attempts+1 WHERE id=?",
                             [.text(leaseID), .int(deadline), .text(job)])
            return ReactionPushLease(jobID: job, leaseID: leaseID, owner: owner, deviceID: device, revision: revision,
                generation: row["generation"]?.int ?? 1, registeredAt: row["registered_at"]?.int ?? 0,
                shareID: shareID, topic: topic, environment: environment, token: token, deadline: deadline,
                expiration: row["expires_at"]?.int ?? now)
        }
    }

    /// Revalidate the current protected registration and exact unexpired lease immediately
    /// before provider admission. A changed key, token, topic, revision or opt-out fails closed.
    func isCurrentLease(_ lease: ReactionPushLease, now: Int64) throws -> Bool {
        guard policy.enabled, policy.topics[lease.topic] == lease.environment,
              now < lease.deadline, now < lease.expiration else { return false }
        let key = try enabled(); try validTime(now)
        guard try database.scalar("SELECT COALESCE(MAX(value),0) FROM reaction_push_meta WHERE key='paused'") == 0
        else { return false }
        guard let row = try database.query("""
          SELECT d.sealed_token,d.registered_at FROM reaction_push_jobs j
          JOIN reaction_push_devices d ON d.owner=j.owner AND d.device_id=j.device_id AND d.revision=j.revision
          WHERE j.id=? AND j.lease_id=? AND j.owner=? AND j.device_id=? AND j.revision=?
            AND j.share_id=? AND j.lease_until=? AND j.expires_at>? AND d.expires_at>?
            AND d.topic=? AND d.environment=?
          """, [.text(lease.jobID), .text(lease.leaseID), .text(lease.owner), .text(lease.deviceID),
                 .text(lease.revision), .text(lease.shareID), .int(lease.deadline), .int(now), .int(now),
                 .text(lease.topic), .text(lease.environment.rawValue)]).first,
              row["registered_at"]?.int == lease.registeredAt,
              let text = row["sealed_token"]?.text, let bytes = Data(base64Encoded: text)
        else { return false }
        // No token or database/provider error becomes a log or client response.
        guard let token = try? AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key,
            authenticating: aad(owner: lease.owner, device: lease.deviceID, revision: lease.revision,
                               topic: lease.topic, environment: lease.environment.rawValue))
        else { return false }
        return token == lease.token
    }

    /// Exact lease/revision fencing prevents late provider outcomes from mutating newer work.
    func complete(_ lease: ReactionPushLease, result: ReactionPushResult, now: Int64) throws {
        try validTime(now)
        try database.transaction {
            try sweep(now: now)
            guard let row = try database.query("SELECT generation,attempts,expires_at FROM reaction_push_jobs WHERE id=? AND lease_id=? AND revision=?",
                [.text(lease.jobID), .text(lease.leaseID), .text(lease.revision)]).first else { return }
            switch result {
            case .invalidToken:
                try retire(lease)
            case let .inactive(timestamp):
                if timestamp >= lease.registeredAt { try retire(lease) }
                else { try remove(lease) }
            case .discarded:
                try remove(lease)
            case .providerPaused:
                try database.run("INSERT OR REPLACE INTO reaction_push_meta VALUES('paused',1)")
                try remove(lease)
            case .accepted:
                if (row["generation"]?.int ?? 0) > lease.generation {
                    try requeue(lease, due: now + policy.coalesceDelay, resetAttempts: true)
                } else { try remove(lease) }
            case let .retry(delay):
                let attempts = row["attempts"]?.int ?? 0
                let due = now + max(60_000, min(delay, 3_600_000)) * max(1, attempts)
                if attempts >= policy.maxAttempts || due >= (row["expires_at"]?.int ?? 0) { try remove(lease) }
                else { try requeue(lease, due: due) }
            }
        }
    }
    private func remove(_ lease: ReactionPushLease) throws {
        try database.run("DELETE FROM reaction_push_jobs WHERE id=? AND lease_id=?", [.text(lease.jobID), .text(lease.leaseID)])
    }
    private func retire(_ lease: ReactionPushLease) throws {
        try database.run("DELETE FROM reaction_push_devices WHERE owner=? AND device_id=? AND revision=?",
                         [.text(lease.owner), .text(lease.deviceID), .text(lease.revision)])
        try database.run("DELETE FROM reaction_push_jobs WHERE owner=? AND device_id=? AND revision=?",
                         [.text(lease.owner), .text(lease.deviceID), .text(lease.revision)])
    }
    private func requeue(_ lease: ReactionPushLease, due: Int64, resetAttempts: Bool = false) throws {
        try database.run("UPDATE reaction_push_jobs SET due_at=?,attempts=CASE WHEN ?=1 THEN 0 ELSE attempts END,lease_id=NULL,lease_until=NULL WHERE id=? AND lease_id=?",
                         [.int(due), .int(resetAttempts ? 1 : 0), .text(lease.jobID), .text(lease.leaseID)])
    }
    /// A reviewed credential/configuration correction is required before the caller resumes.
    func resumeProviderAfterConfigurationFix() throws {
        try database.run("DELETE FROM reaction_push_meta WHERE key='paused'")
    }
}

protocol ReactionPushProvider: Sendable {
    /// Actual HTTP/2 implementation must enforce deadline and settle/cancel its transport before
    /// returning/throwing. No timeout task race that leaves an unbounded send running behind it.
    func send(_ lease: ReactionPushLease) async throws -> ReactionPushResult
}

/// One live provider attempt per dispatcher even across actor reentrancy. Hooks must briefly
/// acquire/release the owning service lock themselves; no lock crosses any await/provider call.
actor ReactionPushDispatcher {
    let provider: any ReactionPushProvider
    let prepare: @Sendable () async throws -> ReactionPushLease?
    let admit: @Sendable (ReactionPushLease) async throws -> Bool
    let finish: @Sendable (ReactionPushLease, ReactionPushResult) async throws -> Void
    private var inFlight = false
    var schedulerRunning = false
    init(provider: any ReactionPushProvider,
         prepare: @escaping @Sendable () async throws -> ReactionPushLease?,
         admit: @escaping @Sendable (ReactionPushLease) async throws -> Bool,
         finish: @escaping @Sendable (ReactionPushLease, ReactionPushResult) async throws -> Void) {
        self.provider = provider; self.prepare = prepare; self.admit = admit; self.finish = finish
    }
    @discardableResult
    func runOnce() async throws -> Bool {
        guard !inFlight else { return false }
        inFlight = true; defer { inFlight = false }
        guard !Task.isCancelled, let lease = try await prepare() else { return false }
        guard !Task.isCancelled, try await admit(lease), !Task.isCancelled else {
            try await finish(lease, .discarded); return false
        }
        let result: ReactionPushResult
        do { result = try await provider.send(lease) }
        catch { result = .retry(delayMilliseconds: 900_000) } // Unknown delivery; duplicates possible.
        try await finish(lease, result)
        return true
    }
}
