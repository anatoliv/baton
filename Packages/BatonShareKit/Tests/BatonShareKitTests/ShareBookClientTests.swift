@testable import BatonShareKit
import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A synthetic book service on a loopback port nothing listens on, answering through URLProtocol.
private final class BookPeer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((_ method: String, _ path: String, _ body: Data) -> (Int, Data))?
    nonisolated(unsafe) static var log: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == 9 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let method = request.httpMethod ?? "GET", path = request.url?.path ?? ""
        Self.log.append("\(method) \(path)")
        let (status, data) = Self.handler?(method, path, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ShareBookClientTests: XCTestCase {
    private var root: URL!
    private let base = URL(string: "http://127.0.0.1:9")!
    private let info = ShareClientInfo(platform: "macos", appVersion: "1.0 (1)")
    private let limits = ShareBookLimits(limits: .standard)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("book-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        BookPeer.handler = nil
        BookPeer.log = []
    }

    private func audio(_ bytes: Int, seed: UInt8) throws -> URL {
        let url = root.appendingPathComponent("chapter-\(seed).m4a")
        try Data((0 ..< bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }).write(to: url)
        return url
    }

    private func text(_ words: String) -> ShareBookText {
        ShareBookText(segments: [.init(text: words, paragraph: -1, start: 0, end: 1.5),
                                 .init(text: "And then more.", paragraph: 0, start: 1.5, end: 3)])
    }

    private func chapters() throws -> [PreparedBookShare.Chapter] {
        [.init(audio: try audio(10_000, seed: 1), title: "One", durationSeconds: 61, text: text("Chapter one.")),
         .init(audio: try audio(70_000, seed: 2), title: "Two", durationSeconds: 3600),
         .init(audio: try audio(5, seed: 3), title: "Three", durationSeconds: 1, text: text("Chapter three."))]
    }

    private func make(_ chapters: [PreparedBookShare.Chapter], limits: ShareBookLimits? = nil, preview: BookPreview? = nil,
                      directory: String = "staged", progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> PreparedBookShare {
        try PreparedBookShare.make(chapters: chapters, title: "The Machine Stops", author: "E. M. Forster", from: "Ana",
                              note: "For the train", preview: preview, expiresInSeconds: 604_800, listenerCap: 10,
                              client: info, limits: limits ?? self.limits,
                              directory: root.appendingPathComponent(directory), progress: progress)
    }

    private func sealedFiles(_ directory: String = "staged") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path)) ?? [])
            .filter { $0.hasSuffix(".sealed") }
    }

    // MARK: Sealing

    func testStagedFilesOpenWithTheirChapterAndTextKeysAndMatchTheManifest() throws {
        let input = try chapters()
        let calls = Counter()
        let book = try make(input, progress: { done, total in calls.add(done, total) })
        XCTAssertEqual(calls.values, [[1, 3], [2, 3], [3, 3]], "one chapter sealed at a time, in order")
        XCTAssertEqual(book.manifest.chapters.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(book.blobs.map(\.role), [.audio, .text, .audio, .audio, .text], "audio then its text, chapter by chapter")
        XCTAssertEqual(Set(sealedFiles()), Set(book.blobs.map { $0.id + ".sealed" }))
        XCTAssertEqual(Set(book.blobs.map(\.id)).count, 5, "every blob has its own random ID")
        XCTAssertTrue(book.blobs.allSatisfy { ShareBookCrypto.isCanonicalID($0.id) })
        for (position, chapter) in book.manifest.chapters.enumerated() {
            let sealed = try Data(contentsOf: book.file(chapter.id))
            XCTAssertEqual(sealed.count, chapter.audioBytes)
            XCTAssertEqual(ShareHash.sha256Hex(sealed), chapter.audioSHA256)
            XCTAssertEqual(try book.manifest.openAudio(sealed, chapterID: chapter.id, rootKey: book.key),
                           try Data(contentsOf: input[position].audio))
            if let text = chapter.text {
                let sealedText = try Data(contentsOf: book.file(text.id))
                XCTAssertEqual(try book.manifest.openText(sealedText, chapterID: chapter.id, rootKey: book.key), input[position].text)
                XCTAssertThrowsError(try ShareCrypto.open(sealedText, key: ShareBookCrypto.chapterKey(rootKey: book.key, chapterID: chapter.id),
                                                          purpose: .audio), "text never opens as audio")
            } else {
                XCTAssertNil(input[position].text)
            }
        }
        // Text bound to chapter 1 does not open as chapter 3's.
        let first = book.manifest.chapters[0], third = book.manifest.chapters[2]
        let firstText = try Data(contentsOf: book.file(first.text!.id))
        XCTAssertThrowsError(try ShareCrypto.open(firstText, key: ShareBookCrypto.textKey(rootKey: book.key, chapterID: third.id), purpose: .meta))
        // Private staging: the folder and every file are this user's alone.
        let folder = try FileManager.default.attributesOfItem(atPath: book.directory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for name in sealedFiles() + [PreparedBookShare.ticketName] {
            let attributes = try FileManager.default.attributesOfItem(atPath: book.directory.appendingPathComponent(name).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, name)
        }
    }

    func testTheRequestValidatesAgainstTheAdvertisedLimitsAndCarriesNoPlaintextInPrivateMode() throws {
        let book = try make(try chapters())
        let decoded = try JSONDecoder().decode(CreateBookRequest.self, from: book.requestBody)
        XCTAssertEqual(decoded, book.request)
        XCTAssertNoThrow(try decoded.validated(limits: limits.applied()))
        XCTAssertEqual(decoded.blobs, book.manifest.blobs)
        XCTAssertEqual(decoded.chapterCount, 3)
        XCTAssertEqual(decoded.totalDurationSeconds, 61 + 3600 + 1)
        XCTAssertEqual(decoded.listenerCap, 10)
        XCTAssertNil(decoded.preview)
        let manifest = try ShareBookManifest.open(Data(base64Encoded: decoded.encryptedManifest)!, rootKey: book.key)
        XCTAssertEqual(manifest, book.manifest)
        let body = String(decoding: book.requestBody, as: UTF8.self)
        for secret in ["Machine", "Forster", "Ana", "train", "One", "Chapter one"] {
            XCTAssertFalse(body.contains(secret), "\(secret) travels only inside the encryption")
        }
        let open = try make(try chapters(), preview: BookPreview(title: "The Machine Stops", author: "E. M. Forster", from: "Ana"),
                            directory: "public")
        XCTAssertEqual(open.request.preview?.author, "E. M. Forster")
    }

    func testAReloadedTicketIsTheSameLinkWithAnIdenticalBody() throws {
        var book = try make(try chapters())
        book.created = CreateBookResponse(id: "AAAAAAAAAAAAAAAAAAAAAA", url: "http://127.0.0.1:9/b/AAAAAAAAAAAAAAAAAAAAAA",
                                          expiresAt: ShareDate.string(Date() + 3600), uploads: [:])
        book.uploaded = [book.blobs[0].id]
        try book.save()
        let again = try PreparedBookShare.load(from: book.directory)
        XCTAssertEqual(again.requestBody, book.requestBody)
        XCTAssertEqual(again.request.requestID, book.request.requestID)
        XCTAssertEqual(again.key, book.key)
        XCTAssertEqual(again.blobs, book.blobs)
        XCTAssertEqual(again.created, book.created)
        XCTAssertEqual(again.uploaded, [book.blobs[0].id])
        // A damaged staged file is refused rather than uploaded.
        try Data([1, 2, 3]).write(to: book.file(book.blobs[1].id))
        XCTAssertThrowsError(try PreparedBookShare.load(from: book.directory)) { XCTAssertEqual($0 as? PreparedBookShare.Failure, .damaged) }
        // A second book never takes over a folder that holds one.
        XCTAssertThrowsError(try make(try chapters())) { XCTAssertEqual($0 as? PreparedBookShare.Failure, .directoryInUse) }
    }

    func testCapsRefuseBeforeAnyChapterIsSealed() throws {
        let input = try chapters()
        let calls = Counter()
        var small = limits
        small.maxBookBytes = 70_000
        XCTAssertThrowsError(try make(input, limits: small, directory: "book", progress: { calls.add($0, $1) })) {
            XCTAssertEqual($0 as? PreparedBookShare.Failure, .bookTooLarge)
        }
        var chapterCap = limits
        chapterCap.maxChapterBytes = 20_000
        XCTAssertThrowsError(try make(input, limits: chapterCap, directory: "chapter", progress: { calls.add($0, $1) })) {
            XCTAssertEqual($0 as? PreparedBookShare.Failure, .chapterTooLarge(chapter: 2))
        }
        var textCap = limits
        textCap.maxTextBytes = 40
        XCTAssertThrowsError(try make(input, limits: textCap, directory: "text", progress: { calls.add($0, $1) })) {
            XCTAssertEqual($0 as? PreparedBookShare.Failure, .textTooLarge(chapter: 1))
        }
        var count = limits
        count.maxChapters = 2
        XCTAssertThrowsError(try make(input, limits: count, directory: "count")) {
            XCTAssertEqual($0 as? PreparedBookShare.Failure, .tooManyChapters(max: 2))
        }
        var length = limits
        length.maxBookSeconds = 3000
        XCTAssertThrowsError(try make(input, limits: length, directory: "length")) {
            XCTAssertEqual($0 as? PreparedBookShare.Failure, .tooLong)
        }
        var manifest = limits
        manifest.maxManifestBytes = 100
        XCTAssertThrowsError(try make(input, limits: manifest, directory: "manifest")) {
            XCTAssertEqual($0 as? PreparedBookShare.Failure, .manifestTooLarge)
        }
        XCTAssertEqual(calls.values, [], "nothing was sealed for a book that does not fit")
        for folder in ["book", "chapter", "text", "count", "length", "manifest"] {
            XCTAssertEqual(sealedFiles(folder), [], folder)
        }
    }

    // MARK: Links and the ledger

    func testInvitationsRoundTripForSongsMixtapesAndBooks() throws {
        let id = Base64URL.encode(Data(repeating: 7, count: 16)), key = Data(repeating: 9, count: 16)
        let fragment = Base64URL.encode(key)
        let expected: [(ShareInvitation.Kind, String)] = [(.song, "s"), (.mixtape, "m"), (.book, "b")]
        for (kind, letter) in expected {
            let invitation = ShareInvitation(id: id, key: key, kind: kind)
            XCTAssertEqual(invitation.url().absoluteString, "https://batonmusic.app/\(letter)/\(id)#\(fragment)")
            XCTAssertEqual(ShareInvitation(url: invitation.url()), invitation)
            XCTAssertEqual(ShareInvitation(url: URL(string: "https://baton.tonebox.io/\(letter)/\(id)#\(fragment)")!)?.kind, kind)
        }
        XCTAssertEqual(ShareInvitation(id: id, key: key, kind: .song).browserURL.absoluteString,
                       "https://batonmusic.app/s/\(id)?web=1#\(fragment)", "the song form is unchanged")
        XCTAssertEqual(ShareInvitation(id: id, key: key, kind: .mixtape).browserURL.absoluteString,
                       "https://batonmusic.app/m/\(id)?web=1#\(fragment)", "the mixtape form is unchanged")
        XCTAssertEqual(ShareInvitation(id: id, key: key, kind: .book).browserURL.absoluteString,
                       "https://batonmusic.app/b/\(id)#\(fragment)")
        XCTAssertEqual(ShareInvitation(url: URL(string: "baton://share/\(id)#\(fragment)")!)?.kind, .song)
        XCTAssertEqual(ShareInvitation(url: URL(string: "baton://mixtape/\(id)#\(fragment)")!)?.kind, .mixtape)
        XCTAssertNil(ShareInvitation(url: URL(string: "baton://book/\(id)#\(fragment)")!), "no native book receiver")
        XCTAssertNil(ShareInvitation(url: URL(string: "https://batonmusic.app/x/\(id)#\(fragment)")!))
        XCTAssertNil(ShareInvitation(url: URL(string: "https://batonmusic.app/b/\(id)?web=1#\(fragment)")!))
    }

    private func bookSummary(_ id: String, status: ShareStatus, listeners: Int = 0, expires: Date) -> BookSummary {
        var stats = ShareStats()
        stats.fetches = listeners
        return BookSummary(share: ShareSummary(id: id, status: status, createdAt: ShareDate.string(Date()),
                                               expiresAt: ShareDate.string(expires), playCap: 10, preview: nil,
                                               stats: stats, reactions: []),
                           chapterCount: 30, hasText: true)
    }

    private func record(_ id: String, kind: ShareInvitation.Kind, expires: TimeInterval = 86400) -> ShareLedger.Record {
        ShareLedger.Record(id: id, link: "https://batonmusic.app/\(kind == .book ? "b" : kind == .mixtape ? "m" : "s")/\(id)#k",
                           songID: "", title: "T\(id)", artist: "A", isPrivate: true, createdAt: Date(),
                           expiresAt: Date() + expires, kind: kind)
    }

    func testLedgerMergesBooksFromTheirOwnListOnly() throws {
        var ledger = ShareLedger()
        ledger.add(record("same", kind: .song))
        ledger.add(record("same", kind: .mixtape))
        ledger.add(record("same", kind: .book))
        ledger.add(record("ended", kind: .book, expires: -60))
        ledger.add(record("live", kind: .book))
        let later = Date(timeIntervalSince1970: 2_000_000_000)
        ledger.mergeBooks([bookSummary("same", status: .ready, listeners: 4, expires: later)])
        XCTAssertEqual(ledger.records.map(\.identity).sorted(), ["book:live", "book:same", "mixtape:same", "song:same"],
                       "an ended book the service no longer lists is dropped; a live one is kept")
        let book = try XCTUnwrap(ledger.records.first { $0.identity == "book:same" })
        XCTAssertEqual(book.bookSummary?.share.stats.fetches, 4)
        XCTAssertEqual(book.bookSummary?.chapterCount, 30)
        XCTAssertEqual(book.expiresAt, later)
        XCTAssertNil(ledger.records.first { $0.identity == "song:same" }?.summary, "a song with the same ID is untouched")
        XCTAssertNil(ledger.records.first { $0.identity == "mixtape:same" }?.summary)
        // A song or mixtape list never touches a book.
        ledger.merge([])
        ledger.mergeMixtapes([])
        XCTAssertNotNil(ledger.records.first { $0.identity == "book:same" }?.bookSummary)
        ledger.updateBook(bookSummary("same", status: .revoked, expires: later))
        XCTAssertEqual(ledger.records.first { $0.identity == "book:same" }?.status, .revoked)
        let url = root.appendingPathComponent("ledger.json")
        try ledger.save(to: url)
        XCTAssertEqual(ShareLedger.load(from: url), ledger)
        ledger.remove(id: "same", kind: .book)
        XCTAssertEqual(ledger.records.filter { $0.id == "same" }.count, 2)
    }

    // MARK: The service

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookPeer.self]
        return URLSession(configuration: configuration)
    }

    private func config(books: Bool = true) throws -> Data {
        var config = ShareConfig(enabled: true, limits: .standard)
        config.mixtapes = 1
        if books { config.books = 1; config.book = limits }
        return try JSONEncoder().encode(config)
    }

    private let bookID = Base64URL.encode(Data(repeating: 5, count: 16))

    private func created(for request: CreateBookRequest, url: String? = nil, uploads: [String: String]? = nil) throws -> Data {
        try JSONEncoder().encode(CreateBookResponse(
            id: bookID, url: url ?? "http://127.0.0.1:9/b/\(bookID)", expiresAt: ShareDate.string(Date() + 604_800),
            uploads: uploads ?? Dictionary(uniqueKeysWithValues: request.blobs.keys.map { ($0, "/v1/share/books/\(bookID)/blobs/\($0)") })))
    }

    func testCreateRefusesAForeignOriginAWrongPathAndAMissingOrExtraUpload() async throws {
        let book = try make(try chapters())
        let client = ShareClient(base: base, secret: "synthetic-installation", session: session())
        let good = Dictionary(uniqueKeysWithValues: book.request.blobs.keys.map { ($0, "/v1/share/books/\(bookID)/blobs/\($0)") })
        var missing = good; missing.removeValue(forKey: missing.keys.first!)
        var extra = good; extra[ShareBookCrypto.newID()] = "/v1/share/books/\(bookID)/blobs/x"
        var elsewhere = good; elsewhere[elsewhere.keys.first!] = "/v1/share/mixtapes/\(bookID)/tracks/\(elsewhere.keys.first!)"
        let cases: [(String, Data)] = [
            ("foreign origin", try created(for: book.request, url: "https://evil.invalid/b/\(bookID)")),
            ("another port", try created(for: book.request, url: "http://127.0.0.1:10/b/\(bookID)")),
            ("mixtape path", try created(for: book.request, url: "http://127.0.0.1:9/m/\(bookID)")),
            ("query", try created(for: book.request, url: "http://127.0.0.1:9/b/\(bookID)?x=1")),
            ("fragment", try created(for: book.request, url: "http://127.0.0.1:9/b/\(bookID)#key")),
            ("missing upload", try created(for: book.request, uploads: missing)),
            ("extra upload", try created(for: book.request, uploads: extra)),
            ("upload elsewhere", try created(for: book.request, uploads: elsewhere)),
        ]
        for (name, answer) in cases {
            BookPeer.handler = { _, _, _ in (201, answer) }
            do { _ = try await client.createBook(body: book.requestBody); XCTFail("\(name) was accepted") }
            catch { XCTAssertEqual(error as? ShareClient.Failure, .unexpected(0), name) }
        }
        let answer = try created(for: book.request)
        BookPeer.handler = { method, path, body in
            method == "POST" && path == "/v1/share/books" && body == book.requestBody ? (201, answer) : (400, Data())
        }
        let result = try await client.createBook(body: book.requestBody)
        XCTAssertEqual(result.id, bookID)
    }

    func testTheCreateBodyCapIsTheOneTheServiceUses() async throws {
        XCTAssertEqual(PreparedBookShare.maximumRequestBytes, ShareLimits.maxBookCreateBodyBytes)
        XCTAssertEqual(ShareLimits.maxBookCreateBodyBytes, 524_288)
        let book = try make(try chapters())
        let answer = try created(for: book.request)
        BookPeer.handler = { _, _, _ in (201, answer) }
        let client = ShareClient(base: base, secret: "synthetic-installation", session: session())
        // Trailing spaces keep the JSON valid, so only the size differs.
        let pad = { (count: Int) in book.requestBody + Data(repeating: 32, count: count - book.requestBody.count) }
        let atCap = try await client.createBook(body: pad(ShareLimits.maxBookCreateBodyBytes))
        XCTAssertEqual(atCap.id, bookID)
        XCTAssertEqual(BookPeer.log, ["POST /v1/share/books"], "a body of exactly the cap is sent")
        do { _ = try await client.createBook(body: pad(ShareLimits.maxBookCreateBodyBytes + 1)); XCTFail("over the cap was sent") }
        catch { XCTAssertEqual(error as? ShareClient.Failure, .unexpected(0)) }
        XCTAssertEqual(BookPeer.log.count, 1, "a body one byte over the cap never leaves the device")
    }

    /// Book service state for the end-to-end driver tests.
    private final class FakeBooks: @unchecked Sendable {
        var creates = [Data]()
        var stored = [String: Data]()
        var finalized = false
        var failPutAfter: Int?
        var puts = 0
    }

    private func serve(_ fake: FakeBooks, book: PreparedBookShare) throws {
        let config = try config(), answer = try created(for: book.request), id = bookID, limits = limits
        let summary: @Sendable (ShareStatus) -> Data = { status in
            try! JSONEncoder().encode(BookSummary(share: ShareSummary(
                id: id, status: status, createdAt: ShareDate.string(Date()), expiresAt: ShareDate.string(Date() + 604_800),
                playCap: limits.defaultListeners, preview: nil, stats: ShareStats(), reactions: []),
                chapterCount: book.manifest.chapters.count, hasText: true))
        }
        BookPeer.handler = { method, path, body in
            switch (method, path) {
            case ("GET", "/v1/share/config"): return (200, config)
            case ("POST", "/v1/share/books"):
                fake.creates.append(body)
                return body == book.requestBody ? (201, answer) : (409, Data())
            case ("GET", "/v1/share/books/\(id)"): return (200, summary(fake.finalized ? .ready : .pending))
            case ("POST", "/v1/share/books/\(id)/finalize"):
                guard Set(fake.stored.keys) == Set(book.request.blobs.keys) else { return (409, Data(#"{"error":"x","code":"incomplete"}"#.utf8)) }
                fake.finalized = true
                return (200, summary(.ready))
            case let ("PUT", put) where put.hasPrefix("/v1/share/books/\(id)/blobs/"):
                fake.puts += 1
                if let limit = fake.failPutAfter, fake.puts > limit { return (503, Data(#"{"error":"x","code":"busy"}"#.utf8)) }
                let blob = String(put.split(separator: "/").last!)
                guard let descriptor = book.request.blobs[blob], descriptor.bytes == body.count,
                      ShareHash.sha256Hex(body) == descriptor.sha256 else { return (422, Data()) }
                fake.stored[blob] = body
                return (200, Data(#"{"stored":true}"#.utf8))
            default: return (404, Data())
            }
        }
    }

    func testShareBookUploadsEveryBlobOnceAndAFailedUploadRetriesTheSameLink() async throws {
        let book = try make(try chapters())
        let fake = FakeBooks()
        fake.failPutAfter = 2
        try serve(fake, book: book)
        let client = ShareClient(base: base, secret: "synthetic-installation", session: session())
        do { _ = try await client.shareBook(book); XCTFail("the third upload should fail") }
        catch { XCTAssertEqual(error as? ShareClient.Failure, .service(status: 503, code: "busy", message: "Book request unavailable.")) }
        let interrupted = try PreparedBookShare.load(from: book.directory)
        XCTAssertEqual(interrupted.created?.id, bookID, "the create is kept with the staged book")
        XCTAssertEqual(interrupted.uploaded, Set(book.blobs.prefix(2).map(\.id)))

        fake.failPutAfter = nil
        let fractions = Counter()
        let (link, summary) = try await client.shareBook(book, progress: { fractions.add(Int($0 * 1000), 0) })
        XCTAssertEqual(fake.creates, [book.requestBody], "the retry made no second link")
        XCTAssertEqual(fake.puts, 3 + book.blobs.count - 2, "acknowledged blobs are not sent again")
        XCTAssertEqual(summary.share.status, .ready)
        XCTAssertEqual(link, ShareInvitation(id: bookID, key: book.key, kind: .book).url(base: base))
        XCTAssertEqual(link.path, "/b/\(bookID)")
        XCTAssertEqual(fractions.values.last, [1000, 0])
        for blob in book.blobs { XCTAssertEqual(fake.stored[blob.id], try Data(contentsOf: book.file(blob.id))) }
        XCTAssertTrue(BookPeer.log.allSatisfy { $0.hasPrefix("GET /v1/share/config") || $0.contains("/v1/share/books") })
    }

    func testAnUncertainCreateIsResentWithTheIdenticalBody() async throws {
        let book = try make(try chapters())
        let fake = FakeBooks()
        try serve(fake, book: book)
        let serving = BookPeer.handler!
        var first = true
        BookPeer.handler = { method, path, body in
            if method == "POST", path == "/v1/share/books", first { first = false; fake.creates.append(body); return (502, Data()) }
            return serving(method, path, body)
        }
        let client = ShareClient(base: base, secret: "synthetic-installation", session: session())
        do { _ = try await client.shareBook(book); XCTFail("the first create was lost") } catch {}
        _ = try await client.shareBook(book)
        XCTAssertEqual(fake.creates, [book.requestBody, book.requestBody])
        XCTAssertEqual(try JSONDecoder().decode(CreateBookRequest.self, from: fake.creates[1]).requestID, book.request.requestID)
    }

    func testAServiceThatDoesNotAdvertiseBooksIsNeverAskedToMakeOne() async throws {
        let book = try make(try chapters())
        let config = try config(books: false)
        BookPeer.handler = { method, path, _ in method == "GET" && path == "/v1/share/config" ? (200, config) : (500, Data()) }
        let client = ShareClient(base: base, secret: "synthetic-installation", session: session())
        do { _ = try await client.shareBook(book); XCTFail("an unadvertised service took a book") }
        catch { XCTAssertEqual((error as? ShareClient.Failure).map { if case let .service(_, code, _) = $0 { code } else { "" } }, "unsupported") }
        XCTAssertEqual(BookPeer.log, ["GET /v1/share/config"])
    }

    func testAnUploadRefusesAStagedFileThatNoLongerMatches() async throws {
        let book = try make(try chapters())
        try Data(repeating: 0, count: book.blobs[0].bytes).write(to: book.file(book.blobs[0].id))
        BookPeer.handler = { _, _, _ in (200, Data("{}".utf8)) }
        let client = ShareClient(base: base, secret: "synthetic-installation", session: session())
        do { try await client.uploadBookBlob(bookID, blob: book.blobs[0], file: book.file(book.blobs[0].id)); XCTFail() }
        catch { XCTAssertEqual(error as? ShareClient.Failure, .unexpected(0)) }
        XCTAssertEqual(BookPeer.log, [], "nothing was sent")
    }

    // MARK: Planning

    func testWholeBookPlanningNamesMissingChaptersAndTheCaps() {
        let chapters = (0 ..< 30).map { ShareBookPlan.Chapter(index: $0, title: "C\($0)", durationSeconds: 1200, bytes: 7_200_000) }
        guard case let .success(whole) = ShareBookPlan.checkWholeBook(chapters, chapterCount: 30, limits: limits) else {
            return XCTFail("a 10-hour book in 30 chapters fits a book link")
        }
        XCTAssertEqual(whole.chapters, 30)
        XCTAssertEqual(whole.seconds, 36_000)
        XCTAssertEqual(whole.line(limits: limits), "30 chapters · 10 h 0 m · 206 MB. A book link holds up to 200 chapters and 256 MB.")
        XCTAssertEqual(ShareBookPlan.wholeBookChapterTitle(.init(index: 4, title: " \t", durationSeconds: 1, bytes: 1)), "Chapter 5")
        XCTAssertEqual(ShareBookPlan.wholeBookChapterTitle(.init(index: 4, title: "The\nSurface", durationSeconds: 1, bytes: 1)), "The Surface")
        XCTAssertEqual(ShareBookPlan.bookTitle("  "), "A book")
        XCTAssertEqual(ShareBookPlan.bookTitle(String(repeating: "a", count: 300)).unicodeScalars.count, ShareLimits.maxTitleLength)
        XCTAssertTrue(ShareBookPlan.prefersWholeBook(chapters, chapterCount: 30, limits: .standard, bookLimits: limits))
        XCTAssertFalse(ShareBookPlan.prefersWholeBook(chapters, chapterCount: 30, limits: .standard, bookLimits: nil),
                       "nothing new without the service's advertisement")
        let short = Array(chapters.prefix(1)).map { ShareBookPlan.Chapter(index: $0.index, title: $0.title, durationSeconds: 600, bytes: 100) }
        XCTAssertFalse(ShareBookPlan.prefersWholeBook(short, chapterCount: 1, limits: .standard, bookLimits: limits),
                       "a book that fits Phase 1 keeps it")
        var gapped = chapters
        gapped.remove(at: 7); gapped.remove(at: 2)
        XCTAssertEqual(ShareBookPlan.checkWholeBook(gapped, chapterCount: 30, limits: limits), .failure(.missingChapters([3, 8])))
        XCTAssertFalse(ShareBookPlan.prefersWholeBook(gapped, chapterCount: 30, limits: .standard, bookLimits: limits))
        XCTAssertTrue(ShareBookPlan.WholeBookRefusal.missingChapters([3, 9]).message.hasPrefix("Chapters 3 and 9 aren't on this device."))
        XCTAssertTrue(ShareBookPlan.WholeBookRefusal.missingChapters([4]).message.hasPrefix("Chapter 4 isn't on this device."))
        XCTAssertTrue(ShareBookPlan.WholeBookRefusal.missingChapters(Array(1 ... 8)).message.hasPrefix("Chapters 1, 2, 3, 4, 5 and 3 more"))
        var big = chapters
        big[4].bytes = 30_000_000
        XCTAssertEqual(ShareBookPlan.checkWholeBook(big, chapterCount: 30, limits: limits),
                       .failure(.chapterTooLarge(5, maxBytes: limits.maxChapterBytes)))
        let many = (0 ..< 201).map { ShareBookPlan.Chapter(index: $0, title: "", durationSeconds: 1, bytes: 1) }
        XCTAssertEqual(ShareBookPlan.checkWholeBook(many, chapterCount: 201, limits: limits), .failure(.tooManyChapters(max: 200)))
        let huge = (0 ..< 12).map { ShareBookPlan.Chapter(index: $0, title: "", durationSeconds: 3600, bytes: 25_000_000) }
        XCTAssertEqual(ShareBookPlan.checkWholeBook(huge, chapterCount: 12, limits: limits),
                       .failure(.tooLarge(bytes: 12 * ShareCrypto.sealedLength(plaintextLength: 25_000_000), maxBytes: limits.maxBookBytes)))
    }

    func testReadAlongTextIsMadeOneTheFormatAccepts() throws {
        let long = String(repeating: "é", count: ShareBookText.maxSegmentLength + 10)
        let text = try XCTUnwrap(ShareBookPlan.readAlongText([
            .init(text: "Heading", paragraph: -3, start: 0, end: 1),
            .init(text: "   ", paragraph: 0, start: 1, end: 2),
            .init(text: "Backwards", paragraph: 0, start: 5, end: 4),
            .init(text: "Nowhere", paragraph: 0, start: .nan, end: 1),
            .init(text: long, paragraph: 1, start: 6, end: .infinity),
        ]))
        XCTAssertEqual(text.segments.map(\.paragraph), [-1, 0, 1])
        XCTAssertEqual(text.segments[1].end, 5)
        XCTAssertEqual(text.segments[2].text.unicodeScalars.count, ShareBookText.maxSegmentLength)
        XCTAssertEqual(text.segments[2].end, 6)
        XCTAssertNoThrow(try text.encoded())
        XCTAssertNil(ShareBookPlan.readAlongText([]))
    }
}

/// Collects callback values from a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [[Int]]()
    func add(_ a: Int, _ b: Int) { lock.lock(); stored.append([a, b]); lock.unlock() }
    var values: [[Int]] { lock.lock(); defer { lock.unlock() }; return stored }
}
