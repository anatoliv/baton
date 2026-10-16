import Foundation

/// Durable tickets contain encrypted audio and its key, never the plaintext song or
/// authentication secret. Public-mode preview images retain their public bytes.
/// No network action is possible until a composer has explicitly staged a ticket.
public struct ShareUploadStore: Sendable {
    public struct Body: Codable, Equatable, Sendable {
        public var kind: String
        public var bytes: Int
    }

    public struct Job: Codable, Sendable, Identifiable {
        public var id: UUID
        public var base: URL
        public var key: Data
        public var record: ShareLedger.Record
        public var bodies: [Body]
        public var created: CreateShareResponse?
        public var completedKinds: Set<String> = []
        public var attempts: [String: Int] = [:]
        public var finalized: ShareSummary?
        public var failure: String?
        public var createBody: Data?
        public var createProof: ShareAttestationProof?
        public var version: Int?
        public var mixtapeCreated: CreateMixtapeResponse?
        public var mixtapeFinalized: MixtapeSummary?

        public var isMixtape: Bool { version == 2 }
        public var hasCreated: Bool { created != nil || mixtapeCreated != nil }
        public var hasFinalized: Bool { finalized != nil || mixtapeFinalized != nil }

        public var nextKind: String? {
            guard hasCreated, !hasFinalized, failure == nil else { return nil }
            return bodies.first { !completedKinds.contains($0.kind) }?.kind ?? "finalize"
        }
    }

    public let directory: URL
    public let ledgerURL: URL

    public init(directory: URL, ledgerURL: URL) { self.directory = directory; self.ledgerURL = ledgerURL }

    public func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func file(_ id: UUID, kind: String) -> URL { folder(id).appendingPathComponent(kind + ".body") }

    public func stage(_ prepared: PreparedShare, base: URL, songID: String, title: String, artist: String) throws -> Job {
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

    public func attach(_ created: CreateShareResponse, to job: inout Job) throws {
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

    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port
            && lhs.user == nil && lhs.password == nil
    }

    public func save(_ job: Job) throws {
        try write(JSONEncoder().encode(job), to: folder(job.id).appendingPathComponent("ticket.json"))
    }

    /// Corrupt/incomplete folders are returned separately, never silently interpreted
    /// as a new create. URLSession tasks for those IDs must be cancelled before cleanup.
    public func load() throws -> (jobs: [Job], orphans: [UUID]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        var jobs: [Job] = []
        var orphans: [UUID] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            let ticket = url.appendingPathComponent("ticket.json")
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            let retainedTracks = names.contains { name in
                guard name.hasSuffix(".body") else { return false }
                return Self.trackID(String(name.dropLast(5))) != nil
            }
            guard FileManager.default.fileExists(atPath: ticket.path) else {
                guard !retainedTracks else { throw URLError(.cannotDecodeContentData) }
                orphans.append(id)
                continue
            }
            // Locked or unreadable files are not corrupt. Propagate the read error
            // so restoration leaves all jobs intact until a later unlock/launch.
            let data = try Data(contentsOf: ticket)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let versioned = retainedTracks || object?["version"] != nil
            if versioned {
                guard let job = try? JSONDecoder().decode(Job.self, from: data), job.id == id,
                      job.isMixtape, job.key.count == 16, Self.valid(job) else { throw URLError(.cannotDecodeContentData) }
                jobs.append(job)
                continue
            }
            if let job = try? JSONDecoder().decode(Job.self, from: data), job.id == id {
                if job.version != nil {
                    // A damaged or unsupported container ticket still owns private
                    // recovery material. Never pass it to legacy orphan deletion.
                    guard job.isMixtape, job.key.count == 16, Self.valid(job) else { throw URLError(.cannotDecodeContentData) }
                    jobs.append(job)
                } else if job.key.count == 16, Self.valid(job) { jobs.append(job) }
                else { orphans.append(id) }
            } else { orphans.append(id) }
        }
        return (jobs, orphans)
    }

