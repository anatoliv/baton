import XCTest
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
@testable import BatonMobile

/// The phone's half of a book made on the home server (M5.3): what it remembers after sending,
/// how chapters come down into Clippings once each, and what the list shows meanwhile. The
/// logic is `Shared/HomeServerBooks.swift`, the same file the Mac compiles, so this is the only
/// place its phone build is exercised; the Mac's `DocumentLibraryHomeServerTests` cover the
/// Mac's wiring of it.
@MainActor
final class HomeServerBooksPhoneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-phone-books-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The home server: books it holds, how many chapters of each are ready, every request seen.
    final class FakeGateway: @unchecked Sendable {
        private let lock = NSLock()
        private var jobs: [String: BookJob] = [:]
        private var readyCount: [String: Int] = [:]
        private(set) var requests: [String] = []
        let audio = Data(repeating: 0x41, count: 4_096)
        /// Each job's chapters sound different, as a book in another voice does.
        /// Off by default, so every other test sees the one audio it always did.
        var audioByJob = false
        func chapterAudio(for jobID: String) -> Data {
            audioByJob ? Data(String(repeating: String(jobID.prefix(12)), count: 64).utf8) : audio
        }

        /// The home server answers every DELETE with a 503, as when its disk is unavailable.
        private var _failDeletes = false
        var failDeletes: Bool {
            get { lock.withLock { _failDeletes } }
            set { lock.withLock { _failDeletes = newValue } }
        }

        func setReady(_ id: String, _ count: Int) { lock.withLock { readyCount[id] = count } }

        /// A book another device sent: on the home server, never submitted from here.
        @discardableResult
        func add(_ book: PreparedBook, ready: Int = 0) -> String {
            let id = BookJob.id(for: book)
            lock.withLock {
                jobs[id] = BookJob(id: id, book: book)
                readyCount[id] = ready
            }
            return id
        }

        /// Books that failed for good on the home server.
        private var failed: Set<String> = []
        func fail(_ id: String) { lock.withLock { _ = failed.insert(id) } }

        /// The job as the home server reports it now: chapters ready up to `readyCount`.
        private func current(_ job: BookJob) -> BookJob {
            var job = job
            let ready = readyCount[job.id] ?? 0
            for i in job.chapters.indices {
                let audio = chapterAudio(for: job.id)
                job.chapters[i] = i < ready ? .ready(file: "chapter-\(i + 1).m4a", bytes: audio.count, seconds: 60,
                                                     sha256: SHA256Digest.hex(of: audio))
                                            : (i == ready ? .rendering(done: 1, of: 4) : .queued)
            }
            job.status = failed.contains(job.id) ? .failed : (ready >= job.chapters.count ? .ready : .rendering)
            return job
        }
        var seen: [String] { lock.withLock { requests } }

        func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            lock.withLock {
                let method = request.httpMethod ?? "GET"
                let path = request.url!.path
                requests.append("\(method) \(path)")
                func reply(_ status: Int, _ body: Data, _ headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
                    (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
                }
                let parts = path.split(separator: "/").map(String.init)
                if method == "GET", parts == ["v1", "books"] {
                    // As `BookRoutes.list`: every book's summary, newest first.
                    let books = jobs.values.sorted { $0.createdAt > $1.createdAt }.map { job in
                        try! JSONSerialization.jsonObject(with: BookJSON.encoder.encode(current(job).summary))
                    }
                    let body: [String: Any] = ["available": true, "books": books, "used_bytes": 0,
                                               "maximum_bytes": 4_294_967_296, "keep_finished_days": 30]
                    return reply(200, try! JSONSerialization.data(withJSONObject: body))
                }
                guard parts.count >= 3 else { return reply(404, Data()) }
                let id = parts[2]
                if method == "DELETE", _failDeletes { return reply(503, Data("unavailable".utf8)) }
                if method == "PUT" {
                    let book = try! PreparedBook.decode(request.httpBody ?? Data())
                    jobs[id] = BookJob(id: id, book: book)
                    return reply(201, try! BookJSON.encoder.encode(jobs[id]!.summary))
                }
                guard let job = jobs[id] else { return reply(404, Data()) }
                if method == "DELETE" { jobs[id] = nil; return reply(204, Data()) }
                if method == "POST" { return reply(204, Data()) }
                if parts.count == 4, parts[3] == "book" { return reply(200, try! job.book.encoded()) }
                if parts.count == 5, parts[3] == "chapters", let n = Int(parts[4]) {
                    let audio = chapterAudio(for: id)
                    return reply(200, audio, ["X-Baton-SHA256": SHA256Digest.hex(of: audio), "X-Baton-Duration": "60.0",
                                              "X-Baton-Name": "chapter \(n)"])
                }
                return reply(200, try! BookJSON.encoder.encode(current(job).summary))
            }
        }
    }

    private func book() throws -> PreparedBook {
        let url = root.appendingPathComponent("two-rooms.md")
        try "# Two Rooms\n\n## The Cell\n\nA small room, like the cell of a bee.\n\n## The Surface\n\nThe light at the top was grey."
            .write(to: url, atomically: true, encoding: .utf8)
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
    }

    private func books(_ fake: FakeGateway, clippings: ClippingStore) -> HomeServerBooks {
        HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                        gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
    }

    func testABookIsRememberedAndItsChaptersComeDownOnceEach() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-books"))!)
        let library = books(fake, clippings: clippings)
        let prepared = try book()

        let available = await library.available()
        XCTAssertTrue(available)
        let id = try await library.submit(prepared)
        XCTAssertEqual(library.records.map(\.documentID), [prepared.documentID])
        XCTAssertFalse(library.isCollected(library.records[0]))

        // Nothing ready yet: the row shows the book making chapter 1.
        await library.collect()
        XCTAssertEqual(clippings.items.count, 0)
        let shelf = MobileBookShelf.books(items: clippings.items, records: library.records, summaries: library.summaries, ledger: clippings.ledger)
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(shelf[0].title, "Two Rooms")
        XCTAssertEqual(shelf[0].summaryText, "0 of 2 chapters ready")
        XCTAssertEqual(shelf[0].storedText, "On the Baton server")
        XCTAssertEqual(shelf[0].statusLine?.text, "Making chapter 1 of 2, 25%")

        // Chapter 1 ready: collected, filed as a chapter of the book, announced once.
        fake.setReady(id, 1)
        let arrived = await library.collect()
        XCTAssertEqual(arrived.map(\.chapterIndex), [0])
        XCTAssertEqual(arrived.first?.record.title, "Two Rooms")
        XCTAssertEqual(clippings.items.count, 1)
        XCTAssertEqual(clippings.items[0].clipping.documentID, prepared.documentID)
        XCTAssertEqual(clippings.items[0].clipping.chapterIndex, 0)
        XCTAssertEqual(clippings.items[0].clipping.chapterTitle, "The Cell")

        // Asking again fetches nothing twice, and reports nothing new.
        let again = await library.collect()
        XCTAssertEqual(again, [])
        await library.collect()
        XCTAssertEqual(fake.seen.filter { $0.hasSuffix("/chapters/1") }.count, 1)

        // Both ready: the book is complete and the row says so.
        fake.setReady(id, 2)
        await library.collect()
        XCTAssertTrue(library.isCollected(library.records[0]))
        let done = MobileBookShelf.books(items: clippings.items, records: library.records, summaries: library.summaries, ledger: clippings.ledger)
        XCTAssertEqual(done[0].summaryText, "2 chapters · 2 m")
        XCTAssertEqual(done[0].storedText, "On this phone")
        XCTAssertNil(done[0].statusLine)
    }

    /// After a relaunch the Clippings store has not read its folder yet when the first refresh
    /// asks the home server. A chapter already here must still count as here: before TBX-10975
    /// the first ready chapter of the first book was downloaded again and kept twice, because
    /// the "already here?" lookup ran against the unread store (seen on the simulator walk).
    func testAChapterAlreadyHereIsNotCollectedAgainAfterARelaunch() async throws {
        let fake = FakeGateway()
        let defaults = UserDefaults(suiteName: ThrowawayDefaults.name("phone-books"))!
        let folder = root.appendingPathComponent("Clippings")
        let first = ClippingStore(directory: folder, defaults: defaults)
        let library = books(fake, clippings: first)
        let id = try await library.submit(try book())
        fake.setReady(id, 2)
        let arrived = await library.collect()
        XCTAssertEqual(arrived.map(\.chapterIndex), [0, 1])

        let relaunchedStore = ClippingStore(directory: folder, defaults: defaults)
        let relaunched = books(fake, clippings: relaunchedStore)
        let downloadsBefore = fake.seen.filter { $0.contains("/chapters/") }.count
        let again = await relaunched.collect()
        XCTAssertEqual(again, [], "a chapter already in Clippings came down again")
        XCTAssertEqual(fake.seen.filter { $0.contains("/chapters/") }.count, downloadsBefore, "nothing should be downloaded again")
        XCTAssertEqual(relaunchedStore.items.count, 2, "each chapter is kept once")
    }

    func testTheRecordSurvivesARelaunchAndStoppingDeletesItOnTheServer() async throws {
        let fake = FakeGateway()
        let defaults = UserDefaults(suiteName: ThrowawayDefaults.name("phone-books"))!
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: defaults)
        let id = try await books(fake, clippings: clippings).submit(try book())

        let relaunched = books(fake, clippings: clippings)
        XCTAssertEqual(relaunched.records.map(\.jobID), [id])
        await relaunched.cancel(jobID: id)
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(id)"))
        XCTAssertEqual(relaunched.records, [])
    }

    /// A book stopped while the home server cannot delete it is gone here at once, remembered
    /// across a relaunch, and deleted there on a later refresh; only then is it forgotten.
    func testAStopThatFailsIsAskedAgainUntilTheServerDeletesIt() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-books"))!)
        let library = books(fake, clippings: clippings)
        let id = try await library.submit(try book())

        fake.failDeletes = true
        await library.cancel(jobID: id)
        XCTAssertEqual(library.records, [], "the book is gone from this phone straight away")
        XCTAssertEqual(library.pendingDeleteIDs, [id])
        await library.collect()
        XCTAssertEqual(fake.seen.filter { $0 == "DELETE /v1/books/\(id)" }.count, 2, "asked again on refresh")
        XCTAssertEqual(library.pendingDeleteIDs, [id])
        let listing = await library.listing()
        XCTAssertNotNil(listing)

        let relaunched = books(fake, clippings: clippings)
        XCTAssertEqual(relaunched.pendingDeleteIDs, [id], "the pending delete survives a relaunch")
        XCTAssertEqual(relaunched.records, [])
        fake.failDeletes = false
        await relaunched.collect()
        XCTAssertEqual(relaunched.pendingDeleteIDs, [])
        let deletes = fake.seen.filter { $0 == "DELETE /v1/books/\(id)" }.count
        await relaunched.collect()
        XCTAssertEqual(fake.seen.filter { $0 == "DELETE /v1/books/\(id)" }.count, deletes, "not asked once confirmed")
    }

    /// A 404 means the home server no longer has the book: the delete is done.
    func testAStopTheServerAnswersWith404IsDone() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-books"))!)
        let library = books(fake, clippings: clippings)
        await library.cancel(jobID: "0123456789abcdef")
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/0123456789abcdef"))
        XCTAssertEqual(library.pendingDeleteIDs, [])
    }

    /// The watch (M5.3): while a book is still being made it asks again on its own, every
    /// `pollInterval` (five seconds in the app; 50 ms here), stops by itself once every chapter is
    /// here, and stops when the screen goes (`stopWatching`).
    private var watchChanges = 0

    func testTheWatchAsksUntilEveryChapterIsHereAndStopsWhenTold() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-books"))!)
        let library = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                                      gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } },
                                      pollInterval: .milliseconds(50))
        let id = try await library.submit(try book())
        let statusReads = { fake.seen.filter { $0 == "GET /v1/books/\(id)" }.count }

        watchChanges = 0
        library.watchIfNeeded { self.watchChanges += 1 }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThanOrEqual(statusReads(), 3, "a book being made is asked about again and again")
        XCTAssertGreaterThanOrEqual(watchChanges, 3, "the screen is told after each look")

        library.stopWatching()
        try await Task.sleep(for: .milliseconds(100))
        let stopped = statusReads()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(statusReads(), stopped, "stopped: no more asking")

        // Watching again, and every chapter arrives: the watch ends by itself.
        fake.setReady(id, 2)
        library.watchIfNeeded { }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(clippings.items.count, 2)
        XCTAssertTrue(library.isCollected(library.records[0]))
        let done = statusReads()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(statusReads(), done, "nothing left to collect: the watch has ended")
        library.watchIfNeeded { }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(statusReads(), done, "and does not start again for a book that is all here")
    }

    // MARK: - A book another device sent

    /// A book the Mac sent: same document shape, its own words, never submitted from here.
    private func macBook() throws -> PreparedBook {
        let url = root.appendingPathComponent("the-storm.md")
        try "# The Storm\n\n## The Harbour\n\nBoats rocked at the quay.\n\n## The Squall\n\nThe rain came in sideways."
            .write(to: url, atomically: true, encoding: .utf8)
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:af_heart"))
    }

    private func clippings(_ name: String = "phone-books") -> ClippingStore {
        ClippingStore(directory: root.appendingPathComponent("Clippings"),
                      defaults: UserDefaults(suiteName: ThrowawayDefaults.name(name))!)
    }

    /// The literal TBX-10974 path: a book made on the home server from the Mac shows on the
    /// phone without importing anything, under the job the Mac made, and its chapters come down
    /// with their words, filed under the Mac's document id.
    func testABookTheMacSentIsAdoptedWithoutResubmittingItAndItsChaptersComeDown() async throws {
        let fake = FakeGateway()
        let store = clippings()
        let library = books(fake, clippings: store)
        var announced: [String] = []
        library.firstChapterArrived = { announced.append($0.title) }
        let mac = try macBook()
        let id = fake.add(mac, ready: 1)

        let arrived = await library.collect()
        XCTAssertEqual(announced, [], "no \"Chapter 1 is ready\" for a book another device made")
        XCTAssertEqual(library.records.map(\.jobID), [id], "the Mac's job id, unchanged")
        XCTAssertEqual(library.records.first?.documentID, mac.documentID)
        XCTAssertEqual(library.records.first?.adopted, true)
        XCTAssertEqual(library.records.first?.chapterTitles, ["The Harbour", "The Squall"])
        XCTAssertFalse(fake.seen.contains { $0.hasPrefix("PUT") }, "adopting must not send the book again: \(fake.seen)")
        XCTAssertEqual(arrived.map(\.chapterIndex), [0])
        XCTAssertEqual(store.items.first?.clipping.documentID, mac.documentID)
        XCTAssertTrue(store.items.first?.clipping.text?.contains("Boats rocked at the quay.") == true,
                      "the words come with it, for read-along")
        XCTAssertTrue(library.hasPreparedBook(forJob: id), "kept for Render Again")

        // The row: one book, said to be made on the home server, the rest still being made.
        var shelf = MobileBookShelf.books(items: store.items, records: library.records, summaries: library.summaries,
                                          ledger: store.ledger)
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(shelf[0].title, "The Storm")
        XCTAssertEqual(shelf[0].jobID, id)
        XCTAssertEqual(shelf[0].originText, "Made on the Baton server")
        XCTAssertEqual(shelf[0].summaryText, "1 of 2 chapters ready · 1 m")

        // Collected on demand like the phone's own, the shaped book fetched once.
        fake.setReady(id, 2)
        await library.collect()
        await library.collect()
        XCTAssertTrue(library.isCollected(library.records[0]))
        XCTAssertEqual(fake.seen.filter { $0 == "GET /v1/books/\(id)/book" }.count, 1)
        XCTAssertEqual(fake.seen.filter { $0.hasSuffix("/chapters/2") }.count, 1)
        shelf = MobileBookShelf.books(items: store.items, records: library.records, summaries: library.summaries, ledger: store.ledger)
        XCTAssertEqual(shelf[0].storedText, "On this phone")
        XCTAssertFalse(fake.seen.contains { $0.hasPrefix("PUT") })
    }

    /// The place and "finished" travel by document id, so the phone resumes the Mac's book where
    /// the Mac stopped, and finishing it here tells the home server under the Mac's job.
    func testTheMacsPlaceAndFinishedAreSharedThroughTheDocumentID() async throws {
        let fake = FakeGateway()
        let store = clippings()
        let library = books(fake, clippings: store)
        let mac = try macBook()
        let id = fake.add(mac, ready: 2)
        await library.collect()

        // What the shared ledger brings from the Mac once sync has happened: chapter 2 at 0:10.
        var ledger = store.ledger
        ledger.setPosition(documentID: mac.documentID, chapterIndex: 1, seconds: 10)
        store.ledger = ledger

        let book = try XCTUnwrap(MobileBookShelf.books(items: store.items, records: library.records,
                                                        summaries: library.summaries, ledger: store.ledger).first)
        let queue = MobileBookShelf.queue(for: book)
        XCTAssertEqual(queue.startIndex, 1, "Play starts at the Mac's chapter")
        XCTAssertEqual(BookPlayback.resumeOffset(for: queue.songs[1], clippings: store), 10, "inside it, at the Mac's place")

        // Finished here: the ledger says so for every device, and the home server hears it under
        // the job the Mac made.
        let finished = MobileBookShelf.recordProgress(queue.songs[1], time: 60, duration: 60, clippings: store, homeServer: library)
        XCTAssertEqual(finished, mac.documentID)
        await MobileBookShelf.markFinished(documentID: mac.documentID, homeServer: library)
        XCTAssertTrue(fake.seen.contains("POST /v1/books/\(id)/finished"), "\(fake.seen)")
        XCTAssertEqual(store.ledger.document(mac.documentID)?.finished, true)
    }

    /// Remove from this iPhone leaves the home server's copy for the Mac and keeps the book
    /// hidden here, across a relaunch and later listings. Delete Everywhere deletes it there.
    func testRemovingFromThisPhoneHidesItAndDeleteEverywhereDeletesItOnTheServer() async throws {
        let fake = FakeGateway()
        let defaults = UserDefaults(suiteName: ThrowawayDefaults.name("phone-books-delete"))!
        let store = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: defaults)
        let library = books(fake, clippings: store)
        let cleanup = BookCleanup(directory: root.appendingPathComponent("Books"), clippings: store, homeServer: library,
                                  defaults: defaults)
        let mac = try macBook()
        let id = fake.add(mac, ready: 2)
        await library.collect()
        var book = try XCTUnwrap(MobileBookShelf.books(items: store.items, records: library.records,
                                                        summaries: library.summaries, ledger: store.ledger).first)

        await MobileBookShelf.delete(book, everywhere: false, homeServer: library, cleanup: cleanup, ledger: store.ledger)
        XCTAssertFalse(fake.seen.contains("DELETE /v1/books/\(id)"), "the Mac keeps it")
        XCTAssertEqual(library.records, [])
        XCTAssertEqual(library.hiddenDocumentIDs, [mac.documentID])

        let relaunched = books(fake, clippings: store)
        await relaunched.collect()
        await relaunched.collect()
        XCTAssertEqual(relaunched.records, [], "not adopted again")
        XCTAssertEqual(fake.seen.filter { $0 == "GET /v1/books/\(id)/book" }.count, 1)

        // Restored from Recently removed: it is this phone's again, so the next listing adopts it.
        let entry = try XCTUnwrap(cleanup.removed.first)
        try cleanup.restore(entry)
        XCTAssertEqual(relaunched.hiddenDocumentIDs, [])
        await relaunched.collect()
        XCTAssertEqual(relaunched.records.map(\.jobID), [id])

        // Delete Everywhere: deleted on the home server, gone here, nothing to adopt.
        book = try XCTUnwrap(MobileBookShelf.books(items: store.items, records: relaunched.records,
                                                    summaries: relaunched.summaries, ledger: store.ledger).first)
        await MobileBookShelf.delete(book, everywhere: true, homeServer: relaunched, cleanup: cleanup, ledger: store.ledger)
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(id)"))
        await relaunched.collect()
        XCTAssertEqual(relaunched.records, [])
    }

    /// Not adopted: a book that failed for good, and a book this phone already has under the
    /// same document (its own, in another voice). Its own book is never adopted a second time.
    func testAFailedBookAndASecondCopyOfABookAlreadyHereAreNotAdopted() async throws {
        let fake = FakeGateway()
        let store = clippings()
        let library = books(fake, clippings: store)
        let own = try book()
        let ownID = try await library.submit(own)
        let failed = fake.add(try macBook())
        fake.fail(failed)
        var otherVoice = own
        otherVoice.voices = VoicePlan(narrator: "kokoro:af_heart")
        let otherID = fake.add(otherVoice)
        XCTAssertNotEqual(otherID, ownID)

        await library.collect()
        XCTAssertEqual(library.records.map(\.jobID), [ownID])
        XCTAssertNil(library.records[0].adopted)
        XCTAssertFalse(fake.seen.contains { $0.hasSuffix("/book") }, "\(fake.seen)")
    }

    func testWithNoGatewayConfiguredNothingIsOffered() async {
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-books"))!)
        let library = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings, gateway: { nil })
        XCTAssertFalse(library.isConfigured)
        let available = await library.available()
        XCTAssertFalse(available)
        do {
            _ = try await library.submit(DocumentSpeech.prepare(try DocumentImporter.importFile(at: {
                let url = root.appendingPathComponent("one.txt"); try! "One line.".write(to: url, atomically: true, encoding: .utf8); return url
            }()), voices: VoicePlan(narrator: "kokoro:bf_emma")))
            XCTFail("a book cannot be sent nowhere")
        } catch {
            XCTAssertEqual("\(error)", "the Baton server is not set up in Settings")
        }
    }

    func testTheLanguageDefaultVoiceIsAnEngineAndAVoice() throws {
        let url = root.appendingPathComponent("hello.txt")
        try "Hello there. This is a short English text with a few sentences in it.".write(to: url, atomically: true, encoding: .utf8)
        let document = try DocumentImporter.importFile(at: url)
        let voice = DocumentVoices.languageDefault(for: document)
        XCTAssertTrue(voice.contains(":"), voice)
        XCTAssertEqual(DocumentImportScreen.voiceLabel("kokoro:bf_emma"), "bf_emma on Kokoro")
        XCTAssertTrue(DocumentImportScreen.estimateLine(ListeningEstimate(document)).hasPrefix("Under a minute of audio"),
                      DocumentImportScreen.estimateLine(ListeningEstimate(document)))
    }

    /// TBX-10916, the shared rule on the phone's build: Heart or Emma only when the voice list is
    /// known and has them. The phone's import passes none (the home server does not list its
    /// voices), so it keeps the configured default.
    func testTheEnglishNarratorDefaultNeedsAKnownVoiceList() {
        var book = ImportedDocument(sourceSHA256: "uk", sourceKind: .html, title: "Colour", language: "en",
                                    languageRegion: "gb",
                                    chapters: [DocumentChapter(index: 0, title: "One", paragraphs: ["The colour was grey."])])
        let configured = DocumentVoices.languageDefault(for: book)
        XCTAssertEqual(DocumentVoices.languageDefault(for: book, available: ["kokoro:af_heart", "kokoro:bf_emma"]), "kokoro:bf_emma")
        XCTAssertEqual(DocumentVoices.languageDefault(for: book, available: ["kokoro:af_heart"]), configured)
        book.languageRegion = nil
        XCTAssertEqual(DocumentVoices.languageDefault(for: book, available: ["kokoro:af_heart", "kokoro:bf_emma"]), "kokoro:af_heart")
        XCTAssertEqual(DocumentVoices.languageDefault(for: book, available: nil), configured)
    }

    // MARK: - "Chapter 1 is ready", once

    /// The phone's announcer wired the way `MobileModel` wires it, with the foreground and the
    /// notification centre stood in for: `posted` lists every "Chapter 1 is ready" said.
    private var posted: [String] = []
    private var inForeground = false

    private func announcingBooks(_ fake: FakeGateway, clippings: ClippingStore, directory: String = "Books",
                                 pollInterval: Duration = .seconds(5)) -> HomeServerBooks {
        let library = HomeServerBooks(directory: root.appendingPathComponent(directory), clippings: clippings,
                                      gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } },
                                      pollInterval: pollInterval)
        library.firstChapterArrived = MobileDocuments.chapterReadyAnnouncer(isInForeground: { self.inForeground },
                                                                            post: { self.posted.append($0.title) })
        return library
    }

    private func clippingStore(_ folder: String = "Clippings") -> ClippingStore {
        ClippingStore(directory: root.appendingPathComponent(folder), defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-books"))!)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Whichever path brings chapter 1 down with Baton away from the foreground says so once:
    /// the import screen's watch (the walk's silent case: it used to collect without announcing),
    /// and `collectBooks()`, which activation and the background refresh both run. Later rounds,
    /// and later chapters, say nothing more.
    func testChapterOneIsAnnouncedOnceWhicheverPathCollectsIt() async throws {
        for path in ["watch", "collect"] {
            posted = []
            inForeground = false
            let fake = FakeGateway()
            let clippings = clippingStore("Clippings-\(path)")
            let library = announcingBooks(fake, clippings: clippings, directory: "Books-\(path)", pollInterval: .milliseconds(50))
            let id = try await library.submit(try book())
            await library.collect()
            XCTAssertEqual(posted, [], "\(path): nothing is ready yet")

            fake.setReady(id, 1)
            if path == "watch" {
                library.watchIfNeeded { }
                try await waitUntil { clippings.items.count == 1 && !self.posted.isEmpty }
                library.stopWatching()
            } else {
                await library.collect()
            }
            XCTAssertEqual(clippings.items.count, 1, "\(path): chapter 1 came down")
            XCTAssertEqual(posted, ["Two Rooms"], "\(path): chapter 1 is announced")

            // The background refresh after it finds nothing new, and chapter 2 is not announced.
            await library.collect()
            fake.setReady(id, 2)
            await library.collect()
            XCTAssertEqual(clippings.items.count, 2)
            XCTAssertEqual(posted, ["Two Rooms"], "\(path): said once, never again")
            XCTAssertEqual(library.records.first?.firstChapterAnnounced, true)
        }
    }

    /// With the app in front the row in Clippings says it, so no notification, and the book
    /// counts as told: chapter 1 coming down again later, away from the foreground, says nothing.
    func testChapterOneIsNeverAnnouncedInTheForeground() async throws {
        posted = []
        inForeground = true
        let fake = FakeGateway()
        let clippings = clippingStore()
        let library = announcingBooks(fake, clippings: clippings)
        let id = try await library.submit(try book())
        fake.setReady(id, 1)
        let arrived = await library.collect()
        XCTAssertEqual(arrived.map(\.chapterIndex), [0])
        XCTAssertEqual(posted, [], "never while the person is looking at the app")

        inForeground = false
        clippings.remove(id: clippings.items[0].id, dismissing: false)
        fake.setReady(id, 2)
        let again = await library.collect()
        XCTAssertEqual(again.map(\.chapterIndex), [0, 1])
        XCTAssertEqual(posted, [], "chapter 1 was already told in the foreground")
    }

    /// The record is kept on disk: after a relaunch, chapter 1 coming down again (its clipping
    /// gone, or brought back with Download Again) is not announced a second time.
    func testChapterOneIsNotAnnouncedTwiceAcrossARelaunch() async throws {
        posted = []
        inForeground = false
        let fake = FakeGateway()
        let defaults = UserDefaults(suiteName: ThrowawayDefaults.name("phone-books"))!
        let folder = root.appendingPathComponent("Clippings")
        let clippings = ClippingStore(directory: folder, defaults: defaults)
        let id = try await announcingBooks(fake, clippings: clippings).submit(try book())
        fake.setReady(id, 1)
        await announcingBooks(fake, clippings: clippings).collect()
        XCTAssertEqual(posted, ["Two Rooms"])

        let relaunchedStore = ClippingStore(directory: folder, defaults: defaults)
        relaunchedStore.loadIfNeeded()
        relaunchedStore.remove(id: relaunchedStore.items[0].id, dismissing: false)
        let relaunched = announcingBooks(fake, clippings: relaunchedStore)
        XCTAssertEqual(relaunched.records.first?.firstChapterAnnounced, true, "remembered on disk")
        let arrived = await relaunched.collect()
        XCTAssertEqual(arrived.map(\.chapterIndex), [0], "chapter 1 came down again")
        XCTAssertEqual(posted, ["Two Rooms"], "and was not announced twice")

        relaunched.offload(jobID: id, chapters: [0])
        relaunchedStore.remove(id: relaunchedStore.items[0].id, dismissing: false)
        try await relaunched.downloadAgain(jobID: id)
        XCTAssertNotNil(relaunchedStore.item(documentID: relaunched.records[0].documentID, chapterIndex: 0))
        XCTAssertEqual(posted, ["Two Rooms"], "Download Again is not news")
    }

    /// Where no announcer is wired (the Mac), nothing is said and the record is written as before.
    func testWithoutAnAnnouncerTheRecordIsUnchanged() async throws {
        let fake = FakeGateway()
        let library = books(fake, clippings: clippingStore())
        let id = try await library.submit(try book())
        fake.setReady(id, 1)
        let arrived = await library.collect()
        XCTAssertEqual(arrived.map(\.chapterIndex), [0])
        XCTAssertNil(library.records.first?.firstChapterAnnounced)
        let file = try String(contentsOf: root.appendingPathComponent("Books/home-server-books.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("firstChapterAnnounced"))
    }

    /// Away from the foreground the watch slows down rather than stopping: while
    /// music keeps Baton alive it still brings chapter 1 down, and says so once; back in front it
    /// returns to its quick pace. Here 50 ms in front and 400 ms behind stand in for 5 s and 60 s.
    func testTheWatchSlowsInTheBackgroundStillAnnouncesAndSpeedsUpOnReturn() async throws {
        posted = []
        inForeground = true
        let fake = FakeGateway()
        let clippings = clippingStore()
        let library = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                                      gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } },
                                      pollInterval: .milliseconds(50), backgroundPollInterval: .milliseconds(400))
        library.firstChapterArrived = MobileDocuments.chapterReadyAnnouncer(isInForeground: { self.inForeground },
                                                                            post: { self.posted.append($0.title) })
        let id = try await library.submit(try book())
        let statusReads = { fake.seen.filter { $0 == "GET /v1/books/\(id)" }.count }

        library.watchIfNeeded { }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThanOrEqual(statusReads(), 3, "in front: asking every 50 ms")

        inForeground = false
        library.enterBackground()
        try await Task.sleep(for: .milliseconds(60))
        let behind = statusReads()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(statusReads(), behind, "behind: not asking at the quick pace")

        fake.setReady(id, 1)
        try await waitUntil({ clippings.items.count == 1 && !self.posted.isEmpty }, seconds: 2)
        XCTAssertEqual(clippings.items.count, 1, "behind: the slow watch still brings chapter 1 down")
        XCTAssertEqual(posted, ["Two Rooms"], "and announces it, once")
        XCTAssertLessThanOrEqual(statusReads() - behind, 3, "about one look per 400 ms")

        inForeground = true
        library.enterForeground()
        let back = statusReads()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThanOrEqual(statusReads() - back, 3, "back in front: the quick pace again")
        library.stopWatching()
        XCTAssertEqual(posted, ["Two Rooms"])
    }
}
