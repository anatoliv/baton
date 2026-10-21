import BatonGatewayCore
import BatonMCPProtocol

import BatonShareKit
import Foundation

extension ShareService {
    func mixtapeRoute(_ request: HTTPRequestMessage, parts: [String], who: ShareRequester) throws -> ShareResponse? {
        let method = request.method.uppercased()
        guard parts.count >= 3, parts[0] == "v1", parts[1] == "share", ["mixtapes", "m"].contains(parts[2]) else { return nil }
        let owner = parts[2] == "mixtapes"
        if owner {
            guard let sharer = sharer(bearer: request.bearerToken) else { return .error(401, "unauthorized", "Missing install secret.") }
            if parts.count == 3 {
                if method == "POST" {
                    guard config.mixtapesEnabled else { return mixtapesUnsupported }
                    return try createMixtape(request, sharer: sharer, who: who)
                }
                if method == "GET" {
                    let rows = try store.database.query("SELECT * FROM shares WHERE sharer_digest=? AND is_mixtape=1 AND is_book=0 ORDER BY created_at DESC,id LIMIT 200", [.text(sharer.digest)])
                    return .json(MixtapeList(mixtapes: try rows.map { try mixtapeSummary(ShareStore.record($0)) }))
                }
            }
            guard parts.count >= 4, ShareLink.isValidID(parts[3]), let record = try store.share(id: parts[3]), record.isMixtape, !record.isBook, record.sharerDigest == sharer.digest else { return .error(404, "not_found", "No such share.") }
            if parts.count == 4 {
                switch method {
                case "GET": return .json(try mixtapeSummary(record))
                case "DELETE":
                    if record.status == .pending || record.status == .ready { try store.tombstone(id: record.id, as: .revoked, now: now) }
                    return .noContent
                case "PATCH":
                    guard config.mixtapesEnabled else { return mixtapesUnsupported }
                    return try patchMixtape(request, record: record)
                default: break
                }
            }
            if parts.count == 5, parts[4] == "finalize", method == "POST" {
                guard config.mixtapesEnabled else { return mixtapesUnsupported }
                return try store.database.transaction {
                    guard let fresh = try store.share(id: record.id), fresh.isMixtape, !fresh.isBook, fresh.sharerDigest == sharer.digest else { return .error(404, "not_found", "No such share.") }
                    if let denial = try enforcementWriteDenial(fresh) { return denial }
                    if fresh.status == .ready { return .json(try mixtapeSummary(fresh)) }
                    guard fresh.status == .pending, fresh.expiresAt > now else { return .error(409, "state", "This mixtape has ended.") }
                    guard try store.mixtapeMaterialComplete(fresh) else { return .error(409, "incomplete", "Upload every declared track first.") }
                    try store.database.run("UPDATE shares SET status='ready',audio_stored=1 WHERE id=? AND status='pending'", [.text(fresh.id)])
                    try store.record(event: "share_finalized", at: now, shareID: fresh.id, sharerID: fresh.sharerID, props: ["audioBytes": .int(fresh.audioBytes), "kind": .string("mixtape")])
                    return .json(try mixtapeSummary(try store.share(id: fresh.id)!))
                }
            }
            return .error(405, "method", "Method not allowed.")
        }
        guard config.mixtapesEnabled else { return mixtapesUnsupported }
        guard parts.count >= 4, ShareLink.isValidID(parts[3]), let candidate = try store.share(id: parts[3]), candidate.isMixtape, !candidate.isBook else {
            return .error(404, "not_found", "No such share.")
        }
        if parts.count == 4, method == "GET", candidate.status == .pending, candidate.expiresAt > now, try !store.isEnforced(candidate) {
            return .json(PublicMixtape(status: .pending, preview: mixtapePreview(candidate), encryptedManifest: candidate.encryptedMeta ?? "", tracks: try descriptors(candidate.id), expiresAt: date(candidate.expiresAt), remainingPlays: candidate.playCap))
        }
        guard let record = try playableMixtape(parts[3]) else { return .error(410, "expired", "This mixtape is unavailable or has ended.") }
        if parts.count == 4, method == "GET" {
            return .json(PublicMixtape(status: record.status, preview: mixtapePreview(record), encryptedManifest: record.encryptedMeta ?? "",
                tracks: try descriptors(record.id), expiresAt: date(record.expiresAt), remainingPlays: max(0, record.playCap - record.stats.fetches)))
        }
        if parts.count == 5, parts[4] == "sessions", method == "POST" { return try admitMixtape(record, who: who) }
        if parts.count == 6, parts[4] == "tracks", ["GET", "HEAD"].contains(method) {
            return try readMixtapeTrack(request, record: record, trackID: parts[5], head: method == "HEAD")
        }
        // Events/reactions use normal container counters and retention, including the last admitted play.
        if parts.count == 5, method == "POST", ["events", "reactions"].contains(parts[4]) {
            guard try validMixtapeSession(request, record: record) != nil else { return .error(401, "session", "Start a listening session first.") }
            if parts[4] == "events" { return try mixtapeEvent(request, record: record, who: who) }
            return try mixtapeReaction(request, record: record, who: who)
        }
        return .error(404, "not_found", "No such route.")
    }

