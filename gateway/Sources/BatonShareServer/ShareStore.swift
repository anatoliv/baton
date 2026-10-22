import BatonShareKit
import Foundation

/// One share as the store holds it.
public struct ShareRecord: Equatable, Sendable {
    public var id: String
    public var sharerDigest: String
    public var sharerID: String
    public var status: ShareStatus
    public var createdAt: Int64
    public var expiresAt: Int64
    public var playCap: Int
    public var isPrivate: Bool
    public var preview: ShareMetadata?
    public var encryptedMeta: String?
    public var audioBytes: Int
    public var audioSHA256: String
    public var audioStored: Bool
    /// `nil`, `image/jpeg`, `image/png`, or `application/octet-stream` for private artwork.
    public var artType: String?
    public var cardType: String?
    public var storedBytes: Int64
    public var stats: ShareStats
    public var reviewPreservationConsent: String? = nil
    public var isMixtape: Bool = false
    /// A whole-book link (`/b/`): also `isMixtape`, so every song route refuses it.
    public var isBook: Bool = false
    public var accessGeneration: Int64 = 1
    /// A `/b/` link's collection kind (album or playlist); nil for a book and every other share.
    public var bookKind: ShareCollectionKind? = nil

    /// Whether the play cap has been reached: the audio answers 410 from here on.
    public var isCapped: Bool { stats.fetches >= playCap }
}

/// The SQLite tables and the blob directory behind `baton-share` (spec §5, §7).
///
/// Everything here is synchronous and unlocked. `ShareService` is the only caller and holds its
/// lock around every call, so the store can assume one thread at a time and say so plainly
/// rather than half-defending against concurrency it never sees.
public final class ShareStore {
    public static let schemaVersion = 3

