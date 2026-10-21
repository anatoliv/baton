import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
import Foundation

/// Whole-book links (`/b/<id>#<K>`), specs/book-sharing.md "Phase 2: whole-book links".
///
/// The routes mirror the mixtape ones (`ShareMixtapeService.swift`) over the same tables, with a
/// book's own limits: 1 to 200 chapters, 25 MiB per chapter, 1 MiB per read-along text, 256 MiB
/// per book (manifest included), 3 live books per sharer and a 10 GiB slice of the quota, both
/// reserved at create. A listener session admits one listener for the life of the link (extending
/// the link extends it) with a byte allowance of 1.5 times the book. Default-off behind
/// `BATON_SHARE_BOOKS`; with it off, only the sharer's own list, read and revoke still answer.
///
/// An album or playlist link (specs/collection-sharing.md) is a book row with a `book_kind`, so
/// every route, limit and reservation here holds for it too. Its own default-off flag,
/// `BATON_SHARE_COLLECTIONS`, refuses a new collection and a collection's listener routes, finalize,
/// upload and PATCH with 409 `unsupported`; the sharer's list, read and revoke still answer.
extension ShareService {
    /// The create body ceiling: a 256 KiB manifest in base64 plus 400 blob descriptors fits. The
    /// kit holds the number, so the app's check and this one cannot drift apart.
    static let maxBookCreateBodyBytes = ShareLimits.maxBookCreateBodyBytes

    func bookRoute(_ request: HTTPRequestMessage, parts: [String], who: ShareRequester) throws -> ShareResponse? {
        let method = request.method.uppercased()
        guard parts.count >= 3, parts[0] == "v1", parts[1] == "share", ["books", "b"].contains(parts[2]) else { return nil }
        if parts[2] == "books" {
            guard let sharer = sharer(bearer: request.bearerToken) else { return .error(401, "unauthorized", "Missing install secret.") }
            if parts.count == 3 {
                if method == "POST" {
                    guard config.booksEnabled else { return booksUnsupported }
                    guard config.collectionsEnabled || !Self.isCollectionRequest(request.body) else { return collectionsUnsupported }
                    return try createBook(request, sharer: sharer, who: who)
                }
                if method == "GET" {
                    let rows = try store.database.query("SELECT * FROM shares WHERE sharer_digest=? AND is_book=1 ORDER BY created_at DESC,id LIMIT 200", [.text(sharer.digest)])
                    return .json(BookList(books: try rows.map { try bookSummary(ShareStore.record($0)) }))
                }
                return .error(405, "method", "Method not allowed.")
            }
            guard ShareLink.isValidID(parts[3]), let record = try store.share(id: parts[3]), record.isBook,
                  record.sharerDigest == sharer.digest else { return .error(404, "not_found", "No such share.") }
            if parts.count == 4 {
                switch method {
                case "GET": return .json(try bookSummary(record))
                case "DELETE":
                    if record.status == .pending || record.status == .ready {
                        try store.tombstone(id: record.id, as: .revoked, now: now)
                        try store.record(event: "share_revoked", at: now, shareID: record.id, sharerID: record.sharerID, props: ["kind": .string(Self.kindLabel(record))])
                    }
                    return .noContent
                case "PATCH":
                    guard config.booksEnabled else { return booksUnsupported }
                    if let refusal = collectionRefusal(record) { return refusal }
                    return try patchBook(request, record: record)
                default: return .error(405, "method", "Method not allowed.")
                }
            }
            if parts.count == 5, parts[4] == "finalize" {
                guard method == "POST" else { return .error(405, "method", "Method not allowed.") }
                guard config.booksEnabled else { return booksUnsupported }
                if let refusal = collectionRefusal(record) { return refusal }
                return try finalizeBook(record, sharer: sharer)
            }
            if parts.count == 6, parts[4] == "blobs" {
                // Uploads never reach here: the transport streams every PUT to a canonical blob path.
                return method == "PUT" ? .error(400, "invalid", "Upload with a Content-Length.") : .error(405, "method", "Method not allowed.")
            }
            return .error(404, "not_found", "No such route.")
        }

        guard config.booksEnabled else { return booksUnsupported }
        guard parts.count >= 4, ShareLink.isValidID(parts[3]), let candidate = try store.share(id: parts[3]), candidate.isBook else {
            return .error(404, "not_found", "No such share.")
        }
        if let refusal = collectionRefusal(candidate) { return refusal }
        if parts.count == 4, method == "GET", candidate.status == .pending, candidate.expiresAt > now, try !store.isEnforced(candidate) {
            return .json(publicBook(candidate, remaining: candidate.playCap))
        }
        // Revoked, expired, held and capped-out-of-time all read as expired to a listener.
        guard let record = try playableBook(parts[3]) else { return .error(410, "expired", "This link is unavailable or has ended.") }
        if parts.count == 4 {
            guard method == "GET" else { return .error(405, "method", "Method not allowed.") }
            return .json(publicBook(record, remaining: max(0, record.playCap - record.stats.fetches)))
        }
        if parts.count == 5, parts[4] == "sessions", method == "POST" { return try admitBook(record, who: who) }
        if parts.count == 6, parts[4] == "blobs", ["GET", "HEAD"].contains(method) {
            return try readBookBlob(request, record: record, blobID: parts[5], head: method == "HEAD")
        }
        if parts.count == 5, method == "POST", ["events", "reactions"].contains(parts[4]) {
            guard try validBookSession(request, record: record) != nil else { return .error(401, "session", "Start a listening session first.") }
            if parts[4] == "events" { return try mixtapeEvent(request, record: record, who: who) }
            return try mixtapeReaction(request, record: record, who: who)
        }
        return .error(404, "not_found", "No such route.")
    }