    private func createMixtape(_ request: HTTPRequestMessage, sharer: Sharer, who: ShareRequester) throws -> ShareResponse {
        guard config.enabled else { return .error(503, "share_disabled", "Sharing is paused for now.") }
        if let denial = try enforcementCreateDenial(sharer) { return denial }
        guard request.body.count <= 100_000, UniqueJSONKeys.validate(request.body), let body = try? JSONDecoder().decode(CreateMixtapeRequest.self, from: request.body) else { return .error(400, "invalid", "Not a bounded mixtape request.") }
        let valid = try body.validated(limits: config.limits)
        let hash = ShareHash.sha256Hex(request.body)
        let integrity = try verifyCreate(request, sharer: sharer)
        if let replay = integrity.replay { return replay }
        return try store.database.transaction {
            if let previous = try store.database.query("SELECT body_hash,share_id FROM mixtape_creates WHERE owner=? AND request_id=?", [.text(sharer.digest), .text(valid.requestID)]).first {
                guard previous["body_hash"]?.text == hash, let id = previous["share_id"]?.text, let record = try store.share(id: id), !record.isBook, record.status == .pending || record.status == .ready else { return .error(409, "conflict", "This retry identity no longer matches a live mixtape.") }
                let response = try mixtapeCreated(record)
                if let verified = integrity.verified { try commitVerifiedCreate(verified, response: response, digest: sharer.digest) }
                return response
            }
            let manifestBytes = Data(base64Encoded: valid.encryptedManifest)!.count
            guard try store.quotaBytes() <= config.limits.quotaBytes - Int64(valid.audioBytes + manifestBytes) else { return .error(503, "busy", "Sharing is busy right now.") }
            let preview = valid.preview.map { ShareMetadata(title: $0.title, artist: "", durationSeconds: valid.totalDurationSeconds, from: $0.from, note: $0.note) }
            let single = CreateShareRequest(expiresInSeconds: valid.expiresInSeconds, playCap: valid.playCap, preview: preview, encryptedMeta: valid.encryptedManifest,
                durationBucket: DurationBucket(seconds: valid.totalDurationSeconds), audioBytes: valid.audioBytes, audioSHA256: String(repeating: "0", count: 64), client: valid.client, reviewPreservationConsent: valid.reviewPreservationConsent)
            let created = try createAuthorized(single, sharer: sharer, who: who, verified: integrity.verified != nil)
            guard created.status == 201 else { return created }
            let id = try JSONDecoder().decode(CreateShareResponse.self, from: created.body).id
            try store.database.run("UPDATE shares SET is_mixtape=1,stored_bytes=? WHERE id=?", [.int(Int64(manifestBytes)), .text(id)])
            for (track, descriptor) in valid.tracks {
                try store.database.run("INSERT INTO mixtape_tracks(share_id,track_id,audio_bytes,audio_sha256) VALUES(?,?,?,?)", [.text(id), .text(track), .int(Int64(descriptor.audioBytes)), .text(descriptor.audioSHA256)])
            }
            try store.database.run("INSERT INTO mixtape_creates VALUES(?,?,?,?)", [.text(sharer.digest), .text(valid.requestID), .text(hash), .text(id)])
            let response = try mixtapeCreated(try store.share(id: id)!)
            if let verified = integrity.verified { try commitVerifiedCreate(verified, response: response, digest: sharer.digest) }
            return response
        }
    }