    let database: SQLiteDatabase
    public let root: URL
    public var blobsDirectory: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    public var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Permissions are part of the deployment, so they are set here rather than left to a umask.
        // nginx in another container serves the blobs as a different user, so the path to them is
        // world-readable; the database (sharer digests, events) is not. SQLite gives its -wal and
        // -shm files the database's mode *when it creates them*, so the database is made private
        // before SQLite first opens it, and any older sidecar files are tightened too.
        let manager = FileManager.default
        let databasePath = root.appendingPathComponent("share.sqlite").path
        if !manager.fileExists(atPath: databasePath) {
            manager.createFile(atPath: databasePath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        for path in [databasePath, databasePath + "-wal", databasePath + "-shm"] where manager.fileExists(atPath: path) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        database = try SQLiteDatabase(path: databasePath)
        try manager.createDirectory(at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try migrate()
        try migrateEnforcement()
        try migrateMixtapes()
        try migrateBooks()
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobsDirectory.path)
    }

    private func migrate() throws {
        try database.execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sharers(
            digest TEXT PRIMARY KEY,
            sharer_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            platform TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS shares(
            id TEXT PRIMARY KEY,
            sharer_digest TEXT NOT NULL,
            sharer_id TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            ended_at INTEGER,
            play_cap INTEGER NOT NULL,
            is_private INTEGER NOT NULL,
            preview TEXT,
            encrypted_meta TEXT,
            audio_bytes INTEGER NOT NULL,
            audio_sha256 TEXT NOT NULL,
            audio_stored INTEGER NOT NULL DEFAULT 0,
            art_type TEXT,
            card_type TEXT,
            stored_bytes INTEGER NOT NULL DEFAULT 0,
            opens INTEGER NOT NULL DEFAULT 0,
            fetches INTEGER NOT NULL DEFAULT 0,
            plays INTEGER NOT NULL DEFAULT 0,
            listened30 INTEGER NOT NULL DEFAULT 0,
            completed INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS shares_by_sharer ON shares(sharer_digest, created_at);
        CREATE INDEX IF NOT EXISTS shares_by_status ON shares(status, expires_at);
        CREATE TABLE IF NOT EXISTS events(
            id INTEGER PRIMARY KEY,
            at INTEGER NOT NULL,
            type TEXT NOT NULL,
            share_id TEXT,
            sharer_id TEXT,
            visitor TEXT,
            props TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS events_by_time ON events(at);
        CREATE INDEX IF NOT EXISTS events_by_share ON events(share_id, type);
        CREATE TABLE IF NOT EXISTS reactions(
            id INTEGER PRIMARY KEY,
            share_id TEXT NOT NULL,
            at INTEGER NOT NULL,
            emoji TEXT NOT NULL,
            name TEXT NOT NULL,
            reply TEXT NOT NULL,
            visitor TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS reactions_by_share ON reactions(share_id, at);
        CREATE TABLE IF NOT EXISTS song_allowances(
            share_id TEXT NOT NULL,
            visitor TEXT NOT NULL,
            remaining INTEGER NOT NULL,
            at INTEGER NOT NULL,
            PRIMARY KEY(share_id, visitor)
        );
        """)
        let columns = Set(try database.query("PRAGMA table_info(shares)").compactMap { $0["name"]?.text })
        if !columns.contains("review_consent") {
            try database.execute("ALTER TABLE shares ADD COLUMN review_consent TEXT")
        }
        try database.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema', ?)",
                         [.text(String(Self.schemaVersion))])
    }

    // MARK: - Sharers

    /// Whether this digest has shared before.
    public func sharerExists(digest: String) throws -> Bool {
        try database.scalar("SELECT COUNT(*) FROM sharers WHERE digest = ?", [.text(digest)]) > 0
    }

    public func insertSharer(digest: String, sharerID: String, platform: String, now: Int64) throws {
        try database.run("INSERT OR IGNORE INTO sharers(digest, sharer_id, created_at, platform) VALUES(?,?,?,?)",
                         [.text(digest), .text(sharerID), .int(now), .text(platform)])
    }

    public func sharesCreated(byDigest digest: String, since: Int64) throws -> Int {
        Int(try database.scalar("SELECT COUNT(*) FROM shares WHERE sharer_digest = ? AND created_at >= ?",
                                [.text(digest), .int(since)]))
    }

    public func liveShares(byDigest digest: String) throws -> Int {
        Int(try database.scalar("SELECT COUNT(*) FROM shares WHERE sharer_digest = ? AND status IN ('pending','ready')",
                                [.text(digest)]))
    }

    // MARK: - Shares

    public func insert(_ record: ShareRecord) throws {
        try database.run("""
        INSERT INTO shares(id, sharer_digest, sharer_id, status, created_at, expires_at, play_cap, is_private,
                           preview, encrypted_meta, audio_bytes, audio_sha256, review_consent)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(record.id), .text(record.sharerDigest), .text(record.sharerID), .text(record.status.rawValue),
            .int(record.createdAt), .int(record.expiresAt), .int(Int64(record.playCap)),
            .int(record.isPrivate ? 1 : 0), record.preview.map { .text(Self.json($0)) } ?? .null,
            record.encryptedMeta.map(SQLValue.text) ?? .null, .int(Int64(record.audioBytes)),
            .text(record.audioSHA256), record.reviewPreservationConsent.map(SQLValue.text) ?? .null,
        ])
    }

    public func share(id: String) throws -> ShareRecord? {
        try database.query("SELECT * FROM shares WHERE id = ?", [.text(id)]).first.map(Self.record)
    }

    public func shares(byDigest digest: String, limit: Int = 200) throws -> [ShareRecord] {
        try database.query("SELECT * FROM shares WHERE sharer_digest = ? AND is_mixtape=0 ORDER BY created_at DESC, id LIMIT ?",
                           [.text(digest), .int(Int64(limit))]).map(Self.record)
    }

    public func markStored(id: String, kind: BlobKind, contentType: String, bytes: Int64) throws {
        switch kind {
        case .audio:
            try database.run("UPDATE shares SET audio_stored = 1, stored_bytes = stored_bytes + ? WHERE id = ?",
                             [.int(bytes), .text(id)])
        case .art:
            try database.run("UPDATE shares SET art_type = ?, stored_bytes = stored_bytes + ? WHERE id = ?",
                             [.text(contentType), .int(bytes), .text(id)])
        case .card:
            try database.run("UPDATE shares SET card_type = ?, stored_bytes = stored_bytes + ? WHERE id = ?",
                             [.text(contentType), .int(bytes), .text(id)])
        }
    }

    public func setStatus(id: String, _ status: ShareStatus) throws {
        try database.run("UPDATE shares SET status = ? WHERE id = ?", [.text(status.rawValue), .text(id)])
    }

    public func setExpiry(id: String, _ expiresAt: Int64) throws {
        try database.run("UPDATE shares SET expires_at = ? WHERE id = ?", [.int(expiresAt), .text(id)])
    }

    public func setPlayCap(id: String, _ cap: Int) throws {
        try database.run("UPDATE shares SET play_cap = ? WHERE id = ?", [.int(Int64(cap)), .text(id)])
    }

    /// The counters a share carries itself. `listeners` is derived from events instead.
    public enum Counter: String {
        case opens, fetches, plays, listened30, completed
    }

    /// A listener's transfer allowance left on a song share (specs/song-sharing.md §4.2), or 0.
    func allowance(shareID: String, visitor: String) throws -> Int64 {
        try database.scalar("SELECT COALESCE(MAX(remaining), 0) FROM song_allowances WHERE share_id=? AND visitor=?",
                            [.text(shareID), .text(visitor)])
    }

    func setAllowance(shareID: String, visitor: String, remaining: Int64, at now: Int64) throws {
        try database.run("""
        INSERT INTO song_allowances(share_id,visitor,remaining,at) VALUES(?,?,?,?)
        ON CONFLICT(share_id,visitor) DO UPDATE SET remaining=excluded.remaining, at=excluded.at
        """, [.text(shareID), .text(visitor), .int(max(0, remaining)), .int(now)])
    }

    public func increment(id: String, _ counter: Counter) throws {
        try database.run("UPDATE shares SET \(counter.rawValue) = \(counter.rawValue) + 1 WHERE id = ?", [.text(id)])
    }

    public func listeners(id: String) throws -> Int {
        Int(try database.scalar(
            "SELECT COUNT(DISTINCT visitor) FROM events WHERE share_id = ? AND type = 'play_started' AND visitor IS NOT NULL",
            [.text(id)]))
    }

    /// Bytes held for live shares, against the quota.
    public func storedBytes() throws -> Int64 {
        try database.scalar("SELECT COALESCE(SUM(stored_bytes), 0) FROM shares WHERE status IN ('pending','ready') OR id IN (SELECT share_id FROM enforcement_cleanup)")
    }

    /// Durable quota promises include bytes not yet uploaded. Physical-byte reporting stays separate.
    public func quotaBytes() throws -> Int64 {
        try database.scalar("""
        SELECT COALESCE(SUM(stored_bytes + CASE
          WHEN is_mixtape=1 THEN COALESCE((SELECT SUM(audio_bytes) FROM mixtape_tracks t WHERE t.share_id=shares.id AND stored=0),0)
          WHEN audio_stored=0 THEN audio_bytes ELSE 0 END),0)
        FROM shares WHERE status IN ('pending','ready') OR id IN (SELECT share_id FROM enforcement_cleanup)
        """)
    }

    /// Ends a share: blobs deleted, content fields nulled, reactions dropped, counters kept.
    public func tombstone(id: String, as status: ShareStatus, now: Int64) throws {
        if try share(id: id)?.isMixtape == true {
            try endMixtape(id: id, status: status, now: now); return
        }
        if try revokeEnforced(id: id, status: status, now: now) { return }
        try database.transaction {
            try database.run("""
            UPDATE shares SET status = ?, ended_at = ?, preview = NULL, encrypted_meta = NULL,
                              art_type = NULL, card_type = NULL, audio_stored = 0, stored_bytes = 0
            WHERE id = ?
            """, [.text(status.rawValue), .int(now), .text(id)])
            try database.run("DELETE FROM reactions WHERE share_id = ?", [.text(id)])
        }
        removeBlobs(id: id)
    }

    /// Deletes a share outright: for a pending share that never finished uploading.
    public func delete(id: String, now: Int64? = nil) throws {
        if try share(id: id)?.isMixtape == true {
            try endMixtape(id: id, status: .expired, now: now ?? Int64(Date().timeIntervalSince1970)); return
        }
        try database.run("DELETE FROM shares WHERE id = ?", [.text(id)])
        removeBlobs(id: id)
    }

    // MARK: - Blobs

    public enum BlobKind: String, CaseIterable, Sendable {
        case audio, art, card
    }

    public func blobURL(id: String, kind: BlobKind) -> URL {
        blobsDirectory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(kind.rawValue)
    }

    /// Moves a staged upload into place, replacing any earlier upload of the same kind.
    public func adopt(staged: URL, id: String, kind: BlobKind) throws {
        let destination = blobURL(id: id, kind: kind)
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o755])
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: staged, to: destination)
        // Ciphertext and preview images only: readable by nginx, which serves them (spec §4.2).
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    }

