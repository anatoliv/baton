import XCTest
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
@testable import BatonMobile

/// Book storage on the phone (M6.3 to M6.5), through the shared `HomeServerBooks` and
/// `BookCleanup` the Mac compiles too: a removed download stays removed while collecting runs,
/// Download Again brings it back, a book the home server has since removed is made again from
/// the saved book, a deleted book is restored from Recently removed, and the weekly suggestion
/// offers the largest finished books when space is low.
@MainActor
final class BookStoragePhoneTests: XCTestCase {
    private typealias FakeGateway = HomeServerBooksPhoneTests.FakeGateway
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-phone-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func book() throws -> PreparedBook {
        let url = root.appendingPathComponent("two-rooms.md")
        try "# Two Rooms\n\n## The Cell\n\nA small room, like the cell of a bee.\n\n## The Surface\n\nThe light at the top was grey."
            .write(to: url, atomically: true, encoding: .utf8)
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
    }

    private func client(_ fake: FakeGateway) -> GatewayBookClient {
        GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) }
    }

    /// A phone with one book sent, both chapters collected.
    private func collected() async throws -> (HomeServerBooks, BookCleanup, ClippingStore, FakeGateway, String, PreparedBook) {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                      defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-storage"))!)
        let books = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                                    gateway: { [fake] in self.client(fake) })
        let cleanup = BookCleanup(directory: root.appendingPathComponent("Books"), clippings: clippings, homeServer: books,
                                  defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-storage"))!)
        let prepared = try book()
        let id = try await books.submit(prepared)
        fake.setReady(id, 2)
        await books.collect()
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID).count, 2)
        return (books, cleanup, clippings, fake, id, prepared)
    }

    private func shelf(_ books: HomeServerBooks, _ clippings: ClippingStore) -> [MobileBookShelf.Book] {
        MobileBookShelf.books(items: clippings.items, records: books.records, summaries: books.summaries, ledger: clippings.ledger)
    }

    private func stored(_ books: HomeServerBooks, _ clippings: ClippingStore) throws -> StoredBook {
        MobileBookShelf.stored(try XCTUnwrap(shelf(books, clippings).first), homeServer: books, ledger: clippings.ledger)
    }

    func testARemovedDownloadStaysRemovedUntilDownloadAgain() async throws {
        let (books, cleanup, clippings, fake, id, prepared) = try await collected()
        let downloads = { fake.seen.filter { $0.contains("/chapters/") }.count }
        XCTAssertEqual(downloads(), 2)

        let freed = cleanup.offload(try stored(books, clippings))
        XCTAssertGreaterThan(freed, 0)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [])
        await books.collect()
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [], "collecting does not undo it")
        XCTAssertEqual(downloads(), 2)
        XCTAssertFalse(books.hasUncollected, "and nothing keeps asking the home server for it")
        let row = try XCTUnwrap(shelf(books, clippings).first)
        XCTAssertEqual(row.storedText, "Download removed")
        XCTAssertEqual(row.missing, [0, 1])
        XCTAssertEqual(cleanup.removed.map(\.kind), [.offloaded])

        try await books.downloadAgain(jobID: id)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID).count, 2)
        XCTAssertEqual(downloads(), 4)
        XCTAssertNil(books.record(forJob: id)?.offloadedChapters)
    }

    func testABookTheServerRemovedIsMadeAgainFromTheSavedBook() async throws {
        let (books, cleanup, clippings, fake, id, prepared) = try await collected()
        XCTAssertNotNil(books.preparedBook(forJob: id), "the shaped book is kept beside the record")
        cleanup.offload(try stored(books, clippings))
        try await client(fake).delete(id)   // finished and past its keep date on the server

        let relaunched = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                                         gateway: { [fake] in self.client(fake) })
        await relaunched.collect()
        let record = try XCTUnwrap(relaunched.record(forJob: id), "kept: its chapters can still be made again")
        XCTAssertEqual(record.serverRemoved, true)
        XCTAssertTrue(relaunched.canGetBack(record))
        XCTAssertEqual(shelf(relaunched, clippings).first?.missing, [0, 1])

        try await relaunched.downloadAgain(jobID: id)
        XCTAssertTrue(fake.seen.contains("PUT /v1/books/\(id)"), "sent to be made again")
        XCTAssertNil(relaunched.record(forJob: id)?.serverRemoved)
        fake.setReady(id, 2)
        await relaunched.collect()
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID).count, 2)
    }

    func testADeletedBookIsRestoredFromRecentlyRemoved() async throws {
        let (books, cleanup, clippings, _, id, prepared) = try await collected()
        cleanup.delete(try stored(books, clippings), everywhere: false)
        books.forget(jobID: id)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [])
        let entry = try XCTUnwrap(cleanup.removed.first)
        XCTAssertEqual(entry.kind, .deleted)
        try cleanup.restore(entry)
        let back = clippings.chapters(ofDocument: prepared.documentID)
        XCTAssertEqual(back.map(\.clipping.chapterTitle), ["The Cell", "The Surface"])
        XCTAssertTrue(back.allSatisfy(\.isPresent))
        XCTAssertEqual(cleanup.removed, [])
    }

    /// Delete Book… asks the home server to delete the book whichever answer is chosen, as its
    /// question says, and Recently removed still restores it from the audio held here.
    func testDeleteBookAsksTheHomeServerToDeleteItEitherWayAndRestoreStillWorks() async throws {
        for everywhere in [false, true] {
            if everywhere { try tearDownWithError(); try setUpWithError() }
            let (books, cleanup, clippings, fake, id, prepared) = try await collected()
            let row = try XCTUnwrap(shelf(books, clippings).first)
            await MobileBookShelf.delete(row, everywhere: everywhere, homeServer: books, cleanup: cleanup,
                                         ledger: clippings.ledger)
            XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(id)"), "everywhere: \(everywhere)")
            XCTAssertEqual(books.records, [], "everywhere: \(everywhere)")
            XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [])

            let entry = try XCTUnwrap(cleanup.removed.first)
            XCTAssertEqual(entry.everywhere, everywhere)
            try cleanup.restore(entry)
            let back = clippings.chapters(ofDocument: prepared.documentID)
            XCTAssertEqual(back.map(\.clipping.chapterTitle), ["The Cell", "The Surface"], "everywhere: \(everywhere)")
            XCTAssertTrue(back.allSatisfy(\.isPresent))
        }
    }

    func testLowSpaceOffersFinishedBooksAndRemoveTakesThem() async throws {
        let (books, cleanup, clippings, _, _, prepared) = try await collected()
        var ledger = clippings.ledger
        ledger.setFinished(true, documentID: prepared.documentID, at: Date().addingTimeInterval(-2 * StoragePolicy.day))
        clippings.ledger = ledger
        let all = [try stored(books, clippings)]
        let offered = try XCTUnwrap(cleanup.suggestion(for: all, freeBytes: 900_000_000))
        XCTAssertEqual(offered.kind, .lowDeviceSpace)
        XCTAssertEqual(BookStorage.suggestionText(offered, title: nil, device: "this iPhone"),
                       "This iPhone has 900 MB free. Remove the downloads of your largest finished book to free \(BookStorage.sizeText(offered.bytes))?")
        cleanup.answer(.remove, to: offered, books: all)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [])
        XCTAssertNil(cleanup.suggestion(for: [try stored(books, clippings)], freeBytes: 900_000_000), "once a week at most")
    }
}
