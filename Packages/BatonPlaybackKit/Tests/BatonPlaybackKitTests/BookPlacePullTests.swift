import XCTest
@testable import BatonPlaybackKit

/// Play on a book fetches the other device's place first, and never waits long for it
///. Found by the TBX-10974 re-walk: a Mac left in front never pulled, so Play there
/// started from the Mac's own older place while the phone had played on.
@MainActor
final class BookPlacePullTests: XCTestCase {
    private let book = "doc-canal"

    private func ledger(chapter: Int, seconds: Double, finished: Bool = false) -> ClippingLedger {
        var ledger = ClippingLedger()
        ledger.setPosition(documentID: book, chapterIndex: chapter, seconds: seconds)
        if finished { ledger.setFinished(true, documentID: book) }
        return ledger
    }

    /// The order: the sync lands first, then Play reads the place, so it starts where the other
    /// device stopped (chapter 3 at 14.25 s), not where this one did (chapter 2 at 10.25 s).
    func testPlayStartsFromThePlaceThePullBrought() async {
        var local = ledger(chapter: 1, seconds: 10.25)
        var events: [String] = []
        let outcome = await BookPlacePull.run(sync: {
            events.append("sync")
            try? await Task.sleep(for: .milliseconds(50))
            local = self.ledger(chapter: 2, seconds: 14.25)
            return true
        })
        events.append("start")
        let place = BookPlacePull.place(of: book, in: local)
        XCTAssertEqual(outcome, .pulled)
        XCTAssertEqual(events, ["sync", "start"])
        XCTAssertEqual(place.position?.chapterIndex, 2, "Play started from this device's own older place")
        XCTAssertEqual(place.position?.seconds ?? 0, 14.25, accuracy: 0.001)
    }

    /// A gateway that does not answer holds Play up for the bound and no longer: the book starts
    /// from the place here, and the sync was asked.
    func testASlowGatewayStartsFromTheLocalPlaceWithinTheBound() async {
        let local = ledger(chapter: 1, seconds: 10.25)
        var asked = false
        let began = Date()
        let outcome = await BookPlacePull.run(timeout: .milliseconds(300), sync: {
            asked = true
            try? await Task.sleep(for: .seconds(5))
            return true
        })
        let waited = Date().timeIntervalSince(began)
        XCTAssertTrue(asked, "Play did not ask for the other device's place")
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(waited, 1.0, "Play waited \(waited) s for a gateway that did not answer")
        XCTAssertEqual(BookPlacePull.place(of: book, in: local).position?.chapterIndex, 1)
    }

    /// The default bound is about two seconds.
    func testTheDefaultBoundIsAboutTwoSeconds() {
        XCTAssertEqual(BookPlacePull.defaultTimeout, .seconds(2))
    }

    /// An unreachable gateway answers at once with a failure, and Play goes ahead.
    func testAnUnreachableGatewayStartsAtOnce() async {
        var asked = false
        let outcome = await BookPlacePull.run(sync: { asked = true; return false })
        XCTAssertTrue(asked)
        XCTAssertEqual(outcome, .unreachable)
    }

    /// Switched off (`BATON_DEBUG_PREFERENCE_SYNC=off`) or no gateway: the app hands over no sync,
    /// and nothing waits.
    func testSwitchedOffSyncAsksNothingAndDoesNotWait() async {
        let began = Date()
        let outcome = await BookPlacePull.run(sync: nil)
        XCTAssertEqual(outcome, .off)
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.05)
    }

    /// Which Plays resume, and so pull: the book's Play, and a tap on the chapter the book is in.
    /// A tap on another chapter starts that chapter and needs no place.
    func testOnlyAResumingPlayPulls() {
        XCTAssertTrue(BookPlacePull.resumes(fromChapter: nil, placeChapter: 1))
        XCTAssertTrue(BookPlacePull.resumes(fromChapter: nil, placeChapter: nil))
        XCTAssertTrue(BookPlacePull.resumes(fromChapter: 1, placeChapter: 1))
        XCTAssertFalse(BookPlacePull.resumes(fromChapter: 0, placeChapter: 1))
        XCTAssertFalse(BookPlacePull.resumes(fromChapter: 2, placeChapter: nil))
    }

    /// The finished mark travels with the place, so a book the other device finished starts
    /// from the top here.
    func testThePlaceCarriesTheFinishedMark() {
        let place = BookPlacePull.place(of: book, in: ledger(chapter: 2, seconds: 25, finished: true))
        XCTAssertTrue(place.finished)
        XCTAssertNil(BookPlacePull.place(of: "other", in: ledger(chapter: 2, seconds: 25)).position)
    }
}
