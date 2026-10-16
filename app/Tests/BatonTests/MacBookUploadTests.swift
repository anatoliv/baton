import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// TBX-11017: a book made with this Mac's own voices goes to the Baton server, so the iPhone
/// adopts it through the TBX-10985 path. The renderer and encoder are the real ones (as in
/// `DocumentLibraryTests`); the Baton server is a fake that keeps what it is sent with the
/// gateway's rules (`BookRoutes.receiveBook`, `receiveChapter`, `receiveTiming`): the id is the
/// book's content, a chapter is kept only when its digest matches, and an uploaded job's chapters
/// are ready only once their audio has arrived.
@MainActor
final class MacBookUploadTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-uploads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The Baton server, keeping uploaded books as the gateway does.
    final class FakeBatonServer: @unchecked Sendable {
        private let lock = NSLock()
        private var jobs: [String: BookJob] = [:]
        private var audio: [String: [Int: Data]] = [:]
        private var timing: [String: [Int: ReadAlongTiming]] = [:]
        private var requests: [String] = []
        private var _away = false
        private var _older = false

        /// Every request fails to connect, as when the Baton server is off.
        var away: Bool {
            get { lock.withLock { _away } }
            set { lock.withLock { _away = newValue } }
        }

        /// A gateway from before TBX-11017: `PUT …/upload` reads as a bad book id.
        var older: Bool {
            get { lock.withLock { _older } }
            set { lock.withLock { _older = newValue } }
        }

        var seen: [String] { lock.withLock { requests } }
        func job(_ id: String) -> BookJob? { lock.withLock { jobs[id] } }
        func chapter(_ id: String, _ index: Int) -> Data? { lock.withLock { audio[id]?[index] } }
        func timing(_ id: String, _ index: Int) -> ReadAlongTiming? { lock.withLock { timing[id]?[index] } }
        var ids: [String] { lock.withLock { Array(jobs.keys) } }

        /// The iPhone's Delete Everywhere, or the keep date passing.
        func remove(_ id: String) { lock.withLock { jobs[id] = nil } }

        func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            try lock.withLock {
                let method = request.httpMethod ?? "GET"
                let path = request.url!.path
                if _away { throw URLError(.cannotConnectToHost) }
                requests.append("\(method) \(path)")
                func reply(_ status: Int, _ body: Data = Data()) -> (Data, HTTPURLResponse) {
                    (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
                }
                func summary(_ job: BookJob, _ status: Int = 200) -> (Data, HTTPURLResponse) {
                    reply(status, try! BookJSON.encoder.encode(job.summary))
                }
                let parts = path.split(separator: "/").map(String.init)   // v1 books {id} ...
                if method == "GET", parts == ["v1", "books"] {
                    let books = jobs.values.sorted { $0.createdAt > $1.createdAt }.map {
                        try! JSONSerialization.jsonObject(with: BookJSON.encoder.encode($0.summary))
                    }
                    let body: [String: Any] = ["available": true, "books": books, "used_bytes": 0,
                                               "maximum_bytes": 4_294_967_296, "keep_finished_days": 30]
                    return reply(200, try! JSONSerialization.data(withJSONObject: body))
                }
                guard parts.count >= 3 else { return reply(404) }
                let id = parts[2]
                switch (method, Array(parts.dropFirst(3))) {
                case ("PUT", ["upload"]):
                    if _older { return reply(400, Data(#"{"error":"bad book id"}"#.utf8)) }
                    let book = try PreparedBook.decode(request.httpBody ?? Data())
                    guard BookJob.id(for: book) == id else { return reply(400) }
                    if let existing = jobs[id] { return summary(existing) }
                    var job = BookJob(id: id, book: book)
                    job.uploaded = true
                    jobs[id] = job
                    return summary(job, 201)
                case let ("PUT", rest) where rest.count == 3 && rest[0] == "chapters" && rest[2] == "timing":
                    guard jobs[id]?.uploaded == true, let n = Int(rest[1]) else { return reply(404) }
                    guard let decoded = ReadAlongTiming.decode(request.httpBody ?? Data()) else { return reply(400) }
                    timing[id, default: [:]][n - 1] = decoded
                    return reply(200, Data(#"{"ok":true}"#.utf8))
                case let ("PUT", rest) where rest.count == 2 && rest[0] == "chapters":
                    guard var job = jobs[id], job.uploaded == true, let n = Int(rest[1]), job.chapters.indices.contains(n - 1)
                    else { return reply(404) }
                    let body = request.httpBody ?? Data()
                    let sha = SHA256Digest.hex(of: body)
                    guard request.value(forHTTPHeaderField: "X-Baton-SHA256") == sha,
                          let seconds = request.value(forHTTPHeaderField: "X-Baton-Duration").flatMap(Double.init)
                    else { return reply(422) }
                    audio[id, default: [:]][n - 1] = body
                    job.chapters[n - 1] = .ready(file: "chapter-\(n).m4a", bytes: body.count, seconds: seconds, sha256: sha)
                    job.status = job.readyChapters == job.chapters.count ? .ready : .rendering
                    jobs[id] = job
                    return summary(job)
                case ("GET", []):
                    guard let job = jobs[id] else { return reply(404) }
                    return summary(job)
                case ("GET", ["book"]):
                    guard let job = jobs[id] else { return reply(404) }
                    return reply(200, try job.book.encoded())
                case ("POST", ["finished"]):
                    guard var job = jobs[id] else { return reply(404) }
                    job.finishedAt = Date()
                    jobs[id] = job
                    return reply(200)
                case ("DELETE", []):
                    jobs[id] = nil
                    return reply(200)
                default:
                    return reply(404)
                }
            }
        }
    }

    private func book(_ name: String = "the-machine-stops") throws -> PreparedBook {
        let url = root.appendingPathComponent("\(name).md")
        try """
        # The Machine Stops

        ## The Air-Ship

        Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee. It is lighted \
        neither by window nor by lamp, yet it is filled with a soft radiance.

        ## The Mending Apparatus

        He went up to the surface. The stairway was long, and the light at the top was grey.
        """.write(to: url, atomically: true, encoding: .utf8)
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:af_heart"))
    }

    private func clippingStore() -> ClippingStore {
        ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("uploads"))
    }

    /// A Mac library over `Books`, with or without a Baton server set up.
    private func library(_ server: FakeBatonServer?, clippings: ClippingStore) -> DocumentLibrary {
        DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                        synthesizer: DocumentLibraryTests.FakeKokoro(), retry: .init(initialDelay: 0.02, maximumDelay: 0.05),
                        refreshInterval: .milliseconds(50), storageDefaults: ThrowawayDefaults.make("uploads-storage"),
                        uploadRetry: .init(initial: .milliseconds(50), maximum: .milliseconds(200)),
                        gateway: {
                            server.map { s in GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { try s.answer($0) } }
                        })
    }

    private func eventually(_ library: DocumentLibrary, timeout: TimeInterval = 20, _ what: String = "",
                            _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            library.refresh()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out: \(what)")
    }

    private func puts(_ server: FakeBatonServer) -> [String] { server.seen.filter { $0.hasPrefix("PUT") } }

    /// The owner's report: a book made with the Mac's own voices reaches the Baton server with
    /// every chapter, its digest and its read-along timing, listed under its document, so the
    /// iPhone adopts it. Each part goes once; the Mac neither keeps a record of having "sent" it
    /// in TBX-10985's sense nor adopts its own book back from the listing.
    func testABookMadeOnThisMacGoesToTheBatonServerChapterByChapterOnce() async throws {
        let server = FakeBatonServer()
        let clippings = clippingStore()
        let library = library(server, clippings: clippings)
        library.start(force: true)
        defer { library.stop() }
        let book = try book()
        let id = try await library.submit(book)

        try await eventually(library, "every chapter on the Baton server") {
            server.job(id)?.status == .ready && library.uploads.entry(forJob: id)?.done == true
        }
        let chapters = clippings.chapters(ofDocument: book.documentID)
        XCTAssertEqual(chapters.count, book.chapters.count)
        let job = try XCTUnwrap(server.job(id))
        XCTAssertEqual(job.uploaded, true)
        XCTAssertEqual(job.summary.documentID, book.documentID, "listed under its document, for the iPhone to adopt")
        for item in chapters {
            let index = try XCTUnwrap(item.clipping.chapterIndex)
            XCTAssertEqual(job.summary.chapters[index].sha256, item.clipping.sha256, "chapter \(index + 1): the audio this Mac made")
            XCTAssertEqual(server.chapter(id, index).map { SHA256Digest.hex(of: $0) }, item.clipping.sha256)
            XCTAssertEqual(server.timing(id, index), library.homeServer.readAlong.load(forAudio: item.clipping.sha256),
                           "chapter \(index + 1) keeps its read-along timing")
            XCTAssertNotNil(server.timing(id, index))
        }
        XCTAssertEqual(puts(server).filter { $0.hasSuffix("/upload") }, ["PUT /v1/books/\(id)/upload"])
        for n in 1...book.chapters.count {
            XCTAssertEqual(puts(server).filter { $0 == "PUT /v1/books/\(id)/chapters/\(n)" }.count, 1, "chapter \(n) once")
        }

        // Not "sent from this device", and never adopted back: one book here, made on this Mac.
        await library.refreshHomeServer()
        XCTAssertEqual(library.homeServer.records, [])
        XCTAssertFalse(server.seen.contains("GET /v1/books/\(id)/book"), "the Mac does not adopt its own book")
        XCTAssertEqual(library.jobs.map(\.renderer), [.thisMac])

        // Asked again (Baton to the front, a relaunch): nothing goes twice.
        let before = puts(server).count
        library.uploads.kick(force: true)
        await library.uploads.sendNow()
        let relaunched = self.library(server, clippings: clippings)
        relaunched.start(force: true)
        defer { relaunched.stop() }
        await relaunched.uploads.sendNow()
        XCTAssertEqual(puts(server).count, before, "nothing is sent twice: \(puts(server))")
    }

    /// The Machine Stops: a book made before this build, on a Mac with no Baton server set up
    /// then, is sent once when Baton runs with one, and never again after.
    func testABookMadeBeforeTheUpdateIsSentOnce() async throws {
        let server = FakeBatonServer()
        let clippings = clippingStore()
        let before = library(nil, clippings: clippings)
        before.start(force: true)
        let book = try book()
        let id = try await before.submit(book)
        try await eventually(before, "made on this Mac") { before.jobs.first?.summary.status == .ready }
        before.stop()
        XCTAssertEqual(before.uploads.entries, [], "nothing to send to without a Baton server")
        XCTAssertTrue(server.seen.isEmpty)

        let updated = library(server, clippings: clippings)
        updated.start(force: true)
        try await eventually(updated, "sent after the update") { updated.uploads.entry(forJob: id)?.done == true }
        XCTAssertEqual(server.job(id)?.status, .ready)
        XCTAssertEqual(server.job(id)?.readyChapters, book.chapters.count)
        updated.stop()
        let sent = puts(server)

        let later = library(server, clippings: clippings)
        later.start(force: true)
        defer { later.stop() }
        await later.uploads.sendNow()
        XCTAssertEqual(puts(server), sent, "sent once only")
    }

    /// The Baton server away, or a gateway older than the route: nothing is lost, and the book
    /// goes up when it can. A book gone from the Baton server afterwards (deleted from the
    /// iPhone) is never sent again.
    func testWhileTheBatonServerIsAwayOrOlderTheBookWaitsAndGoesLater() async throws {
        let server = FakeBatonServer()
        server.away = true
        let clippings = clippingStore()
        let library = library(server, clippings: clippings)
        library.start(force: true)
        defer { library.stop() }
        let book = try book()
        let id = try await library.submit(book)
        try await eventually(library, "made on this Mac") { library.jobs.first?.summary.status == .ready }
        await library.uploads.sendNow()
        XCTAssertEqual(library.uploads.entry(forJob: id)?.accepted, false)
        XCTAssertEqual(library.uploads.entry(forJob: id)?.done, false)

        server.away = false
        server.older = true
        await library.uploads.sendNow()
        XCTAssertEqual(library.uploads.entry(forJob: id)?.done, false, "an older gateway is asked again later")
        XCTAssertNil(server.job(id))

        // The gateway deployed: the retry, without anyone asking, sends it.
        server.older = false
        library.uploads.kick(force: true)
        try await eventually(library, "sent once the Baton server can take it") { library.uploads.entry(forJob: id)?.done == true }
        XCTAssertEqual(server.job(id)?.readyChapters, book.chapters.count)

        // Deleted from the iPhone: gone there, and this Mac does not put it back.
        server.remove(id)
        let relaunched = self.library(server, clippings: clippings)
        relaunched.start(force: true)
        defer { relaunched.stop() }
        await relaunched.uploads.sendNow()
        XCTAssertNil(server.job(id), "a book deleted there is not sent again")
    }

    /// TBX-10985's rules for a book made here: Remove from This Mac keeps the Baton server's copy
    /// for the iPhone and does not adopt it back; Delete Everywhere deletes it there too.
    func testRemoveFromThisMacKeepsTheServerCopyAndDeleteEverywhereDeletesIt() async throws {
        let server = FakeBatonServer()
        let clippings = clippingStore()
        let library = library(server, clippings: clippings)
        library.start(force: true)
        defer { library.stop() }
        let book = try book()
        let id = try await library.submit(book)
        try await eventually(library, "sent") { library.uploads.entry(forJob: id)?.done == true }

        let row = try XCTUnwrap(library.shelf.first)
        await library.deleteBook(row, everywhere: false)
        XCTAssertNotNil(server.job(id), "removed from this Mac, kept for the iPhone")
        XCTAssertTrue(library.homeServer.hiddenDocumentIDs.contains(book.documentID))
        await library.refreshHomeServer()
        XCTAssertEqual(library.homeServer.records, [], "and not adopted back here")
        XCTAssertTrue(clippings.chapters(ofDocument: book.documentID).isEmpty)

        // Restored: this Mac's again, nothing sent twice, the copy there is the same.
        let removed = try XCTUnwrap(library.cleanup.removed.first)
        try library.restore(removed)
        XCTAssertFalse(library.homeServer.hiddenDocumentIDs.contains(book.documentID))
        let chaptersBefore = puts(server).filter { $0.contains("/chapters/") && !$0.hasSuffix("/timing") }.count
        library.uploads.kick(force: true)
        try await eventually(library, "restored and checked") { library.uploads.entry(forJob: id)?.done == true }
        XCTAssertEqual(puts(server).filter { $0.contains("/chapters/") && !$0.hasSuffix("/timing") }.count, chaptersBefore,
                       "the Baton server already has every chapter")

        let restoredRow = try XCTUnwrap(library.shelf.first)
        await library.deleteBook(restoredRow, everywhere: true)
        XCTAssertNil(server.job(id), "Delete Everywhere deletes the Baton server's copy")
        XCTAssertTrue(server.seen.contains("DELETE /v1/books/\(id)"))
    }

    /// Made again in another voice on this Mac: the new job goes up, and the copy sent before is
    /// deleted once it is there, so the iPhone follows the book to its new voice.
    func testABookMadeAgainHereReplacesTheCopySentBefore() async throws {
        let server = FakeBatonServer()
        let clippings = clippingStore()
        let library = library(server, clippings: clippings)
        library.start(force: true)
        defer { library.stop() }
        let book = try book()
        let first = try await library.submit(book)
        try await eventually(library, "sent") { library.uploads.entry(forJob: first)?.done == true }

        let row = try XCTUnwrap(library.shelf.first)
        try await library.changeVoice(row, to: "kokoro:bf_emma")
        let second = BookJob.id(for: book.inVoice("kokoro:bf_emma"))
        try await eventually(library, "the new voice sent") {
            library.uploads.entry(forJob: second)?.done == true && library.voiceChange(for: row) == nil
        }
        XCTAssertNil(server.job(first), "the old voice is gone from the Baton server")
        XCTAssertEqual(server.job(second)?.readyChapters, book.chapters.count)
        XCTAssertEqual(server.ids, [second])
    }

    /// Stop on a voice change made here goes back to the job it had: that one goes up again and
    /// the new voice's copy goes, so the iPhone ends with the voice the Mac has.
    func testStoppingAVoiceChangeHerePutsTheOldVoiceBackOnTheBatonServer() async throws {
        let server = FakeBatonServer()
        let kokoro = DocumentLibraryTests.FakeKokoro()
        let clippings = clippingStore()
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: kokoro, retry: .init(initialDelay: 0.02, maximumDelay: 0.05),
                                      refreshInterval: .milliseconds(50), storageDefaults: ThrowawayDefaults.make("uploads-storage"),
                                      uploadRetry: .init(initial: .milliseconds(50), maximum: .milliseconds(200)),
                                      gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { try server.answer($0) } })
        library.start(force: true)
        defer { library.stop() }
        let book = try book()
        let first = try await library.submit(book)
        try await eventually(library, "sent") { library.uploads.entry(forJob: first)?.done == true }

        // The new voice cannot be made yet: its job is sent, and the old voice's copy goes.
        await kokoro.setDown(true)
        let row = try XCTUnwrap(library.shelf.first)
        try await library.changeVoice(row, to: "kokoro:bf_emma")
        let second = BookJob.id(for: book.inVoice("kokoro:bf_emma"))
        try await eventually(library, "the new voice's job sent") { server.job(second) != nil && server.job(first) == nil }

        try await library.cancelVoiceChange(try XCTUnwrap(library.shelf.first))
        await kokoro.setDown(false)
        library.uploads.kick(force: true)
        try await eventually(library, "the old voice back on the Baton server") {
            server.job(first)?.readyChapters == book.chapters.count && server.job(second) == nil
        }
        XCTAssertEqual(server.ids, [first])
        XCTAssertEqual(server.job(first)?.summary.chapters.map(\.sha256),
                       clippings.chapters(ofDocument: book.documentID).map(\.clipping.sha256),
                       "the audio this Mac plays")
    }
}
