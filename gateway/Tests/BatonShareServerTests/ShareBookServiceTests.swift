@testable import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
@testable import BatonShareServer
import Foundation
import XCTest

/// Whole-book links (`/b/`), specs/book-sharing.md "Phase 2: whole-book links", service routes.
final class ShareBookServiceTests: XCTestCase {
    var root: URL!
    var service: ShareService!
    let clock = TestClock()
    let owner = Base64URL.encode(Data(repeating: 41, count: 32))
    let other = Base64URL.encode(Data(repeating: 42, count: 32))
    let operatorToken = String(repeating: "B", count: 40)
    let address = "203.0.113.91"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("book-" + UUID().uuidString)
        service = try reopen()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("blobs").path)
        service = nil
        try? FileManager.default.removeItem(at: root)
    }

    func reopen(books: Bool = true, mixtapes: Bool = true, enabled: Bool = true, change: (inout ShareConfiguration) -> Void = { _ in }) throws -> ShareService {
        var config = ShareConfiguration(dataDirectory: root, enabled: enabled, blobDelivery: .direct)
        config.booksEnabled = books
        config.mixtapesEnabled = mixtapes
        config.enforcement = try .init(token: operatorToken, retentionSeconds: 90 * 86400, auditRetentionSeconds: 90 * 86400, reasonCodes: ["review"])
        change(&config)
        return try ShareService(config: config, clock: { [clock] in clock.now })
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: Data = Data(), token: String? = nil, range: String? = nil,
              agent: String = "Synthetic browser", peer: ConnectionPeer = .unknown) -> ShareResponse {
        var headers = ["user-agent": agent]
        if peer != .loopback { headers["x-real-ip"] = address }
        if let token { headers["authorization"] = "Bearer " + token }
        if let range { headers["range"] = range }
        return service.handle(.init(method: method, path: path, query: [:], headers: headers, body: body), peer: peer)
    }
    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    func decode<T: Decodable>(_ type: T.Type, _ response: ShareResponse, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        XCTAssertLessThan(response.status, 300, String(decoding: response.body, as: UTF8.self), file: file, line: line)
        return try JSONDecoder().decode(type, from: response.body)
    }
    func code(_ response: ShareResponse) -> String? {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["code"] as? String
    }

    // MARK: - Fixtures

    struct Book {
        let key: Data
        let manifest: ShareBookManifest
        let blobs: [String: Data]
        var body: CreateBookRequest
        var chapterIDs: [String] { manifest.chapters.map(\.id) }
        var textIDs: [String] { manifest.chapters.compactMap { $0.text?.id } }
    }

    /// A real book: every chapter and text sealed under its own key, the manifest sealed and valid.
    func book(chapters: Int = 2, text: Bool = true, listeners: Int = 2, size: Int = 200, preview: BookPreview? = nil, consent: Bool = false) throws -> Book {
        let key = ShareCrypto.newKey()
        var list = [ShareBookManifest.Chapter](), blobs = [String: Data]()
        for index in 0 ..< chapters {
            let id = ShareBookCrypto.newID()
            let audio = try ShareCrypto.seal(Data(repeating: UInt8(index % 250), count: size), key: ShareBookCrypto.chapterKey(rootKey: key, chapterID: id), purpose: .audio)
            blobs[id] = audio
            var chapter = ShareBookManifest.Chapter(id: id, title: "Chapter \(index + 1)", durationSeconds: 60, audioBytes: audio.count, audioSHA256: ShareHash.sha256Hex(audio))
            if text && index == 0 {
                let textID = ShareBookCrypto.newID()
                let plain = try ShareBookText(segments: [.init(text: "It begins.", paragraph: 0, start: 0, end: 1.5)]).encoded()
                let sealed = try ShareCrypto.seal(plain, key: ShareBookCrypto.textKey(rootKey: key, chapterID: id), purpose: .meta)
                blobs[textID] = sealed
                chapter.text = .init(id: textID, bytes: sealed.count, sha256: ShareHash.sha256Hex(sealed))
            }
            list.append(chapter)
        }
        let manifest = ShareBookManifest(title: "Synthetic book", author: "Synthetic author", chapters: list)
        let sealed = try manifest.seal(rootKey: key)
        let body = CreateBookRequest(encryptedManifest: sealed.base64EncodedString(), blobs: manifest.blobs, totalDurationSeconds: manifest.durationSeconds,
            expiresInSeconds: 86400, listenerCap: listeners, preview: preview, client: .init(platform: "macos", appVersion: "synthetic"),
            reviewPreservationConsent: consent ? "review-v1" : nil)
        return .init(key: key, manifest: manifest, blobs: blobs, body: body)
    }

    /// Descriptors only, for create-time limits: the service never opens the manifest.
    func declared(audio: [Int], texts: [Int] = [], listeners: Int = 10) throws -> CreateBookRequest {
        let key = ShareCrypto.newKey()
        let manifest = try ShareCrypto.seal(Data("{}".utf8), key: ShareBookCrypto.manifestKey(rootKey: key), purpose: .meta)
        var blobs = [String: BookBlobDescriptor]()
        for bytes in audio { blobs[ShareBookCrypto.newID()] = .init(role: .audio, bytes: bytes, sha256: String(repeating: "a", count: 64)) }
        for bytes in texts { blobs[ShareBookCrypto.newID()] = .init(role: .text, bytes: bytes, sha256: String(repeating: "b", count: 64)) }
        return CreateBookRequest(encryptedManifest: manifest.base64EncodedString(), blobs: blobs, totalDurationSeconds: 60, expiresInSeconds: 86400,
                                 listenerCap: listeners, preview: nil, client: .init(platform: "macos", appVersion: "synthetic"))
    }

    func create(_ book: Book, token: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> CreateBookResponse {
        let response = send("POST", "/v1/share/books", body: try encode(book.body), token: token ?? owner)
        XCTAssertEqual(response.status, 201, String(decoding: response.body, as: UTF8.self), file: file, line: line)
        return try JSONDecoder().decode(CreateBookResponse.self, from: response.body)
    }
    func upload(_ path: String, bytes: Data, length: Int? = nil, token: String? = nil) throws -> ShareResponse {
        let file = root.appendingPathComponent("synthetic-upload-" + UUID().uuidString)
        try bytes.write(to: file)
        return service.handleUpload(.init(method: "PUT", path: path, headers: ["authorization": "Bearer " + (token ?? owner)], contentLength: length ?? bytes.count), file: file)
    }
    func ready(_ book: Book) throws -> CreateBookResponse {
        let created = try create(book)
        for (id, bytes) in book.blobs { XCTAssertEqual(try upload(created.uploads[id]!, bytes: bytes).status, 200) }
        XCTAssertEqual(send("POST", "/v1/share/books/\(created.id)/finalize", token: owner).status, 200)
        return created
    }
    func session(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> BookSession {
        let response = send("POST", "/v1/share/b/\(id)/sessions")
        XCTAssertEqual(response.status, 201, file: file, line: line)
        return try JSONDecoder().decode(BookSession.self, from: response.body)
    }
    func blobPath(_ id: String, _ blob: String) -> String { "/v1/share/b/\(id)/blobs/\(blob)" }
    func ownerSummary(_ id: String) throws -> BookSummary { try decode(BookSummary.self, send("GET", "/v1/share/books/\(id)", token: owner)) }
    func storedBytes(_ id: String) throws -> Int64 { try service.store.database.scalar("SELECT stored_bytes FROM shares WHERE id=?", [.text(id)]) }

    // MARK: - Configuration

    func testBooksFlagParsesStrictlyAndDefaultsOff() throws {
        XCTAssertFalse(try ShareConfiguration.fromEnvironment([:]).booksEnabled)
        for on in ["1", "true", "TRUE"] { XCTAssertTrue(try ShareConfiguration.fromEnvironment(["BATON_SHARE_BOOKS": on]).booksEnabled, on) }
        for off in ["0", "false", ""] { XCTAssertFalse(try ShareConfiguration.fromEnvironment(["BATON_SHARE_BOOKS": off]).booksEnabled, off) }
        XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(["BATON_SHARE_BOOKS": "yes"]))
        // Independent of mixtapes in both directions.
        let mixtapesOnly = try ShareConfiguration.fromEnvironment(["BATON_SHARE_MIXTAPES": "1"])
        XCTAssertTrue(mixtapesOnly.mixtapesEnabled); XCTAssertFalse(mixtapesOnly.booksEnabled)
    }

    func testConfigAdvertisesBooksOnlyWhenSharingAndBooksAreOn() throws {
        let on = try decode(ShareConfig.self, send("GET", "/v1/share/config"))
        XCTAssertEqual(on.books, 1)
        XCTAssertEqual(on.book, ShareBookLimits(limits: .standard))
        XCTAssertEqual(on.book?.maxBookBytes, 268_435_456); XCTAssertEqual(on.book?.maxChapters, 200)
        XCTAssertEqual(on.book?.maxListeners, 50); XCTAssertEqual(on.book?.defaultListeners, 10); XCTAssertEqual(on.book?.liveBooksPerSharer, 3)
        for (books, enabled) in [(false, true), (true, false)] {
            service = try reopen(books: books, enabled: enabled)
            let response = send("GET", "/v1/share/config")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            XCTAssertNil(object["books"]); XCTAssertNil(object["book"])
        }
    }

    func testCapabilityOffRefusesNewWorkButKeepsOwnerReadbackAndRevoke() throws {
        let fixture = try book(), created = try ready(fixture)
        service = try reopen(books: false)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try book().body), token: owner).status, 409)
        XCTAssertEqual(code(send("POST", "/v1/share/books", body: Data("{}".utf8), token: owner)), "unsupported")
        XCTAssertEqual(send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(playCap: 3)), token: owner).status, 409)
        XCTAssertEqual(send("POST", "/v1/share/books/\(created.id)/finalize", token: owner).status, 409)
        XCTAssertEqual(try upload(created.uploads[fixture.chapterIDs[0]]!, bytes: fixture.blobs[fixture.chapterIDs[0]]!).status, 409)
        XCTAssertEqual(send("GET", "/v1/share/b/\(created.id)").status, 409)
        XCTAssertEqual(send("POST", "/v1/share/b/\(created.id)/sessions").status, 409)
        XCTAssertEqual(send("GET", "/b/\(created.id)").status, 409)
        XCTAssertEqual(try ownerSummary(created.id).share.status, .ready)
        XCTAssertEqual(try decode(BookList.self, send("GET", "/v1/share/books", token: owner)).books.count, 1)
        XCTAssertEqual(send("GET", "/v1/share/books/\(created.id)", token: other).status, 404)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: owner).status, 204)
        service = try reopen()
        XCTAssertEqual(try ownerSummary(created.id).share.status, .revoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/\(created.id)").path))
    }

    // MARK: - Create

    func testCreateRetryIsIdempotentAndAnAlteredBodyConflicts() throws {
        let fixture = try book()
        let created = try create(fixture)
        XCTAssertTrue(created.url.hasSuffix("/b/\(created.id)"))
        XCTAssertFalse(created.url.contains("#"))
        XCTAssertEqual(Set(created.uploads.keys), Set(fixture.blobs.keys))
        for (blob, path) in created.uploads { XCTAssertEqual(path, "/v1/share/books/\(created.id)/blobs/\(blob)") }
        XCTAssertEqual(try create(fixture), created)
        service = try reopen()
        XCTAssertEqual(try create(fixture), created, "the retry identity is durable")
        var altered = fixture; altered.body.listenerCap = 3
        let conflict = send("POST", "/v1/share/books", body: try encode(altered.body), token: owner)
        XCTAssertEqual(conflict.status, 409); XCTAssertEqual(code(conflict), "conflict")
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares WHERE is_book=1"), 1)
        // Another installation reusing the request ID makes its own book.
        XCTAssertNotEqual(try create(fixture, token: other).id, created.id)
        // An ended book's retry identity is a conflict, not a resurrection.
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: owner).status, 204)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(fixture.body), token: owner).status, 409)
    }

    func testChapterCountAndByteBoundsIncludingTheManifest() throws {
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try book(chapters: 1, text: false).body), token: owner).status, 201)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try book(chapters: 200, text: true).body), token: other).status, 201)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: Array(repeating: 100, count: 201))), token: owner).status, 400)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: [])), token: owner).status, 400)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: [26_214_401])), token: owner).status, 400)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: [100], texts: [1_048_577])), token: owner).status, 400)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: [100], texts: [100, 100])), token: owner).status, 400, "at most one text per chapter")
        let manifestBytes = try declared(audio: [100]).manifestBytes
        let full = Array(repeating: 26_214_400, count: 10)
        let remainder = 268_435_456 - full.reduce(0, +) - manifestBytes
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: full + [remainder + 1])), token: owner).status, 400, "one byte over 256 MiB with the manifest")
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: Array(repeating: 26_214_400, count: 11))), token: owner).status, 400)
        // The edges themselves are accepted: a full 25 MiB chapter, a full 1 MiB text, exactly 256 MiB.
        service = try reopen()
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: [26_214_400], texts: [1_048_576])), token: owner).status, 201)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: full + [remainder])), token: owner).status, 201)
        // Listener cap 1 to 50, expiry from the song choices.
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try declared(audio: [100], listeners: 51)), token: other).status, 400)
        var odd = try declared(audio: [100]); odd.expiresInSeconds = 3600
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(odd), token: other).status, 400)
        // The body ceiling and duplicate keys are refused before decoding.
        XCTAssertEqual(send("POST", "/v1/share/books", body: Data(repeating: 32, count: ShareService.maxBookCreateBodyBytes + 1), token: owner).status, 400)
        let body = try encode(try declared(audio: [100]))
        let duplicated = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "{\"blobs\":", with: "{\"listenerCap\":2,\"blobs\":")
        XCTAssertEqual(send("POST", "/v1/share/books", body: Data(duplicated.utf8), token: owner).status, 400)
    }

    func testFourthLiveBookIsRateLimitedWithItsOwnScope() throws {
        var ids = [String]()
        for _ in 0 ..< 3 { ids.append(try create(try book()).id) }
        let refused = send("POST", "/v1/share/books", body: try encode(try book().body), token: owner)
        XCTAssertEqual(refused.status, 429); XCTAssertEqual(code(refused), "rate_limited")
        let scopes = try service.store.database.query("SELECT props FROM events WHERE type='rate_limited'").compactMap { $0["props"]?.text }
        XCTAssertEqual(scopes, ["{\"scope\":\"sharer_live_books\"}"])
        XCTAssertEqual(try create(try book(), token: other).id.count, 22, "the cap is per sharer")
        // A song or mixtape does not count against it; ending a book frees a place.
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(ids[0])", token: owner).status, 204)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try book().body), token: owner).status, 201)
    }

    func testBookSliceAndWholeQuotaAreReservedAtCreate() throws {
        let first = try book(), second = try book()
        let firstBytes = Int64(first.body.totalBytes)
        service = try reopen { $0.limits.bookQuotaBytes = firstBytes + 10 }
        let created = try create(first)
        let busy = send("POST", "/v1/share/books", body: try encode(second.body), token: other)
        XCTAssertEqual(busy.status, 503); XCTAssertEqual(code(busy), "busy")
        // Uploading does not charge twice: the reservation already holds the bytes.
        for (id, bytes) in first.blobs { XCTAssertEqual(try upload(created.uploads[id]!, bytes: bytes).status, 200) }
        XCTAssertEqual(try service.store.bookQuotaBytes(), firstBytes)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(second.body), token: other).status, 503)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: owner).status, 204)
        XCTAssertEqual(try create(second, token: other).id.count, 22)

        // The whole quota binds too, shared atomically with songs.
        let third = try book()
        service = try reopen { $0.limits.quotaBytes = Int64(second.body.totalBytes + third.body.totalBytes - 1) }
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(third.body), token: owner).status, 503)
        let song = third.blobs[third.chapterIDs[0]]!
        let single = CreateShareRequest(expiresInSeconds: 86400, playCap: 1, preview: .init(title: "Single", durationSeconds: 10), encryptedMeta: nil, durationBucket: nil,
                                        audioBytes: song.count, audioSHA256: ShareHash.sha256Hex(song), client: .init(platform: "macos", appVersion: "test"))
        XCTAssertEqual(send("POST", "/v1/share/shares", body: try encode(single), token: owner).status, 201, "smaller than the book, so it fits")
    }

    // MARK: - Upload and finalize

    func testUploadChecksLengthFramingAndChecksumAndChargesOnce() throws {
        let fixture = try book(), created = try create(fixture)
        let chapter = fixture.chapterIDs[0], bytes = fixture.blobs[chapter]!, path = created.uploads[chapter]!
        XCTAssertEqual(try upload(path, bytes: bytes + Data([0])).status, 400, "wrong length")
        XCTAssertEqual(try upload(path, bytes: bytes, length: bytes.count + 1).status, 400, "declared length mismatch")
        XCTAssertEqual(try upload(path, bytes: Data(repeating: 7, count: bytes.count)).status, 400, "not a BSH1 stream")
        let impostor = try ShareCrypto.seal(Data(repeating: 99, count: 200), key: ShareBookCrypto.chapterKey(rootKey: fixture.key, chapterID: chapter), purpose: .audio)
        XCTAssertEqual(impostor.count, bytes.count)
        XCTAssertEqual(try upload(path, bytes: impostor).status, 422)
        XCTAssertEqual(try upload(path, bytes: bytes, token: other).status, 404)
        let before = try storedBytes(created.id)
        XCTAssertEqual(try upload(path, bytes: bytes).status, 200)
        XCTAssertEqual(try storedBytes(created.id), before + Int64(bytes.count))
        XCTAssertEqual(try upload(path, bytes: bytes).status, 200, "a repeat answers 200")
        XCTAssertEqual(try storedBytes(created.id), before + Int64(bytes.count), "without a second charge")
        XCTAssertEqual(try upload("/v1/share/books/\(created.id)/blobs/\(ShareBookCrypto.newID())", bytes: bytes).status, 409, "undeclared blob")
        XCTAssertTrue(ShareService.streamsBody(.init(method: "PUT", path: path, headers: [:], contentLength: 1)))
        XCTAssertFalse(ShareService.streamsBody(.init(method: "PUT", path: "/v1/share/books/\(created.id)/blobs/not-canonical", headers: [:], contentLength: 1)))
    }

    func testPartialFinalizeStaysPendingAndCompleteFinalizePublishes() throws {
        let fixture = try book(chapters: 3), created = try create(fixture)
        for id in fixture.chapterIDs { XCTAssertEqual(try upload(created.uploads[id]!, bytes: fixture.blobs[id]!).status, 200) }
        let partial = send("POST", "/v1/share/books/\(created.id)/finalize", token: owner)
        XCTAssertEqual(partial.status, 409); XCTAssertEqual(code(partial), "incomplete", "the text is still missing")
        let pending = try decode(PublicBook.self, send("GET", "/v1/share/b/\(created.id)"))
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(send("POST", "/v1/share/b/\(created.id)/sessions").status, 410, "a pending book admits nobody")
        XCTAssertEqual(try upload(created.uploads[fixture.textIDs[0]]!, bytes: fixture.blobs[fixture.textIDs[0]]!).status, 200)
        // A stored blob altered on disk after upload fails the re-verification at finalize.
        let file = service.store.mixtapeTrackURL(id: created.id, track: fixture.chapterIDs[1])
        let original = try Data(contentsOf: file)
        var tampered = original; tampered[tampered.count - 1] ^= 1
        try tampered.write(to: file)
        XCTAssertEqual(send("POST", "/v1/share/books/\(created.id)/finalize", token: owner).status, 409)
        try original.write(to: file)
        let summary = try decode(BookSummary.self, send("POST", "/v1/share/books/\(created.id)/finalize", token: owner))
        XCTAssertEqual(summary.share.status, .ready); XCTAssertEqual(summary.chapterCount, 3); XCTAssertTrue(summary.hasText)
        XCTAssertEqual(send("POST", "/v1/share/books/\(created.id)/finalize", token: owner).status, 200, "finalize repeats")
        XCTAssertEqual(try upload(created.uploads[fixture.chapterIDs[0]]!, bytes: fixture.blobs[fixture.chapterIDs[0]]!).status, 409, "no uploads once ready")
        let details = try decode(PublicBook.self, send("GET", "/v1/share/b/\(created.id)"))
        XCTAssertEqual(details.status, .ready)
        let opened = try details.open(rootKey: fixture.key)
        XCTAssertEqual(opened.chapters.map(\.id), fixture.chapterIDs, "chapter order comes from the authenticated manifest")
    }

    // MARK: - Listening

    func testPublicDetailsSpendNothingAndAdmissionCountsOneListener() throws {
        let fixture = try book(listeners: 2), created = try ready(fixture)
        for _ in 0 ..< 3 { XCTAssertEqual(try decode(PublicBook.self, send("GET", "/v1/share/b/\(created.id)")).remainingListeners, 2) }
        XCTAssertNil(try decode(PublicBook.self, send("GET", "/v1/share/b/\(created.id)")).preview, "private mode")
        XCTAssertEqual(try ownerSummary(created.id).share.stats.fetches, 0)
        let first = try session(created.id)
        XCTAssertEqual(first.remainingListeners, 1)
        XCTAssertEqual(first.remainingBytes, ShareLimits.bookSessionAllowance(bookBytes: fixture.body.blobBytes))
        XCTAssertEqual(first.expiresAt, try decode(PublicBook.self, send("GET", "/v1/share/b/\(created.id)")).expiresAt, "the session lasts as long as the link")
        XCTAssertEqual(first.token.count, 43)
        XCTAssertFalse(first.description.contains(first.token))
        _ = try session(created.id)
        let capped = send("POST", "/v1/share/b/\(created.id)/sessions")
        XCTAssertEqual(capped.status, 410); XCTAssertEqual(code(capped), "play_cap")
        XCTAssertEqual(try ownerSummary(created.id).share.stats.fetches, 2)
        XCTAssertEqual(try ownerSummary(created.id).share.playCap, 2)
        // The last admitted listener keeps listening.
        XCTAssertEqual(send("GET", blobPath(created.id, fixture.chapterIDs[1]), token: first.token).status, 200)
        // A session outlives 30 minutes, unlike a mixtape's.
        clock.advance(3600)
        XCTAssertEqual(send("GET", blobPath(created.id, fixture.chapterIDs[0]), token: first.token).status, 200)
        let digests = try service.store.database.query("SELECT digest FROM mixtape_sessions").compactMap { $0["digest"]?.text }
        XCTAssertFalse(digests.contains(first.token), "only a digest of the token is kept")
    }

    func testBlobReadsNeedTheTokenHonorRangesAndStopAtTheAllowance() throws {
        let fixture = try book(chapters: 1, text: true, listeners: 3), created = try ready(fixture)
        let chapter = fixture.chapterIDs[0], text = fixture.textIDs[0]
        let bytes = fixture.blobs[chapter]!, path = blobPath(created.id, chapter)
        XCTAssertEqual(send("GET", path).status, 401)
        XCTAssertEqual(send("GET", path, token: Base64URL.encode(Data(repeating: 1, count: 32))).status, 401)
        let admitted = try session(created.id)
        XCTAssertEqual(send("GET", blobPath(created.id, ShareBookCrypto.newID()), token: admitted.token).status, 404)
        for range in ["bytes=0-1,4-5", "bytes=999999-", "bytes=5-2", "bytes=-0", "items=0-1"] {
            let refused = send("GET", path, token: admitted.token, range: range)
            XCTAssertEqual(refused.status, 416, range); XCTAssertEqual(refused.headers["Content-Range"], "bytes */\(bytes.count)")
        }
        let head = send("HEAD", path, token: admitted.token)
        XCTAssertEqual(head.status, 200); XCTAssertTrue(head.body.isEmpty); XCTAssertEqual(head.headers["Content-Length"], String(bytes.count))
        let part = send("GET", path, token: admitted.token, range: "bytes=0-9")
        XCTAssertEqual(part.status, 206); XCTAssertEqual(part.body, bytes.prefix(10))
        XCTAssertEqual(part.headers["Content-Range"], "bytes 0-9/\(bytes.count)"); XCTAssertEqual(part.headers["Content-Length"], "10")
        XCTAssertEqual(part.headers["Cache-Control"], "private, no-store")
        let rest = send("GET", path, token: admitted.token, range: "bytes=10-")
        XCTAssertEqual(rest.status, 206); XCTAssertEqual(rest.body, bytes.dropFirst(10))
        let sealedText = send("GET", blobPath(created.id, text), token: admitted.token)
        XCTAssertEqual(sealedText.status, 200)
        XCTAssertEqual(try fixture.manifest.openText(sealedText.body, chapterID: chapter, rootKey: fixture.key).segments.first?.text, "It begins.")
        XCTAssertEqual(try fixture.manifest.openAudio(bytes, chapterID: chapter, rootKey: fixture.key), Data(repeating: 0, count: 200))
        // The allowance is 1.5 times the book's blobs: one listen plus half again, then no more.
        let allowance = ShareLimits.bookSessionAllowance(bookBytes: fixture.body.blobBytes)
        var left = allowance - bytes.count - fixture.blobs[text]!.count
        service = try reopen()
        while left >= bytes.count {
            XCTAssertEqual(send("GET", path, token: admitted.token).status, 200); left -= bytes.count
        }
        if left > 0 { XCTAssertEqual(send("GET", path, token: admitted.token, range: "bytes=0-\(left - 1)").status, 206) }
        let spent = send("GET", path, token: admitted.token, range: "bytes=0-0")
        XCTAssertEqual(spent.status, 409); XCTAssertEqual(code(spent), "transfer_budget")
        XCTAssertEqual(send("HEAD", path, token: admitted.token).status, 200, "HEAD spends nothing")
        XCTAssertEqual(try ownerSummary(created.id).share.stats.fetches, 1, "exhaustion never admits a second listener")
    }

    func testExtendingTheLinkExtendsItsSessionsAndPatchBoundsListeners() throws {
        let fixture = try book(listeners: 3), created = try ready(fixture)
        clock.advance(86400 - 10)
        let admitted = try session(created.id)
        let patched = try decode(BookSummary.self, send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(extendBySeconds: 86400)), token: owner))
        XCTAssertEqual(patched.share.status, .ready)
        clock.advance(60); service = try reopen()
        XCTAssertEqual(send("GET", blobPath(created.id, fixture.chapterIDs[0]), token: admitted.token).status, 200, "the issued session follows the link")
        XCTAssertEqual(send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(playCap: 51)), token: owner).status, 400)
        XCTAssertEqual(send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(playCap: 0)), token: owner).status, 400)
        XCTAssertEqual(try decode(BookSummary.self, send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(playCap: 50)), token: owner)).share.playCap, 50)
        XCTAssertEqual(send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(playCap: 1)), token: owner).status, 200)
        XCTAssertEqual(send("GET", blobPath(created.id, fixture.chapterIDs[0]), token: admitted.token).status, 200, "ordinal 1 is within a cap of 1")
        XCTAssertEqual(send("POST", "/v1/share/b/\(created.id)/sessions").status, 410)
        clock.advance(86400 + 60)
        XCTAssertEqual(send("GET", blobPath(created.id, fixture.chapterIDs[0]), token: admitted.token).status, 410, "but not past the extended link")
    }

    func testRevokedReadsAsExpiredOnEveryListenerSurface() throws {
        let fixture = try book(listeners: 5), created = try ready(fixture), admitted = try session(created.id)
        XCTAssertEqual(send("POST", "/v1/share/b/\(created.id)/events", body: Data("{\"type\":\"play_started\",\"ms\":800}".utf8), token: admitted.token).status, 204)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: other).status, 404)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: owner).status, 204)
        XCTAssertEqual(try ownerSummary(created.id).share.status, .revoked, "only the sharer sees revoked")
        XCTAssertEqual(try decode(BookList.self, send("GET", "/v1/share/books", token: owner)).books.first?.share.status, .revoked)
        let surfaces: [ShareResponse] = [
            send("GET", "/v1/share/b/\(created.id)"),
            send("POST", "/v1/share/b/\(created.id)/sessions"),
            send("GET", blobPath(created.id, fixture.chapterIDs[0]), token: admitted.token),
            send("HEAD", blobPath(created.id, fixture.chapterIDs[0]), token: admitted.token),
            send("POST", "/v1/share/b/\(created.id)/events", body: Data("{\"type\":\"play_30s\"}".utf8), token: admitted.token),
            send("POST", "/v1/share/b/\(created.id)/reactions", body: Data("{\"emoji\":\"❤️\"}".utf8), token: admitted.token),
        ]
        for response in surfaces {
            XCTAssertEqual(response.status, 410); XCTAssertEqual(code(response), "expired")
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("revoked"))
        }
        let page = send("GET", "/b/\(created.id)")
        XCTAssertEqual(page.status, 410)
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains("\"state\":\"expired\"")); XCTAssertFalse(html.contains("revoked"))
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM mixtape_sessions WHERE share_id=?", [.text(created.id)]), 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM mixtape_tracks WHERE share_id=?", [.text(created.id)]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/\(created.id)").path))
        XCTAssertEqual(try service.store.bookQuotaBytes(), 0)
        XCTAssertEqual(try service.store.quotaBytes(), 0)
    }

    func testExpiryEndsTheLinkItsSessionsAndItsBlobs() throws {
        let fixture = try book(), created = try ready(fixture), admitted = try session(created.id)
        let pending = try create(try book())
        clock.advance(86400)
        XCTAssertEqual(code(send("GET", blobPath(created.id, fixture.chapterIDs[0]), token: admitted.token)), "expired")
        XCTAssertEqual(code(send("GET", "/v1/share/b/\(created.id)")), "expired")
        XCTAssertEqual(try ownerSummary(created.id).share.status, .expired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/\(created.id)").path))
        XCTAssertEqual(send("GET", "/b/\(created.id)").status, 410)
        XCTAssertEqual(code(send("GET", "/v1/share/b/\(pending.id)")), "expired")
        try service.sweep()
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM mixtape_sessions"), 0)
        XCTAssertEqual(try service.store.bookQuotaBytes(), 0)
        XCTAssertEqual(send("GET", "/v1/share/b/\(ShareBookCrypto.newID())").status, 404, "an unknown link is 404")
    }

    func testAPendingBookOutlivesTheOrdinaryPendingWindowButNotItsOwn() throws {
        XCTAssertEqual(ShareLimits.standard.pendingBookLifetimeSeconds, 21_600)
        XCTAssertGreaterThan(ShareLimits.standard.pendingBookLifetimeSeconds, ShareLimits.standard.pendingLifetimeSeconds)
        let fixture = try book(), created = try create(fixture)
        let song = fixture.blobs[fixture.chapterIDs[0]]!
        let single = CreateShareRequest(expiresInSeconds: 86400, playCap: 1, preview: .init(title: "Single", durationSeconds: 10), encryptedMeta: nil, durationBucket: nil,
                                        audioBytes: song.count, audioSHA256: ShareHash.sha256Hex(song), client: .init(platform: "macos", appVersion: "test"))
        let pendingSong = try JSONDecoder().decode(CreateShareResponse.self, from: send("POST", "/v1/share/shares", body: try encode(single), token: other).body)
        let key = ShareCrypto.newKey()
        let tracks = try (1 ... 2).map { index -> ShareMixtapeManifest.Track in
            let trackID = ShareBookCrypto.newID()
            let audio = try ShareCrypto.seal(Data(repeating: UInt8(index), count: 50), key: ShareMixtapeCrypto.trackKey(rootKey: key, trackID: trackID), purpose: .audio)
            return .init(id: trackID, metadata: .init(title: "Track \(index)", durationSeconds: 10), audioBytes: audio.count, audioSHA256: ShareHash.sha256Hex(audio))
        }
        let mixtape = CreateMixtapeRequest(encryptedManifest: try ShareMixtapeManifest(title: "Mixtape", tracks: tracks).seal(rootKey: key).base64EncodedString(),
            tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, .init(audioBytes: $0.audioBytes, audioSHA256: $0.audioSHA256)) }),
            totalDurationSeconds: 20, expiresInSeconds: 86400, playCap: 2, preview: nil, client: .init(platform: "macos", appVersion: "synthetic"))
        let pendingMixtape = try JSONDecoder().decode(CreateMixtapeResponse.self, from: send("POST", "/v1/share/mixtapes", body: try encode(mixtape), token: other).body)

        // Past the ordinary hour: the song and the mixtape are swept, the book is not.
        clock.advance(TimeInterval(ShareLimits.standard.pendingLifetimeSeconds + 60))
        XCTAssertEqual(try service.sweep().abandoned, 2)
        XCTAssertNil(try service.store.share(id: pendingSong.id))
        XCTAssertEqual(try service.store.share(id: pendingMixtape.id)?.status, .expired)
        XCTAssertEqual(try ownerSummary(created.id).share.status, .pending)
        XCTAssertEqual(try decode(PublicBook.self, send("GET", "/v1/share/b/\(created.id)")).status, .pending)
        // The upload and finalize still work inside the book's own window.
        for (id, bytes) in fixture.blobs where id != fixture.textIDs[0] { XCTAssertEqual(try upload(created.uploads[id]!, bytes: bytes).status, 200) }
        let late = try create(try book())
        clock.advance(TimeInterval(ShareLimits.standard.pendingBookLifetimeSeconds - ShareLimits.standard.pendingLifetimeSeconds - 120))
        try service.sweep()
        XCTAssertEqual(try ownerSummary(created.id).share.status, .pending, "still inside six hours")
        // Past the book window it goes like any abandoned upload, its bytes and reservation with it.
        clock.advance(120)
        XCTAssertEqual(try service.sweep().abandoned, 1)
        XCTAssertEqual(try ownerSummary(created.id).share.status, .expired)
        XCTAssertEqual(code(send("GET", "/v1/share/b/\(created.id)")), "expired")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/\(created.id)").path))
        XCTAssertEqual(try ownerSummary(late.id).share.status, .pending, "a younger book keeps its window")
        XCTAssertEqual(try service.store.bookQuotaBytes(), Int64(try book().body.totalBytes), "only the younger book stays reserved")
    }

    func testEnforcementHoldFencesSessionsAndRestorationIssuesNewOnes() throws {
        let fixture = try book(listeners: 3, consent: true), created = try ready(fixture), admitted = try session(created.id)
        let start = Int64(clock.now.timeIntervalSince1970)
        func apply(_ action: String, dates: Bool = false) throws {
            var request: [String: Any] = ["operationID": UUID().uuidString, "action": action, "shareID": created.id, "caseReference": "case_book", "reasonCode": "review"]
            if dates { request["reviewUntil"] = start + 20 * 86400; request["preservationDeadline"] = start + 22 * 86400 }
            let plan = send("POST", "/v1/share/admin/enforcement/plan", body: try JSONSerialization.data(withJSONObject: request), token: operatorToken, peer: .loopback)
            XCTAssertEqual(plan.status, 200, String(decoding: plan.body, as: UTF8.self))
            XCTAssertEqual(send("POST", "/v1/share/admin/enforcement/apply", body: plan.body, token: operatorToken, peer: .loopback).status, 200)
        }
        let path = blobPath(created.id, fixture.chapterIDs[0])
        try apply("disable-share", dates: true)
        XCTAssertEqual(code(send("GET", "/v1/share/b/\(created.id)")), "expired")
        XCTAssertEqual(code(send("GET", path, token: admitted.token)), "expired")
        XCTAssertEqual(send("GET", "/b/\(created.id)").status, 410)
        let held = try ownerSummary(created.id)
        XCTAssertNotNil(held.reviewDeadline); XCTAssertNotNil(held.share.actionRequired); XCTAssertNil(held.share.preview)
        XCTAssertEqual(send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(playCap: 5)), token: owner).status, 403)
        try apply("restore-share")
        XCTAssertEqual(send("GET", path, token: admitted.token).status, 401, "the fence outlives the hold")
        let fresh = try session(created.id)
        XCTAssertEqual(send("GET", path, token: fresh.token).status, 200)
        try apply("suspend-sharer", dates: true)
        XCTAssertEqual(send("HEAD", path, token: fresh.token).status, 410)
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(try book().body), token: owner).status, 403)
        try apply("unsuspend-sharer")
        XCTAssertEqual(send("GET", path, token: fresh.token).status, 410, "still held until restored")
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: owner).status, 204, "a held book stays revocable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/\(created.id)").path))
    }

    // MARK: - Route separation

    func testMixtapeAndSongRoutesRefuseABookAndBookRoutesRefuseAMixtape() throws {
        let fixture = try book(), created = try ready(fixture), id = created.id, blob = fixture.chapterIDs[0]
        // Mixtape routes.
        XCTAssertEqual(send("GET", "/v1/share/mixtapes/\(id)", token: owner).status, 404)
        XCTAssertEqual(send("PATCH", "/v1/share/mixtapes/\(id)", body: try encode(PatchShareRequest(playCap: 9)), token: owner).status, 404)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes/\(id)/finalize", token: owner).status, 404)
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(id)", token: owner).status, 404)
        XCTAssertEqual(try decode(MixtapeList.self, send("GET", "/v1/share/mixtapes", token: owner)).mixtapes.count, 0)
        XCTAssertEqual(send("GET", "/v1/share/m/\(id)").status, 404)
        XCTAssertEqual(send("POST", "/v1/share/m/\(id)/sessions").status, 404)
        XCTAssertEqual(send("GET", "/m/\(id)").status, 404)
        XCTAssertEqual(try upload("/v1/share/mixtapes/\(id)/tracks/\(blob)", bytes: fixture.blobs[blob]!).status, 404)
        // Song routes.
        XCTAssertEqual(send("GET", "/v1/share/p/\(id)").status, 404)
        XCTAssertEqual(send("GET", "/v1/share/p/\(id)/audio").status, 404)
        XCTAssertEqual(send("GET", "/s/\(id)").status, 404)
        XCTAssertEqual(send("PATCH", "/v1/share/shares/\(id)", body: try encode(PatchShareRequest(playCap: 9)), token: owner).status, 404)
        XCTAssertEqual(send("POST", "/v1/share/shares/\(id)/finalize", token: owner).status, 404)
        XCTAssertEqual(send("DELETE", "/v1/share/shares/\(id)", token: owner).status, 404)
        XCTAssertEqual(try decode(ShareList.self, send("GET", "/v1/share/shares", token: owner)).shares.count, 0)
        XCTAssertEqual(try upload("/v1/share/shares/\(id)/audio", bytes: fixture.blobs[blob]!).status, 404)
        XCTAssertEqual(try ownerSummary(id).share.status, .ready, "nothing above touched the book")
        XCTAssertEqual(try ownerSummary(id).share.playCap, 2)

        // And the reverse: a mixtape is not a book.
        let key = ShareCrypto.newKey()
        let tracks = try (1 ... 2).map { index -> ShareMixtapeManifest.Track in
            let trackID = ShareBookCrypto.newID()
            let audio = try ShareCrypto.seal(Data(repeating: UInt8(index), count: 50), key: ShareMixtapeCrypto.trackKey(rootKey: key, trackID: trackID), purpose: .audio)
            return .init(id: trackID, metadata: .init(title: "Track \(index)", durationSeconds: 10), audioBytes: audio.count, audioSHA256: ShareHash.sha256Hex(audio))
        }
        let mixtape = CreateMixtapeRequest(encryptedManifest: try ShareMixtapeManifest(title: "Mixtape", tracks: tracks).seal(rootKey: key).base64EncodedString(),
            tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, .init(audioBytes: $0.audioBytes, audioSHA256: $0.audioSHA256)) }),
            totalDurationSeconds: 20, expiresInSeconds: 86400, playCap: 2, preview: nil, client: .init(platform: "macos", appVersion: "synthetic"))
        let made = try JSONDecoder().decode(CreateMixtapeResponse.self, from: send("POST", "/v1/share/mixtapes", body: try encode(mixtape), token: owner).body)
        XCTAssertEqual(send("GET", "/v1/share/books/\(made.id)", token: owner).status, 404)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(made.id)", token: owner).status, 404)
        XCTAssertEqual(send("GET", "/v1/share/b/\(made.id)").status, 404)
        XCTAssertEqual(send("GET", "/b/\(made.id)").status, 404)
        XCTAssertEqual(try upload("/v1/share/books/\(made.id)/blobs/\(tracks[0].id)", bytes: Data(repeating: 1, count: tracks[0].audioBytes)).status, 404)
        XCTAssertEqual(try decode(BookList.self, send("GET", "/v1/share/books", token: owner)).books.map(\.share.id), [id])
        XCTAssertEqual(try decode(MixtapeList.self, send("GET", "/v1/share/mixtapes", token: owner)).mixtapes.map(\.share.id), [made.id])
        // A retry identity reused across the two creates cannot hand back the other kind.
        var reused = try book(); reused.body.requestID = mixtape.requestID
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(reused.body), token: owner).status, 409)
    }

    func testMigrationIsIdempotentOnAnExistingDatabase() throws {
        let created = try ready(try book())
        service = nil
        let store = try ShareStore(root: root)
        try store.migrateMixtapes(); try store.migrateBooks(); try store.migrateBooks()
        XCTAssertEqual(try store.share(id: created.id)?.isBook, true)
        XCTAssertEqual(try store.bookBlobs(id: created.id).filter { $0.role == .text }.count, 1)
        service = try reopen()
        XCTAssertEqual(try ownerSummary(created.id).share.status, .ready)
    }

    // MARK: - Usage

    func testUsageIsCountedByTheServiceWithKindBookAndNoRawAddress() throws {
        let fixture = try book(preview: .init(title: "Public title", author: "Public author", from: "Sam", note: "For you")), created = try ready(fixture)
        send("GET", "/b/\(created.id)")
        send("GET", "/b/\(created.id)", agent: "Slackbot-LinkExpanding 1.0")
        let admitted = try session(created.id)
        send("GET", blobPath(created.id, fixture.chapterIDs[0]), token: admitted.token)
        XCTAssertEqual(send("POST", "/v1/share/b/\(created.id)/events", body: Data("{\"type\":\"play_started\",\"ms\":900}".utf8), token: admitted.token).status, 204)
        XCTAssertEqual(send("POST", "/v1/share/b/\(created.id)/events", body: Data("{\"type\":\"play_started\"}".utf8)).status, 401, "events need the session")
        XCTAssertEqual(send("POST", "/v1/share/b/\(created.id)/reactions", body: Data("{\"emoji\":\"❤️\",\"reply\":\"lovely\"}".utf8), token: admitted.token).status, 204)
        XCTAssertEqual(try ownerSummary(created.id).share.reactions.count, 1)
        XCTAssertEqual(send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(extendBySeconds: 86400)), token: owner).status, 200)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: owner).status, 204)

        func kinds(_ type: String) throws -> [String] {
            try service.store.database.query("SELECT props FROM events WHERE type=?", [.text(type)]).map { row in
                let props = try JSONDecoder().decode([String: PropValue].self, from: Data((row["props"]?.text ?? "{}").utf8))
                if case let .string(kind)? = props["kind"] { return kind }
                return "none"
            }
        }
        // reaction_sent too: a book's reaction is recorded as a book's.
        for type in ["share_created", "share_finalized", "audio_fetched", "page_opened", "link_unfurled", "share_extended", "share_revoked", "reaction_sent"] {
            XCTAssertEqual(try kinds(type), ["book"], type)
        }
        let now = Int64(clock.now.timeIntervalSince1970)
        let report = try ShareReport.build(store: service.store, since: now - 86400, until: now + 1, quotaBytes: ShareLimits.standard.quotaBytes)
        XCTAssertEqual(report.books, .init(created: 1, finalized: 1, revoked: 1, pageOpens: 1, unfurls: 1, listeners: 1))
        XCTAssertEqual(report.shares.created, 1, "a book is also in the totals")

        try service.store.database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        for name in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            guard let bytes = try? Data(contentsOf: root.appendingPathComponent(name)) else { continue }
            XCTAssertNil(bytes.range(of: Data(address.utf8)), "\(name) contains the client address")
        }
    }

    // MARK: - Page

    /// BATON_SHARE_ENABLED=0 refuses new shares; links already sent keep playing, page included.
    func testSharingPausedKeepsASentBookPagePlaying() throws {
        let created = try ready(try book())
        service = try reopen(enabled: false)
        XCTAssertEqual(send("GET", "/v1/share/b/\(created.id)").status, 200)
        let page = send("GET", "/b/\(created.id)")
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains(#"data-state="ready""#))
    }

    /// The song page's D-21 case on the book page.
    func testACombiningMarkCannotCarryAQuoteOrBracketPastEscaping() throws {
        let mark = "\u{301}"
        let preview = BookPreview(title: "Book <\(mark)b>", author: "A'\(mark)&\(mark)>\(mark)", from: "Sam\"\(mark)",
                                  note: "0;url=https://evil.example\"\(mark) http-equiv=refresh")
        let created = try ready(try book(preview: preview))
        for agent in ["Synthetic page browser", "Slackbot-LinkExpanding 1.0"] {
            let html = send("GET", "/b/\(created.id)", agent: agent).body
            try assertNoRawMarkupBeforeCombiningMark(html, dataID: "book-data")
            XCTAssertNotNil(html.range(of: Data("Book &lt;\(mark)".utf8)), String(decoding: html, as: UTF8.self))
        }
    }

    func testPageStatesAndPrivateModeShowsNothingIdentifying() throws {
        let hidden = try ready(try book())
        let page = send("GET", "/b/\(hidden.id)", agent: "Slackbot-LinkExpanding 1.0")
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(html.contains("Someone sent you a book")); XCTAssertTrue(html.contains("data-state=\"ready\""))
        XCTAssertTrue(html.contains("/b/\(hidden.id)\"")); XCTAssertFalse(html.contains("Synthetic book")); XCTAssertFalse(html.contains("Chapter 1"))
        XCTAssertFalse(html.contains("encryptedManifest")); XCTAssertFalse(html.contains("og:image")); XCTAssertFalse(html.contains("{{"))
        XCTAssertEqual(page.headers["Cache-Control"], "no-store")
        XCTAssertEqual(page.headers["Referrer-Policy"], "no-referrer")
        XCTAssertEqual(page.headers["Content-Security-Policy"], SharePage.pageHeaders["Content-Security-Policy"])

        let shown = try ready(try book(preview: .init(title: "A <long> book", author: "Ann & co", from: "Sam", note: "Read </script> this")))
        let public_ = String(decoding: send("GET", "/b/\(shown.id)").body, as: UTF8.self)
        XCTAssertTrue(public_.contains("Sam sent you A &lt;long&gt; book by Ann &amp; co"))
        XCTAssertTrue(public_.contains("Read &lt;/script&gt; this")); XCTAssertFalse(public_.contains("Chapter 1"))
        XCTAssertEqual(try decode(PublicBook.self, send("GET", "/v1/share/b/\(shown.id)")).preview?.author, "Ann & co")

        let pending = try create(try book())
        XCTAssertTrue(String(decoding: send("GET", "/b/\(pending.id)").body, as: UTF8.self).contains("data-state=\"pending\""))
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(shown.id)", token: owner).status, 204)
        let ended = send("GET", "/b/\(shown.id)")
        XCTAssertEqual(ended.status, 410)
        let endedHTML = String(decoding: ended.body, as: UTF8.self)
        XCTAssertTrue(endedHTML.contains("data-state=\"expired\"")); XCTAssertFalse(endedHTML.contains("A &lt;long&gt; book")); XCTAssertFalse(endedHTML.contains("Sam"))
        let unknown = send("GET", "/b/\(ShareBookCrypto.newID())")
        XCTAssertEqual(unknown.status, 404); XCTAssertTrue(String(decoding: unknown.body, as: UTF8.self).contains("data-state=\"unknown\""))
        XCTAssertEqual(send("GET", "/b/not-an-id").status, 404)
        XCTAssertEqual(send("POST", "/b/\(hidden.id)").status, 405)
        XCTAssertEqual(send("GET", "/b//\(hidden.id)").status, 404)
        service = try reopen(books: false)
        let off = send("GET", "/b/\(hidden.id)")
        XCTAssertEqual(off.status, 409)
        let offHTML = String(decoding: off.body, as: UTF8.self)
        XCTAssertTrue(offHTML.contains("data-state=\"unsupported\"")); XCTAssertFalse(offHTML.contains(hidden.id))
    }

    func testBookAssetsAreServedVersionedUnderTheirOwnPrefix() throws {
        let version = service.bookPage.version
        let html = String(decoding: send("GET", "/b/\(ShareBookCrypto.newID())").body, as: UTF8.self)
        XCTAssertTrue(html.contains("/b/_/book.mjs?v=\(version)")); XCTAssertTrue(html.contains("/b/_/book.css?v=\(version)"))
        for asset in ["book.mjs", "book.css", "share-book-crypto.mjs", "share-mixtape-crypto.mjs", "share-crypto.mjs", "icon.svg"] {
            let response = send("GET", "/b/_/" + asset)
            XCTAssertEqual(response.status, 200, asset)
            XCTAssertEqual(response.headers["Cache-Control"], "public, no-cache", asset)
            XCTAssertEqual(response.headers["X-Content-Type-Options"], "nosniff", asset)
        }
        let crypto = String(decoding: send("GET", "/b/_/share-book-crypto.mjs").body, as: UTF8.self)
        XCTAssertTrue(crypto.contains("\"./share-crypto.mjs?v=\(version)\"")); XCTAssertTrue(crypto.contains("\"./share-mixtape-crypto.mjs?v=\(version)\""))
        XCTAssertTrue(String(decoding: send("GET", "/b/_/book.mjs").body, as: UTF8.self).contains("\"./share-book-crypto.mjs?v=\(version)\""))
        XCTAssertEqual(send("GET", "/b/_/mixtape.mjs").status, 404)
        XCTAssertEqual(send("GET", "/m/_/book.mjs").status, 404)
        XCTAssertEqual(send("GET", "/b/_/missing.mjs").status, 404)
        XCTAssertEqual(ShareDeliveryCapacity.reservation(for: .init(method: "GET", path: blobPath("x", "y"), query: [:], headers: [:], body: Data()),
                                                         maximumAudioBytes: 100), 100 * 2 + 65_536)
    }

    /// Under accel nginx sends a song's blob, so the service's answer is headers only; a book or
    /// mixtape blob is still sent by the service.
    func testAccelSongBlobsReserveOnlyHeaders() {
        func reservation(_ path: String, _ delivery: ShareConfiguration.BlobDelivery) -> Int {
            ShareDeliveryCapacity.reservation(for: .init(method: "GET", path: path, query: [:], headers: [:], body: Data()),
                                              maximumAudioBytes: 26_214_400, blobDelivery: delivery)
        }
        let id = Base64URL.encode(Data(repeating: 1, count: 16))
        for kind in ["audio", "art", "card"] {
            XCTAssertEqual(reservation("/v1/share/p/\(id)/\(kind)", .accel), 65_536, kind)
            XCTAssertEqual(reservation("/v1/share/p/\(id)/\(kind)", .direct), 26_214_400 * 2 + 65_536, kind)
        }
        XCTAssertEqual(reservation(blobPath(id, "y"), .accel), 26_214_400 * 2 + 65_536)
        XCTAssertEqual(reservation("/v1/share/m/\(id)/tracks/y", .accel), 26_214_400 * 2 + 65_536)
        XCTAssertLessThanOrEqual(3 * reservation("/v1/share/p/\(id)/audio", .accel), ShareDeliveryCapacity.maximumBytes,
                                 "a third concurrent song fetch is not refused for capacity")
    }
}
