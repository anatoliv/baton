import XCTest
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
@testable import BatonMobile

/// Change Voice… on the phone: the home server makes the whole book again in the new
/// narrator's voice through `resubmit`, and the row keeps its chapters, playing the old voice until
/// each new one lands in its place, while it says "Making again in …" with how far it has got.
@MainActor
final class BookVoiceChangePhoneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-phone-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private typealias FakeGateway = HomeServerBooksPhoneTests.FakeGateway

    func testTheRowSaysMakingAgainAndEachChapterIsReplacedInPlace() async throws {
        let fake = FakeGateway()
        fake.audioByJob = true
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                      defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-voice"))!)
        let books = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                                    gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
        let url = root.appendingPathComponent("two-rooms.md")
        try "# Two Rooms\n\n## The Cell\n\nA small room, like the cell of a bee.\n\n## The Surface\n\nThe light at the top was grey."
            .write(to: url, atomically: true, encoding: .utf8)
        var prepared = DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:af_heart"))
        var lexicon = PronunciationLexicon()
        lexicon.set("Cell", ipa: "sˈɛl")
        prepared.lexicon = lexicon
        let oldID = try await books.submit(prepared)
        fake.setReady(oldID, 2)
        await books.collect()
        let rows = clippings.chapters(ofDocument: prepared.documentID)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.clipping.voice), ["kokoro:af_heart", "kokoro:af_heart"])
        var ledger = clippings.ledger
        ledger.setPosition(documentID: prepared.documentID, chapterIndex: 1, seconds: 12)
        clippings.ledger = ledger
        func shelf() -> MobileBookShelf.Book {
            MobileBookShelf.books(items: clippings.items, records: books.records, summaries: books.summaries,
                                  ledger: clippings.ledger, changes: books.voiceChanges.all)[0]
        }

        let newID = try await books.changeVoice(jobID: oldID, to: "kokoro:af_sky")
        XCTAssertNotEqual(newID, oldID)
        XCTAssertEqual(books.records.count, 1)
        XCTAssertEqual(books.preparedBook(forJob: newID)?.voices.narrator, "kokoro:af_sky")
        XCTAssertEqual(books.preparedBook(forJob: newID)?.lexicon, lexicon, "the pronunciations carry over")
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(oldID)"))
        await books.collect()
        XCTAssertEqual(shelf().statusLine?.text, "Making again in af_sky on Kokoro… chapter 1 of 2, 25%")
        XCTAssertTrue(shelf().canStopRemaking)
        XCTAssertEqual(shelf().readyChapters.count, 2, "both chapters still play, in the old voice")
        XCTAssertFalse(books.isCollected(books.records[0]), "the watch keeps asking while chapters wait for their new voice")

        fake.setReady(newID, 1)
        await books.collect()
        let halfway = clippings.chapters(ofDocument: prepared.documentID)
        XCTAssertEqual(halfway.map(\.id), rows.map(\.id), "the same rows")
        XCTAssertEqual(halfway.map(\.clipping.voice), ["kokoro:af_sky", "kokoro:af_heart"])
        XCTAssertEqual(shelf().statusLine?.text, "Making again in af_sky on Kokoro… chapter 2 of 2, 25%")

        fake.setReady(newID, 2)
        await books.collect()
        let done = clippings.chapters(ofDocument: prepared.documentID)
        XCTAssertEqual(done.map(\.id), rows.map(\.id))
        XCTAssertEqual(Set(done.map(\.clipping.sha256)), [SHA256Digest.hex(of: fake.chapterAudio(for: newID))])
        XCTAssertNil(shelf().statusLine)
        XCTAssertFalse(shelf().canStopRemaking)
        XCTAssertEqual(shelf().position?.chapterIndex, 1)
        XCTAssertEqual(shelf().position?.seconds, 12)
        XCTAssertTrue(books.isCollected(books.records[0]))
    }
}
