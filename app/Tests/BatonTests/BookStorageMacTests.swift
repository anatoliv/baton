import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// Book storage on the Mac (M6.3 to M6.5): Remove Download keeps the book and Render Again
/// brings it back from the chunk cache; the rules remove only what they should and never a
/// book marked Keep; a deleted book waits a week in Recently removed and Restore brings it back
/// with its render job; and the weekly suggestion's "Always do this" sets the rule.
@MainActor
final class BookStorageMacTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-storage-\(UUID().uuidString)")
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

    private func clippingStore() -> ClippingStore {
        ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("storage-clips"))
    }

    private func library(_ kokoro: DocumentLibraryTests.FakeKokoro, clippings: ClippingStore,
                         defaults: UserDefaults) -> DocumentLibrary {
        DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"), synthesizer: kokoro,
                        retry: .init(initialDelay: 0.02, maximumDelay: 0.05), refreshInterval: .milliseconds(50),
                        storageDefaults: defaults, gateway: { nil })
    }

    private func eventually(_ library: DocumentLibrary, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            library.refresh()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out")
    }

    /// A library with one book made and every chapter in Clippings.
    private func madeBook(defaults: UserDefaults? = nil) async throws
        -> (DocumentLibrary, ClippingStore, DocumentLibraryTests.FakeKokoro, PreparedBook) {
        let kokoro = DocumentLibraryTests.FakeKokoro()
        let clippings = clippingStore()
        let library = library(kokoro, clippings: clippings, defaults: defaults ?? ThrowawayDefaults.make("storage"))
        library.start(force: true)
        let prepared = try book()
        try await library.submit(prepared)
        try await eventually(library) { clippings.chapters(ofDocument: prepared.documentID).count == prepared.chapters.count }
        return (library, clippings, kokoro, prepared)
    }

    private func finish(_ documentID: String, daysAgo: Double, clippings: ClippingStore) {
        var ledger = clippings.ledger
        ledger.setFinished(true, documentID: documentID, at: Date().addingTimeInterval(-daysAgo * StoragePolicy.day))
        clippings.ledger = ledger
    }

    // MARK: - Remove Download, Render Again (M6.3)

    func testRemovingADownloadKeepsTheBookAndRenderAgainBringsItBackFromTheCache() async throws {
        let (library, clippings, kokoro, prepared) = try await madeBook()
        let shelfBook = try XCTUnwrap(library.shelf.first)
        XCTAssertTrue(library.stored(shelfBook).canGetBack, "made here, with its job kept")
        XCTAssertNil(library.getBackTitle(shelfBook), "nothing is missing yet")

        let freed = library.offload(shelfBook)
        XCTAssertGreaterThan(freed, 0)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [], "the audio is gone from this Mac")
        let offloaded = try XCTUnwrap(library.shelf.first, "the book keeps its row")
        XCTAssertTrue(offloaded.isOffloaded)
        XCTAssertEqual(offloaded.storedText, "Download removed")
        XCTAssertEqual(offloaded.chapters.map(\.state), Array(repeating: .removed, count: prepared.chapters.count))
        XCTAssertEqual(library.getBackTitle(offloaded), "Render Again")
        XCTAssertEqual(library.cleanup.removed.map(\.kind), [.offloaded])
        XCTAssertEqual(library.cleanup.removed.first?.bytes, freed)

        let voiced = await kokoro.calls
        try await library.getBack(offloaded)
        try await eventually(library) { clippings.chapters(ofDocument: prepared.documentID).count == prepared.chapters.count }
        let after = await kokoro.calls
        XCTAssertEqual(after, voiced, "made again from the chunk cache: nothing voiced twice")
        XCTAssertFalse(try XCTUnwrap(library.shelf.first).isOffloaded)
        XCTAssertEqual(library.cleanup.removed, [], "back again, so its entry has done its job")
    }

    func testOneChapterCanBeRemovedAndBroughtBack() async throws {
        let (library, clippings, _, prepared) = try await madeBook()
        let shelfBook = try XCTUnwrap(library.shelf.first)
        library.offload(shelfBook, chapters: [1])
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID).compactMap(\.clipping.chapterIndex), [0])
        let partly = try XCTUnwrap(library.shelf.first)
        XCTAssertEqual(partly.chapters.map(\.state), [.ready, .removed])
        try await library.getBack(partly, chapters: [1])
        try await eventually(library) { clippings.chapters(ofDocument: prepared.documentID).count == 2 }
    }

    // MARK: - Rules (M6.2 applied)

    func testRulesRemoveOnlyWhatIsDueAndNeverABookMarkedKeep() async throws {
        let (library, clippings, _, prepared) = try await madeBook()
        finish(prepared.documentID, daysAgo: 10, clippings: clippings)

        XCTAssertEqual(library.applyStorageRules(), [], "no rule chosen: nothing is removed")
        library.cleanup.setRules(.init(afterFinished: 7 * StoragePolicy.day))
        library.cleanup.setKeep(true, documentID: prepared.documentID)
        XCTAssertEqual(library.applyStorageRules(), [], "Keep overrides every rule")
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID).count, 2)

        library.cleanup.setKeep(false, documentID: prepared.documentID)
        XCTAssertEqual(library.applyStorageRules(), [prepared.documentID])
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [])
        XCTAssertEqual(library.cleanup.removed.first?.automatic, true, "listed in Recently removed as the rule's doing")
        XCTAssertTrue(try XCTUnwrap(library.shelf.first).isOffloaded)
    }

    func testTheBookInProgressIsNeverRemoved() async throws {
        let (library, clippings, _, prepared) = try await madeBook()
        var ledger = clippings.ledger
        ledger.setPosition(documentID: prepared.documentID, chapterIndex: 0, seconds: 5,
                           at: Date().addingTimeInterval(-400 * StoragePolicy.day))
        clippings.ledger = ledger
        library.cleanup.setRules(.init(unplayedFor: 30 * StoragePolicy.day, spaceLimit: 1))
        XCTAssertEqual(library.applyStorageRules(), [])
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID).count, 2)
    }

    // MARK: - Delete, Recently removed, Restore (M6.3)

    func testADeletedBookWaitsAWeekAndRestoreBringsItBackWithItsJob() async throws {
        let (library, clippings, _, prepared) = try await madeBook()
        let shelfBook = try XCTUnwrap(library.shelf.first)
        await library.deleteBook(shelfBook, everywhere: false)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [])
        XCTAssertNil(library.job(forDocument: prepared.documentID), "it stops being made")
        XCTAssertTrue(library.shelf.isEmpty, "gone from Clippings")
        let entry = try XCTUnwrap(library.cleanup.removed.first)
        XCTAssertEqual(entry.kind, .deleted)
        XCTAssertGreaterThan(entry.bytes, 0, "its audio is held")

        try library.restore(entry)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID).map(\.clipping.chapterIndex), [0, 1])
        XCTAssertNotNil(library.job(forDocument: prepared.documentID), "the render job is back, so Render Again works")
        XCTAssertEqual(library.cleanup.removed, [])
        XCTAssertTrue(clippings.chapters(ofDocument: prepared.documentID).allSatisfy(\.isPresent))
    }

    /// Two clippings for one chapter, as an internal task once left, are both held under the same file
    /// name, so the second cannot be. A chapter that is not held must not be deleted.
    func testADeleteThatCannotHoldAChapterLeavesItInsteadOfDeletingIt() async throws {
        let (library, clippings, _, prepared) = try await madeBook()
        let extra = root.appendingPathComponent("extra.m4a")
        try Data(repeating: 0x42, count: 2_048).write(to: extra)
        try clippings.adopt(extra, title: "The Cell", durationSeconds: 1,
                            chapter: .init(documentID: prepared.documentID, documentTitle: "Two Rooms", author: nil,
                                           chapterIndex: 0, chapterTitle: "The Cell"))
        let all = clippings.chapters(ofDocument: prepared.documentID)
        XCTAssertEqual(all.count, 3)
        var stored = library.stored(try XCTUnwrap(library.shelf.first))
        stored.present = all

        library.cleanup.delete(stored, everywhere: false)
        let left = clippings.chapters(ofDocument: prepared.documentID)
        XCTAssertEqual(left.count, 1, "the chapter it could not hold stays in Clippings")
        XCTAssertTrue(left.allSatisfy(\.isPresent))
        let entry = try XCTUnwrap(library.cleanup.removed.first)
        XCTAssertEqual(entry.chapters, [0, 1])

        try library.cleanup.restore(entry)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID).count, 3, "no chapter's audio was lost")
    }

    // MARK: - A collection already running

    /// Something to do on the main actor while one chapter's download is on the wire.
    private final class MidFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@MainActor @Sendable () -> Void)?
        func set(_ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { self.action = action } }
        func take() -> (@MainActor @Sendable () -> Void)? { lock.withLock { defer { action = nil }; return action } }
    }

    /// A home server with the book on it and both chapters ready, and this device's books, whose
    /// download of chapter 1 runs `midFlight` before it answers.
    private func homeServerBook() throws
        -> (HomeServerBooks, ClippingStore, PreparedBook, String, MidFlight) {
        let fake = DocumentLibraryHomeServerTests.FakeGateway()
        let prepared = try book()
        let id = fake.add(prepared, ready: prepared.chapters.count)
        let midFlight = MidFlight()
        let clippings = clippingStore()
        let books = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings, gateway: {
            GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { request in
                if request.url?.path.hasSuffix("/chapters/1") == true, let action = midFlight.take() { await action() }
                return fake.answer(request)
            }
        })
        return (books, clippings, prepared, id, midFlight)
    }

    func testADownloadRemovedWhileItIsCollectedDoesNotComeBack() async throws {
        let (books, clippings, prepared, id, midFlight) = try homeServerBook()
        midFlight.set { books.offload(jobID: id, chapters: [0, 1]) }
        await books.collect()
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [], "removed on purpose, so not fetched back")
        XCTAssertEqual(books.record(forJob: id)?.offloaded, [0, 1])
    }

    func testABookRemovedFromThisDeviceWhileItIsCollectedLeavesNoChaptersBehind() async throws {
        let (books, clippings, prepared, _, midFlight) = try homeServerBook()
        midFlight.set { books.hide(documentID: prepared.documentID) }
        await books.collect()
        XCTAssertTrue(books.records.isEmpty)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [], "no chapters with no book")
    }

    func testAfterAWeekADeletedBookIsPurged() async throws {
        let (library, _, _, _) = try await madeBook()
        await library.deleteBook(try XCTUnwrap(library.shelf.first), everywhere: false)
        let entry = try XCTUnwrap(library.cleanup.removed.first)
        let held = root.appendingPathComponent("Books/recently-removed/\(entry.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        library.cleanup.purge(now: Date().addingTimeInterval(6 * StoragePolicy.day))
        XCTAssertEqual(library.cleanup.removed.count, 1, "still restorable on day six")
        library.cleanup.purge(now: Date().addingTimeInterval(7 * StoragePolicy.day + 60))
        XCTAssertEqual(library.cleanup.removed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.path), "the held audio goes with it")
    }

    // MARK: - Suggestions (M6.5)

    func testAlwaysDoThisRemovesTheBookSetsTheRuleAndIsRemembered() async throws {
        let defaults = ThrowawayDefaults.make("storage-suggest")
        let (library, clippings, _, prepared) = try await madeBook(defaults: defaults)
        finish(prepared.documentID, daysAgo: 9, clippings: clippings)

        let offered = try XCTUnwrap(library.cleanup.suggestion(for: library.storedBooks, freeBytes: nil))
        XCTAssertEqual(offered.kind, .finishedBook)
        XCTAssertEqual(offered.ids, [prepared.documentID])
        XCTAssertEqual(library.cleanup.suggestion(for: library.storedBooks, freeBytes: nil), offered,
                       "the same suggestion until it is answered")

        library.cleanup.answer(.always, to: offered, books: library.storedBooks)
        XCTAssertEqual(clippings.chapters(ofDocument: prepared.documentID), [])
        XCTAssertEqual(library.cleanup.rules.afterFinished, 7 * StoragePolicy.day)
        XCTAssertNil(library.cleanup.suggestion(for: library.storedBooks, freeBytes: nil), "answered, and a week has not passed")

        let relaunched = BookCleanup(directory: root.appendingPathComponent("Books"), clippings: clippings,
                                     homeServer: library.homeServer, defaults: defaults)
        XCTAssertEqual(relaunched.rules.afterFinished, 7 * StoragePolicy.day, "the rule is this Mac's setting now")
        XCTAssertNotNil(relaunched.settings.lastSuggestedAt)
    }
}
