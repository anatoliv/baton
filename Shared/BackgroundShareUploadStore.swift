import BatonShareKit
import Foundation

/// Durable tickets contain encrypted audio and its key, never the plaintext song or
/// authentication secret. Public-mode preview images retain their public bytes.
/// No network action is possible until a composer has explicitly staged a ticket.
struct BackgroundShareUploadStore: Sendable {
    struct Body: Codable, Equatable, Sendable {
        var kind: String
        var bytes: Int
    }

    struct Job: Codable, Sendable, Identifiable {
        var id: UUID
        var base: URL
        var key: Data
        var record: ShareLedger.Record
        var bodies: [Body]
        var created: CreateShareResponse?
        var completedKinds: Set<String> = []
        var attempts: [String: Int] = [:]
        var finalized: ShareSummary?
        var failure: String?
        var createBody: Data?
        var createProof: ShareAttestationProof?

        var nextKind: String? {
            guard created != nil, finalized == nil, failure == nil else { return nil }
            return bodies.first { !completedKinds.contains($0.kind) }?.kind ?? "finalize"
        }
    }

    let directory: URL
    let ledgerURL: URL

    func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func file(_ id: UUID, kind: String) -> URL { folder(id).appendingPathComponent(kind + ".body") }

    func stage(_ prepared: PreparedShare, base: URL, songID: String, title: String, artist: String) throws -> Job {
        let id = UUID()
        let folder = folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var parent = directory
        try parent.setResourceValues(resource)
        do {
            var bodies = [Body(kind: "audio", bytes: prepared.sealedAudio.count)]
            try write(prepared.sealedAudio, to: file(id, kind: "audio"))
            if let art = prepared.art {
                bodies.append(Body(kind: "art", bytes: art.count))
                try write(art, to: file(id, kind: "art"))
            }
            if let card = prepared.card {
                bodies.append(Body(kind: "card", bytes: card.count))
                try write(card, to: file(id, kind: "card"))
            }
            try write(Data(), to: file(id, kind: "finalize"))
            let now = Date()
            let record = ShareLedger.Record(id: "", link: "", songID: songID, title: title, artist: artist,
                                           isPrivate: prepared.request.isPrivate, createdAt: now,
                                           expiresAt: now + TimeInterval(prepared.request.expiresInSeconds))
            let job = Job(id: id, base: base, key: prepared.key, record: record, bodies: bodies)
            try save(job)
            return job
        } catch {
            try? remove(id)
            throw error
        }
    }

    func attach(_ created: CreateShareResponse, to job: inout Job) throws {
        // Never permit a response to redirect authenticated uploads to another origin.
        guard ShareLink.isValidID(created.id),
              let url = URL(string: created.url), Self.sameOrigin(url, job.base),
              url.path == "/s/\(created.id)",
              [created.uploads.audio, created.uploads.art, created.uploads.card].allSatisfy({
                  guard let resolved = URL(string: $0, relativeTo: job.base)?.absoluteURL else { return false }
                  return Self.sameOrigin(resolved, job.base)
              }) else { throw URLError(.badServerResponse) }
        job.created = created
        job.record.id = created.id
        job.record.link = ShareLink(id: created.id, key: job.key).url(base: job.base).absoluteString
        job.record.expiresAt = ShareDate.date(created.expiresAt) ?? job.record.expiresAt
        try save(job)
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port
            && lhs.user == nil && lhs.password == nil
    }

    func save(_ job: Job) throws {
        try write(JSONEncoder().encode(job), to: folder(job.id).appendingPathComponent("ticket.json"))
    }

    /// Corrupt/incomplete folders are returned separately, never silently interpreted
    /// as a new create. URLSession tasks for those IDs must be cancelled before cleanup.
    func load() throws -> (jobs: [Job], orphans: [UUID]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        var jobs: [Job] = []
        var orphans: [UUID] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            let ticket = url.appendingPathComponent("ticket.json")
            guard FileManager.default.fileExists(atPath: ticket.path) else {
                orphans.append(id)
                continue
            }
            // Locked or unreadable files are not corrupt. Propagate the read error
            // so restoration leaves all jobs intact until a later unlock/launch.
            let data = try Data(contentsOf: ticket)
            if let job = try? JSONDecoder().decode(Job.self, from: data), job.id == id,
               job.bodies.allSatisfy({ ["audio", "art", "card"].contains($0.kind) }),
               job.key.count == 16 {
                jobs.append(job)
            } else { orphans.append(id) }
        }
        return (jobs, orphans)
    }

    func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: folder(id)) }

    /// Ledger and completion receipt share one atomic write. A crash between committing
    /// the result and deleting a ticket cannot duplicate a failure or lose a ready link.
    func commit(_ job: Job) throws -> ShareLedger {
        var ledger = ShareLedger.load(from: ledgerURL)
        var receipts = Self.receipts(at: ledgerURL)
        if !receipts.contains(job.id.uuidString) {
            if let summary = job.finalized {
                var record = job.record
                record.summary = summary
                record.expiresAt = ShareDate.date(summary.expiresAt) ?? record.expiresAt
                ledger.add(record)
            } else if let failure = job.failure {
                ledger.noteFailure(failure)
            } else { throw URLError(.badServerResponse) }
            receipts.insert(job.id.uuidString)
            try Self.saveLedger(ledger, to: ledgerURL, receipts: receipts)
        }
        return ledger
    }

    /// Preserve receipts when the ordinary UI refreshes or edits the ledger.
    static func saveLedger(_ ledger: ShareLedger, to url: URL, receipts: Set<String>? = nil) throws {
        let data = try JSONEncoder().encode(ledger)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotCreateFile)
        }
        object["backgroundUploadReceipts"] = Array(receipts ?? Self.receipts(at: url)).sorted()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeProtected(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), to: url)
    }

    static func receipts(at url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["backgroundUploadReceipts"] as? [String] else { return [] }
        return Set(values)
    }

    func write(_ data: Data, to url: URL) throws { try Self.writeProtected(data, to: url) }

    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        // Background callbacks must work while locked, after the first unlock.
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
