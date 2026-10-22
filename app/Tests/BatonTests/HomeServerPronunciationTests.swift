import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// Pronunciations for a book made on the home server: the editor works from the
/// shaped book saved beside the record (M6.3), and a correction sends the book to the home
/// server again under its new id, the chapters that say the word leaving Clippings to come down
/// again. Against the gateway's routes as `GatewayBookClient` speaks them, through the fake
/// home server that refuses a PUT whose id is not the book's content, as `BookRoutes` does.
@MainActor
final class HomeServerPronunciationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-home-lexicon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private typealias FakeGateway = DocumentLibraryHomeServerTests.FakeGateway

    /// Vashti in both chapters, Kuno in the second only; a cast of two and a speed, which a
    /// correction must not lose.
    private func book() throws -> PreparedBook {
        let url = root.appendingPathComponent("machine.md")
        try """
        # The Machine Stops

        ## The Air-Ship

        Vashti sat in her room. The bell rang and she touched a switch.

        ## The Mending Apparatus

        Kuno called from the other side of the earth. Vashti did not want to come.
        """.write(to: url, atomically: true, encoding: .utf8)
        var plan = VoicePlan(narrator: "kokoro:bf_emma")
        plan.speed = 1.1
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: plan)
    }

    private func library(_ fake: FakeGateway, clippings: ClippingStore) -> DocumentLibrary {
        DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                        synthesizer: DocumentLibraryTests.FakeKokoro(), storageDefaults: ThrowawayDefaults.make("home-lexicon-storage"),
                        gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
    }

    /// A book made on the home server with both chapters collected, and the listener halfway
    /// through chapter 1.
    private func collectedBook(_ fake: FakeGateway, _ clippings: ClippingStore) async throws
        -> (library: DocumentLibrary, book: PreparedBook, jobID: String) {
        let library = library(fake, clippings: clippings)
        let book = try book()
        let id = try await library.submit(book, on: .homeServer)
        fake.setReady(id, book.chapters.count)
        await library.refreshHomeServer()
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, 2)
        var ledger = clippings.ledger
        ledger.setPosition(documentID: book.documentID, chapterIndex: 0, seconds: 30)
        clippings.ledger = ledger
        return (library, book, id)
    }

    private func row(_ library: DocumentLibrary, _ documentID: String) throws -> BookShelf.Book {
        try XCTUnwrap(library.shelf.first { $0.documentID == documentID })
    }

    func testACorrectionSendsTheBookAgainAndOnlyTheChaptersThatSayTheWordComeDownAgain() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home-lexicon"))
        let (library, book, oldID) = try await collectedBook(fake, clippings)
        let chapterOne = try XCTUnwrap(clippings.item(documentID: book.documentID, chapterIndex: 0))
        let before = try row(library, book.documentID)
        XCTAssertEqual(before.madeOn, .homeServer)
        XCTAssertTrue(library.canEditPronunciations(before), "Pronunciations… is offered for a home-server book")
        XCTAssertEqual(library.pronunciationSource(documentID: book.documentID)?.renderer, .homeServer)

        // Kuno, corrected, beside two model proposals that give two words one sound: those two
        // are not what any renderer sends, so they are not sent (PronunciationLexicon.validated).
        var lexicon = PronunciationLexicon()
        lexicon.set("Kuno", ipa: "kˈuːnoʊ")
        lexicon.set("Vashti", ipa: "ˈvæʃti", source: "model")
        lexicon.set("Machine", ipa: "ˈvæʃti", source: "model")
        let remade = try await library.applyLexicon(lexicon, to: before, clippings: clippings)
        XCTAssertEqual(remade, [1], "Kuno is said in chapter 2 only")

        let record = try XCTUnwrap(library.homeServer.record(forDocument: book.documentID))
        XCTAssertNotEqual(record.jobID, oldID, "a different lexicon is a different job")
        XCTAssertEqual(library.remoteBooks.count, 1, "one record, moved to the new job")
        XCTAssertTrue(fake.seen.contains("PUT /v1/books/\(record.jobID)"))
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(oldID)"), "the old job is removed from the home server")
        let sent = try XCTUnwrap(fake.submitted(record.jobID))
        XCTAssertEqual(sent.lexicon?.entries.map(\.word), ["Kuno"], "only the validated entry is sent")
        XCTAssertEqual(sent.lexicon?.entries.first?.phonemes, "kˈuːnO")
        XCTAssertEqual(sent.voices, book.voices, "the narrator and the speed are kept")
        XCTAssertEqual(sent.chapters, book.chapters, "the words are kept")
        XCTAssertEqual(library.homeServer.preparedBook(forJob: record.jobID)?.lexicon, sent.lexicon, "the saved book is the one sent")
        XCTAssertNil(library.homeServer.preparedBook(forJob: oldID))

        // Chapter 1 stays; chapter 2 left Clippings and the row says it is being made again.
        XCTAssertEqual(clippings.item(documentID: book.documentID, chapterIndex: 0)?.id, chapterOne.id)
        XCTAssertNil(clippings.item(documentID: book.documentID, chapterIndex: 1))
        let making = try row(library, book.documentID)
        XCTAssertTrue(making.isRendering)
        XCTAssertEqual(MusicBooksView.statusLine(making)?.text, "Waiting to make chapter 2 of 2")
        XCTAssertEqual(making.position?.chapterIndex, 0)
        XCTAssertEqual(making.position?.seconds, 30, "the listening position is the book's, and stays")

        fake.setReady(record.jobID, 1)
        await library.refreshHomeServer()
        XCTAssertEqual(MusicBooksView.statusLine(try row(library, book.documentID))?.text, "Making chapter 2 of 2, 25%")

        // The home server finishes: chapter 2 comes down in its place, chapter 1 is not fetched.
        fake.setReady(record.jobID, 2)
        await library.refreshHomeServer()
        let after = try row(library, book.documentID)
        XCTAssertEqual(after.chapters.map { $0.item != nil }, [true, true])
        XCTAssertEqual(clippings.item(documentID: book.documentID, chapterIndex: 0)?.id, chapterOne.id)
        XCTAssertNil(MusicBooksView.statusLine(after))
        let downloads = fake.seen.filter {
            $0.hasPrefix("GET /v1/books/\(record.jobID)/chapters/") && !$0.hasSuffix("/timing")  // read-along timing, an internal task
        }
        XCTAssertEqual(downloads, ["GET /v1/books/\(record.jobID)/chapters/2"], "only the corrected chapter comes down")
        XCTAssertEqual(after.position?.seconds, 30)
    }

    func testTheJobIDChangesOnlyWhenTheLexiconDoes() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home-lexicon-id"))
        let (library, book, oldID) = try await collectedBook(fake, clippings)
        let puts = { fake.seen.filter { $0.hasPrefix("PUT ") }.count }
        XCTAssertEqual(puts(), 1)

        // No lexicon to no lexicon, and an entry Kokoro cannot read (dropped, so still none).
        let applied1 = try await library.applyLexicon(nil, to: try row(library, book.documentID), clippings: clippings)
        XCTAssertEqual(applied1, [])
        var unreadable = PronunciationLexicon()
        unreadable.entries = [.init(word: "Kuno", phonemes: "@@", source: "person")]
        let applied2 = try await library.applyLexicon(unreadable, to: try row(library, book.documentID), clippings: clippings)
        XCTAssertEqual(applied2, [])
        XCTAssertEqual(library.homeServer.record(forDocument: book.documentID)?.jobID, oldID)
        XCTAssertEqual(puts(), 1, "nothing sent")

        // A word the book never says: kept in place, nothing re-made, the job keeps its id.
        var nobody = PronunciationLexicon()
        nobody.set("Himalayas", ipa: "hɪməˈleɪəz")
        let applied3 = try await library.applyLexicon(nobody, to: try row(library, book.documentID), clippings: clippings)
        XCTAssertEqual(applied3, [])
        XCTAssertEqual(library.homeServer.record(forDocument: book.documentID)?.jobID, oldID)
        XCTAssertEqual(library.homeServer.preparedBook(forJob: oldID)?.lexicon, nobody)
        XCTAssertEqual(puts(), 1)
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, 2)

        // The same lexicon again: no change at all.
        let applied4 = try await library.applyLexicon(nobody, to: try row(library, book.documentID), clippings: clippings)
        XCTAssertEqual(applied4, [])
        XCTAssertEqual(puts(), 1)

        // Vashti, in both chapters, in a book already finished: a new job, both chapters made
        // again, and the new job is finished on the home server too.
        var ledger = clippings.ledger
        ledger.setFinished(true, documentID: book.documentID)
        clippings.ledger = ledger
        var vashti = nobody
        vashti.set("Vashti", ipa: "ˈvæʃti")
        let applied5 = try await library.applyLexicon(vashti, to: try row(library, book.documentID), clippings: clippings)
        XCTAssertEqual(applied5, [0, 1])
        let newID = try XCTUnwrap(library.homeServer.record(forDocument: book.documentID)?.jobID)
        XCTAssertNotEqual(newID, oldID)
        XCTAssertEqual(newID, BookJob.id(for: try XCTUnwrap(fake.submitted(newID))))
        XCTAssertEqual(puts(), 2)
        XCTAssertTrue(fake.seen.contains("POST /v1/books/\(newID)/finished"), "finished stays finished")

        // And the same again: nothing.
        let applied6 = try await library.applyLexicon(vashti, to: try row(library, book.documentID), clippings: clippings)
        XCTAssertEqual(applied6, [])
        XCTAssertEqual(library.homeServer.record(forDocument: book.documentID)?.jobID, newID)
        XCTAssertEqual(puts(), 2)
    }

    /// The home server away when Save is pressed: the error reaches the sheet and the book is as
    /// it was, its chapters in Clippings and its record on the old job.
    func testAHomeServerThatIsAwayLeavesTheBookAsItWas() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home-lexicon-away"))
        let (library, book, oldID) = try await collectedBook(fake, clippings)
        fake.failPuts = true
        var kuno = PronunciationLexicon()
        kuno.set("Kuno", ipa: "kˈuːnoʊ")
        do {
            try await library.applyLexicon(kuno, to: try row(library, book.documentID), clippings: clippings)
            XCTFail("the save should fail")
        } catch {}
        XCTAssertEqual(library.homeServer.record(forDocument: book.documentID)?.jobID, oldID)
        XCTAssertNil(library.homeServer.preparedBook(forJob: oldID)?.lexicon)
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, 2)
        XCTAssertFalse(fake.seen.contains("DELETE /v1/books/\(oldID)"))
    }

    /// A pronunciation saved in place changes the saved book's id without sending it; Render
    /// Again, once the home server has removed the book, brings it back under the id it now has.
    func testRenderAgainAfterAnInPlaceCorrectionFollowsTheNewID() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home-lexicon-again"))
        let (library, book, oldID) = try await collectedBook(fake, clippings)
        var nobody = PronunciationLexicon()
        nobody.set("Himalayas", ipa: "hɪməˈleɪəz")
        try await library.applyLexicon(nobody, to: try row(library, book.documentID), clippings: clippings)
        XCTAssertEqual(library.homeServer.record(forDocument: book.documentID)?.jobID, oldID)

        try await library.homeServer.renderAgain(jobID: oldID)
        let record = try XCTUnwrap(library.homeServer.record(forDocument: book.documentID))
        XCTAssertNotEqual(record.jobID, oldID)
        XCTAssertEqual(fake.submitted(record.jobID)?.lexicon, nobody)
        XCTAssertNotNil(library.homeServer.preparedBook(forJob: record.jobID))
        XCTAssertEqual(library.remoteBooks.count, 1)
    }
}