    public func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: folder(id)) }

    /// Ledger and completion receipt share one atomic write. A crash between committing
    /// the result and deleting a ticket cannot duplicate a failure or lose a ready link.
    public func commit(_ job: Job) throws -> ShareLedger {
        if job.isMixtape {
            guard Self.valid(job), let summary = job.mixtapeFinalized,
                  summary.share.id == job.record.id, summary.share.status == .ready,
                  summary.share.actionRequired == nil else { throw URLError(.badServerResponse) }
        }
        var ledger = ShareLedger.load(from: ledgerURL)
        var receipts = Self.receipts(at: ledgerURL)
        if !receipts.contains(job.id.uuidString) {
            if let summary = job.mixtapeFinalized {
                var record = job.record
                record.summary = summary.share
                record.mixtapeSummary = summary
                record.expiresAt = ShareDate.date(summary.share.expiresAt) ?? record.expiresAt
                ledger.add(record)
            } else if let summary = job.finalized {
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
    public static func saveLedger(_ ledger: ShareLedger, to url: URL, receipts: Set<String>? = nil) throws {
        let data = try JSONEncoder().encode(ledger)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotCreateFile)
        }
        object["backgroundUploadReceipts"] = Array(receipts ?? Self.receipts(at: url)).sorted()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeProtected(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), to: url)
    }

    public static func receipts(at url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["backgroundUploadReceipts"] as? [String] else { return [] }
        return Set(values)
    }

    public func write(_ data: Data, to url: URL) throws { try Self.writeProtected(data, to: url) }

    public static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        // Background callbacks must work while locked, after the first unlock.
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}

extension ShareUploadStore {
    public static func trackKind(_ id: String) -> String { "track_" + id }
    public static func trackID(_ kind: String) -> String? {
        guard kind.hasPrefix("track_") else { return nil }
        let id = String(kind.dropFirst(6))
        return ShareMixtapeCrypto.isCanonicalTrackID(id) ? id : nil
    }
    public func stage(_ prepared: PreparedMixtape, base: URL, songIDs: [String]) throws -> Job {
        guard songIDs.count == prepared.manifest.tracks.count else { throw URLError(.badServerResponse) }
        _ = try ShareReceiverClient(base: base)
        let id = UUID()
        let destination = self.folder(id)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var parent = directory; try parent.setResourceValues(excluded)
        do {
            var bodies = [Body]()
            for track in prepared.manifest.tracks {
                guard let data = prepared.sealedTracks[track.id], data.count == track.audioBytes,
                      ShareHash.sha256Hex(data) == track.audioSHA256 else { throw URLError(.badServerResponse) }
                let kind = Self.trackKind(track.id)
                bodies.append(.init(kind: kind, bytes: data.count)); try write(data, to: file(id, kind: kind))
            }
            try write(Data(), to: file(id, kind: "finalize"))
            let now = Date()
            let record = ShareLedger.Record(id: "", link: "", songID: "", title: prepared.manifest.title, artist: "",
                isPrivate: prepared.request.preview == nil, createdAt: now, expiresAt: now + TimeInterval(prepared.request.expiresInSeconds), kind: .mixtape, songIDs: songIDs)
            let job = Job(id: id, base: base, key: prepared.key, record: record, bodies: bodies,
                          createBody: try prepared.encodedRequest(), version: 2)
            try save(job); return job
        } catch { try? remove(id); throw error }
    }
    public func attach(_ created: CreateMixtapeResponse, to job: inout Job) throws {
        guard job.isMixtape, let body = job.createBody,
              let request = try? JSONDecoder().decode(CreateMixtapeRequest.self, from: body),
              ShareLink.isValidID(created.id), created.url == job.base.appendingPathComponent("m/" + created.id).absoluteString,
              ShareDate.date(created.expiresAt) != nil,
              Set(created.uploads.keys) == Set(request.tracks.keys),
              created.uploads.allSatisfy({ $0.value == "/v1/share/mixtapes/\(created.id)/tracks/\($0.key)" }) else { throw URLError(.badServerResponse) }
        job.mixtapeCreated = created; job.record.id = created.id
        job.record.link = ShareInvitation(id: created.id, key: job.key, kind: .mixtape).url(base: job.base).absoluteString
        job.record.expiresAt = ShareDate.date(created.expiresAt)!
        try save(job)
    }
    private static func valid(_ job: Job) -> Bool {
        if !job.isMixtape { return job.version == nil && job.bodies.allSatisfy { ["audio", "art", "card"].contains($0.kind) } }
        guard job.created == nil, job.finalized == nil, job.record.containerKind == .mixtape,
              let body = job.createBody, body.count <= 100_000,
              let request = try? JSONDecoder().decode(CreateMixtapeRequest.self, from: body),
              (try? request.validated()) != nil, job.bodies.count == request.tracks.count,
              Set(job.bodies.map(\.kind)).count == job.bodies.count,
              job.bodies.allSatisfy({ item in
                  guard let id = trackID(item.kind) else { return false }
                  return request.tracks[id]?.audioBytes == item.bytes
              }), job.completedKinds.isSubset(of: Set(job.bodies.map(\.kind))) else { return false }
        guard let encrypted = Data(base64Encoded: request.encryptedManifest),
              let manifest = try? ShareMixtapeManifest.open(encrypted, rootKey: job.key),
              manifest.tracks.count == request.tracks.count,
              manifest.tracks.allSatisfy({ request.tracks[$0.id] == .init(audioBytes: $0.audioBytes, audioSHA256: $0.audioSHA256) }),
              job.record.songIDs?.count == manifest.tracks.count else { return false }
        if let created = job.mixtapeCreated {
            guard ShareLink.isValidID(created.id), job.record.id == created.id,
                  job.record.link == ShareInvitation(id: created.id, key: job.key, kind: .mixtape).url(base: job.base).absoluteString,
                  created.url == job.base.appendingPathComponent("m/" + created.id).absoluteString,
                  Set(created.uploads.keys) == Set(request.tracks.keys),
                  created.uploads.allSatisfy({ $0.value == "/v1/share/mixtapes/\(created.id)/tracks/\($0.key)" }) else { return false }
        } else if !job.record.id.isEmpty || !job.record.link.isEmpty || job.mixtapeFinalized != nil { return false }
        if let finalized = job.mixtapeFinalized {
            guard finalized.share.id == job.mixtapeCreated?.id, finalized.share.status == .ready,
                  finalized.share.actionRequired == nil, finalized.trackCount == manifest.tracks.count else { return false }
        }
        return true
    }
}