    func uploadMixtape(_ request: StreamingUpload.Request, file: URL) throws -> ShareResponse {
        guard config.mixtapesEnabled else { return .error(409, "unsupported", "This server does not support mixtapes.") }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count == 6, parts[4] == "tracks", ShareLink.isValidID(parts[3]), ShareMixtapeCrypto.isCanonicalTrackID(parts[5]),
              let sharer = sharer(bearer: request.bearerToken) else { return .error(404, "not_found", "No such route.") }
        return try store.database.transaction {
            // The shared write lock fences every snapshot, material adoption and one-time charge.
            guard let record = try store.share(id: parts[3]), record.isMixtape, !record.isBook, record.sharerDigest == sharer.digest else { return .error(404, "not_found", "No such share.") }
            if let denial = try enforcementWriteDenial(record) { return denial }
            guard record.status == .pending, record.expiresAt > now,
                  let track = try store.mixtapeTracks(id: record.id).first(where: { $0.id == parts[5] }) else { return .error(409, "state", "The mixtape is no longer pending.") }
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  request.contentLength == track.bytes, (attrs[.size] as? NSNumber)?.intValue == track.bytes,
                  (try? ShareCrypto.layout(headerBytes: readHead(file), totalLength: track.bytes)) != nil else { return .error(400, "invalid", "The track length or encrypted stream is invalid.") }
            guard try sha256(file) == track.hash else { return .error(422, "checksum", "The track does not match its declared checksum.") }
            if track.stored { return .json(["ok": true]) }
            let destination = store.mixtapeTrackURL(id: record.id, track: track.id)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A crash before commit leaves adopted material covered by its durable reservation.
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: file, to: destination)
            let changed = try store.database.run("UPDATE mixtape_tracks SET stored=1 WHERE share_id=? AND track_id=? AND stored=0", [.text(record.id), .text(track.id)])
            guard changed == 1 else { throw ShareValidationError("track", "upload state changed") }
            try store.database.run("UPDATE shares SET stored_bytes=stored_bytes+? WHERE id=?", [.int(Int64(track.bytes)), .text(record.id)])
            return .json(["ok": true])
        }
    }

    private var mixtapesUnsupported: ShareResponse { .error(409, "unsupported", "This server does not support mixtapes.") }

    private func playableMixtape(_ id: String, expire: Bool = true) throws -> ShareRecord? {
        guard ShareLink.isValidID(id), let record = try store.share(id: id), record.isMixtape, !record.isBook,
              record.status == .ready, try !store.isEnforced(record) else { return nil }
        guard record.expiresAt > now else { if expire { try store.tombstone(id: id, as: .expired, now: now) }; return nil }
        return record
    }
    private func descriptors(_ id: String) throws -> [String: MixtapeTrackDescriptor] {
        Dictionary(uniqueKeysWithValues: try store.mixtapeTracks(id: id).map { ($0.id, .init(audioBytes: $0.bytes, audioSHA256: $0.hash)) })
    }
    private func mixtapePreview(_ record: ShareRecord) -> MixtapePreview? { record.preview.map { .init(title: $0.title, from: $0.from, note: $0.note) } }
    private func date(_ seconds: Int64) -> String { ShareDate.string(Date(timeIntervalSince1970: TimeInterval(seconds))) }
    private func mixtapeCreated(_ record: ShareRecord) throws -> ShareResponse {
        .json(CreateMixtapeResponse(id: record.id, url: config.publicBase.appendingPathComponent("m/\(record.id)").absoluteString,
            expiresAt: date(record.expiresAt), uploads: Dictionary(uniqueKeysWithValues: try store.mixtapeTracks(id: record.id).map { ($0.id, "/v1/share/mixtapes/\(record.id)/tracks/\($0.id)") })), status: 201)
    }
    private func mixtapeSummary(_ record: ShareRecord) throws -> MixtapeSummary {
        let state = try store.enforcementState(id: record.id)
        var value = try summary(record)
        if try store.isEnforced(record) { value.preview = nil; value.actionRequired = "This link requires review. You can still revoke it." }
        return .init(share: value, trackCount: try store.mixtapeTracks(id: record.id).count,
            reviewDeadline: state?.disabled == true ? state.map { date($0.deadline) } : nil,
            pausedLifetimeSeconds: state?.hasPausedLifetime == true ? state?.remainingSeconds : nil)
    }
    private func patchMixtape(_ request: HTTPRequestMessage, record: ShareRecord) throws -> ShareResponse {
        if let denial = try enforcementWriteDenial(record) { return denial }
        guard record.status == .pending || record.status == .ready, let body = try? JSONDecoder().decode(PatchShareRequest.self, from: request.body) else { return .error(409, "state", "This mixtape cannot be changed.") }
        if let extend = body.extendBySeconds {
            guard (1...config.limits.maxExpirySeconds).contains(extend), record.expiresAt > now else { throw ShareValidationError("extendBySeconds", "invalid extension") }
            try store.setExpiry(id: record.id, min(record.expiresAt + Int64(extend), now + Int64(config.limits.maxExpirySeconds)))
        }
        if let cap = body.playCap {
            guard (1...config.limits.maxPlayCap).contains(cap) else { throw ShareValidationError("playCap", "invalid cap") }
            try store.setPlayCap(id: record.id, cap)
        }
        return .json(try mixtapeSummary(try store.share(id: record.id)!))
    }
    private func admitMixtape(_ record: ShareRecord, who: ShareRequester) throws -> ShareResponse {
        let visitor = visitor(who, shareID: record.id)
        guard limiter.allow("session:\(visitor)", limit: config.limits.eventsPerVisitorPerMinute, per: 60, now: now) else { return .error(429, "rate_limited", "Try again later.") }
        return try store.database.transaction {
            guard let fresh = try playableMixtape(record.id, expire: false), fresh.stats.fetches < fresh.playCap else { return .error(410, "play_cap", "No new listening sessions remain.") }
            let token = Base64URL.encode(ShareCrypto.newKey() + ShareCrypto.newKey())
            let deadline = min(now + 1800, fresh.expiresAt)
            try store.database.run("DELETE FROM mixtape_sessions WHERE deadline<=?", [.int(now)])
            try store.database.run("INSERT INTO mixtape_sessions VALUES(?,?,?,?,?,?,?)", [.text(ShareHash.secretDigest(token)), .text(record.id), .int(fresh.accessGeneration),
                .int(try store.sharerRevision(digest: fresh.sharerDigest)), .int(Int64(fresh.stats.fetches + 1)), .int(deadline), .int(Int64(fresh.audioBytes))])
            try store.increment(id: record.id, .fetches)
            try store.record(event: "audio_fetched", at: now, shareID: record.id, sharerID: record.sharerID, visitor: visitor, props: ["kind": .string("mixtape")])
            return .json(MixtapeSession(token: token, expiresAt: date(deadline), remainingBytes: fresh.audioBytes, remainingPlays: fresh.playCap - fresh.stats.fetches - 1), status: 201)
        }
    }
    private func validMixtapeSession(_ request: HTTPRequestMessage, record: ShareRecord) throws -> [String: SQLValue]? {
        guard let token = request.bearerToken, token.count == 43, let bytes = Base64URL.decode(token), bytes.count == 32, Base64URL.encode(bytes) == token,
              let row = try store.database.query("SELECT * FROM mixtape_sessions WHERE digest=? AND share_id=?", [.text(ShareHash.secretDigest(token)), .text(record.id)]).first,
              row["generation"]?.int == record.accessGeneration, row["deadline"]?.int ?? 0 > now,
              row["ordinal"]?.int ?? Int64.max <= record.playCap,
              row["owner_revision"]?.int == (try store.sharerRevision(digest: record.sharerDigest)) else { return nil }
        return row
    }
    private func readMixtapeTrack(_ request: HTTPRequestMessage, record: ShareRecord, trackID: String, head: Bool) throws -> ShareResponse {
        try store.database.transaction {
            guard let fresh = try playableMixtape(record.id, expire: false) else { return .error(410, "expired", "This mixtape has ended.") }
            return try readMixtapeTrackWithinTransaction(request, record: fresh, trackID: trackID, head: head)
        }
    }
    private func readMixtapeTrackWithinTransaction(_ request: HTTPRequestMessage, record: ShareRecord, trackID: String, head: Bool) throws -> ShareResponse {
        guard ShareMixtapeCrypto.isCanonicalTrackID(trackID), let track = try store.mixtapeTracks(id: record.id).first(where: { $0.id == trackID && $0.stored }) else { return .error(404, "not_found", "No such track.") }
        guard let session = try validMixtapeSession(request, record: record) else { return .error(401, "session", "Start a new listening session.") }
        guard let range = MixtapeByteRange.parse(request.headers["range"], length: track.bytes) else { return .error(416, "range", "Invalid single byte range.", headers: ["Content-Range": "bytes */\(track.bytes)"]) }
        var headers = ["Cache-Control": "private, no-store", "Accept-Ranges": "bytes", "X-Content-Type-Options": "nosniff", "Content-Length": String(range.count)]
        if range.partial { headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(track.bytes)" }
        if head { return .init(status: range.partial ? 206 : 200, contentType: "application/octet-stream", headers: headers) }
        guard session["remaining_bytes"]?.int ?? 0 >= range.count else { return .error(409, "transfer_budget", "Another transfer needs explicit admission and another play.") }
        let file = try FileHandle(forReadingFrom: store.mixtapeTrackURL(id: record.id, track: trackID))
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(range.start))
        guard let data = try file.read(upToCount: range.count), data.count == range.count else { return .error(410, "expired", "This track is unavailable.") }
        // Reserve the exact returned slice atomically before delivery. Disconnects stay charged.
        let changed = try store.database.run("UPDATE mixtape_sessions SET remaining_bytes=remaining_bytes-? WHERE digest=? AND remaining_bytes>=?", [.int(Int64(range.count)), .text(session["digest"]!.text!), .int(Int64(range.count))])
        guard changed == 1 else { return .error(409, "transfer_budget", "Another transfer needs explicit admission and another play.") }
        return .init(status: range.partial ? 206 : 200, contentType: "application/octet-stream", body: data, headers: headers)
    }
    func mixtapeEvent(_ request: HTTPRequestMessage, record: ShareRecord, who: ShareRequester) throws -> ShareResponse {
        guard let event = try? JSONDecoder().decode(PlayerEvent.self, from: request.body) else { return .error(400, "invalid", "Not a player event.") }
        let props = try event.props(), visitor = visitor(who, shareID: record.id)
        guard limiter.allow("event:\(visitor)", limit: config.limits.eventsPerVisitorPerMinute, per: 60, now: now) else { return .error(429, "rate_limited", "Try again later.") }
        switch event.type { case .playStarted: try store.increment(id: record.id, .plays)
        case .played30s: try store.increment(id: record.id, .listened30)
        case .playCompleted: try store.increment(id: record.id, .completed)
        default: break }
        try store.record(event: event.type.rawValue, at: now, shareID: record.id, sharerID: record.sharerID, visitor: visitor, props: props)
        return .noContent
    }
    func mixtapeReaction(_ request: HTTPRequestMessage, record: ShareRecord, who: ShareRequester) throws -> ShareResponse {
        guard let body = try? JSONDecoder().decode(ReactionRequest.self, from: request.body) else { return .error(400, "invalid", "Not a reaction.") }
        let reaction = try body.validated()
        let visitor = visitor(who, shareID: record.id)
        guard try store.reactionCount(shareID: record.id, visitor: visitor, since: now - now % 86400) < config.limits.reactionsPerVisitorPerDay else { return .error(429, "rate_limited", "Try again later.") }
        try store.addReaction(shareID: record.id, reaction, visitor: visitor, at: now)
        return .noContent
    }
}

struct MixtapeByteRange {
    let start: Int
    let end: Int
    let partial: Bool
    var count: Int { end - start + 1 }
    static func parse(_ header: String?, length: Int) -> Self? {
        guard let header else { return .init(start: 0, end: length - 1, partial: false) }
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let pair = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard pair.count == 2, pair.allSatisfy({ $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return nil }
        if pair[0].isEmpty {
            guard let suffix = Int(pair[1]), suffix > 0 else { return nil }
            return .init(start: max(0, length - suffix), end: length - 1, partial: true)
        }
        guard let start = Int(pair[0]), start >= 0, start < length,
              let end = pair[1].isEmpty ? length - 1 : Int(pair[1]), end >= start, end < length else { return nil }
        return .init(start: start, end: end, partial: true)
    }
}