    var booksUnsupported: ShareResponse { .error(409, "unsupported", "This server does not support book links.") }
    var collectionsUnsupported: ShareResponse { .error(409, "unsupported", "This server does not support album and playlist links.") }

    /// 409 `unsupported` for an album or playlist while collections are off; nil for a book.
    func collectionRefusal(_ record: ShareRecord) -> ShareResponse? {
        record.bookKind != nil && !config.collectionsEnabled ? collectionsUnsupported : nil
    }

    /// The `kind` a `/b/` link's usage events carry: `book`, `album` or `playlist`.
    static func kindLabel(_ record: ShareRecord) -> String { record.bookKind?.rawValue ?? "book" }

    /// Whether a create body asks for a collection (its schema or a `kind`), read only far enough to
    /// refuse it while collections are off, before any other check. A book body never matches.
    static func isCollectionRequest(_ body: Data) -> Bool {
        struct Probe: Decodable { let schema: String?; let kind: String? }
        guard body.count <= maxBookCreateBodyBytes, let probe = try? JSONDecoder().decode(Probe.self, from: body) else { return false }
        return probe.schema == ShareBookManifest.collectionSchemaVersion || probe.kind != nil
    }

    // MARK: - Owner

    private func createBook(_ request: HTTPRequestMessage, sharer: Sharer, who: ShareRequester) throws -> ShareResponse {
        guard config.enabled else { return .error(503, "share_disabled", "Sharing is paused for now.") }
        if let denial = try enforcementCreateDenial(sharer) { return denial }
        guard request.body.count <= Self.maxBookCreateBodyBytes, UniqueJSONKeys.validate(request.body),
              let body = try? JSONDecoder().decode(CreateBookRequest.self, from: request.body) else { return .error(400, "invalid", "Not a bounded book request.") }
        let valid = try body.validated(limits: config.limits)
        let hash = ShareHash.sha256Hex(request.body)
        let integrity = try verifyCreate(request, sharer: sharer)
        if let replay = integrity.replay { return replay }
        return try store.database.transaction {
            if let previous = try store.database.query("SELECT body_hash,share_id FROM mixtape_creates WHERE owner=? AND request_id=?", [.text(sharer.digest), .text(valid.requestID)]).first {
                guard previous["body_hash"]?.text == hash, let id = previous["share_id"]?.text, let record = try store.share(id: id), record.isBook, record.bookKind == valid.kind,
                      record.status == .pending || record.status == .ready else { return .error(409, "conflict", "This retry identity no longer matches a live book.") }
                let response = try bookCreated(record)
                if let verified = integrity.verified { try commitVerifiedCreate(verified, response: response, digest: sharer.digest) }
                return response
            }
            let total = Int64(valid.totalBytes), limits = config.limits
            let preview = valid.preview.map { ShareMetadata(title: $0.title, artist: $0.author, durationSeconds: valid.totalDurationSeconds, from: $0.from, note: $0.note) }
            let single = CreateShareRequest(expiresInSeconds: valid.expiresInSeconds, playCap: valid.listenerCap, preview: preview, encryptedMeta: valid.encryptedManifest,
                durationBucket: DurationBucket(seconds: valid.totalDurationSeconds), audioBytes: valid.blobBytes, audioSHA256: String(repeating: "0", count: 64),
                client: valid.client, reviewPreservationConsent: valid.reviewPreservationConsent)
            let created = try createAuthorized(single, sharer: sharer, who: who, verified: integrity.verified != nil, kind: valid.kind?.rawValue ?? "book") {
                guard try self.store.liveBooks(byDigest: sharer.digest) < limits.liveBooksPerSharer else { return self.rateLimited("sharer_live_books", now: self.now) }
                // The whole quota and the book slice, both reserved by the row this transaction inserts.
                guard try self.store.quotaBytes() <= limits.quotaBytes - total,
                      try self.store.bookQuotaBytes() <= min(limits.bookQuotaBytes, limits.quotaBytes) - total else {
                    return .error(503, "busy", "Sharing is busy right now.")
                }
                return nil
            }
            guard created.status == 201 else { return created }
            let id = try JSONDecoder().decode(CreateShareResponse.self, from: created.body).id
            try store.database.run("UPDATE shares SET is_mixtape=1,is_book=1,book_kind=?,stored_bytes=? WHERE id=?",
                                   [.text(valid.kind?.rawValue ?? "book"), .int(Int64(valid.manifestBytes)), .text(id)])
            for (blob, descriptor) in valid.blobs {
                try store.database.run("INSERT INTO mixtape_tracks(share_id,track_id,audio_bytes,audio_sha256,role) VALUES(?,?,?,?,?)",
                    [.text(id), .text(blob), .int(Int64(descriptor.bytes)), .text(descriptor.sha256), .text(descriptor.role.rawValue)])
            }
            try store.database.run("INSERT INTO mixtape_creates VALUES(?,?,?,?)", [.text(sharer.digest), .text(valid.requestID), .text(hash), .text(id)])
            let response = try bookCreated(try store.share(id: id)!)
            if let verified = integrity.verified { try commitVerifiedCreate(verified, response: response, digest: sharer.digest) }
            return response
        }
    }

