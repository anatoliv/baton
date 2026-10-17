import XCTest
@testable import BatonMobile

/// The alarm schedule as the iPhone build computes it. The full cases live in
/// `BatonPlaybackKitTests/AlarmScheduleTests`, which run on the Mac; that package's test target
/// cannot build for iOS (several engine tests use the Mac's output devices), so the cases that
/// matter most are repeated here against the same code compiled for the phone: the next
/// occurrence, repeat days, DST both ways, a one-off switching off and snooze.
@MainActor
final class AlarmSchedulePhoneTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let song = NavidromeSong(id: "song-1", title: "Variatio 4", artist: "Kimiko Ishizaka")

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = newYork
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, utc: Bool = false) -> Date {
        var c = calendar
        if utc { c.timeZone = TimeZone(identifier: "UTC")! }
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func alarm(_ h: Int, _ m: Int, repeats: Set<Int> = []) -> BatonAlarm {
        BatonAlarm(hour: h, minute: m, repeatDays: repeats, choice: .song(song), armedAt: .distantPast)
    }

    func testNextOccurrenceAndWeekdays() {
        XCTAssertEqual(alarm(7, 0).nextOccurrence(after: date(2026, 10, 17, 8, 0), calendar: calendar), date(2026, 10, 18, 7, 0))
        // Friday after the alarm: the weekday alarm comes back on Monday.
        XCTAssertEqual(alarm(7, 0, repeats: AlarmRepeat.weekdays).nextOccurrence(after: date(2026, 10, 16, 8, 0), calendar: calendar),
                       date(2026, 10, 19, 7, 0))
    }

    func testDSTBothWays() {
        // 2:30 does not exist on 8 March 2026: the first valid time after it, 3:00 EDT.
        XCTAssertEqual(alarm(2, 30).nextOccurrence(after: date(2026, 3, 7, 12, 0), calendar: calendar), date(2026, 3, 8, 7, 0, utc: true))
        // 1:30 happens twice on 1 November 2026: the first pass only.
        let a = alarm(1, 30, repeats: AlarmRepeat.everyDay)
        let first = a.nextOccurrence(after: date(2026, 10, 31, 12, 0), calendar: calendar)!
        XCTAssertEqual(first, date(2026, 11, 1, 5, 30, utc: true))
        XCTAssertEqual(a.nextOccurrence(after: first, calendar: calendar), date(2026, 11, 2, 6, 30, utc: true))
    }

    func testOneOffSwitchesOffAndSnoozeComesBack() {
        let cal = calendar
        let store = AlarmStore(defaults: ThrowawayDefaults.make("phone-alarms"), calendar: { cal })
        let a = alarm(7, 0)
        store.save(a, now: date(2026, 10, 17, 6, 0))
        XCTAssertEqual(store.due(at: date(2026, 10, 17, 7, 0)).count, 1)
        XCTAssertFalse(store.alarms[0].isEnabled)
        store.snooze(id: a.id, now: date(2026, 10, 17, 7, 0))
        XCTAssertEqual(store.nextDue(after: date(2026, 10, 17, 7, 0)), date(2026, 10, 17, 7, 9))
        XCTAssertEqual(store.due(at: date(2026, 10, 17, 7, 9)).count, 1)
    }
}
