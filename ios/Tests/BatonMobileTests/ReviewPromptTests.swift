import XCTest
@testable import BatonMobile

/// The review prompt is one of the few things in the app that cannot be retried: iOS allows
/// three across every app the user owns, per year, and reports nothing back about whether it
/// was shown or what the answer was. So the gate is worth proving rather than eyeballing.
final class ReviewPromptTests: XCTestCase {
    private let version = "1.1"

    func testStaysQuietUntilThreeSeparateDaysOfListening() {
        var state = ReviewPrompt.State()
        XCTAssertFalse(ReviewPrompt.shouldAsk(state, version: version))

        state = ReviewPrompt.recording(day: "2026-09-01", in: state)
        XCTAssertFalse(ReviewPrompt.shouldAsk(state, version: version))

        state = ReviewPrompt.recording(day: "2026-09-02", in: state)
        XCTAssertFalse(ReviewPrompt.shouldAsk(state, version: version))

        state = ReviewPrompt.recording(day: "2026-09-03", in: state)
        XCTAssertTrue(ReviewPrompt.shouldAsk(state, version: version))
    }

    /// The bug this exists to stop: an afternoon of pressing play reading as three days of
    /// affection, and the one prompt of the year being spent on the first hour of ownership.
    func testAWholeDayOfPlayingIsStillOneDay() {
        var state = ReviewPrompt.State()
        for _ in 0..<40 {
            state = ReviewPrompt.recording(day: "2026-09-01", in: state)
        }
        XCTAssertEqual(state.listeningDays, ["2026-09-01"])
        XCTAssertFalse(ReviewPrompt.shouldAsk(state, version: version))
    }

    func testNeverAsksTwiceForTheSameVersion() {
        var state = ReviewPrompt.State()
        for day in ["2026-09-01", "2026-09-02", "2026-09-03"] {
            state = ReviewPrompt.recording(day: day, in: state)
        }
        XCTAssertTrue(ReviewPrompt.shouldAsk(state, version: version))

        state.lastPromptedVersion = version
        XCTAssertFalse(ReviewPrompt.shouldAsk(state, version: version))

        // A later release earns a fresh ask: the user is rating something new.
        XCTAssertTrue(ReviewPrompt.shouldAsk(state, version: "1.2"))
    }

    /// Left untrimmed this array grows one entry per day of ownership, forever, in a plist
    /// that is read on every play.
    func testTheDayListDoesNotGrowWithoutBound() {
        var state = ReviewPrompt.State()
        for day in 1...30 {
            state = ReviewPrompt.recording(day: String(format: "2026-09-%02d", day), in: state)
        }
        for day in 1...30 {
            state = ReviewPrompt.recording(day: String(format: "2026-10-%02d", day), in: state)
        }
        XCTAssertEqual(state.listeningDays.count, ReviewPrompt.requiredListeningDays)
        // Trimming keeps the newest, and must not drop the gate back below the threshold.
        XCTAssertEqual(state.listeningDays.last, "2026-10-30")
        XCTAssertTrue(ReviewPrompt.shouldAsk(state, version: version))
    }

    func testDayStampsAreZeroPaddedSoTheySortAsDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let march9 = DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 3, day: 9, hour: 23, minute: 59
        ).date!
        XCTAssertEqual(ReviewPrompt.dayStamp(march9, calendar: calendar), "2026-03-09")
    }

    /// Two plays either side of midnight are two days, which is the whole reason the stamp is
    /// a calendar day rather than a rolling 24-hour window.
    func testEitherSideOfMidnightCountsAsTwoDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func stamp(day: Int, hour: Int) -> String {
            let date = DateComponents(
                calendar: calendar, timeZone: calendar.timeZone,
                year: 2026, month: 9, day: day, hour: hour
            ).date!
            return ReviewPrompt.dayStamp(date, calendar: calendar)
        }
        var state = ReviewPrompt.State()
        state = ReviewPrompt.recording(day: stamp(day: 1, hour: 23), in: state)
        state = ReviewPrompt.recording(day: stamp(day: 2, hour: 0), in: state)
        XCTAssertEqual(state.listeningDays.count, 2)
    }

    /// The live path, end to end, over the real `UserDefaults` keys: three days recorded, one
    /// claim granted, every later claim refused.
    func testClaimSpendsThePromptExactlyOnce() {
        ReviewPrompt.resetForTesting()
        defer { ReviewPrompt.resetForTesting() }

        let day = TimeInterval(86_400)
        for offset in [2 * day, day, 0] {
            ReviewPrompt.recordListening(now: Date(timeIntervalSinceNow: -offset))
        }
        XCTAssertTrue(ReviewPrompt.isEarned)
        XCTAssertTrue(ReviewPrompt.claimAsk())
        XCTAssertFalse(ReviewPrompt.claimAsk())
        XCTAssertFalse(ReviewPrompt.isEarned)
    }
}