    func uploadBook(_ request: StreamingUpload.Request, file: URL) throws -> ShareResponse {
        guard config.booksEnabled else { return booksUnsupported }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count == 6, parts[4] == "blobs", ShareLink.isValidID(parts[3]), ShareBookCrypto.isCanonicalID(parts[5]),
              let sharer = sharer(bearer: request.bearerToken) else { return .error(404, "not_found", "No such route.") }
        return try store.database.transaction {
            guard let record = try store.share(id: parts[3]), record.isBook, record.sharerDigest == sharer.digest else { return .error(404, "not_found", "No such share.") }
            if let refusal = collectionRefusal(record) { return refusal }
            if let denial = try enforcementWriteDenial(record) { return denial }
            guard record.status == .pending, record.expiresAt > now,
                  let blob = try store.bookBlobs(id: record.id).first(where: { $0.id == parts[5] }) else { return .error(409, "state", "The book is no longer pending.") }
            let cap = blob.role == .audio ? config.limits.maxBookChapterBytes : config.limits.maxBookTextBytes
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular, blob.bytes <= cap,
                  request.contentLength == blob.bytes, (attrs[.size] as? NSNumber)?.intValue == blob.bytes,
                  (try? ShareCrypto.layout(headerBytes: readHead(file), totalLength: blob.bytes)) != nil else { return .error(400, "invalid", "The blob length or encrypted stream is invalid.") }
            guard try sha256(file) == blob.hash else { return .error(422, "checksum", "The blob does not match its declared checksum.") }
            if blob.stored { return .json(["ok": true]) }
            let destination = store.mixtapeTrackURL(id: record.id, track: blob.id)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: file, to: destination)
            let changed = try store.database.run("UPDATE mixtape_tracks SET stored=1 WHERE share_id=? AND track_id=? AND stored=0", [.text(record.id), .text(blob.id)])
            guard changed == 1 else { throw ShareValidationError("blob", "upload state changed") }
            try store.database.run("UPDATE shares SET stored_bytes=stored_bytes+? WHERE id=?", [.int(Int64(blob.bytes)), .text(record.id)])
            return .json(["ok": true])
        }
    }

    private func finalizeBook(_ record: ShareRecord, sharer: Sharer) throws -> ShareResponse {
        try store.database.transaction {
            guard let fresh = try store.share(id: record.id), fresh.isBook, fresh.sharerDigest == sharer.digest else { return .error(404, "not_found", "No such share.") }
            if let denial = try enforcementWriteDenial(fresh) { return denial }
            if fresh.status == .ready { return .json(try bookSummary(fresh)) }
            guard fresh.status == .pending, fresh.expiresAt > now else { return .error(409, "state", "This book has ended.") }
            guard try store.bookMaterialComplete(fresh, limits: config.limits) else { return .error(409, "incomplete", "Upload every declared chapter and text first.") }
            try store.database.run("UPDATE shares SET status='ready',audio_stored=1 WHERE id=? AND status='pending'", [.text(fresh.id)])
            try store.record(event: "share_finalized", at: now, shareID: fresh.id, sharerID: fresh.sharerID,
                             props: ["audioBytes": .int(fresh.audioBytes), "kind": .string(Self.kindLabel(fresh))])
            return .json(try bookSummary(try store.share(id: fresh.id)!))
        }
    }

    private func patchBook(_ request: HTTPRequestMessage, record: ShareRecord) throws -> ShareResponse {
        if let denial = try enforcementWriteDenial(record) { return denial }
        guard record.status == .pending || record.status == .ready, let body = try? JSONDecoder().decode(PatchShareRequest.self, from: request.body) else { return .error(409, "state", "This book cannot be changed.") }
        if let cap = body.playCap {
            guard (1 ... config.limits.maxBookListeners).contains(cap) else { throw ShareValidationError("playCap", "must be from 1 to \(config.limits.maxBookListeners)") }
        }
        try store.database.transaction {
            if let extend = body.extendBySeconds {
                guard (1 ... config.limits.maxExpirySeconds).contains(extend), record.expiresAt > now else { throw ShareValidationError("extendBySeconds", "invalid extension") }
                let expiry = min(record.expiresAt + Int64(extend), now + Int64(config.limits.maxExpirySeconds))
                try store.setExpiry(id: record.id, expiry)
                // A book session lasts as long as its link: extending the link extends its sessions.
                try store.database.run("UPDATE mixtape_sessions SET deadline=? WHERE share_id=?", [.int(expiry), .text(record.id)])
                try store.record(event: "share_extended", at: now, shareID: record.id, sharerID: record.sharerID, props: ["kind": .string(Self.kindLabel(record))])
            }
            if let cap = body.playCap { try store.setPlayCap(id: record.id, cap) }
        }
        return .json(try bookSummary(try store.share(id: record.id)!))
    }

    private func bookCreated(_ record: ShareRecord) throws -> ShareResponse {
        .json(CreateBookResponse(id: record.id, url: bookURL(record.id), expiresAt: bookDate(record.expiresAt),
            uploads: Dictionary(uniqueKeysWithValues: try store.bookBlobs(id: record.id).map { ($0.id, "/v1/share/books/\(record.id)/blobs/\($0.id)") })), status: 201)
    }

    private func bookSummary(_ record: ShareRecord) throws -> BookSummary {
        let state = try store.enforcementState(id: record.id)
        var value = try summary(record)
        if try store.isEnforced(record) { value.preview = nil; value.actionRequired = "This link requires review. You can still revoke it." }
        let blobs = try store.bookBlobs(id: record.id)
        return .init(share: value, chapterCount: blobs.filter { $0.role == .audio }.count, hasText: blobs.contains { $0.role == .text },
            reviewDeadline: state?.disabled == true ? state.map { bookDate($0.deadline) } : nil,
            pausedLifetimeSeconds: state?.hasPausedLifetime == true ? state?.remainingSeconds : nil, kind: record.bookKind)
    }

    // MARK: - Listener

    func bookURL(_ id: String) -> String { config.publicBase.appendingPathComponent("b").appendingPathComponent(id).absoluteString }
    private func bookDate(_ seconds: Int64) -> String { ShareDate.string(Date(timeIntervalSince1970: TimeInterval(seconds))) }

    static func bookPreview(_ record: ShareRecord) -> BookPreview? {
        record.preview.map { BookPreview(title: $0.title, author: $0.artist, from: $0.from, note: $0.note) }
    }

    private func publicBook(_ record: ShareRecord, remaining: Int) -> PublicBook {
        let blobs = (try? store.bookBlobs(id: record.id)) ?? []
        return PublicBook(status: record.status, preview: Self.bookPreview(record), encryptedManifest: record.encryptedMeta ?? "",
            blobs: Dictionary(uniqueKeysWithValues: blobs.map { ($0.id, BookBlobDescriptor(role: $0.role, bytes: $0.bytes, sha256: $0.hash)) }),
            expiresAt: bookDate(record.expiresAt), remainingListeners: remaining, kind: record.bookKind)
    }

    private func playableBook(_ id: String, expire: Bool = true) throws -> ShareRecord? {
        guard ShareLink.isValidID(id), let record = try store.share(id: id), record.isBook,
              record.status == .ready, try !store.isEnforced(record) else { return nil }
        guard record.expiresAt > now else {
            if expire {
                try store.tombstone(id: id, as: .expired, now: now)
                try store.record(event: "share_expired", at: now, shareID: id, sharerID: record.sharerID, props: ["kind": .string(Self.kindLabel(record))])
            }
            return nil
        }
        return record
    }

    private func admitBook(_ record: ShareRecord, who: ShareRequester) throws -> ShareResponse {
        let visitor = visitor(who, shareID: record.id)
        guard limiter.allow("session:\(visitor)", limit: config.limits.eventsPerVisitorPerMinute, per: 60, now: now) else { return .error(429, "rate_limited", "Try again later.") }
        return try store.database.transaction {
            guard let fresh = try playableBook(record.id, expire: false), fresh.stats.fetches < fresh.playCap else { return .error(410, "play_cap", "No listeners remain on this link.") }
            let token = Base64URL.encode(ShareCrypto.newKey() + ShareCrypto.newKey())
            let allowance = ShareLimits.bookSessionAllowance(bookBytes: fresh.audioBytes)
            try store.database.run("DELETE FROM mixtape_sessions WHERE deadline<=?", [.int(now)])
            try store.database.run("INSERT INTO mixtape_sessions VALUES(?,?,?,?,?,?,?)", [.text(ShareHash.secretDigest(token)), .text(fresh.id), .int(fresh.accessGeneration),
                .int(try store.sharerRevision(digest: fresh.sharerDigest)), .int(Int64(fresh.stats.fetches + 1)), .int(fresh.expiresAt), .int(Int64(allowance))])
            try store.increment(id: fresh.id, .fetches)
            try store.record(event: "audio_fetched", at: now, shareID: fresh.id, sharerID: fresh.sharerID, visitor: visitor, props: ["kind": .string(Self.kindLabel(fresh))])
            return .json(BookSession(token: token, expiresAt: bookDate(fresh.expiresAt), remainingBytes: allowance,
                                     remainingListeners: fresh.playCap - fresh.stats.fetches - 1), status: 201)
        }
    }

    /// The token's session, only while it still holds: same link and enforcement generation,
    /// unchanged sharer revision, an ordinal inside the current cap and an unexpired link.
    private func validBookSession(_ request: HTTPRequestMessage, record: ShareRecord) throws -> [String: SQLValue]? {
        guard let token = request.bearerToken, token.count == 43, let bytes = Base64URL.decode(token), bytes.count == 32, Base64URL.encode(bytes) == token,
              let row = try store.database.query("SELECT * FROM mixtape_sessions WHERE digest=? AND share_id=?", [.text(ShareHash.secretDigest(token)), .text(record.id)]).first,
              row["generation"]?.int == record.accessGeneration, row["deadline"]?.int ?? 0 > now, record.expiresAt > now,
              row["ordinal"]?.int ?? Int64.max <= record.playCap,
              row["owner_revision"]?.int == (try store.sharerRevision(digest: record.sharerDigest)) else { return nil }
        return row
    }

    private func readBookBlob(_ request: HTTPRequestMessage, record: ShareRecord, blobID: String, head: Bool) throws -> ShareResponse {
        try store.database.transaction {
            guard let fresh = try playableBook(record.id, expire: false) else { return .error(410, "expired", "This link has ended.") }
            guard ShareBookCrypto.isCanonicalID(blobID), let blob = try store.bookBlobs(id: fresh.id).first(where: { $0.id == blobID && $0.stored }) else { return .error(404, "not_found", "No such blob.") }
            guard let session = try validBookSession(request, record: fresh) else { return .error(401, "session", "Start a new listening session.") }
            guard let range = MixtapeByteRange.parse(request.headers["range"], length: blob.bytes) else {
                return .error(416, "range", "Invalid single byte range.", headers: ["Content-Range": "bytes */\(blob.bytes)"])
            }
            var headers = ["Cache-Control": "private, no-store", "Accept-Ranges": "bytes", "X-Content-Type-Options": "nosniff", "Content-Length": String(range.count)]
            if range.partial { headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(blob.bytes)" }
            if head { return .init(status: range.partial ? 206 : 200, contentType: "application/octet-stream", headers: headers) }
            guard session["remaining_bytes"]?.int ?? 0 >= range.count else { return .error(409, "transfer_budget", "This listen has used its transfer allowance.") }
            let file = try FileHandle(forReadingFrom: store.mixtapeTrackURL(id: fresh.id, track: blob.id))
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(range.start))
            guard let data = try file.read(upToCount: range.count), data.count == range.count else { return .error(410, "expired", "This link is unavailable.") }
            // Reserve the exact slice before delivery; a disconnect stays charged.
            let changed = try store.database.run("UPDATE mixtape_sessions SET remaining_bytes=remaining_bytes-? WHERE digest=? AND remaining_bytes>=?",
                                                 [.int(Int64(range.count)), .text(session["digest"]!.text!), .int(Int64(range.count))])
            guard changed == 1 else { return .error(409, "transfer_budget", "This listen has used its transfer allowance.") }
            return .init(status: range.partial ? 206 : 200, contentType: "application/octet-stream", body: data, headers: headers)
        }
    }

    // MARK: - Page

    func bookPlayerPage(id: String, who: ShareRequester) throws -> ShareResponse {
        // The stored kind picks the page: book.html for a book, collection.html for an album or playlist.
        let found = ShareLink.isValidID(id) ? try store.share(id: id).flatMap { $0.isBook ? $0 : nil } : nil
        let kind = found?.bookKind
        guard config.booksEnabled, kind == nil || config.collectionsEnabled else { return bookPage.render(id: nil, state: "unsupported", kind: kind) }
        guard let record = found else { return bookPage.render(id: nil, state: "unknown") }
        // Not `config.enabled`: pausing sharing refuses new shares, and links already sent keep playing.
        guard try !store.isEnforced(record), record.expiresAt > now,
              record.status == .ready || record.status == .pending else { return bookPage.render(id: id, state: "expired", kind: kind) }
        let state = record.status == .pending ? "pending" : "ready"
        if let app = ClientClass.crawler(userAgent: who.userAgent) {
            try store.record(event: "link_unfurled", at: now, shareID: id, sharerID: record.sharerID, props: ["app": .string(app), "kind": .string(Self.kindLabel(record))])
        } else {
            if record.status == .ready { try store.increment(id: id, .opens) }
            try store.record(event: "page_opened", at: now, shareID: id, sharerID: record.sharerID, visitor: visitor(who, shareID: id),
                             props: ["device": .string(ClientClass.device(userAgent: who.userAgent)), "state": .string(state), "kind": .string(Self.kindLabel(record))])
        }
        return bookPage.render(id: id, state: state, preview: Self.bookPreview(record), kind: kind)
    }
}
