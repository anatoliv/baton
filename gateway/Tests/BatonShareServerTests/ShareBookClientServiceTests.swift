@testable import BatonShareKit
import BatonMCPProtocol
@testable import BatonGatewayCore
@testable import BatonShareServer
import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The kit's book client (`PreparedBookShare` and the `ShareClient` book routes) against the real
/// `ShareService` with books on, through an in-process HTTP bridge, as the apps will use it
/// (specs/book-sharing.md Phase 2, TBX-1000000132). The transport follows ShareMixtapeClientTests.
final class BookHTTPBridge: @unchecked Sendable {
    let service: ShareService
    let root: URL
    private let lock = NSLock()
    private var captured: [String] = []
    /// A path fragment whose next response is lost after the service has acted on it.
    var loseNext: String?
    /// A path fragment whose next request never reaches the service.
    var failNext: String?
    init(service: ShareService, root: URL) { self.service = service; self.root = root }
    func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return captured }
    func respond(_ request: URLRequest) throws -> ShareResponse {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        lock.lock(); captured.append("\(method) \(path)"); lock.unlock()
        var headers = [String: String]()
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                if count == 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        if method == "PUT" {
            let file = root.appendingPathComponent("bridge-upload-" + UUID().uuidString)
            try body.write(to: file)
            return service.handleUpload(.init(method: method, path: path, headers: headers, contentLength: body.count), file: file)
        }
        return service.handle(.init(method: method, path: path, query: [:], headers: headers, body: body))
    }
}

