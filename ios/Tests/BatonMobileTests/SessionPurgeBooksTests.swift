import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import XCTest
@testable import BatonMobile

/// Books on "Disconnect and delete my data". The purge left the Books
/// records, the books hidden from this device, the deletes still owed to the old server and the
/// covers, whatever Keep downloads said. Owner decision, 2026-10-21: with Keep downloads on, the
/// downloaded books stay (audio, records, covers); with it off they go. Hidden-book marks and the
/// deletes owed to the old server always go: they belong to the account, not the downloads.
@MainActor
final class SessionPurgeBooksTests: XCTestCase {
    private var root: URL!
    private var fake: HomeServerBooksPhoneTests.FakeGateway!
    private var books: HomeServerBooks!
    private var covers: BookCoverStore!
    private var documentID: String!

    private var booksDirectory: URL { root.appendingPathComponent("Books", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-purge-books-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fake = HomeServerBooksPhoneTests.FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                      defaults: UserDefaults(suiteName: ThrowawayDefaults.name("purge-books"))!)
        books = HomeServerBooks(directory: booksDirectory, clippings: clippings,
                                gateway: { [fake] in GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake!.answer($0) } })
        covers = BookCoverStore(directory: booksDirectory.appendingPathComponent("covers", isDirectory: true))

        // A downloaded book with its cover, a book hidden from this device, and a delete the
        // old server still owes.
        let url = root.appendingPathComponent("two-rooms.md")
        try "# Two Rooms\n\n## The Cell\n\nA small room, like the cell of a bee."
            .write(to: url, atomically: true, encoding: .utf8)
        let prepared = DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
        documentID = prepared.documentID
        _ = try await books.submit(prepared)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 32)
        try covers.set(png, documentID: documentID, source: .book)
        books.hide(documentID: "0123456789abcdef0123456789abcdef")
        fake.failDeletes = true
        await books.cancel(jobID: "fedcba9876543210")
        XCTAssertEqual(books.records.count, 1, "precondition: a book record")
        XCTAssertTrue(covers.hasCover(documentID), "precondition: its cover")
        XCTAssertEqual(books.hiddenDocumentIDs.count, 1, "precondition: a hidden book")
        XCTAssertEqual(books.pendingDeleteIDs, ["fedcba9876543210"], "precondition: a delete owed")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testKeepDownloadsKeepsTheBooksAndDropsTheAccountState() {
        SessionPurge.purgeBooks(books, covers: covers, directory: booksDirectory, keepDownloads: true)

        XCTAssertEqual(books.records.map(\.documentID), [documentID], "the downloaded book stays")
        XCTAssertTrue(covers.hasCover(documentID), "and its cover")
        XCTAssertEqual(books.hiddenDocumentIDs, [], "hidden-book marks belong to the account")
        XCTAssertEqual(books.pendingDeleteIDs, [], "deletes owed to the old server go with it")
    }

    func testWithoutKeepDownloadsTheBooksGoToo() {
        SessionPurge.purgeBooks(books, covers: covers, directory: booksDirectory, keepDownloads: false)

        XCTAssertEqual(books.records, [], "the book record stayed")
        XCTAssertFalse(covers.hasCover(documentID), "the cover stayed")
        XCTAssertTrue(covers.entries.isEmpty)
        XCTAssertEqual(books.hiddenDocumentIDs, [])
        XCTAssertEqual(books.pendingDeleteIDs, [])
        let left = (try? FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)) ?? []
        XCTAssertEqual(left.filter { $0 != "covers" }, [], "nothing of the books is left on disk")
        // The cover store made its folder when it started and does not make it again, so the
        // folder stays (empty) and the next cover set before a relaunch still lands.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 9, count: 32)
        XCTAssertNoThrow(try covers.set(png, documentID: documentID, source: .book), "a cover after the purge failed")
        XCTAssertTrue(covers.hasCover(documentID))
    }

    /// The user-facing purge calls it: a book hidden on the phone's own Books store is no longer
    /// hidden after "Disconnect and delete my data", with Keep downloads on.
    func testThePurgeItselfClearsTheHiddenMarks() {
        let model = MobileModel()
        let hiddenID = "00112233445566778899aabbccddeeff"
        model.books.hide(documentID: hiddenID)
        XCTAssertTrue(model.books.hiddenDocumentIDs.contains(hiddenID), "precondition")

        SessionPurge.purge(model, keepDownloads: true)

        XCTAssertFalse(model.books.hiddenDocumentIDs.contains(hiddenID), "the purge left the hidden-book mark")
    }
}
