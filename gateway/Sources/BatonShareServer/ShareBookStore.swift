import BatonShareKit
import Foundation

/// Whole-book links (`/b/`, specs/book-sharing.md "Phase 2") reuse the mixtape tables: a book is a
/// `shares` row with `is_mixtape=1` and `is_book=1`, its blobs are `mixtape_tracks` rows with a
/// `role`, its listener sessions are `mixtape_sessions` rows and its create retries are
/// `mixtape_creates` rows. So the mixtape delete trigger, enforcement fences, cleanup queue and
/// quota reservation cover a book with no second copy; only the checks that differ live here.
struct BookStoredBlob {
    let id: String
    let role: BookBlobDescriptor.Role
    let bytes: Int
    let hash: String
    let stored: Bool
}

extension ShareStore {
    /// Idempotent on an existing database: each column is added only when it is missing.
    func migrateBooks() throws {
        let shares = Set(try database.query("PRAGMA table_info(shares)").compactMap { $0["name"]?.text })
        if !shares.contains("is_book") {
            try database.execute("ALTER TABLE shares ADD COLUMN is_book INTEGER NOT NULL DEFAULT 0")
        }
        // A collection (specs/collection-sharing.md) is a book row whose kind is album or playlist.
        if !shares.contains("book_kind") {
            try database.execute("ALTER TABLE shares ADD COLUMN book_kind TEXT NOT NULL DEFAULT 'book'")
        }
        let tracks = Set(try database.query("PRAGMA table_info(mixtape_tracks)").compactMap { $0["name"]?.text })
        if !tracks.contains("role") {
            try database.execute("ALTER TABLE mixtape_tracks ADD COLUMN role TEXT NOT NULL DEFAULT 'audio'")
        }
    }

    func bookBlobs(id: String) throws -> [BookStoredBlob] {
        try database.query("SELECT * FROM mixtape_tracks WHERE share_id=? ORDER BY track_id", [.text(id)]).map {
            .init(id: $0["track_id"]?.text ?? "", role: $0["role"]?.text == "text" ? .text : .audio,
                  bytes: Int($0["audio_bytes"]?.int ?? 0), hash: $0["audio_sha256"]?.text ?? "", stored: $0["stored"]?.int == 1)
        }
    }

    /// Live books held by one sharer (pending or ready), for the per-sharer live-book cap. Albums and
    /// playlists are book rows too, so the cap is shared across every kind.
    func liveBooks(byDigest digest: String) throws -> Int {
        Int(try database.scalar("SELECT COUNT(*) FROM shares WHERE sharer_digest=? AND is_book=1 AND status IN ('pending','ready')", [.text(digest)]))
    }

    /// The book slice's durable promise: every live (or still-cleaning) book's stored bytes plus
    /// its declared blobs not yet uploaded, exactly as `quotaBytes()` counts them. Collections included.
    func bookQuotaBytes() throws -> Int64 {
        try database.scalar("""
        SELECT COALESCE(SUM(stored_bytes + COALESCE((SELECT SUM(audio_bytes) FROM mixtape_tracks t WHERE t.share_id=shares.id AND stored=0),0)),0)
        FROM shares WHERE is_book=1 AND (status IN ('pending','ready') OR id IN (SELECT share_id FROM enforcement_cleanup))
        """)
    }

    /// Ready only when every declared blob is stored and re-verified (length, framing, hash), the
    /// manifest is a bounded BSH1 stream, the counts and per-role caps hold, and the stored total
    /// (manifest included) matches the row.
    func bookMaterialComplete(_ record: ShareRecord, limits: ShareLimits) throws -> Bool {
        guard record.isBook, let text = record.encryptedMeta, let manifest = Data(base64Encoded: text),
              manifest.count <= limits.maxBookManifestBytes,
              (try? ShareCrypto.layout(headerBytes: Array(manifest.prefix(ShareCrypto.headerLength)), totalLength: manifest.count)) != nil else { return false }
        let blobs = try bookBlobs(id: record.id)
        let chapters = blobs.filter { $0.role == .audio }.count
        guard (1 ... limits.maxBookChapters).contains(chapters), blobs.count - chapters <= chapters, blobs.allSatisfy(\.stored) else { return false }
        var bytes = Int64(manifest.count)
        for blob in blobs {
            guard blob.bytes <= (blob.role == .audio ? limits.maxBookChapterBytes : limits.maxBookTextBytes),
                  try storedBlobVerifies(id: record.id, blob: blob.id, bytes: blob.bytes, hash: blob.hash) else { return false }
            bytes += Int64(blob.bytes)
        }
        return bytes <= Int64(limits.maxBookBytes) && bytes == record.storedBytes
    }

    func storedBlobVerifies(id: String, blob: String, bytes: Int, hash: String) throws -> Bool {
        let file = mixtapeTrackURL(id: id, track: blob)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue == bytes else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: ShareCrypto.headerLength) ?? Data()
        guard (try? ShareCrypto.layout(headerBytes: Array(head), totalLength: bytes)) != nil else { return false }
        try handle.seek(toOffset: 0)
        var running = ShareHash.Running()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { running.update(chunk) }
        return running.finalizeHex() == hash
    }
}