    func removeBlobs(id: String) {
        try? FileManager.default.removeItem(at: blobsDirectory.appendingPathComponent(id, isDirectory: true))
    }

    // MARK: - Events and reactions

    public func record(event type: String, at: Int64, shareID: String? = nil, sharerID: String? = nil,
                       visitor: String? = nil, props: [String: PropValue] = [:]) throws {
        try database.run("INSERT INTO events(at, type, share_id, sharer_id, visitor, props) VALUES(?,?,?,?,?,?)", [
            .int(at), .text(type), shareID.map(SQLValue.text) ?? .null, sharerID.map(SQLValue.text) ?? .null,
            visitor.map(SQLValue.text) ?? .null, .text(Self.json(props)),
        ])
    }

    public func addReaction(shareID: String, _ reaction: ReactionRequest, visitor: String, at: Int64) throws {
        try database.run("INSERT INTO reactions(share_id, at, emoji, name, reply, visitor) VALUES(?,?,?,?,?,?)", [
            .text(shareID), .int(at), .text(reaction.emoji), .text(reaction.name ?? ""),
            .text(reaction.reply ?? ""), .text(visitor),
        ])
    }

    public func reactions(shareID: String) throws -> [ShareReaction] {
        try database.query("SELECT * FROM reactions WHERE share_id = ? ORDER BY at, id", [.text(shareID)]).map {
            ShareReaction(emoji: $0["emoji"]?.text ?? "", name: $0["name"]?.text ?? "",
                          reply: $0["reply"]?.text ?? "",
                          at: ShareDate.string(Date(timeIntervalSince1970: TimeInterval($0["at"]?.int ?? 0))))
        }
    }

