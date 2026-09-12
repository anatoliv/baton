import Foundation

/// Versioned, corruption-safe persistence for a Codable payload.
///
/// Baton's stores used to do `try? decode else start-empty`, and the next mutation wrote
/// the empty state back over the old file — so one corrupt/truncated file (power loss) or
/// any future incompatible `Codable` change silently erased irreplaceable user data
/// (subscriptions, progress, listen history, the server list). `VersionedStore` fixes that:
///
///  - persists an envelope `{ version, payload }`;
///  - on a decode failure, preserves the bad bytes as `<name>.corrupt-<timestamp>`
///    (never overwriting them) and returns nil — the caller starts empty, but the original
///    is kept for recovery;
///  - refuses to write over state stamped with a **newer** version than this build writes,
///    rather than downgrading it;
///  - optionally keeps a rolling `<name>.bak` last-good copy for precious stores;
///  - migrates a legacy *unversioned* payload (from an older build) as version 1;
///  - never fails a write silently — encode/write failures are logged at error level.
///
/// ## It is not only about files
///
/// The persisted play queue lives in `UserDefaults` under one key, and had every one of the
/// problems above: a truncated blob read as "no queue", and the next `persistQueue()` wrote an
/// empty one over it, so a long set vanished at launch with nothing said. Writing a second,
/// defaults-shaped copy of this logic is how the two would drift, so the backing is a choice
/// (`.file` or `.defaults`) over one implementation of the envelope, the forward guard, the
/// backup and the quarantine.
public struct VersionedStore<Payload: Codable> {
    /// Where the bytes live.
    public enum Backing {
        case file(URL)
        /// One `UserDefaults` key. The backup and the quarantine become sibling keys.
        case defaults(UserDefaults, key: String)
    }

    public let backing: Backing
    public let currentVersion: Int
    /// Transforms an older decoded payload (with its stored version) into the current shape.
    public let migrate: (Payload, Int) -> Payload
    /// Keep a rolling `.bak` of the last good state — for irreplaceable data.
    public let keepBackup: Bool
    private let log: Logger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private struct Envelope: Codable { let version: Int; let payload: Payload }

    /// The file this store writes, for the file-backed case.
    public var fileURL: URL? {
        if case let .file(url) = backing { return url }
        return nil
    }

    public init(
        fileURL: URL,
        currentVersion: Int = 1,
        keepBackup: Bool = false,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        log: Logger = Logger(subsystem: "io.tonebox.baton", category: "persistence"),
        migrate: @escaping (Payload, Int) -> Payload = { payload, _ in payload }
    ) {
        self.init(backing: .file(fileURL), currentVersion: currentVersion, keepBackup: keepBackup,
                  encoder: encoder, decoder: decoder, log: log, migrate: migrate)
    }

    public init(
        backing: Backing,
        currentVersion: Int = 1,
        keepBackup: Bool = false,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        log: Logger = Logger(subsystem: "io.tonebox.baton", category: "persistence"),
        migrate: @escaping (Payload, Int) -> Payload = { payload, _ in payload }
    ) {
        self.backing = backing
        self.currentVersion = currentVersion
        self.keepBackup = keepBackup
        self.encoder = encoder
        self.decoder = decoder
        self.log = log
        self.migrate = migrate
    }

    /// Why a load produced no payload, which is not one question but several.
    ///
    /// "Nil" used to mean all of them at once, and the caller could only start empty. They want
    /// opposite handling: a fresh install should write happily, a quarantined file should write
    /// (the original is safe aside), and state from a **newer build** must not be written over
    /// at all.
    public enum Outcome: Equatable, Sendable {
        /// The payload was read.
        case loaded
        /// Nothing stored yet.
        case fresh
        /// Unreadable; the bytes were preserved as `<name>.corrupt-<timestamp>`.
        case quarantined
        /// Unreadable, and the rescue copy could not be written. The original remains in place.
        case quarantineFailed
        /// Written by a build that stamps a higher version than this one understands.
        case newerThanThisBuild(found: Int)
    }

    /// Load the payload, or nil when nothing is stored (a fresh install). Corrupt or unreadable
    /// bytes are preserved aside and reported — never silently discarded.
    public func load() -> Payload? { loadWithOutcome().payload }

