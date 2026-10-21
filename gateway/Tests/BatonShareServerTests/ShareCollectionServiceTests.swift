@testable import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
@testable import BatonShareServer
import Foundation
import XCTest

/// Album and playlist links on `/b/` (specs/collection-sharing.md "Service", TBX-1000000485): book
/// rows with a kind, behind `BATON_SHARE_COLLECTIONS`. The book behaviour itself is covered by
/// ShareBookServiceTests; these check what a collection adds and that it shares the book limits.
final class ShareCollectionServiceTests: XCTestCase {
    var root: URL!
    var service: ShareService!
    let clock = TestClock()
    let owner = Base64URL.encode(Data(repeating: 71, count: 32))
    let other = Base64URL.encode(Data(repeating: 72, count: 32))
    let operatorToken = String(repeating: "C", count: 40)
    let address = "203.0.113.97"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("collection-" + UUID().uuidString)
        service = try reopen()
    }
    override func tearDownWithError() throws {
        service = nil
        try? FileManager.default.removeItem(at: root)
    }

    func reopen(collections: Bool = true, books: Bool = true, enabled: Bool = true, change: (inout ShareConfiguration) -> Void = { _ in }) throws -> ShareService {
        var config = ShareConfiguration(dataDirectory: root.appendingPathComponent("service"), enabled: enabled, blobDelivery: .direct)
        config.booksEnabled = books
        config.collectionsEnabled = collections
        config.mixtapesEnabled = true
        config.enforcement = try .init(token: operatorToken, retentionSeconds: 90 * 86400, auditRetentionSeconds: 90 * 86400, reasonCodes: ["review"])
        change(&config)
        return try ShareService(config: config, clock: { [clock] in clock.now })
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: Data = Data(), token: String? = nil, agent: String = "Synthetic browser",
              peer: ConnectionPeer = .unknown) -> ShareResponse {
        var headers = ["user-agent": agent]
        if peer != .loopback { headers["x-real-ip"] = address }
        if let token { headers["authorization"] = "Bearer " + token }
        return service.handle(.init(method: method, path: path, query: [:], headers: headers, body: body), peer: peer)
    }
    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    func decode<T: Decodable>(_ type: T.Type, _ response: ShareResponse, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        XCTAssertLessThan(response.status, 300, String(decoding: response.body, as: UTF8.self), file: file, line: line)
        return try JSONDecoder().decode(type, from: response.body)
    }
    func object(_ response: ShareResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
    }
    func code(_ response: ShareResponse) -> String? { object(response)["code"] as? String }
    func html(_ response: ShareResponse) -> String { String(decoding: response.body, as: UTF8.self) }

    // MARK: - Fixtures

    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: 60)

    /// Sealed by the kit as the apps seal it: an album (with a cover), a playlist, or with no kind a
    /// book. Each call is a fresh link with its own request ID.
    func prepared(_ kind: ShareCollectionKind?, tracks: Int = 2, listeners: Int = 3, preview: BookPreview? = nil,
                  consent: Bool = false) throws -> PreparedBookShare {
        let name = UUID().uuidString
        let source = root.appendingPathComponent("source-" + name)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var list = [PreparedBookShare.Chapter]()
        for index in 0 ..< tracks {
            let audio = source.appendingPathComponent("track-\(index + 1).m4a")
            try Data((0 ..< (600 + index * 50)).map { UInt8(truncatingIfNeeded: $0 &+ index) }).write(to: audio)
            list.append(.init(audio: audio, title: "Track \(index + 1)", durationSeconds: 180, artist: "Synthetic artist",
                              album: "Synthetic album", trackNumber: index + 1))
        }
        return try PreparedBookShare.make(chapters: list, title: kind == nil ? "Synthetic book" : "Synthetic \(kind!.rawValue)",
            author: "Synthetic artist", from: "Sam", preview: preview, expiresInSeconds: 86400, listenerCap: listeners,
            client: .init(platform: "macos", appVersion: "synthetic"), reviewPreservationConsent: consent ? "review-v1" : nil,
            limits: ShareBookLimits(limits: .standard), directory: root.appendingPathComponent("staged-" + name), kind: kind,
            cover: kind == .album ? .init(type: "image/jpeg", bytes: Self.jpeg) : nil)
    }

    func create(_ link: PreparedBookShare, token: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> CreateBookResponse {
        let response = send("POST", "/v1/share/books", body: link.requestBody, token: token ?? owner)
        XCTAssertEqual(response.status, 201, html(response), file: file, line: line)
        return try JSONDecoder().decode(CreateBookResponse.self, from: response.body)
    }
    func upload(_ path: String, bytes: Data, token: String? = nil) throws -> ShareResponse {
        let file = root.appendingPathComponent("synthetic-upload-" + UUID().uuidString)
        try bytes.write(to: file)
        return service.handleUpload(.init(method: "PUT", path: path, headers: ["authorization": "Bearer " + (token ?? owner)], contentLength: bytes.count), file: file)
    }
    func uploadAll(_ link: PreparedBookShare, _ created: CreateBookResponse, token: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        for blob in link.blobs {
            XCTAssertEqual(try upload(created.uploads[blob.id]!, bytes: Data(contentsOf: link.file(blob.id)), token: token).status, 200, file: file, line: line)
        }
    }
    func ready(_ link: PreparedBookShare, file: StaticString = #filePath, line: UInt = #line) throws -> CreateBookResponse {
        let created = try create(link, file: file, line: line)
        try uploadAll(link, created, file: file, line: line)
        XCTAssertEqual(send("POST", "/v1/share/books/\(created.id)/finalize", token: owner).status, 200, file: file, line: line)
        return created
    }
    func session(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> BookSession {
        let response = send("POST", "/v1/share/b/\(id)/sessions")
        XCTAssertEqual(response.status, 201, html(response), file: file, line: line)
        return try JSONDecoder().decode(BookSession.self, from: response.body)
    }
    func blobPath(_ id: String, _ blob: String) -> String { "/v1/share/b/\(id)/blobs/\(blob)" }
    func ownerSummary(_ id: String) throws -> BookSummary { try decode(BookSummary.self, send("GET", "/v1/share/books/\(id)", token: owner)) }

    // MARK: - The flag

    func testCollectionsFlagParsesStrictlyAndDefaultsOff() throws {
        XCTAssertFalse(try ShareConfiguration.fromEnvironment([:]).collectionsEnabled)
        for on in ["1", "true", "TRUE"] { XCTAssertTrue(try ShareConfiguration.fromEnvironment(["BATON_SHARE_COLLECTIONS": on]).collectionsEnabled, on) }
        for off in ["0", "false", ""] { XCTAssertFalse(try ShareConfiguration.fromEnvironment(["BATON_SHARE_COLLECTIONS": off]).collectionsEnabled, off) }
        XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(["BATON_SHARE_COLLECTIONS": "yes"]))
        let booksOnly = try ShareConfiguration.fromEnvironment(["BATON_SHARE_BOOKS": "1"])
        XCTAssertTrue(booksOnly.booksEnabled); XCTAssertFalse(booksOnly.collectionsEnabled)
    }

    func testConfigAdvertisesCollectionsOnlyWithSharingBooksAndCollectionsOn() throws {
        let on = try decode(ShareConfig.self, send("GET", "/v1/share/config"))
        XCTAssertEqual(on.collections, 1)
        XCTAssertEqual(on.collection, ShareCollectionLimits())
        XCTAssertEqual(on.collection?.kinds, [.album, .playlist]); XCTAssertEqual(on.collection?.maxCoverBytes, 131_072)
        XCTAssertEqual(on.books, 1)
        for (collections, books, enabled) in [(false, true, true), (true, false, true), (true, true, false)] {
            service = try reopen(collections: collections, books: books, enabled: enabled)
            let advertised = object(send("GET", "/v1/share/config"))
            XCTAssertNil(advertised["collections"], "\(collections) \(books) \(enabled)"); XCTAssertNil(advertised["collection"])
            XCTAssertEqual(advertised["books"] as? Int, books && enabled ? 1 : nil)
        }
    }

    func testWithCollectionsOffACollectionCreateIsUnsupportedBeforeAnyOtherCheckAndABookStillCreates() throws {
        service = try reopen(collections: false)
        let album = try prepared(.album)
        let refused = send("POST", "/v1/share/books", body: album.requestBody, token: owner)
        XCTAssertEqual(refused.status, 409); XCTAssertEqual(code(refused), "unsupported")
        XCTAssertEqual(code(send("POST", "/v1/share/books", body: try prepared(.playlist).requestBody, token: owner)), "unsupported")
        // Before sharing-off (503), and before validation: an otherwise broken collection body is still 409.
        var broken = album.request; broken.listenerCap = 999
        XCTAssertEqual(code(send("POST", "/v1/share/books", body: try encode(broken), token: owner)), "unsupported")
        service = try reopen(collections: false, enabled: false)
        XCTAssertEqual(code(send("POST", "/v1/share/books", body: album.requestBody, token: owner)), "unsupported")
        XCTAssertEqual(code(send("POST", "/v1/share/books", body: try prepared(nil).requestBody, token: owner)), "share_disabled", "a book keeps its ordering")
        // Books off answers as it always did.
        service = try reopen(collections: false, books: false)
        XCTAssertEqual(object(send("POST", "/v1/share/books", body: album.requestBody, token: owner))["error"] as? String, "This server does not support book links.")
        service = try reopen(collections: false)
        XCTAssertEqual(try create(try prepared(nil)).id.count, 22, "a book still creates")
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares WHERE is_book=1"), 1)
    }

    // MARK: - Create, upload, finalize, listen

    func testAnAlbumCreatesUploadsFinalizesAndPlaysWithItsKindEverywhere() throws {
        let album = try prepared(.album, tracks: 3)
        XCTAssertEqual(album.request.kind, .album)
        let created = try create(album)
        XCTAssertTrue(created.url.hasSuffix("/b/\(created.id)"))
        XCTAssertEqual(Set(created.uploads.keys), Set(album.blobs.map(\.id)))
        XCTAssertEqual(try service.store.share(id: created.id)?.bookKind, .album)
        XCTAssertEqual(try service.store.database.query("SELECT book_kind FROM shares WHERE id=?", [.text(created.id)]).first?["book_kind"]?.text, "album")
        let pending = try decode(PublicBook.self, send("GET", "/v1/share/b/\(created.id)"))
        XCTAssertEqual(pending.status, .pending); XCTAssertEqual(pending.kind, .album)
        XCTAssertEqual(code(send("POST", "/v1/share/books/\(created.id)/finalize", token: owner)), "incomplete")
        try uploadAll(album, created)
        let summary = try decode(BookSummary.self, send("POST", "/v1/share/books/\(created.id)/finalize", token: owner))
        XCTAssertEqual(summary.share.status, .ready); XCTAssertEqual(summary.kind, .album)
        XCTAssertEqual(summary.chapterCount, 3); XCTAssertFalse(summary.hasText)

        let details = send("GET", "/v1/share/b/\(created.id)")
        XCTAssertEqual(object(details)["kind"] as? String, "album")
        XCTAssertEqual(object(details)["schema"] as? String, "baton-collection-1")
        let publicBook = try decode(PublicBook.self, details)
        let opened = try publicBook.open(rootKey: album.key)
        XCTAssertEqual(opened, album.manifest)
        XCTAssertEqual(opened.kind, .album); XCTAssertEqual(opened.cover?.bytes, Self.jpeg)
        XCTAssertEqual(opened.chapters.map(\.trackNumber), [1, 2, 3])
        let admitted = try session(created.id)
        for (index, track) in opened.chapters.enumerated() {
            let blob = send("GET", blobPath(created.id, track.id), token: admitted.token)
            XCTAssertEqual(blob.status, 200)
            XCTAssertEqual(try opened.openAudio(blob.body, chapterID: track.id, rootKey: album.key),
                           Data((0 ..< (600 + index * 50)).map { UInt8(truncatingIfNeeded: $0 &+ index) }))
        }
        XCTAssertEqual(try ownerSummary(created.id).share.stats.fetches, 1)
        XCTAssertEqual(object(send("GET", "/v1/share/books/\(created.id)", token: owner))["kind"] as? String, "album")

        // A playlist and a book beside it: the list carries each kind, and a book carries none.
        let playlist = try ready(try prepared(.playlist))
        let book = try ready(try prepared(nil))
        let list = try decode(BookList.self, send("GET", "/v1/share/books", token: owner))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: list.books.map { ($0.share.id, $0.kind) }),
                       [created.id: .album, playlist.id: .playlist, book.id: nil])
        XCTAssertEqual(try decode(PublicBook.self, send("GET", "/v1/share/b/\(playlist.id)")).kind, .playlist)
        let bookDetails = object(send("GET", "/v1/share/b/\(book.id)"))
        XCTAssertNil(bookDetails["kind"]); XCTAssertEqual(bookDetails["schema"] as? String, "baton-book-1")
        XCTAssertNil(object(send("GET", "/v1/share/books/\(book.id)", token: owner))["kind"], "no kind key for a book")
        let listed = (object(send("GET", "/v1/share/books", token: owner))["books"] as? [[String: Any]]) ?? []
        XCTAssertEqual(listed.filter { $0["kind"] == nil }.count, 1)
    }

    func testARetryAnswersTheSameCollectionAndNeverTheOtherKind() throws {
        let album = try prepared(.album)
        let created = try create(album)
        XCTAssertEqual(try create(album), created)
        service = try reopen()
        XCTAssertEqual(try create(album), created, "the retry identity is durable")
        // A book under the album's request ID, and an album under a book's, are conflicts.
        var book = try prepared(nil).request; book.requestID = album.request.requestID
        let crossed = send("POST", "/v1/share/books", body: try encode(book), token: owner)
        XCTAssertEqual(crossed.status, 409); XCTAssertEqual(code(crossed), "conflict")
        let realBook = try prepared(nil), madeBook = try create(realBook)
        var playlist = try prepared(.playlist).request; playlist.requestID = realBook.request.requestID
        XCTAssertEqual(code(send("POST", "/v1/share/books", body: try encode(playlist), token: owner)), "conflict")
        XCTAssertEqual(try create(realBook), madeBook)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares WHERE is_book=1"), 2)
    }

    func testACollectionTakesNoTextAndItsSchemaAndKindMustAgree() throws {
        let album = try prepared(.album)
        var withText = album.request
        withText.blobs[ShareBookCrypto.newID()] = .init(role: .text, bytes: 100, sha256: String(repeating: "b", count: 64))
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(withText), token: owner).status, 400)
        var bookSchema = album.request; bookSchema.schema = ShareBookManifest.schemaVersion
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(bookSchema), token: owner).status, 400)
        var noKind = album.request; noKind.kind = nil
        XCTAssertEqual(send("POST", "/v1/share/books", body: try encode(noKind), token: owner).status, 400)
        let unknownKind = String(decoding: album.requestBody, as: UTF8.self).replacingOccurrences(of: "\"kind\":\"album\"", with: "\"kind\":\"book\"")
        XCTAssertNotEqual(unknownKind, String(decoding: album.requestBody, as: UTF8.self))
        XCTAssertEqual(send("POST", "/v1/share/books", body: Data(unknownKind.utf8), token: owner).status, 400)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares"), 0)
        XCTAssertEqual(try create(album).id.count, 22)
    }

    // MARK: - Shared limits

    func testTheLiveCapCountsBooksAlbumsAndPlaylistsTogether() throws {
        _ = try create(try prepared(nil)); _ = try create(try prepared(nil))
        let album = try create(try prepared(.album))
        for kind: ShareCollectionKind? in [nil, .album, .playlist] {
            let refused = send("POST", "/v1/share/books", body: try prepared(kind).requestBody, token: owner)
            XCTAssertEqual(refused.status, 429, "\(String(describing: kind))"); XCTAssertEqual(code(refused), "rate_limited")
        }
        let scopes = try service.store.database.query("SELECT props FROM events WHERE type='rate_limited'").compactMap { $0["props"]?.text }
        XCTAssertEqual(scopes, Array(repeating: "{\"scope\":\"sharer_live_books\"}", count: 3))
        XCTAssertEqual(try create(try prepared(.playlist), token: other).id.count, 22, "the cap is per sharer")
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(album.id)", token: owner).status, 204)
        XCTAssertEqual(try create(try prepared(.playlist)).id.count, 22, "ending the album frees a place")
    }

    func testTheBookSliceIsSharedAcrossKinds() throws {
        let book = try prepared(nil), album = try prepared(.album)
        let bookBytes = Int64(book.request.totalBytes), albumBytes = Int64(album.request.totalBytes)
        service = try reopen { $0.limits.bookQuotaBytes = max(bookBytes, albumBytes) + 10 }
        let madeBook = try create(book)
        let busy = send("POST", "/v1/share/books", body: album.requestBody, token: other)
        XCTAssertEqual(busy.status, 503); XCTAssertEqual(code(busy), "busy")
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(madeBook.id)", token: owner).status, 204)
        let madeAlbum = try create(album, token: other)
        XCTAssertEqual(try service.store.bookQuotaBytes(), albumBytes)
        try uploadAll(album, madeAlbum, token: other)
        XCTAssertEqual(try service.store.bookQuotaBytes(), albumBytes, "uploading does not charge twice")
        XCTAssertEqual(send("POST", "/v1/share/books", body: try prepared(nil).requestBody, token: owner).status, 503, "the album holds the slice against a book")
    }

    // MARK: - Ended links

    func testRevokedExpiredAndHeldCollectionsReadAsExpiredOnEveryListenerSurface() throws {
        let album = try prepared(.album, listeners: 5), created = try ready(album), admitted = try session(created.id)
        let track = album.manifest.chapters[0].id
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: other).status, 404)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: owner).status, 204)
        XCTAssertEqual(try ownerSummary(created.id).share.status, .revoked, "only the sharer sees revoked")
        XCTAssertEqual(try ownerSummary(created.id).kind, .album)
        func listenerSurfaces(_ id: String, token: String) -> [ShareResponse] {
            [send("GET", "/v1/share/b/\(id)"),
             send("POST", "/v1/share/b/\(id)/sessions"),
             send("GET", blobPath(id, track), token: token),
             send("HEAD", blobPath(id, track), token: token),
             send("POST", "/v1/share/b/\(id)/events", body: Data("{\"type\":\"play_30s\"}".utf8), token: token),
             send("POST", "/v1/share/b/\(id)/reactions", body: Data("{\"emoji\":\"❤️\"}".utf8), token: token)]
        }
        for response in listenerSurfaces(created.id, token: admitted.token) {
            XCTAssertEqual(response.status, 410); XCTAssertEqual(code(response), "expired")
            XCTAssertFalse(html(response).contains("revoked"))
        }
        let page = send("GET", "/b/\(created.id)")
        XCTAssertEqual(page.status, 410)
        XCTAssertTrue(html(page).contains("This album’s link has expired")); XCTAssertTrue(html(page).contains("\"state\":\"expired\""))
        XCTAssertTrue(html(page).contains("id=\"collection-data\"")); XCTAssertFalse(html(page).contains("revoked"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("service/blobs/\(created.id)").path))

        // Expired.
        let playlist = try prepared(.playlist), live = try ready(playlist), listening = try session(live.id)
        clock.advance(86400)
        XCTAssertEqual(code(send("GET", blobPath(live.id, playlist.manifest.chapters[0].id), token: listening.token)), "expired")
        XCTAssertEqual(code(send("GET", "/v1/share/b/\(live.id)")), "expired")
        XCTAssertEqual(code(send("POST", "/v1/share/b/\(live.id)/sessions")), "expired")
        let expiredPage = send("GET", "/b/\(live.id)")
        XCTAssertEqual(expiredPage.status, 410); XCTAssertTrue(html(expiredPage).contains("This playlist’s link has expired"))
        XCTAssertEqual(try ownerSummary(live.id).share.status, .expired)

        // Held by enforcement.
        let held = try prepared(.album, consent: true), heldLink = try ready(held), heldSession = try session(heldLink.id)
        let start = Int64(clock.now.timeIntervalSince1970)
        let request: [String: Any] = ["operationID": UUID().uuidString, "action": "disable-share", "shareID": heldLink.id, "caseReference": "case_album",
                                      "reasonCode": "review", "reviewUntil": start + 20 * 86400, "preservationDeadline": start + 22 * 86400]
        let plan = send("POST", "/v1/share/admin/enforcement/plan", body: try JSONSerialization.data(withJSONObject: request), token: operatorToken, peer: .loopback)
        XCTAssertEqual(plan.status, 200, html(plan))
        XCTAssertEqual(send("POST", "/v1/share/admin/enforcement/apply", body: plan.body, token: operatorToken, peer: .loopback).status, 200)
        for response in [send("GET", "/v1/share/b/\(heldLink.id)"), send("POST", "/v1/share/b/\(heldLink.id)/sessions"),
                         send("GET", blobPath(heldLink.id, held.manifest.chapters[0].id), token: heldSession.token)] {
            XCTAssertEqual(response.status, 410); XCTAssertEqual(code(response), "expired")
        }
        XCTAssertTrue(html(send("GET", "/b/\(heldLink.id)")).contains("This album’s link has expired"))
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(heldLink.id)", token: owner).status, 204, "a held album stays revocable")
    }

    func testSwitchingCollectionsOffLaterRefusesListenersAndNewWorkButKeepsTheSharersViewAndRevoke() throws {
        let album = try prepared(.album), created = try ready(album), admitted = try session(created.id)
        let unfinished = try prepared(.playlist), pending = try create(unfinished)
        let book = try ready(try prepared(nil))
        service = try reopen(collections: false)
        let track = album.manifest.chapters[0].id
        let surfaces = [
            send("GET", "/v1/share/b/\(created.id)"),
            send("POST", "/v1/share/b/\(created.id)/sessions"),
            send("GET", blobPath(created.id, track), token: admitted.token),
            send("HEAD", blobPath(created.id, track), token: admitted.token),
            send("POST", "/v1/share/b/\(created.id)/events", body: Data("{\"type\":\"play_30s\"}".utf8), token: admitted.token),
            send("POST", "/v1/share/b/\(created.id)/reactions", body: Data("{\"emoji\":\"❤️\"}".utf8), token: admitted.token),
            send("GET", "/v1/share/b/\(pending.id)"),
            send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(playCap: 4)), token: owner),
            send("POST", "/v1/share/books/\(pending.id)/finalize", token: owner),
            try upload(pending.uploads[unfinished.blobs[0].id]!, bytes: Data(contentsOf: unfinished.file(unfinished.blobs[0].id))),
        ]
        for response in surfaces {
            XCTAssertEqual(response.status, 409, html(response)); XCTAssertEqual(code(response), "unsupported")
        }
        let page = send("GET", "/b/\(created.id)")
        XCTAssertEqual(page.status, 409)
        XCTAssertTrue(html(page).contains("data-state=\"unsupported\"")); XCTAssertTrue(html(page).contains("Album and playlist links are unavailable here"))
        XCTAssertFalse(html(page).contains(created.id)); XCTAssertTrue(html(page).contains("id=\"collection-data\""))
        // The book beside it is untouched.
        XCTAssertEqual(try decode(PublicBook.self, send("GET", "/v1/share/b/\(book.id)")).status, .ready)
        XCTAssertEqual(send("GET", "/b/\(book.id)").status, 200)
        // The sharer still reads, lists and revokes.
        XCTAssertEqual(try ownerSummary(created.id).kind, .album)
        XCTAssertEqual(try ownerSummary(pending.id).share.status, .pending)
        XCTAssertEqual(try decode(BookList.self, send("GET", "/v1/share/books", token: owner)).books.count, 3)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: owner).status, 204)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(pending.id)", token: owner).status, 204)
        XCTAssertEqual(try ownerSummary(created.id).share.status, .revoked)
        XCTAssertEqual(try ownerSummary(pending.id).share.status, .revoked)
        // With books off too, a collection's page still says what it is.
        service = try reopen(collections: false, books: false)
        let bookPage = send("GET", "/b/\(book.id)")
        XCTAssertTrue(html(bookPage).contains("Book links are unavailable here"))
        XCTAssertEqual(send("GET", "/b/\(created.id)").status, 409)
        XCTAssertTrue(html(send("GET", "/b/\(created.id)")).contains("Album and playlist links are unavailable here"))
    }

    func testMigrationIsIdempotentAndKeepsTheKind() throws {
        let created = try ready(try prepared(.playlist))
        service = nil
        let store = try ShareStore(root: root.appendingPathComponent("service"))
        try store.migrateBooks(); try store.migrateBooks()
        XCTAssertEqual(try store.share(id: created.id)?.bookKind, .playlist)
        service = try reopen()
        XCTAssertEqual(try ownerSummary(created.id).kind, .playlist)
    }

    // MARK: - Usage

    func testUsageCarriesTheKindAndTheReportCountsEachKindWithNoRawAddress() throws {
        let album = try prepared(.album, preview: .init(title: "Public album", author: "Public artist", from: "Sam"))
        let created = try ready(album)
        send("GET", "/b/\(created.id)")
        send("GET", "/b/\(created.id)", agent: "Slackbot-LinkExpanding 1.0")
        let admitted = try session(created.id)
        send("GET", blobPath(created.id, album.manifest.chapters[0].id), token: admitted.token)
        XCTAssertEqual(send("POST", "/v1/share/b/\(created.id)/events", body: Data("{\"type\":\"play_started\",\"ms\":700}".utf8), token: admitted.token).status, 204)
        XCTAssertEqual(send("POST", "/v1/share/b/\(created.id)/reactions", body: Data("{\"emoji\":\"❤️\",\"reply\":\"lovely\"}".utf8), token: admitted.token).status, 204)
        XCTAssertEqual(send("PATCH", "/v1/share/books/\(created.id)", body: try encode(PatchShareRequest(extendBySeconds: 86400)), token: owner).status, 200)
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(created.id)", token: owner).status, 204)
        // A playlist that runs out: the listener's read records its expiry.
        let playlist = try ready(try prepared(.playlist))
        _ = try session(playlist.id)
        // An album nobody opens again ends in the sweeper, which labels its expiry too.
        let swept = try ready(try prepared(.album))
        clock.advance(86400)
        XCTAssertEqual(code(send("GET", "/v1/share/b/\(playlist.id)")), "expired")
        XCTAssertEqual(try service.store.sweep(now: Int64(clock.now.timeIntervalSince1970), limits: .standard).expired, 1)
        XCTAssertEqual(try service.store.share(id: swept.id)?.status, .expired)

        func kinds(_ type: String) throws -> [String] {
            try service.store.database.query("SELECT props FROM events WHERE type=? ORDER BY rowid", [.text(type)]).map { row in
                let props = try JSONDecoder().decode([String: PropValue].self, from: Data((row["props"]?.text ?? "{}").utf8))
                if case let .string(kind)? = props["kind"] { return kind }
                return "none"
            }
        }
        for type in ["page_opened", "link_unfurled", "share_extended", "share_revoked"] { XCTAssertEqual(try kinds(type), ["album"], type) }
        for type in ["share_created", "share_finalized"] { XCTAssertEqual(try kinds(type), ["album", "playlist", "album"], type) }
        XCTAssertEqual(try kinds("audio_fetched"), ["album", "playlist"])
        XCTAssertEqual(try kinds("share_expired"), ["playlist", "album"])

        let now = Int64(clock.now.timeIntervalSince1970)
        let report = try ShareReport.build(store: service.store, since: now - 3 * 86400, until: now + 1, quotaBytes: ShareLimits.standard.quotaBytes)
        XCTAssertEqual(report.albums, .init(created: 2, finalized: 2, revoked: 1, pageOpens: 1, unfurls: 1, listeners: 1))
        XCTAssertEqual(report.playlists, .init(created: 1, finalized: 1, revoked: 0, pageOpens: 0, unfurls: 0, listeners: 1))
        XCTAssertEqual(report.books, .init(), "book counters stay books only")
        XCTAssertEqual(report.shares.created, 3, "collections are also in the totals")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual((json["albums"] as? [String: Any])?["listeners"] as? Int, 1)
        XCTAssertEqual((json["playlists"] as? [String: Any])?["created"] as? Int, 1)

        try service.store.database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        for name in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            guard let bytes = try? Data(contentsOf: root.appendingPathComponent(name)) else { continue }
            XCTAssertNil(bytes.range(of: Data(address.utf8)), "\(name) contains the client address")
        }
    }

    // MARK: - Page

    func testThePageRendersTheCollectionTemplateWithItsTitles() throws {
        let hidden = try ready(try prepared(.album))
        let privatePage = send("GET", "/b/\(hidden.id)", agent: "Slackbot-LinkExpanding 1.0")
        XCTAssertEqual(privatePage.status, 200)
        let text = html(privatePage)
        XCTAssertTrue(text.contains("Someone sent you an album")); XCTAssertTrue(text.contains("data-state=\"ready\""))
        XCTAssertTrue(text.contains("id=\"collection-data\"")); XCTAssertTrue(text.contains("\"kind\":\"album\""))
        XCTAssertTrue(text.contains("/b/_/collection.mjs?v=\(service.bookPage.version)")); XCTAssertTrue(text.contains("/b/_/collection.css?v=\(service.bookPage.version)"))
        XCTAssertFalse(text.contains("Synthetic album")); XCTAssertFalse(text.contains("Track 1")); XCTAssertFalse(text.contains("{{"))
        XCTAssertEqual(privatePage.headers["Content-Security-Policy"], SharePage.pageHeaders["Content-Security-Policy"])
        XCTAssertEqual(privatePage.headers["Cache-Control"], "no-store")
        let playlist = try ready(try prepared(.playlist))
        XCTAssertTrue(html(send("GET", "/b/\(playlist.id)")).contains("Someone sent you a playlist"))
        let pending = try create(try prepared(.playlist))
        XCTAssertTrue(html(send("GET", "/b/\(pending.id)")).contains("data-state=\"pending\""))
        // Three live links is the cap, so these make room for the rest.
        for id in [hidden.id, playlist.id, pending.id] { XCTAssertEqual(send("DELETE", "/v1/share/books/\(id)", token: owner).status, 204) }

        let shown = try ready(try prepared(.album, preview: .init(title: "A <loud> album", author: "Ann & the band", from: "Sam", note: "Side B")))
        let publicPage = html(send("GET", "/b/\(shown.id)"))
        XCTAssertTrue(publicPage.contains("Sam sent you A &lt;loud&gt; album by Ann &amp; the band")); XCTAssertTrue(publicPage.contains("Side B"))
        let noArtist = try ready(try prepared(.playlist, preview: .init(title: "Road trip", from: "Kim")))
        XCTAssertTrue(html(send("GET", "/b/\(noArtist.id)")).contains("<title>Kim sent you Road trip</title>"))

        XCTAssertEqual(send("DELETE", "/v1/share/books/\(shown.id)", token: owner).status, 204)
        let ended = html(send("GET", "/b/\(shown.id)"))
        XCTAssertTrue(ended.contains("This album’s link has expired")); XCTAssertFalse(ended.contains("Ann")); XCTAssertFalse(ended.contains("Sam"))
        XCTAssertEqual(send("DELETE", "/v1/share/books/\(noArtist.id)", token: owner).status, 204)
        XCTAssertTrue(html(send("GET", "/b/\(noArtist.id)")).contains("This playlist’s link has expired"))

        // An unknown link keeps the book page's unknown state; a book keeps its own page and no kind.
        let unknown = send("GET", "/b/\(ShareBookCrypto.newID())")
        XCTAssertEqual(unknown.status, 404)
        XCTAssertTrue(html(unknown).contains("id=\"book-data\"")); XCTAssertFalse(html(unknown).contains("\"kind\""))
        let book = try ready(try prepared(nil))
        let bookPage = html(send("GET", "/b/\(book.id)"))
        XCTAssertTrue(bookPage.contains("Someone sent you a book")); XCTAssertTrue(bookPage.contains("id=\"book-data\""))
        XCTAssertFalse(bookPage.contains("\"kind\"")); XCTAssertFalse(bookPage.contains("collection.mjs"))
    }

    func testCollectionAssetsAreServedUnderTheBookVersion() throws {
        let version = service.bookPage.version
        for asset in ["collection.mjs", "collection.css", "book.mjs", "book.css", "share-book-crypto.mjs"] {
            let response = send("GET", "/b/_/" + asset)
            XCTAssertEqual(response.status, 200, asset)
            XCTAssertEqual(response.headers["Cache-Control"], "public, no-cache", asset)
            XCTAssertEqual(response.headers["X-Content-Type-Options"], "nosniff", asset)
        }
        XCTAssertEqual(send("GET", "/b/_/collection.mjs").contentType, "text/javascript; charset=utf-8")
        XCTAssertEqual(send("GET", "/b/_/collection.css").contentType, "text/css; charset=utf-8")
        let module = html(send("GET", "/b/_/collection.mjs"))
        if module.contains("./share-book-crypto.mjs") { XCTAssertTrue(module.contains("\"./share-book-crypto.mjs?v=\(version)\"")) }
        XCTAssertEqual(send("GET", "/m/_/collection.mjs").status, 404)
        XCTAssertEqual(send("GET", "/b/_/collection.html").status, 404)
    }
}
