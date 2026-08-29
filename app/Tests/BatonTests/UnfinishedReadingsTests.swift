import XCTest
@testable import Baton

/// Resuming a reading you stopped part-way.
///
/// This store is a deliberate exception to a promise the app makes to the user in two places, so
/// the tests are about the terms of that exception rather than about round-tripping a struct: what
/// is kept, how much of it, for how long, and that it goes away when it should.
@MainActor
final class UnfinishedReadingsTests: XCTestCase {

    private var dir: URL!
    private var store: UnfinishedReadings!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-unfinished-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = UnfinishedReadings(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func chunks(_ n: Int) -> [String] { (1...n).map { "Sentence number \($0)." } }

    // MARK: - What is worth keeping

    func testAReadingStoppedPartWayIsKeptWithItsPosition() {
        store.record(id: UUID(), chunks: chunks(10), resumeIndex: 4, sourceName: "Google Chrome",
                     startedAt: Date())
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.resumeIndex, 4)
        XCTAssertEqual(store.entries.first?.sourceName, "Google Chrome")
    }

    /// A reading that ran to the end is not something to come back to. Keeping it would leave
    /// finished articles sitting in the Resume menu, which is the fastest way to make people stop
    /// reading that menu.
    func testAFinishedReadingIsNotKept() {
        store.record(id: UUID(), chunks: chunks(10), resumeIndex: 10, sourceName: nil, startedAt: Date())
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// Nor is one you stopped before it really began: "resume at 0%" is an entry that costs a menu
    /// row and saves nobody anything.
    func testAReadingStoppedAtTheStartIsNotKept() {
        store.record(id: UUID(), chunks: chunks(10), resumeIndex: 0, sourceName: nil, startedAt: Date())
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// Resuming the same article twice must update one entry, not accumulate a row per attempt.
    func testRecordingTheSameReadingAgainReplacesIt() {
        let id = UUID()
        store.record(id: id, chunks: chunks(10), resumeIndex: 2, sourceName: "Ghostty", startedAt: Date())
        store.record(id: id, chunks: chunks(10), resumeIndex: 6, sourceName: "Ghostty", startedAt: Date())
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.resumeIndex, 6)
    }

    // MARK: - The terms of the exception

    /// Five, and the oldest goes. The cap is the reason this store exists separately from
    /// `SpeechHistory`: one long article must never evict a user's spoken summaries.
    func testTheCapDropsTheOldest() {
        for i in 1...(UnfinishedReadings.maximumEntries + 3) {
            store.record(id: UUID(), chunks: chunks(10), resumeIndex: i % 9 + 1,
                         sourceName: "Source \(i)", startedAt: Date())
        }
        XCTAssertEqual(store.entries.count, UnfinishedReadings.maximumEntries)
        XCTAssertEqual(store.entries.first?.sourceName, "Source \(UnfinishedReadings.maximumEntries + 3)",
                       "newest first")
        XCTAssertFalse(store.entries.contains { $0.sourceName == "Source 1" }, "the oldest should be gone")
    }

    /// The retention is the part the user is told about, so it has to be real. An entry older
    /// than the window is dropped on the next load, not merely hidden.
    func testEntriesExpireAfterTheStatedRetention() throws {
        let now = Date()
        store.record(id: UUID(), chunks: chunks(10), resumeIndex: 3, sourceName: "Old",
                     startedAt: now, now: now)
        XCTAssertEqual(store.entries.count, 1)

        // A fresh store over the same file, reading it a day past the retention window.
        let reopened = UnfinishedReadings(directory: dir)
        reopened.loadIfNeeded(now: now.addingTimeInterval(UnfinishedReadings.retention + 86_400))
        XCTAssertTrue(reopened.entries.isEmpty, "an expired reading survived the retention window")
    }

    func testAnEntryInsideTheWindowSurvivesAReopen() {
        let now = Date()
        store.record(id: UUID(), chunks: chunks(10), resumeIndex: 3, sourceName: "Recent",
                     startedAt: now, now: now)

        let reopened = UnfinishedReadings(directory: dir)
        reopened.loadIfNeeded(now: now.addingTimeInterval(UnfinishedReadings.retention / 2))
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries.first?.chunks.count, 10, "the text has to survive, or resume is empty")
    }

    /// "Cleared on a schedule you can see" is only true if you can also clear it now.
    func testClearForgetsEverythingAndTheFile() {
        store.record(id: UUID(), chunks: chunks(10), resumeIndex: 3, sourceName: nil, startedAt: Date())
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)

        let reopened = UnfinishedReadings(directory: dir)
        reopened.loadIfNeeded()
        XCTAssertTrue(reopened.entries.isEmpty, "clearing left the file behind")
    }

    func testRemovingOneLeavesTheOthers() {
        let keep = UUID(), drop = UUID()
        store.record(id: keep, chunks: chunks(10), resumeIndex: 2, sourceName: "Keep", startedAt: Date())
        store.record(id: drop, chunks: chunks(10), resumeIndex: 2, sourceName: "Drop", startedAt: Date())
        store.remove(id: drop)
        XCTAssertEqual(store.entries.map(\.sourceName), ["Keep"])
    }

    // MARK: - The menu row

    /// The source and how far in you were are the only two things known about a reading, so they
    /// are the only two things the row claims. An unknown source still gets a usable label rather
    /// than a blank one.
    func testTheMenuTitleSaysWhereItCameFromAndHowFarIn() {
        store.record(id: UUID(), chunks: chunks(10), resumeIndex: 5, sourceName: "Ghostty", startedAt: Date())
        XCTAssertEqual(store.entries.first?.menuTitle, "Ghostty — 50% in")

        store.clear()
        store.record(id: UUID(), chunks: chunks(4), resumeIndex: 1, sourceName: "   ", startedAt: Date())
        XCTAssertEqual(store.entries.first?.menuTitle, "Reading — 25% in")
    }
}