    /// The same load, with the reason it produced what it did.
    ///
    /// A separate entry point rather than a changed return type, so the existing adopters keep
    /// the call they have and only the stores that need to act on the reason ask for it.
    public func loadWithOutcome() -> (payload: Payload?, outcome: Outcome) {
        guard let data = readBytes() else { return (nil, .fresh) }
        if let env = try? decoder.decode(Envelope.self, from: data) {
            if env.version == currentVersion { return (env.payload, .loaded) }
            // State from a newer build. Without this branch it went to the identity migration,
            // was adopted as current, and the next `save` re-stamped it as this build's version —
            // destroying the number a future migration keys on, and quietly downgrading whatever
            // the newer build had added. `save` refuses after this, so a downgraded app reads it
            // and stops writing rather than replacing it (S-F14).
            guard env.version < currentVersion else {
                log.error("""
                    store \(name, privacy: .public) is version \(env.version) and this build \
                    understands \(currentVersion); reading it but refusing to write, so a newer \
                    build's data is not downgraded.
                    """)
                return (env.payload, .newerThanThisBuild(found: env.version))
            }
            return (migrate(env.payload, env.version), .loaded)
        }
        // Legacy: a raw (unversioned) payload written by an older build — adopt as v1.
        if let legacy = try? decoder.decode(Payload.self, from: data) {
            log.notice("migrating unversioned store \(name, privacy: .public) → v\(currentVersion)")
            return (migrate(legacy, 1), .loaded)
        }
        guard preserveCorrupt(data) else { return (nil, .quarantineFailed) }
        discardQuarantinedOriginal()
        return (nil, .quarantined)
    }

    /// Write the payload as a versioned envelope (atomically, for a file). Returns false and logs
    /// on failure — a write never fails silently.
    ///
    /// It also refuses to write over state stamped with a **higher** version than this build
    /// writes. The stamp is re-read here rather than carried as a flag from the last load,
    /// because the stored bytes can be replaced under a long-lived store (a settings import does
    /// exactly that) and a stale flag would let through the very downgrade this exists to stop.
    @discardableResult
    public func save(_ payload: Payload) -> Bool {
        if let found = storedVersionIfNewer() {
            log.error("""
                refusing to write \(name, privacy: .public): stored is version \(found), this \
                build writes \(currentVersion). Overwriting would downgrade it.
                """)
            return false
        }
        if let unreadable = unreadableStoredBytes() {
            guard preserveCorrupt(unreadable) else {
                log.error("refusing to replace unreadable store \(name, privacy: .public) because its rescue copy failed")
                return false
            }
            discardQuarantinedOriginal()
        }
        do {
            let data = try encoder.encode(Envelope(version: currentVersion, payload: payload))
            if keepBackup, let existing = readBytes() { writeBackup(existing) }
            try writeBytes(data)
            return true
        } catch {
            log.error("failed to persist \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The version stamped on the stored bytes, when it is higher than this build's.
    private func storedVersionIfNewer() -> Int? {
        guard let data = readBytes(),
              let stamp = try? decoder.decode(VersionStamp.self, from: data),
              stamp.version > currentVersion
        else { return nil }
        return stamp.version
    }

    private func unreadableStoredBytes() -> Data? {
        guard let data = readBytes(),
              (try? decoder.decode(Envelope.self, from: data)) == nil,
              (try? decoder.decode(Payload.self, from: data)) == nil
        else { return nil }
        return data
    }

    @discardableResult
    private func preserveCorrupt(_ data: Data) -> Bool {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        switch backing {
        case let .file(url):
            let aside = url.appendingPathExtension("corrupt-\(stamp)")
            do {
                try data.write(to: aside, options: .atomic)
                log.error("store \(name, privacy: .public) was unreadable, preserved as \(aside.lastPathComponent, privacy: .public); starting empty")
                return true
            } catch {
                log.error("store \(name, privacy: .public) was unreadable and its rescue copy could not be written; leaving the original in place: \(error.localizedDescription, privacy: .public)")
                return false
            }
        case let .defaults(defaults, key):
            defaults.set(data, forKey: "\(key).corrupt-\(stamp)")
            log.error("store \(name, privacy: .public) was unreadable, preserved under \(key, privacy: .public).corrupt-\(stamp, privacy: .public); starting empty")
            return true
        }
    }

    private func discardQuarantinedOriginal() {
        switch backing {
        case let .file(url):
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                log.error("preserved unreadable store \(name, privacy: .public), but could not remove the quarantined original: \(error.localizedDescription, privacy: .public)")
            }
        case let .defaults(defaults, key):
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Bytes

    private var name: String {
        switch backing {
        case let .file(url): url.lastPathComponent
        case let .defaults(_, key): key
        }
    }

    private func readBytes() -> Data? {
        switch backing {
        case let .file(url): try? Data(contentsOf: url)
        case let .defaults(defaults, key): defaults.data(forKey: key)
        }
    }

    private func writeBytes(_ data: Data) throws {
        switch backing {
        case let .file(url):
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        case let .defaults(defaults, key):
            defaults.set(data, forKey: key)
        }
    }

    private func writeBackup(_ existing: Data) {
        switch backing {
        case let .file(url):
            // `.atomic`, because a `.bak` is only worth having if it cannot itself be the
            // truncated file. Without it the backup for a "precious store" is written in place
            // and a crash mid-write leaves both copies damaged (S-F14).
            try? existing.write(to: url.appendingPathExtension("bak"), options: .atomic)
        case let .defaults(defaults, key):
            defaults.set(existing, forKey: "\(key).bak")
        }
    }
}

/// Just the version field of an envelope, so the forward guard can read the stamp without
/// needing to decode a payload it may well not understand — which is the whole point of it.
private struct VersionStamp: Decodable { let version: Int }
