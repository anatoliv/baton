import BatonShareKit
import Foundation

struct MixtapeStoredTrack {
    let id: String
    let bytes: Int
    let hash: String
    let stored: Bool
}

extension ShareStore {
    func migrateMixtapes() throws {
        let columns = Set(try database.query("PRAGMA table_info(shares)").compactMap { $0["name"]?.text })
        for (name, declaration) in [("is_mixtape", "INTEGER NOT NULL DEFAULT 0"), ("access_generation", "INTEGER NOT NULL DEFAULT 1")] where !columns.contains(name) {
            try database.execute("ALTER TABLE shares ADD COLUMN \(name) \(declaration)")
        }
        try database.execute("""
        CREATE TABLE IF NOT EXISTS mixtape_tracks(
          share_id TEXT NOT NULL,track_id TEXT NOT NULL,audio_bytes INTEGER NOT NULL,audio_sha256 TEXT NOT NULL,
          stored INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(share_id,track_id));
        CREATE TABLE IF NOT EXISTS mixtape_sessions(
          digest TEXT PRIMARY KEY,share_id TEXT NOT NULL,generation INTEGER NOT NULL,owner_revision INTEGER NOT NULL,
          ordinal INTEGER NOT NULL,deadline INTEGER NOT NULL,remaining_bytes INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS mixtape_sessions_deadline ON mixtape_sessions(deadline);
        CREATE TABLE IF NOT EXISTS mixtape_creates(
          owner TEXT NOT NULL,request_id TEXT NOT NULL,body_hash TEXT NOT NULL,share_id TEXT NOT NULL,
          PRIMARY KEY(owner,request_id));
        CREATE TRIGGER IF NOT EXISTS mixtape_enforcement_fence AFTER UPDATE OF revision ON share_enforcement
        BEGIN UPDATE shares SET access_generation=access_generation+1 WHERE id=NEW.share_id AND is_mixtape=1; END;
        CREATE TRIGGER IF NOT EXISTS mixtape_suspension_fence AFTER UPDATE OF revision ON sharer_enforcement
        BEGIN UPDATE shares SET access_generation=access_generation+1 WHERE sharer_digest=NEW.digest AND is_mixtape=1; END;
        CREATE TRIGGER IF NOT EXISTS mixtape_delete AFTER DELETE ON shares
        BEGIN DELETE FROM mixtape_tracks WHERE share_id=OLD.id;
          DELETE FROM mixtape_sessions WHERE share_id=OLD.id; DELETE FROM mixtape_creates WHERE share_id=OLD.id; END;
        """)
    }

    func mixtapeTracks(id: String) throws -> [MixtapeStoredTrack] {
        try database.query("SELECT * FROM mixtape_tracks WHERE share_id=? ORDER BY track_id", [.text(id)]).map {
            .init(id: $0["track_id"]?.text ?? "", bytes: Int($0["audio_bytes"]?.int ?? 0),
                  hash: $0["audio_sha256"]?.text ?? "", stored: $0["stored"]?.int == 1)
        }
    }

    func mixtapeTrackURL(id: String, track: String) -> URL {
        blobsDirectory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("tracks", isDirectory: true).appendingPathComponent(track)
    }

    func mixtapeMaterialComplete(_ record: ShareRecord, limits: ShareLimits = .standard) throws -> Bool {
        if record.isBook { return try bookMaterialComplete(record, limits: limits) }
        guard record.isMixtape, let text = record.encryptedMeta, let manifest = Data(base64Encoded: text),
              manifest.count <= ShareMixtapeManifest.maximumEncryptedBytes,
              (try? ShareCrypto.layout(headerBytes: Array(manifest.prefix(ShareCrypto.headerLength)), totalLength: manifest.count)) != nil else { return false }
        let tracks = try mixtapeTracks(id: record.id)
        guard (2...12).contains(tracks.count), tracks.allSatisfy(\.stored) else { return false }
        var bytes = Int64(manifest.count)
        for track in tracks {
            let file = mixtapeTrackURL(id: record.id, track: track.id)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue == track.bytes else { return false }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: ShareCrypto.headerLength) ?? Data()
            guard (try? ShareCrypto.layout(headerBytes: Array(head), totalLength: track.bytes)) != nil else { return false }
            try handle.seek(toOffset: 0)
            var hash = ShareHash.Running()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(chunk) }
            guard hash.finalizeHex() == track.hash else { return false }
            bytes += Int64(track.bytes)
        }
        return bytes == record.storedBytes
    }

    func endMixtape(id: String, status: ShareStatus, now: Int64) throws {
        try database.transaction {
            if let record = try share(id: id), try isEnforced(record) {
                try setEnforcement(id: id, disabled: true, purged: true, deadline: now, caseReference: "owner-revoke")
            }
            try database.run("UPDATE shares SET status=?,ended_at=?,access_generation=access_generation+1 WHERE id=?", [.text(status.rawValue), .int(now), .text(id)])
            try enqueueEnforcementCleanup(id: id, as: status, now: now)
            try database.run("DELETE FROM mixtape_sessions WHERE share_id=?", [.text(id)])
        }
        try performEnforcementCleanup(now: now)
    }
}
