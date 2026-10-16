import BatonSubsonicModels
import Foundation
import BatonSubsonicKit
import XCTest
@testable import BatonPlaybackKit

/// A finished book played again past its first minute is no longer finished, here and in the
/// synced ledger, so the next Play resumes there. Before this nothing cleared the
/// mark, and a finished book restarted at chapter 1 however far into it the listener had got.
/// Three 60-second chapters.
@MainActor
final class BookReplayUnfinishTests: XCTestCase {
    private var dir: URL!
    private var clippings: ClippingStore!
    private var chapters: [ClippingStore.Item] = []
    private let start = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-unfinish-\(UUID().uuidString)")
        clippings = ClippingStore(directory: dir, defaults: UserDefaults(suiteName: ThrowawayDefaults.name("unfinish"))!)
        chapters = try (0..<3).map { index in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ch-\(UUID().uuidString).m4a")
            try Data(repeating: 0x41, count: 512).write(to: url)
            return try clippings.adopt(url, title: "Chapter \(index + 1)", durationSeconds: 60,
                                       chapter: .init(documentID: "doc", documentTitle: "The Machine Stops",
                                                      author: nil, chapterIndex: index, chapterTitle: "Chapter \(index + 1)"))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func play(_ chapter: Int, at time: TimeInterval, seconds offset: TimeInterval) -> String? {
        BookPlayback.record(chapters[chapter].asSong, time: time, duration: 60, chapterCount: 3,
                            clippings: clippings, now: start.addingTimeInterval(offset))
    }

    private var record: ClippingLedger.DocumentRecord? { clippings.ledger.document("doc") }

    /// Finish the book the ordinary way: the end of the last chapter.
    private func finish() {
        XCTAssertEqual(play(2, at: 60, seconds: 0), "doc")
        XCTAssertEqual(record?.finished, true)
    }

    func testReplayingPastTheFirstMinuteUnfinishesAndPlayResumesThere() {
        finish()
        // Play on a finished book starts at chapter 1. Its first minute keeps the mark.
        for (n, t) in stride(from: 5.0, through: 55, by: 5).enumerated() {
            XCTAssertNil(play(0, at: t, seconds: Double(100 + n)))
            XCTAssertEqual(record?.finished, true, "still sampling at \(t) s")
        }
        // Into chapter 2: 65 s into the book.
        XCTAssertNil(play(1, at: 5, seconds: 200))
        XCTAssertEqual(record?.finished, false)
        XCTAssertEqual(record?.finishedAt, start.addingTimeInterval(200),
                       "stamped now, so the merge carries the unfinish to the other device")

        XCTAssertNil(play(1, at: 20, seconds: 215))
        XCTAssertEqual(BookPlayback.startIndex(in: chapters, position: (1, 20), finished: record?.finished ?? true), 1)
        XCTAssertEqual(BookPlayback.resumeOffset(for: chapters[1].asSong, clippings: clippings), 20,
                       "the next Play resumes where the replay stopped")
    }

    /// Crossing the minute inside the first chapter counts too, for a book with long chapters.
    func testTheMinuteIsCountedFromTheStartOfTheBook() {
        XCTAssertEqual(BookPlayback.secondsIntoBook(chapterIndex: 2, seconds: 7, documentID: "doc", clippings: clippings), 127)
        XCTAssertEqual(BookPlayback.secondsIntoBook(chapterIndex: 0, seconds: 59, documentID: "doc", clippings: clippings), 59)
    }

    /// Right after finishing, the last chapter starting once more (as the TBX-10974 walk saw on
    /// the iPhone) must not undo the finish: the position was already past the first minute.
    func testTheTickAfterFinishingDoesNotUndoIt() {
        finish()
        XCTAssertNil(play(2, at: 5, seconds: 10))
        XCTAssertNil(play(2, at: 10, seconds: 15))
        XCTAssertEqual(record?.finished, true)
    }

    func testAnUnfinishedBookIsLeftAlone() {
        XCTAssertNil(play(0, at: 55, seconds: 0))
        XCTAssertNil(play(1, at: 5, seconds: 10))
        XCTAssertEqual(record?.finished, false)
        XCTAssertNil(record?.finishedAt, "no finished stamp for a book never finished")
    }

    /// The other device still says finished, from before the replay. The newer unfinish wins the
    /// per-field merge both ways round.
    func testTheUnfinishWinsTheMergeAgainstTheOlderFinish() {
        finish()
        let otherDevice = clippings.ledger
        _ = play(0, at: 55, seconds: 100)
        _ = play(1, at: 5, seconds: 110)
        XCTAssertEqual(ClippingLedger.merged(clippings.ledger, otherDevice).document("doc")?.finished, false)
        XCTAssertEqual(ClippingLedger.merged(otherDevice, clippings.ledger).document("doc")?.finished, false)
    }

    /// Played to the end again, it finishes again.
    func testAReplayToTheEndFinishesAgain() {
        finish()
        _ = play(0, at: 55, seconds: 100)
        _ = play(1, at: 5, seconds: 110)
        XCTAssertEqual(record?.finished, false)
        XCTAssertEqual(play(2, at: 60, seconds: 300), "doc")
        XCTAssertEqual(record?.finished, true)
    }
}
