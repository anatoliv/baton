import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A whole book, sealed to disk and ready to upload as one `/b/` link (`specs/book-sharing.md`,
/// Phase 2, TBX-1000000132).
///
/// Built by `make`, which seals the chapters one at a time into a caller-given app-private staging
/// directory: read one chapter's audio, seal it under its own chapter key with a fresh random ID,
/// write the sealed file, hash it and let the memory go before the next. Read-along text, when the
/// sharer included it, goes the same way under the text key with its own random ID. Every cap the
/// service advertised is checked before the first chapter is sealed, from the files' sizes and the
/// exact sealed lengths, so a book that does not fit fails at once rather than after an hour of
/// encryption.
///
/// The staged files, the key and the exact request bytes stay in the directory with a small
/// ticket (`book.json`), so a failed upload retries the same link: the same `requestID`, the
/// identical body, the same blobs. Only ciphertext and the key are kept; the key is what the link
/// carries, and the ticket is written readable only by this user.
public struct PreparedBookShare: Sendable {
    public struct Chapter: Sendable {
        /// The chapter's audio file on this device.
        public var audio: URL
        public var title: String
        /// Whole seconds, at least 1 (`ShareBookPlan.Chapter.wireSeconds`).
        public var durationSeconds: Int
        /// The chapter's read-along text, only when the sharer chose to include it. Never on a track.
        public var text: ShareBookText?
        /// A collection track's artist, album and number on its album; nil for a book chapter.
        public var artist: String?
        public var album: String?
        public var trackNumber: Int?
        public init(audio: URL, title: String, durationSeconds: Int, text: ShareBookText? = nil,
                    artist: String? = nil, album: String? = nil, trackNumber: Int? = nil) {
            self.audio = audio; self.title = title; self.durationSeconds = durationSeconds; self.text = text
            self.artist = artist; self.album = album; self.trackNumber = trackNumber
        }
    }

    /// One sealed file waiting in the staging directory, in upload order.
    public struct Blob: Codable, Equatable, Sendable {
        public var id: String
        public var role: BookBlobDescriptor.Role
        public var bytes: Int
        public var sha256: String
        public init(id: String, role: BookBlobDescriptor.Role, bytes: Int, sha256: String) {
            self.id = id; self.role = role; self.bytes = bytes; self.sha256 = sha256
        }
    }

    /// Why a book could not be prepared. Chapter numbers are 1-based positions in the input.
    public enum Failure: Error, Equatable, Sendable {
        case noChapters
        case tooManyChapters(max: Int)
        case unreadable(chapter: Int)
        case chapterTooLong(chapter: Int)
        case tooLong
        case chapterTooLarge(chapter: Int)
        case textTooLarge(chapter: Int)
        case bookTooLarge
        case manifestTooLarge
        case requestTooLarge
        /// The staging directory already holds another book's ticket.
        case directoryInUse
        /// A staged file or ticket no longer matches what was sealed.
        case damaged
    }

    public static let ticketName = "book.json"
    /// `POST /v1/share/books` takes a body of at most this many bytes (`ShareLimits`).
    public static let maximumRequestBytes = ShareLimits.maxBookCreateBodyBytes

    public let directory: URL
    public let key: Data
    public let request: CreateBookRequest
    /// The exact bytes POSTed, kept so a retry sends an identical body.
    public let requestBody: Data
    public let manifest: ShareBookManifest
    public let blobs: [Blob]
    /// The caps the book was checked against, so a later retry checks the same ones.
    public let limits: ShareBookLimits
    /// The App Attest proof sent with the create, when the service asked for one; kept so a retry
    /// of an uncertain create carries the same proof.
    public var proof: ShareAttestationProof?
    /// The service's answer to the create, once it came.
    public var created: CreateBookResponse?
    /// Blob IDs the service has acknowledged.
    public var uploaded: Set<String> = []

    public var totalBlobBytes: Int { blobs.reduce(0) { $0 + $1.bytes } }

    public func file(_ blobID: String) -> URL { directory.appendingPathComponent(blobID + ".sealed") }

    // MARK: Making

    public static func make(chapters: [Chapter], title: String, author: String = "", from: String = "", note: String = "",
                            preview: BookPreview?, expiresInSeconds: Int, listenerCap: Int, client: ShareClientInfo,
                            reviewPreservationConsent: String? = nil, limits bookLimits: ShareBookLimits,
                            directory: URL, key: Data = ShareCrypto.newKey(), requestID: String = UUID().uuidString,
                            kind: ShareCollectionKind? = nil, cover: ShareBookManifest.Cover? = nil,
                            progress: (@Sendable (_ sealed: Int, _ total: Int) -> Void)? = nil) throws -> Self {
        let limits = bookLimits.applied()
        guard key.count == ShareCrypto.keyLength else { throw ShareCrypto.Failure.badKey }
        guard !chapters.isEmpty else { throw Failure.noChapters }
        guard chapters.count <= limits.maxBookChapters else { throw Failure.tooManyChapters(max: limits.maxBookChapters) }

        // Every cap first, from sizes alone: the sealed length of a plaintext is exact.
        var seen = Set<String>()
        func freshID() -> String {
            var id = ShareBookCrypto.newID()
            while !seen.insert(id).inserted { id = ShareBookCrypto.newID() }
            return id
        }
        let placeholder = String(repeating: "0", count: 64)
        var planned = [ShareBookManifest.Chapter](), texts = [Data?](), total = 0, seconds = 0
        for (offset, chapter) in chapters.enumerated() {
            let number = offset + 1
            guard let size = (try? FileManager.default.attributesOfItem(atPath: chapter.audio.path))?[.size] as? Int,
                  size > 0 else { throw Failure.unreadable(chapter: number) }
            guard (1 ... limits.maxBookChapterSeconds).contains(chapter.durationSeconds) else {
                throw Failure.chapterTooLong(chapter: number)
            }
            guard chapter.durationSeconds <= limits.maxBookSeconds - seconds else { throw Failure.tooLong }
            seconds += chapter.durationSeconds
            let audioBytes = ShareCrypto.sealedLength(plaintextLength: size)
            guard audioBytes <= limits.maxBookChapterBytes else { throw Failure.chapterTooLarge(chapter: number) }
            guard audioBytes <= limits.maxBookBytes - total else { throw Failure.bookTooLarge }
            total += audioBytes
            var entry = ShareBookManifest.Chapter(id: freshID(), title: chapter.title, durationSeconds: chapter.durationSeconds,
                                                  audioBytes: audioBytes, audioSHA256: placeholder,
                                                  artist: kind == nil ? nil : chapter.artist, album: kind == nil ? nil : chapter.album,
                                                  trackNumber: kind == nil ? nil : chapter.trackNumber)
            let text = kind == nil ? try chapter.text.map { try $0.encoded() } : nil
            if let text {
                let textBytes = ShareCrypto.sealedLength(plaintextLength: text.count)
                guard textBytes <= limits.maxBookTextBytes else { throw Failure.textTooLarge(chapter: number) }
                guard textBytes <= limits.maxBookBytes - total else { throw Failure.bookTooLarge }
                total += textBytes
                entry.text = .init(id: freshID(), bytes: textBytes, sha256: placeholder)
            }
            planned.append(entry)
            texts.append(text)
        }
        // The manifest's sealed length does not depend on the hashes, so it is known now too.
        func makeManifest(_ chapters: [ShareBookManifest.Chapter]) -> ShareBookManifest {
            guard let kind else { return ShareBookManifest(title: title, author: author, from: from, note: note, chapters: chapters) }
            return ShareBookManifest(collection: kind, title: title, artist: author, from: from, note: note, cover: cover, tracks: chapters)
        }
        let draft = makeManifest(planned)
        let checked = try draft.validated(limits: limits)
        let manifestBytes = ShareCrypto.sealedLength(plaintextLength: try JSONEncoder().encode(checked).count)
        guard manifestBytes <= limits.maxBookManifestBytes else { throw Failure.manifestTooLarge }
        guard manifestBytes <= limits.maxBookBytes - total else { throw Failure.bookTooLarge }
        _ = try draft.validated(limits: limits, encryptedManifestBytes: manifestBytes)

        try Self.prepare(directory)
        var written = [URL]()
        do {
            var sealedChapters = [ShareBookManifest.Chapter](), blobs = [Blob]()
            for (offset, chapter) in chapters.enumerated() {
                var entry = planned[offset]
                // One chapter in memory at a time: read, seal, write, hash, and let it go.
                let audioHash: String = try {
                    guard let plain = try? Data(contentsOf: chapter.audio, options: .mappedIfSafe),
                          ShareCrypto.sealedLength(plaintextLength: plain.count) == entry.audioBytes else {
                        throw Failure.unreadable(chapter: offset + 1)
                    }
                    let sealed = try ShareCrypto.seal(plain, key: ShareBookCrypto.chapterKey(rootKey: key, chapterID: entry.id),
                                                      purpose: .audio)
                    guard sealed.count == entry.audioBytes else { throw Failure.damaged }
                    let url = directory.appendingPathComponent(entry.id + ".sealed")
                    try ShareUploadStore.writeProtected(sealed, to: url)
                    written.append(url)
                    return ShareHash.sha256Hex(sealed)
                }()
                entry.audioSHA256 = audioHash
                blobs.append(.init(id: entry.id, role: .audio, bytes: entry.audioBytes, sha256: audioHash))
                if var text = entry.text, let plain = texts[offset] {
                    let sealed = try ShareCrypto.seal(plain, key: ShareBookCrypto.textKey(rootKey: key, chapterID: entry.id),
                                                      purpose: .meta)
                    guard sealed.count == text.bytes else { throw Failure.damaged }
                    let url = directory.appendingPathComponent(text.id + ".sealed")
                    try ShareUploadStore.writeProtected(sealed, to: url)
                    written.append(url)
                    text.sha256 = ShareHash.sha256Hex(sealed)
                    entry.text = text
                    blobs.append(.init(id: text.id, role: .text, bytes: text.bytes, sha256: text.sha256))
                }
                sealedChapters.append(entry)
                progress?(offset + 1, chapters.count)
            }
            let book = try assemble(makeManifest(sealedChapters), blobs: blobs, key: key, requestID: requestID, preview: preview,
                                    expiresInSeconds: expiresInSeconds, listenerCap: listenerCap, client: client,
                                    reviewPreservationConsent: reviewPreservationConsent, bookLimits: bookLimits, directory: directory)
            written.append(directory.appendingPathComponent(ticketName))
            return book
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// The last step of every make: the sealed manifest, the exact request bytes and the ticket.
    static func assemble(_ draft: ShareBookManifest, blobs: [Blob], key: Data, requestID: String, preview: BookPreview?,
                         expiresInSeconds: Int, listenerCap: Int, client: ShareClientInfo, reviewPreservationConsent: String?,
                         bookLimits: ShareBookLimits, directory: URL) throws -> Self {
        let limits = bookLimits.applied()
        let manifest = try draft.validated(limits: limits)
        let encrypted = try manifest.seal(rootKey: key, limits: limits)
        let request = try CreateBookRequest(
            requestID: requestID, encryptedManifest: encrypted.base64EncodedString(), blobs: manifest.blobs,
            totalDurationSeconds: manifest.durationSeconds, expiresInSeconds: expiresInSeconds, listenerCap: listenerCap,
            preview: preview, client: client, reviewPreservationConsent: reviewPreservationConsent, kind: manifest.kind).validated(limits: limits)
        guard request.totalBytes <= limits.maxBookBytes else { throw Failure.bookTooLarge }
        let body = try Self.encode(request)
        guard body.count <= maximumRequestBytes else { throw Failure.requestTooLarge }
        let book = PreparedBookShare(directory: directory, key: key, request: request, requestBody: body, manifest: manifest,
                                     blobs: blobs, limits: bookLimits)
        try book.save()
        return book
    }

    private init(directory: URL, key: Data, request: CreateBookRequest, requestBody: Data, manifest: ShareBookManifest,
                 blobs: [Blob], limits: ShareBookLimits) {
        self.directory = directory; self.key = key; self.request = request; self.requestBody = requestBody
        self.manifest = manifest; self.blobs = blobs; self.limits = limits
    }

    static func encode(_ request: CreateBookRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    /// An app-private folder: this user only, out of backups, and holding no other book.
    static func prepare(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard !manager.fileExists(atPath: directory.appendingPathComponent(ticketName).path) else { throw Failure.directoryInUse }
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(excluded)
    }

    // MARK: The ticket

    private struct Ticket: Codable {
        var version = 1
        var key: Data
        var requestBody: Data
        var blobs: [Blob]
        var limits: ShareBookLimits
        var proof: ShareAttestationProof?
        var created: CreateBookResponse?
        var uploaded: [String]
    }

    /// Writes the ticket: the key, the request bytes, and how far the upload has got.
    public func save() throws {
        let ticket = Ticket(key: key, requestBody: requestBody, blobs: blobs, limits: limits, proof: proof,
                            created: created, uploaded: uploaded.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try ShareUploadStore.writeProtected(encoder.encode(ticket), to: directory.appendingPathComponent(Self.ticketName))
    }

    /// The book staged in `directory`, checked again: the request still validates, the manifest
    /// opens under the key and declares exactly these blobs, and every staged file is its size.
    public static func load(from directory: URL) throws -> Self {
        let data = try Data(contentsOf: directory.appendingPathComponent(ticketName))
        guard let ticket = try? JSONDecoder().decode(Ticket.self, from: data), ticket.version == 1,
              ticket.key.count == ShareCrypto.keyLength,
              let decoded = try? JSONDecoder().decode(CreateBookRequest.self, from: ticket.requestBody) else { throw Failure.damaged }
        let limits = ticket.limits.applied()
        guard let request = try? decoded.validated(limits: limits),
              let encrypted = Data(base64Encoded: request.encryptedManifest),
              let manifest = try? ShareBookManifest.open(encrypted, rootKey: ticket.key, limits: limits),
              manifest.blobs == request.blobs, ticket.blobs.count == request.blobs.count,
              ticket.blobs.allSatisfy({ request.blobs[$0.id] == .init(role: $0.role, bytes: $0.bytes, sha256: $0.sha256) }),
              Set(ticket.uploaded).isSubset(of: Set(request.blobs.keys)) else { throw Failure.damaged }
        var book = PreparedBookShare(directory: directory, key: ticket.key, request: request, requestBody: ticket.requestBody,
                                manifest: manifest, blobs: ticket.blobs, limits: ticket.limits)
        for blob in book.blobs {
            let size = (try? FileManager.default.attributesOfItem(atPath: book.file(blob.id).path))?[.size] as? Int
            guard size == blob.bytes else { throw Failure.damaged }
        }
        book.proof = ticket.proof
        book.created = ticket.created
        book.uploaded = Set(ticket.uploaded)
        return book
    }

    /// Deletes the staged files and the ticket, once the link is recorded or the sharer gives up.
    public func remove() throws { try FileManager.default.removeItem(at: directory) }
}

// MARK: - The sharer's book routes

extension ShareClient {
    /// The config, with `books: 1` and `book` when the service takes whole-book links.
    public func bookConfiguration() async throws -> ShareConfig { try await mixtapeConfiguration() }

    public func createBook(body: Data, proof: ShareAttestationProof? = nil) async throws -> CreateBookResponse {
        guard body.count <= PreparedBookShare.maximumRequestBytes,
              let request = try? JSONDecoder().decode(CreateBookRequest.self, from: body) else { throw Failure.unexpected(0) }
        let result: CreateBookResponse = try await bookSend("POST", "/v1/share/books", body: body, proof: proof)
        try Self.checkCreated(result, declared: Set(request.blobs.keys), base: base)
        return result
    }

    /// What a create answer must be before any authenticated upload follows it: a valid ID, a
    /// keyless `/b/<id>` link on this service's origin, an expiry, and an upload path for each
    /// declared blob and no other, every one under this book.
    static func checkCreated(_ result: CreateBookResponse, declared: Set<String>, base: URL) throws {
        guard ShareLink.isValidID(result.id), let url = URL(string: result.url), sameBookOrigin(url, base),
              url.path == "/b/\(result.id)", url.query == nil, url.fragment == nil,
              ShareDate.date(result.expiresAt) != nil, Set(result.uploads.keys) == declared,
              result.uploads.allSatisfy({ ShareBookCrypto.isCanonicalID($0.key)
                  && $0.value == "/v1/share/books/\(result.id)/blobs/\($0.key)" }) else { throw Failure.unexpected(0) }
    }

    /// PUTs one staged blob, streamed from its file. Its size and hash are checked against what
    /// was sealed before anything is sent, and it may not exceed its role's cap.
    public func uploadBookBlob(_ id: String, blob: PreparedBookShare.Blob, file: URL, limits: ShareLimits = .standard) async throws {
        let ceiling = blob.role == .audio ? limits.maxBookChapterBytes : limits.maxBookTextBytes
        guard ShareLink.isValidID(id), ShareBookCrypto.isCanonicalID(blob.id), blob.bytes <= ceiling,
              try Self.fileMatches(file, bytes: blob.bytes, sha256: blob.sha256) else { throw Failure.unexpected(0) }
        let path = "/v1/share/books/\(id)/blobs/\(blob.id)"
        let response = try await bookUpload(path, file: file)
        try Self.checkStatus(response)
    }

    public func finalizeBook(_ id: String) async throws -> BookSummary {
        guard ShareLink.isValidID(id) else { throw Failure.unexpected(0) }
        return try Self.checked(await bookSend("POST", "/v1/share/books/\(id)/finalize"), id: id)
    }

    public func book(_ id: String) async throws -> BookSummary {
        guard ShareLink.isValidID(id) else { throw Failure.unexpected(0) }
        return try Self.checked(await bookSend("GET", "/v1/share/books/\(id)"), id: id)
    }

    public func listBooks() async throws -> [BookSummary] {
        let list: BookList = try await bookSend("GET", "/v1/share/books", maximumBytes: 1_048_576)
        return list.books
    }

    public func extendBook(_ id: String, bySeconds seconds: Int) async throws -> BookSummary {
        guard ShareLink.isValidID(id) else { throw Failure.unexpected(0) }
        return try Self.checked(await bookSend("PATCH", "/v1/share/books/\(id)",
                                               body: JSONEncoder().encode(PatchShareRequest(extendBySeconds: seconds))), id: id)
    }

    /// Changes how many listeners the link admits (1 to the advertised most).
    public func setBookListeners(_ id: String, _ cap: Int) async throws -> BookSummary {
        guard ShareLink.isValidID(id) else { throw Failure.unexpected(0) }
        return try Self.checked(await bookSend("PATCH", "/v1/share/books/\(id)",
                                               body: JSONEncoder().encode(PatchShareRequest(playCap: cap))), id: id)
    }

    public func revokeBook(_ id: String) async throws {
        guard ShareLink.isValidID(id) else { throw Failure.unexpected(0) }
        _ = try await bookRaw("DELETE", "/v1/share/books/\(id)", body: nil, contentType: nil, proof: nil, maximumBytes: 4096)
    }

    /// Makes an App Attest proof for a create body under a proof request identity: the iPhone's
    /// `SongShareAppAttest`, asked only during an explicit share. Nil where the platform has none.
    public typealias BookAttestation = @Sendable (_ body: Data, _ proofRequestID: String) async throws -> ShareAttestationProof?

    /// Create, upload every blob one at a time, finalize: the whole of sending a book. Picks up
    /// where an earlier attempt on the same staged book stopped, so a retry is the same link:
    /// the create is resent with the same body (which the service answers with the same book),
    /// blobs it already acknowledged are not sent again, and a book already finalized is done.
    /// The ticket is saved after every step. `progress` runs from 0 to 1 over the bytes sent.
    ///
    /// With `attest`, the create carries a proof. The proof is kept in the ticket so a retry of a
    /// create whose answer was lost replays it (the service's replay table answers the same book).
    /// A proof's challenge lasts only minutes, so a create that never reached the service and is
    /// retried later is refused `app_attest_invalid`; then one fresh proof, under a fresh proof
    /// identity, is made for the identical body and the create is sent once more. The body's own
    /// `requestID` never changes, so the service still answers the same book if it had made one.
    public func shareBook(_ prepared: PreparedBookShare, attest: BookAttestation? = nil,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> (link: URL, summary: BookSummary) {
        var book = prepared
        if let saved = try? PreparedBookShare.load(from: prepared.directory), saved.requestBody == prepared.requestBody,
           saved.key == prepared.key { book = saved }
        let config = try await bookConfiguration()
        guard config.enabled, config.books == 1 else {
            throw Failure.service(status: 409, code: "unsupported", message: "This service does not take book links.")
        }
        let created: CreateBookResponse
        if let earlier = book.created {
            try Self.checkCreated(earlier, declared: Set(book.request.blobs.keys), base: base)
            created = earlier
        } else {
            if book.proof == nil, let attest {
                book.proof = try await attest(book.requestBody, UUID().uuidString)
                try book.save()
            }
            do {
                created = try await createBook(body: book.requestBody, proof: book.proof)
            } catch let Failure.service(_, code, _) where code == "app_attest_invalid" && book.proof != nil && attest != nil {
                book.proof = try await attest!(book.requestBody, UUID().uuidString)
                try book.save()
                created = try await createBook(body: book.requestBody, proof: book.proof)
            }
            book.created = created
            try book.save()
        }
        let state = try await self.book(created.id)
        if state.share.actionRequired != nil {
            throw Failure.service(status: 409, code: "action_required", message: "This book link is held for review.")
        }
        if state.share.status == .ready { progress?(1); return (link(for: created, key: book.key), state) }
        guard state.share.status == .pending else {
            throw Failure.service(status: 410, code: "expired", message: "This book link has ended.")
        }
        let limits = book.limits.applied()
        let total = max(1, book.totalBlobBytes)
        var sent = book.blobs.filter { book.uploaded.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        // The owner summary carries the stored status until the service's sweep, so a link past its
        // end can still read pending here; the upload or finalize then answers 409 `state` ("no
        // longer pending", "has ended"). Only declared blobs are ever sent, so that means ended.
        func ended<T>(_ step: () async throws -> T) async throws -> T {
            do { return try await step() } catch let Failure.service(_, code, _) where code == "state" {
                throw Failure.service(status: 410, code: "expired", message: "This book link has ended.")
            }
        }
        for blob in book.blobs where !book.uploaded.contains(blob.id) {
            try Task.checkCancellation()
            try await ended { try await uploadBookBlob(created.id, blob: blob, file: book.file(blob.id), limits: limits) }
            book.uploaded.insert(blob.id)
            try book.save()
            sent += blob.bytes
            progress?(0.98 * Double(sent) / Double(total))
        }
        let summary = try await ended { try await finalizeBook(created.id) }
        guard summary.share.status == .ready else { throw Failure.unexpected(0) }
        progress?(1)
        return (link(for: created, key: book.key), summary)
    }

    private func link(for created: CreateBookResponse, key: Data) -> URL {
        ShareInvitation(id: created.id, key: key, kind: .book).url(base: base)
    }

    // MARK: HTTP

    private static func checked(_ summary: BookSummary, id: String) throws -> BookSummary {
        guard summary.share.id == id else { throw Failure.unexpected(0) }
        return summary
    }

    static func sameBookOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port && lhs.user == nil && lhs.password == nil
    }

    private static func fileMatches(_ file: URL, bytes: Int, sha256: String) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var hash = ShareHash.Running(), count = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            count += chunk.count
            guard count <= bytes else { return false }
            hash.update(chunk)
        }
        return count == bytes && hash.finalizeHex() == sha256
    }

    private static let knownCodes: Set<String> = [
        "unsupported", "busy", "state", "incomplete", "invalid", "checksum", "conflict", "action_required",
        "share_disabled", "rate_limited", "app_attest_invalid", "expired", "too_large",
    ]

    private static func checkStatus(_ response: ShareReceiverResponse) throws {
        guard (200 ... 299).contains(response.status) else {
            guard response.body.count <= 4096 else { throw Failure.unexpected(0) }
            let code = (try? JSONDecoder().decode(ShareErrorBody.self, from: response.body))?.code ?? "unavailable"
            throw Failure.service(status: response.status, code: knownCodes.contains(code) ? code : "unavailable",
                                  message: "Book request unavailable.")
        }
    }

    private func bookSend<T: Decodable>(_ method: String, _ path: String, body: Data? = nil,
                                        proof: ShareAttestationProof? = nil, maximumBytes: Int = 196_608) async throws -> T {
        let data = try await bookRaw(method, path, body: body, contentType: body == nil ? nil : "application/json",
                                     proof: proof, maximumBytes: maximumBytes)
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw Failure.unexpected(0) }
        return decoded
    }

    private func bookRequest(_ method: String, _ path: String) throws -> URLRequest {
        // The recipient's vetted origin policy: the public service, or a loopback probe service.
        _ = try ShareReceiverClient(base: base)
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL, Self.sameBookOrigin(url, base),
              url.query == nil, url.fragment == nil else { throw Failure.unexpected(0) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        return request
    }

    private func bookRaw(_ method: String, _ path: String, body: Data?, contentType: String?,
                         proof: ShareAttestationProof?, maximumBytes: Int) async throws -> Data {
        var request = try bookRequest(method, path)
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let proof { request.setValue(try proof.headerValue(), forHTTPHeaderField: ShareAttestationProof.header) }
        let configuration = session.configuration
        let transport = BoundedShareReceiverTransport(makeConfiguration: { configuration })
        let response: ShareReceiverResponse
        do { response = try await transport.send(request, maximumBytes: maximumBytes, maximumErrorBytes: 4096) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.transport("Book request unavailable.") }
        try Self.checkStatus(response)
        return response.body
    }

    /// A PUT streamed from a file: no redirects, no cookies or cache, no credentials but the
    /// bearer, and an answer of at most 4 KiB. A chapter of 25 MiB gets a generous clock.
    private func bookUpload(_ path: String, file: URL) async throws -> ShareReceiverResponse {
        var request = try bookRequest("PUT", path)
        request.timeoutInterval = 900
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let configuration = session.configuration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        let upload = BookBlobUpload(configuration: configuration)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await upload.send(request, file: file)
            } onCancel: { upload.cancel() }
        } catch is CancellationError { throw CancellationError() }
        catch { throw Failure.transport("Book upload unavailable.") }
    }
}

private final class BookBlobUpload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumResponseBytes = 4096
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShareReceiverResponse, Error>?
    private var task: URLSessionTask?
    private var bytes = Data()
    private var status = 0
    private var failure: Error?
    private var cancelled = false

    init(configuration: URLSessionConfiguration) { self.configuration = configuration }

    func send(_ request: URLRequest, file: URL) async throws -> ShareReceiverResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.uploadTask(with: request, fromFile: file)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust" {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > Self.maximumResponseBytes { failure = ShareReceiverClient.Failure.tooLarge }
        let allowed = failure == nil && status != 0
        lock.unlock()
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if data.count > Self.maximumResponseBytes - bytes.count {
            failure = ShareReceiverClient.Failure.tooLarge
            lock.unlock(); dataTask.cancel(); return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure: Error? = self.failure ?? (cancelled ? CancellationError() : error)
        let response = ShareReceiverResponse(status: status, body: bytes)
        self.task = nil; bytes = Data()
        lock.unlock()
        session.invalidateAndCancel()
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume(returning: response) }
    }
}
