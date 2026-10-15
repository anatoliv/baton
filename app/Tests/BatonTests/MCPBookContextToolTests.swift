import AVFoundation
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// `document_context` (M8.5): an agent asks about the book being heard and gets passages from
/// the part already heard, never past the listener's position. Pinned here rather than in the
/// schema snapshot because, like `import_document`, it is listed only while
/// `baton.documents.enabled` is on.
@MainActor
final class MCPBookContextToolTests: XCTestCase {

    private var root: URL!
    private var clippings: ClippingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-mcp-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                  defaults: ThrowawayDefaults.make("mcp-book"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let chapterOne = """
    Vashti sat in her hexagonal room, lit by a soft radiance. Kuno, her son, called her from the \
    other side of the earth. He wanted her to come and see him. She said the airship was tiresome. \
    He said the stars had a shape, like a man. She did not understand him, and the bell rang again. \
    The Machine hummed below the floor as it always had.
    """
    private static let chapterTwo = """
    Later the Machine stopped. The light failed and the people cried out in the dark. Kuno found \
    his mother at the last and they spoke of the surface.
    """

    private func tone(seconds: Double) throws -> URL {
        let url = root.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(24_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    /// Two chapters in Clippings with their words, as a book collected from the home server or
    /// whose job is long gone looks.
    @discardableResult
    private func land(documentID: String = "doc", title: String = "The Machine Stops") throws -> [ClippingStore.Item] {
        try [Self.chapterOne, Self.chapterTwo].enumerated().map { index, text in
            try clippings.adopt(try tone(seconds: 10), title: "Chapter \(index + 1)", durationSeconds: 10, text: text,
                                chapter: .init(documentID: documentID, documentTitle: title, author: "E. M. Forster",
                                               chapterIndex: index, chapterTitle: "Chapter \(index + 1)"))
        }
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func texts(_ reply: [String: Any]) -> String {
        (reply["passages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testListedBesideImportDocumentAndReadOnly() throws {
        let names = { (defs: [[String: Any]]) in Set(defs.compactMap { $0["name"] as? String }) }
        XCTAssertFalse(names(BatonMCPToolCatalog.definitions()).contains("document_context"),
                       "the published surface under test must not depend on this Mac's flag")
        let tool = try XCTUnwrap(BatonMCPToolCatalog.definitions(includeDocuments: true)
            .first { $0["name"] as? String == "document_context" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(Set((schema["properties"] as? [String: Any] ?? [:]).keys), ["book", "question", "budget"])
        XCTAssertEqual(schema["required"] as? [String], [])
        let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(annotations["openWorldHint"] as? Bool, false, "the book's text never leaves this Mac")
        XCTAssertTrue((tool["description"] as? String ?? "").contains("Never reveal"), "the package's spoiler rule is in the description")
    }

    func testNothingPastThePlayingPositionComesBack() throws {
        let items = try land()
        // Chapter 1 is playing, a little past halfway: Kuno's call has been heard, the stars not yet.
        let playing = BatonMCPBookTools.Playing(songID: items[0].asSong.id, time: 5.5, duration: 10)
        let reply = try object(try BatonMCPBookTools.run(["question": "who is Kuno?"], library: nil, clippings: clippings, playing: playing))
        XCTAssertEqual(reply["title"] as? String, "The Machine Stops")
        let text = texts(reply)
        XCTAssertTrue(text.contains("Kuno, her son"), text)
        XCTAssertFalse(text.contains("stars"), "not heard yet: \(text)")
        XCTAssertFalse(text.contains("Machine stopped"), "chapter 2 is the future: \(text)")
        XCTAssertTrue((reply["position"] as? String ?? "").hasPrefix("Chapter 1 of 2"), "\(reply["position"] ?? "")")
    }

    func testWithoutAQuestionTheMostRecentPassagesComeAndTheBudgetBoundsThem() throws {
        try land()
        var ledger = clippings.ledger
        ledger.setPosition(documentID: "doc", chapterIndex: 1, seconds: 10)   // chapter 2 heard to its end
        clippings.ledger = ledger
        let all = try object(try BatonMCPBookTools.run([:], library: nil, clippings: clippings, playing: nil))
        XCTAssertTrue(texts(all).contains("Machine stopped"), "synced to the end of chapter 2: \(texts(all))")
        XCTAssertTrue(texts(all).contains("Vashti sat"), texts(all))

        let little = try object(try BatonMCPBookTools.run(["budget": 200], library: nil, clippings: clippings, playing: nil))
        XCTAssertLessThanOrEqual(texts(little).count, 200 + 1)
        XCTAssertTrue(texts(little).contains("surface"), "the newest text, cut from its start: \(texts(little))")
    }

    func testABookIsFoundByTitleAndTheLastPlayedIsTheDefault() throws {
        try land(documentID: "a", title: "The Machine Stops")
        try land(documentID: "b", title: "Two Rooms")
        var ledger = clippings.ledger
        ledger.setPosition(documentID: "a", chapterIndex: 0, seconds: 9, at: Date(timeIntervalSinceNow: -3_600))
        ledger.setPosition(documentID: "b", chapterIndex: 0, seconds: 9, at: Date())
        clippings.ledger = ledger
        let last = try object(try BatonMCPBookTools.run([:], library: nil, clippings: clippings, playing: nil))
        XCTAssertEqual(last["document_id"] as? String, "b")
        let named = try object(try BatonMCPBookTools.run(["book": "machine"], library: nil, clippings: clippings, playing: nil))
        XCTAssertEqual(named["document_id"] as? String, "a")
        XCTAssertThrowsError(try BatonMCPBookTools.run(["book": "War and Peace"], library: nil, clippings: clippings, playing: nil)) { error in
            XCTAssertTrue("\(error)".contains("Two Rooms"), "names the books it has: \(error)")
        }
    }

    func testAnUnstartedBookHasNothingToAnswerFrom() throws {
        try land()
        let reply = try object(try BatonMCPBookTools.run([:], library: nil, clippings: clippings, playing: nil))
        XCTAssertEqual(reply["passage_count"] as? Int, 0)
        XCTAssertTrue((reply["note"] as? String ?? "").contains("not heard any"), "\(reply["note"] ?? "")")
    }

    /// A book made on this Mac keeps its prepared book, whose paragraphs are the passages.
    func testABookMadeOnThisMacReadsFromItsJob() async throws {
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: DocumentLibraryTests.FakeKokoro(),
                                      retry: .init(initialDelay: 0.02, maximumDelay: 0.05), refreshInterval: .milliseconds(50))
        library.start(force: true)
        let url = root.appendingPathComponent("book.md")
        try "# The Machine Stops\n\n## One\n\n\(Self.chapterOne)\n\n## Two\n\n\(Self.chapterTwo)".write(to: url, atomically: true, encoding: .utf8)
        let book = DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
        try await library.submit(book)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, clippings.chapters(ofDocument: book.documentID).count < 2 {
            library.refresh()
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, 2)
        let shelf = try XCTUnwrap(BookShelf.entries(items: clippings.items, jobs: library.jobs, ledger: clippings.ledger)
            .compactMap { if case let .book(b) = $0 { b } else { nil } }.first)
        XCTAssertEqual(BookText.preparedBook(for: shelf, library: library)?.chapters.map(\.title), book.chapters.map(\.title))

        var ledger = clippings.ledger
        ledger.setPosition(documentID: book.documentID, chapterIndex: 0, seconds: 0.4)   // a fifth of a second's chapter
        clippings.ledger = ledger
        let reply = try object(try BatonMCPBookTools.run(["question": "who is Vashti?"], library: library, clippings: clippings, playing: nil))
        XCTAssertEqual(reply["document_id"] as? String, book.documentID)
        XCTAssertFalse(texts(reply).contains("Machine stopped"), texts(reply))
    }
}
