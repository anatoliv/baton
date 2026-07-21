import Foundation
import OSLog

/// Versioned, corruption-safe persistence for a Codable payload. (W-12 / Foundation F1)
///
/// Baton's stores used to do `try? decode else start-empty`, and the next mutation wrote
/// the empty state back over the old file — so one corrupt/truncated file (power loss) or
/// any future incompatible `Codable` change silently erased irreplaceable user data
/// (subscriptions, progress, listen history, the server list). `VersionedStore` fixes that:
///
///  - persists an envelope `{ version, payload }`;
///  - on a decode failure, renames the bad file aside as `<name>.corrupt-<timestamp>`
///    (never overwriting it) and returns nil — the caller starts empty, but the original
///    is preserved for recovery;
///  - optionally keeps a rolling `<name>.bak` last-good copy for precious stores;
///  - migrates a legacy *unversioned* file (a raw payload from an older build) as version 1;
///  - never fails a write silently — encode/write failures are logged at error level.
struct VersionedStore<Payload: Codable> {
    let fileURL: URL
    let currentVersion: Int
    /// Transforms an older decoded payload (with its stored version) into the current shape.
    let migrate: (Payload, Int) -> Payload
    /// Keep a rolling `.bak` of the last good file — for irreplaceable data.
    let keepBackup: Bool
    private let log: Logger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private struct Envelope: Codable { let version: Int; let payload: Payload }

    init(
        fileURL: URL,
        currentVersion: Int = 1,
        keepBackup: Bool = false,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        log: Logger = Logger(subsystem: "io.tonebox.baton", category: "persistence"),
        migrate: @escaping (Payload, Int) -> Payload = { payload, _ in payload }
    ) {
        self.fileURL = fileURL
        self.currentVersion = currentVersion
        self.keepBackup = keepBackup
        self.encoder = encoder
        self.decoder = decoder
        self.log = log
        self.migrate = migrate
    }

    /// Load the payload, or nil when the file is absent (a fresh install). A corrupt or
    /// unreadable file is preserved aside and reported — never silently discarded.
    func load() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil } // absent → fresh
        if let env = try? decoder.decode(Envelope.self, from: data) {
            return env.version == currentVersion ? env.payload : migrate(env.payload, env.version)
        }
        // Legacy: a raw (unversioned) payload written by an older build — adopt as v1.
        if let legacy = try? decoder.decode(Payload.self, from: data) {
            log.notice("migrating unversioned store \(fileURL.lastPathComponent, privacy: .public) → v\(currentVersion)")
            return migrate(legacy, 1)
        }
        preserveCorrupt(data)
        return nil
    }

    /// Write the payload as a versioned envelope (atomically). Returns false and logs on
    /// failure — a write never fails silently.
    @discardableResult
    func save(_ payload: Payload) -> Bool {
        do {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try encoder.encode(Envelope(version: currentVersion, payload: payload))
            if keepBackup, let existing = try? Data(contentsOf: fileURL) {
                try? existing.write(to: fileURL.appendingPathExtension("bak"))
            }
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            log.error("failed to persist \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func preserveCorrupt(_ data: Data) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = fileURL.appendingPathExtension("corrupt-\(stamp)")
        try? data.write(to: aside)
        log.error("store \(fileURL.lastPathComponent, privacy: .public) was unreadable — preserved as \(aside.lastPathComponent, privacy: .public); starting empty")
    }
}
