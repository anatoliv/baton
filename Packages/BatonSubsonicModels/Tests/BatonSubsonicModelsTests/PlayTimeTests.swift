import XCTest
@testable import BatonSubsonicModels

/// The boundary is the whole point.
///
/// Eleven hand-rolled copies of this existed and six of them had no hour branch at all, so
/// a 70-minute mix read `70:23` and its remaining time read `-101:30`. Every one of those
/// copies was correct for the tracks somebody happened to test it with — three-minute
/// songs — which is exactly why nothing caught it. So these tests live at 59:59 and
/// 1:00:00 and stay there.
final class PlayTimeTests: XCTestCase {
    func testTrackRollsOverAtExactlyOneHour() {
        XCTAssertEqual(PlayTime.track(3599), "59:59")
        XCTAssertEqual(PlayTime.track(3600), "1:00:00")
        XCTAssertEqual(PlayTime.track(3601), "1:00:01")
    }

    /// The case that shipped: 70 minutes must not print as minute 70.
    func testTrackDoesNotCountMinutesPastSixty() {
        XCTAssertEqual(PlayTime.track(4223), "1:10:23")
        XCTAssertNotEqual(PlayTime.track(4223), "70:23")
    }

    func testTrackUnderAnHourHasNoHourField() {
        XCTAssertEqual(PlayTime.track(261), "4:21")
        XCTAssertEqual(PlayTime.track(61), "1:01")
        XCTAssertEqual(PlayTime.track(9), "0:09")
    }

    /// A row with no duration renders nothing, not `0:00` — which reads as a real track
    /// that happens to be silent.
    func testAbsentAndNonPositiveDurationsProduceNothing() {
        XCTAssertNil(PlayTime.track(nil as Int?))
        XCTAssertNil(PlayTime.track(0))
        XCTAssertNil(PlayTime.track(-5))
        XCTAssertNil(PlayTime.total(nil as Int?))
        XCTAssertNil(PlayTime.total(0))
        XCTAssertNil(PlayTime.spoken(0))
    }

    func testDoubleOverloadRejectsInfinityAndNaN() {
        XCTAssertNil(PlayTime.track(seconds: Double.infinity))
        XCTAssertNil(PlayTime.track(seconds: Double.nan))
        XCTAssertEqual(PlayTime.track(seconds: 261.7), "4:21")
    }

    func testRemainingCarriesASignAndTheSameBoundary() {
        XCTAssertEqual(PlayTime.remaining(3599), "-59:59")
        XCTAssertEqual(PlayTime.remaining(3600), "-1:00:00")
        XCTAssertEqual(PlayTime.remaining(5955), "-1:39:15")
    }

    /// A stream whose reported duration is a little short would otherwise count up past
    /// the end, which looks broken even though the arithmetic is honest.
    func testRemainingClampsAtZeroRatherThanGoingPositive() {
        XCTAssertEqual(PlayTime.remaining(0), "-0:00")
        XCTAssertEqual(PlayTime.remaining(-12), "-0:00")
    }

    func testTotalReadsAsAnEveningNotAClock() {
        XCTAssertEqual(PlayTime.total(2700), "45m")
        XCTAssertEqual(PlayTime.total(3600), "1h 0m")
        XCTAssertEqual(PlayTime.total(25_020), "6h 57m")
    }

    /// "0 min" was what a 40-second podcast trailer used to render as.
    func testSpokenRoundsUpToOneMinute() {
        XCTAssertEqual(PlayTime.spoken(40), "1 min")
        XCTAssertEqual(PlayTime.spoken(1), "1 min")
        XCTAssertEqual(PlayTime.spoken(2280), "38 min")
        XCTAssertEqual(PlayTime.spoken(15_120), "4 hr 12 min")
        XCTAssertEqual(PlayTime.spoken(7200), "2 hr")
    }
}
