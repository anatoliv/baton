import Foundation
import XCTest
@testable import BatonDocuments

/// What a device keeps about its book storage (M6.3 to M6.5): settings that survive a relaunch,
/// one suggestion a week that is kept until answered, "Always do this" setting the rule,
/// Recently removed lasting a week, and the words, which are user copy and stay dash-free.
final class BookStorageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * StoragePolicy.day) }

    private func finished(_ id: String, days: Double, bytes: Int = 29_000_000) -> StoragePolicy.Item {
        .init(id: id, title: id, bytes: bytes, isBook: true, addedAt: daysAgo(days + 10), lastPlayedAt: daysAgo(days),
              finishedAt: daysAgo(days))
    }

    func testSettingsRoundTripThroughDefaultsAndStartWithNoRule() throws {
        // One fixed name, cleared before and after: this package does not link ThrowawayDefaults,
        // and the repo's rule (ThrowawayDefaultsTests) forbids minting a UUID suite per run.
        let name = "io.tonebox.tests.baton.bookstorage.settings"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(BookStorage.loadSettings(from: defaults), BookStorage.Settings(),
                       "nothing stored: no rule, nothing kept, nothing offered")
        XCTAssertTrue(BookStorage.loadSettings(from: defaults).rules.isEmpty, "nothing is removed until a rule is chosen")

        var settings = BookStorage.Settings()
        settings.rules = .init(afterFinished: StoragePolicy.day, spaceLimit: 2_000_000_000)
        settings.keep = ["a"]
        settings.lastSuggestedAt = now
        BookStorage.save(settings, to: defaults)
        XCTAssertEqual(BookStorage.loadSettings(from: defaults), settings)
    }

    func testASuggestionIsOfferedOnceAWeekAndKeptUntilAnswered() {
        let items = [finished("old", days: 9)]
        let (first, afterFirst) = BookStorage.offer(items, settings: .init(), now: now, freeBytes: nil)
        XCTAssertEqual(first?.kind, .finishedBook)
        XCTAssertEqual(first?.ids, ["old"])
        XCTAssertEqual(first?.daysAgo, 9)
        XCTAssertEqual(afterFirst.lastSuggestedAt, now)

        // Unanswered, the same suggestion stays on offer, even days later.
        let (again, _) = BookStorage.offer(items, settings: afterFirst, now: now.addingTimeInterval(2 * StoragePolicy.day),
                                           freeBytes: nil)
        XCTAssertEqual(again, first)

        // Answered Keep: remembered, and not offered again, this week or later.
        let (removeNow, kept) = BookStorage.answer(.keep, to: first!, settings: afterFirst)
        XCTAssertEqual(removeNow, [])
        XCTAssertNil(kept.pending)
        XCTAssertNil(BookStorage.offer(items, settings: kept, now: now.addingTimeInterval(StoragePolicy.day), freeBytes: nil).suggestion)
        XCTAssertNil(BookStorage.offer(items, settings: kept, now: now.addingTimeInterval(30 * StoragePolicy.day), freeBytes: nil).suggestion,
                     "a declined book is not suggested again")

        // Another finished book waits for the week to pass.
        let more = items + [finished("other", days: 12)]
        XCTAssertNil(BookStorage.offer(more, settings: kept, now: now.addingTimeInterval(3 * StoragePolicy.day), freeBytes: nil).suggestion)
        XCTAssertEqual(BookStorage.offer(more, settings: kept, now: now.addingTimeInterval(8 * StoragePolicy.day), freeBytes: nil)
            .suggestion?.ids, ["other"])
    }

    func testAlwaysDoThisRemovesNowAndSetsTheAfterFinishingRule() {
        let (offered, settings) = BookStorage.offer([finished("old", days: 9)], settings: .init(), now: now, freeBytes: nil)
        let (remove, after) = BookStorage.answer(.always, to: offered!, settings: settings)
        XCTAssertEqual(remove, ["old"])
        XCTAssertEqual(after.rules.afterFinished, 7 * StoragePolicy.day)
        XCTAssertNil(after.pending)
        // With the rule set, the rule does the removing and nothing more is suggested for it.
        XCTAssertEqual(StoragePolicy.removals([finished("old", days: 9)], rules: after.rules, now: now).map(\.id), ["old"])
    }

    func testAPendingSuggestionLapsesWhenItsBookCannotBeRemovedAnyMore() {
        let (offered, settings) = BookStorage.offer([finished("old", days: 9)], settings: .init(), now: now, freeBytes: nil)
        XCTAssertNotNil(offered)
        var kept = finished("old", days: 9)
        kept.keep = true
        let (later, after) = BookStorage.offer([kept], settings: settings, now: now, freeBytes: nil)
        XCTAssertNil(later, "a book marked Keep since is not offered")
        XCTAssertNil(after.pending)
    }

    func testLowSpaceOffersTheLargestFinishedBooks() {
        let items = [finished("a", days: 2, bytes: 10_000_000), finished("b", days: 3, bytes: 90_000_000),
                     finished("c", days: 4, bytes: 50_000_000), finished("d", days: 5, bytes: 70_000_000)]
        let suggestion = BookStorage.offer(items, settings: .init(), now: now, freeBytes: 1_200_000_000).suggestion
        XCTAssertEqual(suggestion?.kind, .lowDeviceSpace)
        XCTAssertEqual(suggestion?.ids, ["b", "d", "c"])
        XCTAssertEqual(suggestion?.bytes, 210_000_000)
    }

    func testRecentlyRemovedLastsAWeek() {
        let entry = BookStorage.Removed(id: "1", documentID: "d", title: "The Machine Stops", bytes: 29_000_000,
                                        removedAt: daysAgo(6), kind: .deleted)
        XCTAssertEqual(BookStorage.expired([entry], now: now), [])
        XCTAssertEqual(BookStorage.expired([entry], now: now.addingTimeInterval(StoragePolicy.day)), [entry])
        XCTAssertEqual(entry.purgeAt, daysAgo(-1))
    }

    func testTheWordsAreWarmAndDashFree() {
        let finishedOne = BookStorage.Suggestion(kind: .finishedBook, ids: ["x"], bytes: 29_000_000, daysAgo: 9, offeredAt: now)
        let low = BookStorage.Suggestion(kind: .lowDeviceSpace, ids: ["x", "y", "z"], bytes: 240_000_000,
                                         freeBytes: 1_200_000_000, offeredAt: now)
        XCTAssertEqual(BookStorage.suggestionText(finishedOne, title: "The Machine Stops", device: "this Mac"),
                       "You finished The Machine Stops 9 days ago. Remove its download from this Mac to free 29 MB? "
                       + "You can download it again whenever you like.")
        XCTAssertEqual(BookStorage.suggestionText(low, title: nil, device: "this iPhone"),
                       "This iPhone has 1.2 GB free. Remove the downloads of your 3 largest finished books to free 240 MB?")
        let offloaded = BookStorage.Removed(id: "1", documentID: "d", title: "t", bytes: 29_000_000, removedAt: daysAgo(2),
                                            kind: .offloaded, automatic: true)
        let deleted = BookStorage.Removed(id: "2", documentID: "d", title: "t", bytes: 0, removedAt: now, kind: .deleted)
        XCTAssertEqual(BookStorage.removedText(offloaded, now: now, device: "this Mac"),
                       "Download removed 2 days ago by your storage rule, freeing 29 MB.")
        XCTAssertEqual(BookStorage.removedText(deleted, now: now, device: "this Mac"),
                       "Deleted from this Mac today. You can restore it for 7 more days.")
        let all = [BookStorage.suggestionText(finishedOne, title: "A", device: "this Mac"),
                   BookStorage.suggestionText(low, title: nil, device: "this Mac"),
                   BookStorage.alwaysConfirmation(device: "this Mac"),
                   BookStorage.removedText(offloaded, now: now, device: "this Mac"),
                   BookStorage.removedText(deleted, now: now, device: "this Mac")]
        for text in all {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}") || text.contains(" - "), text)
        }
        XCTAssertEqual(BookStorage.sizeText(29_400_000), "29 MB")
        XCTAssertEqual(BookStorage.sizeText(2_000_000_000), "2 GB")
        XCTAssertEqual(BookStorage.sizeText(640_000), "640 KB")
    }
}