    public func reactionCount(shareID: String, visitor: String, since: Int64) throws -> Int {
        Int(try database.scalar("SELECT COUNT(*) FROM reactions WHERE share_id = ? AND visitor = ? AND at >= ?",
                                [.text(shareID), .text(visitor), .int(since)]))
    }

    // MARK: - Sweeping (spec §7)

    public struct SweepResult: Equatable, Sendable {
        public var expired = 0
        public var abandoned = 0
        public var purged = 0
        public var eventsPurged = 0
    }

    public func sweep(now: Int64, limits: ShareLimits) throws -> SweepResult {
        var result = SweepResult()
        try sweepEnforcement(now: now)
        try database.run("DELETE FROM mixtape_sessions WHERE deadline<=?", [.int(now)])
        // Visitor hashes change daily, so an allowance is of no use two days after its last use.
        try database.run("DELETE FROM song_allowances WHERE at<=?", [.int(now - 2 * 86400)])
        for row in try database.query("SELECT id, sharer_id, is_book, book_kind FROM shares WHERE status = 'ready' AND expires_at <= ? AND id NOT IN (SELECT share_id FROM share_enforcement WHERE disabled=1)",
                                      [.int(now)]) {
            guard let id = row["id"]?.text else { continue }
            try tombstone(id: id, as: .expired, now: now)
            // A /b/ link's expiry carries its kind (book, album or playlist), as its listener-seen expiry does.
            let kind: [String: PropValue] = row["is_book"]?.int == 1 ? ["kind": .string(row["book_kind"]?.text ?? "book")] : [:]
            try record(event: "share_expired", at: now, shareID: id, sharerID: row["sharer_id"]?.text, props: kind)
            result.expired += 1
        }
        // A book gets its own, longer upload window (pendingBookLifetimeSeconds); songs and
        // mixtapes keep the ordinary one.
        let abandonedBefore = now - Int64(limits.pendingLifetimeSeconds)
        let abandonedBookBefore = now - Int64(limits.pendingBookLifetimeSeconds)
        for row in try database.query("SELECT id FROM shares WHERE status = 'pending' AND (created_at <= CASE WHEN is_book=1 THEN ? ELSE ? END OR expires_at <= ?) AND id NOT IN (SELECT share_id FROM share_enforcement WHERE disabled=1)",
                                      [.int(abandonedBookBefore), .int(abandonedBefore), .int(now)]) {
            guard let id = row["id"]?.text else { continue }
            try delete(id: id, now: now)
            result.abandoned += 1
        }
        let retainAfter = now - Int64(limits.retentionDays) * 86400
        result.purged = try database.run("DELETE FROM shares WHERE status IN ('expired','revoked') AND ended_at <= ? AND id NOT IN (SELECT share_id FROM enforcement_cleanup)",
                                         [.int(retainAfter)])
        result.eventsPurged = try database.run("DELETE FROM events WHERE at <= ?", [.int(retainAfter)])
        // Blob directories with no live row: a crash between the row and the files.
        let live = Set(try database.query("SELECT id FROM shares WHERE status IN ('pending','ready') UNION SELECT share_id AS id FROM enforcement_cleanup")
            .compactMap { $0["id"]?.text })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: blobsDirectory.path)) ?? []
            where !live.contains(name) {
            removeBlobs(id: name)
        }
        return result
    }

    // MARK: - Reporting

    func eventRows(since: Int64, until: Int64) throws -> [[String: SQLValue]] {
        try database.query("SELECT type, share_id, sharer_id, visitor, props FROM events WHERE at >= ? AND at <= ?",
                           [.int(since), .int(until)])
    }

    func liveShareCount() throws -> Int {
        Int(try database.scalar("SELECT COUNT(*) FROM shares WHERE status = 'ready'"))
    }

    // MARK: - Mapping

    static func record(_ row: [String: SQLValue]) -> ShareRecord {
        var stats = ShareStats()
        stats.opens = Int(row["opens"]?.int ?? 0)
        stats.fetches = Int(row["fetches"]?.int ?? 0)
        stats.plays = Int(row["plays"]?.int ?? 0)
        stats.listened30s = Int(row["listened30"]?.int ?? 0)
        stats.completed = Int(row["completed"]?.int ?? 0)
        return ShareRecord(
            id: row["id"]?.text ?? "",
            sharerDigest: row["sharer_digest"]?.text ?? "",
            sharerID: row["sharer_id"]?.text ?? "",
            status: ShareStatus(rawValue: row["status"]?.text ?? "") ?? .expired,
            createdAt: row["created_at"]?.int ?? 0,
            expiresAt: row["expires_at"]?.int ?? 0,
            playCap: Int(row["play_cap"]?.int ?? 0),
            isPrivate: row["is_private"]?.int == 1,
            preview: row["preview"]?.text.flatMap { try? JSONDecoder().decode(ShareMetadata.self, from: Data($0.utf8)) },
            encryptedMeta: row["encrypted_meta"]?.text,
            audioBytes: Int(row["audio_bytes"]?.int ?? 0),
            audioSHA256: row["audio_sha256"]?.text ?? "",
            audioStored: row["audio_stored"]?.int == 1,
            artType: row["art_type"]?.text,
            cardType: row["card_type"]?.text,
            storedBytes: row["stored_bytes"]?.int ?? 0,
            stats: stats, reviewPreservationConsent: row["review_consent"]?.text,
            isMixtape: row["is_mixtape"]?.int == 1, isBook: row["is_book"]?.int == 1, accessGeneration: row["access_generation"]?.int ?? 1,
            bookKind: row["is_book"]?.int == 1 ? row["book_kind"]?.text.flatMap(ShareCollectionKind.init(rawValue:)) : nil)
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
