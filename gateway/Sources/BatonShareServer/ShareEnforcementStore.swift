import BatonShareKit
import Foundation

struct ShareEnforcementState {
    let disabled: Bool
    let purged: Bool
    let revision: Int64
    let deadline: Int64
    let disabledAt: Int64
    let remainingSeconds: Int64
    let reviewUntil: Int64
    let courtReviewRequired: Bool
    let caseReference: String
    var hasPausedLifetime: Bool { disabledAt > 0 && remainingSeconds > 0 }
}

extension ShareStore {
    /// Private overlays preserve the public wire status vocabulary. Tables are always opened:
    /// switching the operator capability off must not undo a previously committed denial.
    func migrateEnforcement() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS share_enforcement(
            share_id TEXT PRIMARY KEY, disabled INTEGER NOT NULL, purged INTEGER NOT NULL DEFAULT 0,
            revision INTEGER NOT NULL, case_ref TEXT NOT NULL, retention_deadline INTEGER NOT NULL,
            case_until INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS sharer_enforcement(
            digest TEXT PRIMARY KEY, suspended INTEGER NOT NULL, revision INTEGER NOT NULL,
            case_ref TEXT NOT NULL, changed_at INTEGER NOT NULL, case_until INTEGER NOT NULL DEFAULT 0,
            suspension_ref TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS enforcement_operations(
            operation_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, receipt TEXT NOT NULL,
            retain_until INTEGER NOT NULL, reason_code TEXT NOT NULL DEFAULT '',
            target_id TEXT NOT NULL DEFAULT '', affected_ids TEXT NOT NULL DEFAULT '[]'
        );
        CREATE TABLE IF NOT EXISTS enforcement_cleanup(
            share_id TEXT PRIMARY KEY, end_status TEXT NOT NULL, requested_at INTEGER NOT NULL,
            failed INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS enforcement_cleanup_requests(
            operation_id TEXT NOT NULL, share_id TEXT NOT NULL,
            PRIMARY KEY(operation_id, share_id)
        );
        """)
        // Additive upgrades also preserve an existing private overlay from an earlier build.
        for (table, columns) in [("share_enforcement", [("case_until", "INTEGER NOT NULL DEFAULT 0"),
            ("disabled_at", "INTEGER NOT NULL DEFAULT 0"), ("remaining_seconds", "INTEGER NOT NULL DEFAULT 0"),
            ("review_until", "INTEGER NOT NULL DEFAULT 0"), ("court_review", "INTEGER NOT NULL DEFAULT 0")]),
                                 ("sharer_enforcement", [("case_until", "INTEGER NOT NULL DEFAULT 0"),
                                                         ("suspension_ref", "TEXT NOT NULL DEFAULT ''")]),
                                 ("enforcement_operations", [("reason_code", "TEXT NOT NULL DEFAULT ''"),
                                                            ("target_id", "TEXT NOT NULL DEFAULT ''"),
                                                            ("affected_ids", "TEXT NOT NULL DEFAULT '[]'"),
                                                            ("contact_revisions", "TEXT NOT NULL DEFAULT '{}'")])] {
            let existing = Set(try database.query("PRAGMA table_info(\(table))").compactMap { $0["name"]?.text })
            for (column, declaration) in columns where !existing.contains(column) {
                try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration)")
            }
        }
        try migrateSuspensionReferences()
    }

    /// Upgrade active legacy overlays, including those with no remaining share or audit row.
    /// The value is random, never derived from the installation digest. One active reference
    /// per overlay; inactive references have no continuing operational purpose.
    private func migrateSuspensionReferences() throws {
        try database.transaction {
            try database.run("UPDATE sharer_enforcement SET suspension_ref='' WHERE suspended=0")
            for row in try database.query("SELECT digest FROM sharer_enforcement WHERE suspended=1 AND suspension_ref='' ORDER BY digest") {
                guard let digest = row["digest"]?.text else { continue }
                try database.run("UPDATE sharer_enforcement SET suspension_ref=? WHERE digest=?", [.text(newSuspensionReference()), .text(digest)])
            }
            try database.execute("CREATE UNIQUE INDEX IF NOT EXISTS active_suspension_reference ON sharer_enforcement(suspension_ref) WHERE suspension_ref<>''")
        }
    }

    private func newSuspensionReference() throws -> String {
        var reference = Base64URL.encode(Data(ShareCrypto.newKey().prefix(16)))
        while try database.scalar("SELECT COUNT(*) FROM sharer_enforcement WHERE suspension_ref=?", [.text(reference)]) > 0 {
            reference = Base64URL.encode(Data(ShareCrypto.newKey().prefix(16)))
        }
        return reference
    }

    func suspensionReference(digest: String) throws -> String? {
        try database.query("SELECT suspension_ref FROM sharer_enforcement WHERE digest=? AND suspended=1", [.text(digest)]).first?["suspension_ref"]?.text
    }

    func suspensionDigest(reference: String) throws -> String? {
        try database.query("SELECT digest FROM sharer_enforcement WHERE suspension_ref=? AND suspended=1", [.text(reference)]).first?["digest"]?.text
    }

    func suspensionInventory(after cursor: String?, maximum: Int) throws -> EnforcementSuspensions {
        let rows = try database.query("SELECT suspension_ref,revision FROM sharer_enforcement WHERE suspended=1 AND suspension_ref>? ORDER BY suspension_ref LIMIT ?",
                                      [.text(cursor ?? ""), .int(Int64(maximum + 1))])
        let entries = rows.prefix(maximum).map {
            EnforcementSuspension(reference: $0["suspension_ref"]?.text ?? "", revision: $0["revision"]?.int ?? 0)
        }
        return EnforcementSuspensions(suspensions: entries, nextCursor: rows.count > maximum ? entries.last?.reference : nil)
    }

    func enforcementState(id: String) throws -> ShareEnforcementState? {
        try database.query("SELECT * FROM share_enforcement WHERE share_id = ?", [.text(id)]).first.map {
            ShareEnforcementState(disabled: $0["disabled"]?.int == 1, purged: $0["purged"]?.int == 1,
                                  revision: $0["revision"]?.int ?? 0,
                                  deadline: $0["retention_deadline"]?.int ?? 0,
                                  disabledAt: $0["disabled_at"]?.int ?? 0,
                                  remainingSeconds: $0["remaining_seconds"]?.int ?? 0,
                                  reviewUntil: $0["review_until"]?.int ?? 0,
                                  courtReviewRequired: $0["court_review"]?.int == 1,
                                  caseReference: $0["case_ref"]?.text ?? "")
        }
    }

    func isSuspended(digest: String) throws -> Bool {
        try database.scalar("SELECT suspended FROM sharer_enforcement WHERE digest = ?", [.text(digest)]) == 1
    }

    func sharerRevision(digest: String) throws -> Int64 {
        try database.scalar("SELECT revision FROM sharer_enforcement WHERE digest = ?", [.text(digest)])
    }

    func isEnforced(_ record: ShareRecord) throws -> Bool {
        try enforcementState(id: record.id)?.disabled == true || isSuspended(digest: record.sharerDigest)
    }

    func enforcementScope(digest: String, maximum: Int) throws -> [ShareRecord] {
        let rows = try database.query("""
        SELECT * FROM shares WHERE sharer_digest = ? AND status IN ('pending','ready')
        ORDER BY id LIMIT ?
        """, [.text(digest), .int(Int64(maximum + 1))])
        guard rows.count <= maximum else { throw EnforcementFailure.scopeTooLarge }
        return rows.map(Self.record)
    }

    /// Used only for a private plan. Hashing the current stored row detects owner expiry/cap
    /// changes, uploads and counters that changed between review and apply, without exposing it.
    func enforcementFingerprint(id: String) throws -> String {
        guard let row = try database.query("SELECT * FROM shares WHERE id = ?", [.text(id)]).first
        else { throw EnforcementFailure.notFound }
        var object: [String: Any] = row.mapValues { value in
            switch value {
            case .null: return NSNull()
            case let .int(number): return number
            case let .text(text): return text
            }
        }
        if row["is_mixtape"]?.int == 1 {
            object["mixtapeTracks"] = try database.query("SELECT * FROM mixtape_tracks WHERE share_id=? ORDER BY track_id", [.text(id)]).map { row in
                row.mapValues { value -> Any in
                    switch value { case .null: return NSNull(); case let .int(number): return number; case let .text(text): return text }
                }
            }
        }
        return ShareHash.sha256Hex(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    func setEnforcement(id: String, disabled: Bool, purged: Bool, deadline: Int64, caseReference: String, caseUntil: Int64 = 0) throws {
        try database.run("""
        INSERT INTO share_enforcement(share_id,disabled,purged,revision,case_ref,retention_deadline,case_until)
        VALUES(?,?,?,1,?,?,?) ON CONFLICT(share_id) DO UPDATE SET disabled=excluded.disabled,
        purged=excluded.purged,revision=share_enforcement.revision+1,
        case_ref=excluded.case_ref,retention_deadline=excluded.retention_deadline,case_until=excluded.case_until
        """, [.text(id), .int(disabled ? 1 : 0), .int(purged ? 1 : 0), .text(caseReference), .int(deadline), .int(caseUntil)])
    }

    func setSuspension(digest: String, suspended: Bool, caseReference: String, now: Int64, caseUntil: Int64 = 0) throws {
        let reference = suspended ? try suspensionReference(digest: digest) ?? newSuspensionReference() : ""
        try database.run("""
        INSERT INTO sharer_enforcement(digest,suspended,revision,case_ref,changed_at,case_until,suspension_ref) VALUES(?,?,1,?,?,?,?)
        ON CONFLICT(digest) DO UPDATE SET suspended=excluded.suspended,
        revision=sharer_enforcement.revision+1,case_ref=excluded.case_ref,changed_at=excluded.changed_at,case_until=excluded.case_until,
        suspension_ref=excluded.suspension_ref
        """, [.text(digest), .int(suspended ? 1 : 0), .text(caseReference), .int(now), .int(caseUntil), .text(reference)])
    }

    /// Called in the same transaction as denial and its immutable receipt.
    func setPreservation(id: String, startedAt: Int64, remaining: Int64, reviewUntil: Int64, courtReviewRequired: Bool) throws {
        try database.run("UPDATE share_enforcement SET disabled_at=?,remaining_seconds=?,review_until=?,court_review=? WHERE share_id=?",
                         [.int(startedAt), .int(remaining), .int(reviewUntil), .int(courtReviewRequired ? 1 : 0), .text(id)])
    }

    func enforcementOperation(id: String) throws -> (fingerprint: String, receipt: EnforcementReceipt)? {
        guard let row = try database.query("SELECT fingerprint,receipt FROM enforcement_operations WHERE operation_id = ?",
                                           [.text(id)]).first,
              let fingerprint = row["fingerprint"]?.text, let text = row["receipt"]?.text
        else { return nil }
        return (fingerprint, try JSONDecoder().decode(EnforcementReceipt.self, from: Data(text.utf8)))
    }

    func recordEnforcement(fingerprint: String, receipt: EnforcementReceipt, plan: EnforcementPlan, retainUntil: Int64) throws {
        var revisions: [String: Int64] = [:]
        for affected in plan.affected {
            if let record = try share(id: affected.id), let state = try enforcementState(id: affected.id) {
                revisions[affected.id] = try Self.contactRevision(overlay: state.revision,
                    installation: sharerRevision(digest: record.sharerDigest))
            }
        }
        try database.run("INSERT INTO enforcement_operations(operation_id,fingerprint,receipt,retain_until,reason_code,target_id,affected_ids,contact_revisions) VALUES(?,?,?,?,?,?,?,?)",
                         [.text(receipt.operationID), .text(fingerprint), .text(Self.json(receipt)), .int(retainUntil),
                          .text(plan.request.reasonCode), .text(plan.request.shareID ?? ""), .text(Self.json(plan.affected.map(\.id))), .text(Self.json(revisions))])
    }

    func enqueueEnforcementCleanup(id: String, as status: ShareStatus, now: Int64, operationID: String? = nil) throws {
        try database.run("""
        INSERT INTO enforcement_cleanup(share_id,end_status,requested_at) VALUES(?,?,?)
        ON CONFLICT(share_id) DO UPDATE SET end_status=excluded.end_status
        """, [.text(id), .text(status.rawValue), .int(now)])
        if let operationID {
            try database.run("INSERT OR IGNORE INTO enforcement_cleanup_requests(operation_id,share_id) VALUES(?,?)",
                             [.text(operationID), .text(id)])
        }
    }

    func enforcementRecovery(id: String) throws -> EnforcementRecovery? {
        guard let operation = try enforcementOperation(id: id) else { return nil }
        let rows = try database.query("""
        SELECT c.failed FROM enforcement_cleanup c JOIN enforcement_cleanup_requests r ON c.share_id=r.share_id
        WHERE r.operation_id=?
        """, [.text(id)])
        return EnforcementRecovery(receipt: operation.receipt, cleanupPending: rows.count,
                                   cleanupFailed: rows.filter { $0["failed"]?.int == 1 }.count)
    }

    /// Never report purged until both deletion and its database update succeed. A crash in
    /// between leaves a durable queue and denied access; retry sees already-absent files.
    @discardableResult
    func performEnforcementCleanup(now: Int64, remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws -> Int {
        var completed = 0
        for row in try database.query("SELECT * FROM enforcement_cleanup ORDER BY share_id") {
            guard let id = row["share_id"]?.text, let status = row["end_status"]?.text else { continue }
            do {
                let folder = blobsDirectory.appendingPathComponent(id, isDirectory: true)
                if FileManager.default.fileExists(atPath: folder.path) {
                    try remove(folder)
                }
                try database.transaction {
                    try database.run("""
                    UPDATE shares SET status=?,ended_at=?,preview=NULL,encrypted_meta=NULL,
                    art_type=NULL,card_type=NULL,audio_stored=0,stored_bytes=0 WHERE id=?
                    """, [.text(status), .int(now), .text(id)])
                    try database.run("DELETE FROM reactions WHERE share_id=?", [.text(id)])
                    try database.run("DELETE FROM song_allowances WHERE share_id=?", [.text(id)])
                    try database.run("DELETE FROM mixtape_tracks WHERE share_id=?", [.text(id)])
                    try database.run("DELETE FROM mixtape_sessions WHERE share_id=?", [.text(id)])
                    try database.run("DELETE FROM enforcement_cleanup WHERE share_id=?", [.text(id)])
                }
                completed += 1
            } catch {
                // Generic failure bit only: paths, SQL errors or confidential case content
                // never become an operator/public receipt. Keep quota conservatively charged.
                try database.run("UPDATE enforcement_cleanup SET failed=1 WHERE share_id=?", [.text(id)])
            }
        }
        return completed
    }

    /// Voluntary revoke remains available under a hold. Denial and cleanup intent commit
    /// together; the normal best-effort file remover must not undercount retained material.
    func revokeEnforced(id: String, status: ShareStatus, now: Int64) throws -> Bool {
        guard let record = try share(id: id), try isEnforced(record) else { return false }
        try database.transaction {
            try purgeHeldByOwner(id: id, now: now)
            try database.run("UPDATE shares SET status=?,ended_at=? WHERE id=?",
                             [.text(status.rawValue), .int(now), .text(id)])
            try enqueueEnforcementCleanup(id: id, as: status, now: now)
        }
        try performEnforcementCleanup(now: now)
        return true
    }

    /// A held share its sharer revokes: disabled and purged now, while the operator's case
    /// reference and how long it is kept stay as they were, for the audit trail; before, the next
    /// sweep cleared the reference at once. The revision still moves on, so
    /// a contact action planned before the revoke no longer matches. Call inside a transaction.
    func purgeHeldByOwner(id: String, now: Int64) throws {
        let held = try database.query("SELECT case_ref,case_until FROM share_enforcement WHERE share_id=?", [.text(id)]).first
        try setEnforcement(id: id, disabled: true, purged: true, deadline: now,
                           caseReference: held?["case_ref"]?.text ?? "", caseUntil: held?["case_until"]?.int ?? 0)
    }

    func sweepEnforcement(now: Int64) throws {
        let due = try database.query("SELECT * FROM share_enforcement WHERE disabled=1 AND purged=0 AND retention_deadline<=?",
                                     [.int(now)])
        try database.transaction {
            for row in due {
                guard let id = row["share_id"]?.text else { continue }
                try database.run("UPDATE share_enforcement SET purged=1,revision=revision+1 WHERE share_id=?", [.text(id)])
                try enqueueEnforcementCleanup(id: id, as: .expired, now: now)
            }
        }
        try performEnforcementCleanup(now: now)
        try database.transaction {
            try database.run("UPDATE share_enforcement SET case_ref='' WHERE case_until<=?", [.int(now)])
            try database.run("UPDATE sharer_enforcement SET case_ref='' WHERE case_until<=?", [.int(now)])
            try database.run("DELETE FROM enforcement_cleanup_requests WHERE operation_id IN (SELECT operation_id FROM enforcement_operations WHERE retain_until<=?)", [.int(now)])
            try database.run("DELETE FROM enforcement_operations WHERE retain_until<=?", [.int(now)])
            // Inactive minimal overlays have no continuing operational purpose once the
            // associated share/digest has disappeared. Active suspensions remain explicit.
            try database.run("DELETE FROM share_enforcement WHERE share_id NOT IN (SELECT id FROM shares)")
            try database.run("DELETE FROM sharer_enforcement WHERE suspended=0 AND digest NOT IN (SELECT sharer_digest FROM shares)")
        }
    }
}