/// The renderer's half of M6.3 and TBX-10801: chapters put back in the queue are made again from
/// the chunk cache, and stopping leaves a book to be resumed rather than failed.
final class BookRendererRequeueTests: XCTestCase {
    func testRequeuedChaptersAreMadeAgainFromTheCache() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = FakeSynthesizer()
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: synth,
                                    muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let book = sampleBook()
        let id = BookJob.id(for: book)
        _ = try await renderer.submit(book, id: id)
        await renderer.waitUntilIdle()
        let calls = synth.calls.count
        // The chapter's audio left the device (on the Mac it is moved into Clippings, then offloaded).
        guard case let .ready(file, _, _, _) = try XCTUnwrap(store.load(id)).chapters[1] else { return XCTFail("not ready") }
        try FileManager.default.removeItem(at: try XCTUnwrap(store.chapterURL(id, file: file)))

        let requeued = await renderer.requeue(id, chapters: [1])
        XCTAssertTrue(requeued)
        await renderer.waitUntilIdle()
        let job = try XCTUnwrap(store.load(id))
        XCTAssertEqual(job.status, .ready)
        guard case let .ready(again, _, _, _) = job.chapters[1] else { return XCTFail("chapter 2 not made again") }
        XCTAssertNotNil(store.chapterURL(id, file: again), "the chapter's audio is there again")
        XCTAssertEqual(synth.calls.count, calls, "made from the chunk cache: nothing voiced twice")
        let unknown = await renderer.requeue(String(repeating: "f", count: 64))
        XCTAssertFalse(unknown)
    }

    func testStoppingLeavesTheBookToResumeNotFailed() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = PauseGate()
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: gate,
                                    muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let book = sampleBook()
        let id = BookJob.id(for: book)
        _ = try await renderer.submit(book, id: id)
        try await Task.sleep(nanoseconds: 100_000_000)
        await renderer.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let job = try XCTUnwrap(store.load(id))
        XCTAssertNotEqual(job.status, .failed, "stopping is not a failure")
        XCTAssertFalse(job.chapters.contains { if case .failed = $0 { true } else { false } })
        gate.up = true
        await renderer.startIfNeeded()
        await renderer.waitUntilIdle()
        XCTAssertEqual(store.load(id)?.status, .ready, "started again, it finishes the book")
    }
}