final class BookBridgeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bridge: BookHTTPBridge?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let bridge = Self.bridge!
            if let fail = bridge.failNext, request.url!.path.hasSuffix(fail) {
                bridge.failNext = nil
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = try bridge.respond(request)
            if let lose = bridge.loseNext, request.url!.path.hasSuffix(lose) {
                bridge.loseNext = nil
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let headers = response.headers.merging(["Content-Type": response.contentType, "Content-Length": String(response.body.count)],
                                                   uniquingKeysWith: { _, rhs in rhs })
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                                                  headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ShareBookClientServiceTests: XCTestCase {
    var root: URL!
    private var bridge: BookHTTPBridge!
    var service: ShareService!
    var client: ShareClient!
    var session: URLSession!
    let clock = TestClock()
    let owner = Base64URL.encode(Data(repeating: 61, count: 32))
    let base = URL(string: "https://batonmusic.app")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("book-client-service-" + UUID().uuidString)
        var config = ShareConfiguration(dataDirectory: root.appendingPathComponent("service"), blobDelivery: .direct)
        config.booksEnabled = true
        config.mixtapesEnabled = true
        service = try ShareService(config: config, clock: { [clock] in clock.now })
        bridge = BookHTTPBridge(service: service, root: root)
        BookBridgeProtocol.bridge = bridge
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookBridgeProtocol.self]
        session = URLSession(configuration: configuration)
        client = ShareClient(base: base, secret: owner, session: session)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        BookBridgeProtocol.bridge = nil; bridge = nil; service = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func listener(_ method: String, _ path: String, body: Data = Data(), token: String? = nil) -> ShareResponse {
        var headers = ["user-agent": "Synthetic browser"]
        if let token { headers["authorization"] = "Bearer " + token }
        return service.handle(.init(method: method, path: path, query: [:], headers: headers, body: body))
    }

    private func code(_ response: ShareResponse) -> String? {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["code"] as? String
    }

    /// Three chapters on disk, the first with read-along text, sealed by the kit as the apps seal them.
    private func prepared(_ name: String = "book", listeners: Int = 3) async throws -> PreparedBookShare {
        let config = try await client.bookConfiguration()
        let limits = try XCTUnwrap(config.book)
        var chapters = [PreparedBookShare.Chapter]()
        for index in 0 ..< 3 {
            let audio = root.appendingPathComponent("\(name)-chapter-\(index + 1).m4a")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data((0 ..< (2_000 + index * 70_000)).map { UInt8(truncatingIfNeeded: $0 &+ index) }).write(to: audio)
            let text = index == 0 ? ShareBookText(segments: [.init(text: "It begins.", paragraph: -1, start: 0, end: 1.5)]) : nil
            chapters.append(.init(audio: audio, title: "Chapter \(index + 1)", durationSeconds: 60 * (index + 1), text: text))
        }
        return try PreparedBookShare.make(chapters: chapters, title: "The Machine Stops", author: "E. M. Forster", from: "Ana",
                                          note: "For the train", preview: nil, expiresInSeconds: 86400, listenerCap: listeners,
                                          client: .init(platform: "macos", appVersion: "synthetic"), limits: limits,
                                          directory: root.appendingPathComponent("staged-\(name)"))
    }

    func testTheKitClientMakesManagesAndRevokesABookOnTheRealService() async throws {
        let config = try await client.bookConfiguration()
        XCTAssertEqual(config.books, 1)
        XCTAssertEqual(config.book, ShareBookLimits(limits: .standard))
        let book = try await prepared()
        let (link, summary) = try await client.shareBook(book)
        let invitation = try XCTUnwrap(ShareInvitation(url: link))
        XCTAssertEqual(invitation.kind, .book)
        XCTAssertEqual(invitation.key, book.key)
        XCTAssertEqual(link.path, "/b/\(summary.share.id)")
        XCTAssertEqual(summary.share.status, .ready)
        XCTAssertEqual(summary.chapterCount, 3)
        XCTAssertTrue(summary.hasText)
        XCTAssertEqual(summary.share.playCap, 3, "the listener cap the sharer chose")
        let id = summary.share.id

        // The sharer's own view.
        let owned = try await client.book(id)
        XCTAssertEqual(owned.share.status, .ready)
        let listed = try await client.listBooks()
        XCTAssertEqual(listed.map(\.share.id), [id])
        let capped = try await client.setBookListeners(id, 4)
        XCTAssertEqual(capped.share.playCap, 4)
        let before = try XCTUnwrap(ShareDate.date(capped.share.expiresAt))
        let extended = try await client.extendBook(id, bySeconds: 86400)
        XCTAssertEqual(try XCTUnwrap(ShareDate.date(extended.share.expiresAt)).timeIntervalSince(before), 86400, accuracy: 1)

        // A listener's view: the details open under the key and match what was sealed.
        let details = listener("GET", "/v1/share/b/\(id)")
        XCTAssertEqual(details.status, 200)
        let publicBook = try JSONDecoder().decode(PublicBook.self, from: details.body)
        XCTAssertEqual(try publicBook.open(rootKey: book.key), book.manifest)
        XCTAssertNil(publicBook.preview, "private mode sends no preview")
        XCTAssertEqual(publicBook.remainingListeners, 4)
        XCTAssertThrowsError(try publicBook.open(rootKey: ShareCrypto.newKey()))
        let admitted = listener("POST", "/v1/share/b/\(id)/sessions")
        XCTAssertEqual(admitted.status, 201)
        let token = try JSONDecoder().decode(BookSession.self, from: admitted.body).token
        for chapter in book.manifest.chapters {
            let blob = listener("GET", "/v1/share/b/\(id)/blobs/\(chapter.id)", token: token)
            XCTAssertEqual(blob.status, 200)
            XCTAssertNoThrow(try book.manifest.openAudio(blob.body, chapterID: chapter.id, rootKey: book.key))
            if let text = chapter.text {
                let sealed = listener("GET", "/v1/share/b/\(id)/blobs/\(text.id)", token: token)
                XCTAssertEqual(try book.manifest.openText(sealed.body, chapterID: chapter.id, rootKey: book.key).segments.first?.text, "It begins.")
            }
        }

        // The same prepared book again is the same link, and no second book is made.
        let creates = bridge.requests().filter { $0 == "POST /v1/share/books" }.count
        let again = try await client.shareBook(book)
        XCTAssertEqual(again.link, link)
        let repeated = try await client.createBook(body: book.requestBody)
        XCTAssertEqual(repeated.id, id, "the service answers an identical create with the same book")
        XCTAssertEqual(bridge.requests().filter { $0 == "POST /v1/share/books" }.count, creates + 1)
        let stillOne = try await client.listBooks()
        XCTAssertEqual(stillOne.count, 1)

        // Revoked: the sharer sees revoked; every listener surface reads as expired.
        try await client.revokeBook(id)
        let revoked = try await client.book(id)
        XCTAssertEqual(revoked.share.status, .revoked)
        let surfaces = [
            listener("GET", "/v1/share/b/\(id)"),
            listener("POST", "/v1/share/b/\(id)/sessions"),
            listener("GET", "/v1/share/b/\(id)/blobs/\(book.manifest.chapters[0].id)", token: token),
            listener("HEAD", "/v1/share/b/\(id)/blobs/\(book.manifest.chapters[0].id)", token: token),
            listener("POST", "/v1/share/b/\(id)/events", body: Data("{\"type\":\"play_30s\"}".utf8), token: token),
            listener("POST", "/v1/share/b/\(id)/reactions", body: Data("{\"emoji\":\"❤️\"}".utf8), token: token),
        ]
        for response in surfaces {
            XCTAssertEqual(response.status, 410)
            XCTAssertEqual(code(response), "expired")
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("revoked"))
        }
        do { _ = try await client.shareBook(book); XCTFail("a revoked book was finished again") }
        catch { XCTAssertEqual((error as? ShareClient.Failure).flatMap(Self.code), "expired") }
    }

    func testALostCreateOrUploadResponseRetriesTheSameLink() async throws {
        for lost in ["/v1/share/books", "/blobs/", "/finalize"] {
            let book = try await prepared("lost-\(lost.count)")
            bridge.loseNext = lost == "/blobs/" ? book.blobs[1].id : lost
            do { _ = try await client.shareBook(book); XCTFail("the \(lost) response was lost") } catch {}
            // As the app does after a relaunch: from the staged folder alone.
            let reopened = try PreparedBookShare.load(from: book.directory)
            let (link, summary) = try await client.shareBook(reopened)
            XCTAssertEqual(summary.share.status, .ready, lost)
            XCTAssertEqual(ShareInvitation(url: link)?.key, book.key)
            let ids = try await client.listBooks().filter { $0.share.status == .ready }.map(\.share.id)
            XCTAssertEqual(ids.filter { $0 == summary.share.id }.count, 1, lost)
            try await client.revokeBook(summary.share.id)
        }
        let remaining = try await client.listBooks()
        XCTAssertEqual(remaining.filter { $0.share.status != .revoked }.count, 0, "no stray second link")
        XCTAssertEqual(remaining.count, 3, "one book for each attempt, however its response was lost")
    }

    func testAnExpiredBookReadsAsExpiredAndIsNeverFinishedLater() async throws {
        let ready = try await prepared("ready")
        let (_, made) = try await client.shareBook(ready)
        // Created, one blob sent, then left: the pending window ends it.
        let pending = try await prepared("pending")
        let created = try await client.createBook(body: pending.requestBody)
        try await client.uploadBookBlob(created.id, blob: pending.blobs[0], file: pending.file(pending.blobs[0].id))
        clock.advance(86400 + 1)
        // Every listener surface ends at once.
        XCTAssertEqual(code(listener("GET", "/v1/share/b/\(made.share.id)")), "expired")
        XCTAssertEqual(code(listener("POST", "/v1/share/b/\(made.share.id)/sessions")), "expired")
        XCTAssertEqual(code(listener("GET", "/v1/share/b/\(created.id)")), "expired")
        XCTAssertEqual(code(listener("POST", "/v1/share/b/\(created.id)/sessions")), "expired")
        // Before the sweep the owner summary still carries the stored status (as for songs and
        // mixtapes). The app's retry must learn the link ended anyway, so it discards the staged copy.
        var staged = try PreparedBookShare.load(from: pending.directory)
        staged.created = created
        try staged.save()
        do { _ = try await client.shareBook(staged); XCTFail("an expired book was finished") }
        catch { XCTAssertEqual((error as? ShareClient.Failure).flatMap(Self.code), "expired") }
        do { _ = try await client.extendBook(made.share.id, bySeconds: 86400); XCTFail("an expired book was extended") }
        catch { XCTAssertNotNil(error as? ShareClient.Failure) }
        try service.sweep()
        let ended = try await client.book(made.share.id)
        XCTAssertEqual(ended.share.status, .expired)
        let endedPending = try await client.book(created.id)
        XCTAssertEqual(endedPending.share.status, .expired)
        do { _ = try await client.shareBook(staged); XCTFail("an expired book was finished") }
        catch { XCTAssertEqual((error as? ShareClient.Failure).flatMap(Self.code), "expired") }
    }

    func testTheServiceTakesACreateBodyOfExactlyTheKitsCapAndRefusesOneByteMore() async throws {
        XCTAssertEqual(ShareService.maxBookCreateBodyBytes, ShareLimits.maxBookCreateBodyBytes)
        let book = try await prepared()
        let pad = { (count: Int) in book.requestBody + Data(repeating: 32, count: count - book.requestBody.count) }
        func post(_ body: Data) -> ShareResponse {
            service.handle(.init(method: "POST", path: "/v1/share/books", query: [:],
                                 headers: ["authorization": "Bearer " + owner, "user-agent": "Synthetic"], body: body))
        }
        XCTAssertEqual(post(pad(ShareLimits.maxBookCreateBodyBytes + 1)).status, 400)
        let atCap = post(pad(ShareLimits.maxBookCreateBodyBytes))
        XCTAssertEqual(atCap.status, 201, String(decoding: atCap.body, as: UTF8.self))
    }

    private static func code(_ failure: ShareClient.Failure) -> String? {
        if case let .service(_, code, _) = failure { return code }
        return nil
    }
}