/// Serial foreground recovery. All progress is a protected ticket; a lost response
/// leaves the same key/body/container available for the next explicit retry or launch.
public actor MixtapeUploadCoordinator {
    public enum Failure: Error { case interrupted, held, ended }
    public let store: ShareUploadStore
    private let onLedgerChanged: (@MainActor @Sendable (ShareLedger) -> Void)?
    private var active = Set<UUID>()
    public init(store: ShareUploadStore, onLedgerChanged: (@MainActor @Sendable (ShareLedger) -> Void)? = nil) { self.store = store; self.onLedgerChanged = onLedgerChanged }
    public func resume(_ id: UUID, client: ShareClient,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> ShareLedger.Record {
        guard active.insert(id).inserted else { throw Failure.interrupted }
        defer { active.remove(id) }
        guard var job = try store.load().jobs.first(where: { $0.id == id }), job.isMixtape,
              ShareUploadStore.sameOrigin(client.base, job.base) else { throw Failure.interrupted }
        do {
            if let summary = job.mixtapeFinalized { return try await finish(&job, summary: summary) }
            if job.mixtapeCreated == nil {
                guard let body = job.createBody else { throw Failure.interrupted }
                try store.attach(try await client.createMixtape(body: body, proof: job.createProof), to: &job)
            }
            let created = job.mixtapeCreated!
            let state = try await client.mixtape(created.id)
            guard state.share.id == created.id else { throw Failure.interrupted }
            if state.share.actionRequired != nil { throw Failure.held }
            if state.share.status == .ready { return try await finish(&job, summary: state) }
            guard state.share.status == .pending else { throw Failure.ended }
            for (index, item) in job.bodies.enumerated() where !job.completedKinds.contains(item.kind) {
                guard let track = ShareUploadStore.trackID(item.kind) else { throw Failure.interrupted }
                let data = try Data(contentsOf: store.file(id, kind: item.kind))
                guard data.count == item.bytes else { throw Failure.interrupted }
                try await client.uploadMixtape(created.id, trackID: track, data: data)
                job.completedKinds.insert(item.kind); try store.save(job)
                progress?(Double(index + 1) / Double(job.bodies.count + 1))
            }
            let summary = try await client.finalizeMixtape(created.id)
            guard summary.share.id == created.id, summary.share.status == .ready else { throw Failure.interrupted }
            progress?(1); return try await finish(&job, summary: summary)
        } catch { throw error } // Never discard an unresolved protected ticket or create a replacement.
    }
    private func finish(_ job: inout ShareUploadStore.Job, summary: MixtapeSummary) async throws -> ShareLedger.Record {
        guard summary.share.id == job.mixtapeCreated?.id, summary.share.id == job.record.id,
              summary.share.status == .ready, summary.share.actionRequired == nil,
              summary.trackCount == job.bodies.count else { throw Failure.interrupted }
        job.mixtapeFinalized = summary; try store.save(job)
        let completed = job, store = self.store, callback = onLedgerChanged
        // App consumers and the existing iOS engine mutate the same ledger on
        // MainActor. Publish the new in-memory ledger synchronously before cleanup
        // or another UI writer can persist an older snapshot. This is not a
        // cross-process file transaction; the app must retain one coordinator.
        return try await MainActor.run {
            let ledger = try store.commit(completed)
            guard let record = ledger.records.first(where: { $0.id == summary.share.id && $0.containerKind == .mixtape }) else { throw Failure.interrupted }
            callback?(ledger)
            try store.remove(completed.id); return record
        }
    }
}
