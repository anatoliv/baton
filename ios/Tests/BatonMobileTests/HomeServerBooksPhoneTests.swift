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

        func setReady(_ id: String, _ count: Int) { lock.withLock { readyCount[id] = count } }
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
                    return reply(200, Data(#"{"available":true,"books":[],"used_bytes":0,"maximum_bytes":4294967296,"keep_finished_days":30}"#.utf8))
                }
                guard parts.count >= 3 else { return reply(404, Data()) }
                let id = parts[2]
                if method == "PUT" {
                    let book = try! PreparedBook.decode(request.httpBody ?? Data())
                    jobs[id] = BookJob(id: id, book: book)
                    return reply(201, try! BookJSON.encoder.encode(jobs[id]!.summary))
                }
                guard var job = jobs[id] else { return reply(404, Data()) }
                if method == "DELETE" { jobs[id] = nil; return reply(204, Data()) }
                if method == "POST" { return reply(204, Data()) }
                if parts.count == 5, parts[3] == "chapters", let n = Int(parts[4]) {
                    return reply(200, audio, ["X-Baton-SHA256": SHA256Digest.hex(of: audio), "X-Baton-Duration": "60.0",
                                              "X-Baton-Name": "chapter \(n)"])
                }
                let ready = readyCount[id] ?? 0
                for i in job.chapters.indices {
                    job.chapters[i] = i < ready ? .ready(file: "chapter-\(i + 1).m4a", bytes: audio.count, seconds: 60,
                                                         sha256: SHA256Digest.hex(of: audio))
                                                : (i == ready ? .rendering(done: 1, of: 4) : .queued)
                }
                job.status = ready >= job.chapters.count ? .ready : .rendering
                return reply(200, try! BookJSON.encoder.encode(job.summary))
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
        XCTAssertEqual(shelf[0].storedText, "On the home server")
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
            XCTAssertEqual("\(error)", "the home server is not set up in Settings")
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
}
