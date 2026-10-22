import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// When a Clock-style alarm or timer is due (TBX-11171, specs/alarm-and-timer.md): the next
/// occurrence, repeat days, DST in both directions, a time zone change, one-off switch-off,
/// snooze, the late grace and answering each occurrence once. Pure dates, so it runs the same on
/// the Mac and on an iOS simulator.
@MainActor
final class AlarmScheduleTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, in zone: TimeZone? = nil) -> Date {
        calendar(zone ?? newYork).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        date(y, mo, d, h, mi, in: TimeZone(identifier: "UTC")!)
    }

    private let song = NavidromeSong(id: "song-1", title: "Variatio 4", artist: "Kimiko Ishizaka")
    private var choice: AlarmChoice { .song(song) }

    private func alarm(_ h: Int, _ m: Int, repeats: Set<Int> = [], armedAt: Date = .distantPast) -> BatonAlarm {
        BatonAlarm(hour: h, minute: m, repeatDays: repeats, choice: choice, armedAt: armedAt)
    }

    private func store(_ zone: TimeZone? = nil) -> AlarmStore {
        let defaults = ThrowawayDefaults.make("alarms")
        let cal = calendar(zone ?? newYork)
        return AlarmStore(defaults: defaults, calendar: { cal })
    }

    // MARK: Next occurrence

    func testOneOffAlarmIsLaterTodayOrTomorrow() {
        let a = alarm(7, 0)
        XCTAssertEqual(a.nextOccurrence(after: date(2026, 10, 17, 6, 0), calendar: calendar(newYork)), date(2026, 10, 17, 7, 0))
        XCTAssertEqual(a.nextOccurrence(after: date(2026, 10, 17, 8, 0), calendar: calendar(newYork)), date(2026, 10, 18, 7, 0))
        // Exactly at the time, the next one is tomorrow's: "after" is exclusive.
        XCTAssertEqual(a.nextOccurrence(after: date(2026, 10, 17, 7, 0), calendar: calendar(newYork)), date(2026, 10, 18, 7, 0))
    }

    func testWeekdayAlarmSkipsTheWeekend() {
        // Friday 16 October 2026, after the alarm: next is Monday the 19th.
        let a = alarm(7, 0, repeats: AlarmRepeat.weekdays)
        XCTAssertEqual(a.nextOccurrence(after: date(2026, 10, 16, 8, 0), calendar: calendar(newYork)), date(2026, 10, 19, 7, 0))
        // Friday before the alarm: today.
        XCTAssertEqual(a.nextOccurrence(after: date(2026, 10, 16, 6, 0), calendar: calendar(newYork)), date(2026, 10, 16, 7, 0))
    }

    func testPreviousOccurrenceCountsTheExactMinute() {
        let a = alarm(7, 0, repeats: AlarmRepeat.everyDay)
        let cal = calendar(newYork)
        XCTAssertEqual(a.previousOccurrence(atOrBefore: date(2026, 10, 17, 7, 0), calendar: cal), date(2026, 10, 17, 7, 0))
        XCTAssertEqual(a.previousOccurrence(atOrBefore: date(2026, 10, 17, 6, 59), calendar: cal), date(2026, 10, 16, 7, 0))
    }

    // MARK: DST and time zones

    func testSpringForwardSkippedTimeFiresAtTheFirstValidTime() {
        // 8 March 2026, New York: 2:00 jumps to 3:00, so 2:30 does not exist that night.
        let a = alarm(2, 30)
        let next = a.nextOccurrence(after: date(2026, 3, 7, 12, 0), calendar: calendar(newYork))
        XCTAssertEqual(next, utc(2026, 3, 8, 7, 0), "3:00 EDT, the first time after the gap")
    }

    func testFallBackRepeatedTimeFiresOnceOnItsFirstPass() {
        // 1 November 2026, New York: 1:00 to 2:00 happens twice. 1:30 goes off at 1:30 EDT.
        let a = alarm(1, 30, repeats: AlarmRepeat.everyDay)
        let cal = calendar(newYork)
        let first = a.nextOccurrence(after: date(2026, 10, 31, 12, 0), calendar: cal)
        XCTAssertEqual(first, utc(2026, 11, 1, 5, 30), "1:30 EDT")
        // Not again an hour later at 1:30 EST: the next is the following night.
        let second = a.nextOccurrence(after: first!, calendar: cal)
        XCTAssertEqual(second, utc(2026, 11, 2, 6, 30), "1:30 EST on 2 November")
    }

    func testDailyAlarmKeepsItsWallClockTimeAcrossTheChange() {
        let a = alarm(7, 0, repeats: AlarmRepeat.everyDay)
        let cal = calendar(newYork)
        let saturday = a.nextOccurrence(after: date(2026, 10, 31, 6, 0), calendar: cal)!
        let sunday = a.nextOccurrence(after: saturday, calendar: cal)!
        XCTAssertEqual(saturday, utc(2026, 10, 31, 11, 0))
        XCTAssertEqual(sunday, utc(2026, 11, 1, 12, 0))
        XCTAssertEqual(sunday.timeIntervalSince(saturday), 25 * 3600, "the day the clocks go back is 25 hours long")
    }

    func testTimeZoneChangeKeepsLocalTime() {
        let a = alarm(7, 0)
        let instant = utc(2026, 10, 17, 0, 0)
        let ny = a.nextOccurrence(after: instant, calendar: calendar(newYork))!
        let tyo = a.nextOccurrence(after: instant, calendar: calendar(tokyo))!
        XCTAssertEqual(calendar(newYork).component(.hour, from: ny), 7)
        XCTAssertEqual(calendar(tokyo).component(.hour, from: tyo), 7)
        XCTAssertNotEqual(ny, tyo)
    }

    func testStoreFollowsItsCalendarWhenTheZoneChanges() {
        var zone = newYork
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.tz"), calendar: { [unowned self] in self.calendar(zone) })
        store.save(alarm(7, 0), now: utc(2026, 10, 17, 0, 0))
        XCTAssertEqual(store.nextDue(after: utc(2026, 10, 17, 0, 0)), utc(2026, 10, 17, 11, 0))
        zone = tokyo
        XCTAssertEqual(store.nextDue(after: utc(2026, 10, 17, 0, 0)), utc(2026, 10, 17, 22, 0), "7:00 in Tokyo")
    }

    // MARK: Repeat words

    func testRepeatSummaryUsesClocksWords() {
        let cal = calendar(newYork)
        XCTAssertEqual(AlarmRepeat.summary([], calendar: cal), "Never")
        XCTAssertEqual(AlarmRepeat.summary(AlarmRepeat.everyDay, calendar: cal), "Every day")
        XCTAssertEqual(AlarmRepeat.summary(AlarmRepeat.weekdays, calendar: cal), "Weekdays")
        XCTAssertEqual(AlarmRepeat.summary(AlarmRepeat.weekend, calendar: cal), "Weekends")
        XCTAssertEqual(AlarmRepeat.summary([2], calendar: cal), "Every Monday")
        XCTAssertEqual(AlarmRepeat.summary([6, 2, 4], calendar: cal), "Mon Wed Fri")
    }

    // MARK: The store answering occurrences

    func testOneOffAlarmGoesOffOnceAndSwitchesItselfOff() {
        let store = store()
        store.save(alarm(7, 0), now: date(2026, 10, 17, 6, 0))
        XCTAssertTrue(store.due(at: date(2026, 10, 17, 6, 59)).isEmpty)
        let fires = store.due(at: date(2026, 10, 17, 7, 0))
        XCTAssertEqual(fires.map(\.occurrence), [date(2026, 10, 17, 7, 0)])
        XCTAssertEqual(fires.first?.isLate, false)
        XCTAssertFalse(store.alarms[0].isEnabled, "a one-off alarm switches off after going off, as in Clock")
        XCTAssertTrue(store.due(at: date(2026, 10, 17, 7, 1)).isEmpty, "answered once")
        XCTAssertNil(store.nextDue(after: date(2026, 10, 17, 7, 1)))
    }

    func testRepeatingAlarmStaysOnAndComesBack() {
        let store = store()
        store.save(alarm(7, 0, repeats: AlarmRepeat.everyDay), now: date(2026, 10, 17, 6, 0))
        XCTAssertEqual(store.due(at: date(2026, 10, 17, 7, 0)).count, 1)
        XCTAssertTrue(store.alarms[0].isEnabled)
        XCTAssertEqual(store.nextDue(after: date(2026, 10, 17, 7, 0)), date(2026, 10, 18, 7, 0))
        XCTAssertEqual(store.due(at: date(2026, 10, 18, 7, 0, in: nil)).count, 1)
    }

    func testAnAlarmSavedAfterItsTimeWaitsForTomorrow() {
        let store = store()
        store.save(alarm(7, 0), now: date(2026, 10, 17, 7, 30))
        XCTAssertTrue(store.due(at: date(2026, 10, 17, 7, 31)).isEmpty, "7:00 today came before it was set")
        XCTAssertEqual(store.nextDue(after: date(2026, 10, 17, 7, 31)), date(2026, 10, 18, 7, 0))
    }

    func testSwitchedOffAlarmNeverFires() {
        let store = store()
        let a = alarm(7, 0, repeats: AlarmRepeat.everyDay)
        store.save(a, now: date(2026, 10, 17, 6, 0))
        store.setEnabled(false, id: a.id)
        XCTAssertTrue(store.due(at: date(2026, 10, 17, 7, 0)).isEmpty)
        XCTAssertNil(store.nextDue(after: date(2026, 10, 17, 6, 0)))
    }

    func testSnoozeComesBackInNineMinutes() {
        let store = store()
        let a = alarm(7, 0)
        store.save(a, now: date(2026, 10, 17, 6, 0))
        XCTAssertEqual(store.due(at: date(2026, 10, 17, 7, 0)).count, 1)
        store.snooze(id: a.id, now: date(2026, 10, 17, 7, 0))
        XCTAssertEqual(store.nextDue(after: date(2026, 10, 17, 7, 0)), date(2026, 10, 17, 7, 9))
        XCTAssertTrue(store.due(at: date(2026, 10, 17, 7, 8)).isEmpty)
        let again = store.due(at: date(2026, 10, 17, 7, 9))
        XCTAssertEqual(again.map(\.occurrence), [date(2026, 10, 17, 7, 9)])
        XCTAssertNil(store.alarms[0].snoozedUntil)
    }

    func testAnOccurrenceTooLongAgoComesBackAsMissed() {
        let store = store()
        store.save(alarm(7, 0), now: date(2026, 10, 17, 6, 0))
        let fires = store.due(at: date(2026, 10, 17, 7, 11))
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires.first?.isLate, true, "more than \(Int(AlarmStore.lateGrace / 60)) minutes late")
        XCTAssertFalse(store.alarms[0].isEnabled)
    }

    func testClaimAnswersAnOccurrenceOnceWhicheverPathComesFirst() {
        let store = store()
        let a = alarm(7, 0, repeats: AlarmRepeat.everyDay)
        store.save(a, now: date(2026, 10, 17, 6, 0))
        XCTAssertNotNil(store.claim(id: a.id, now: date(2026, 10, 17, 7, 2)), "the system path plays it")
        XCTAssertTrue(store.due(at: date(2026, 10, 17, 7, 3)).isEmpty, "and the in-app clock does not play it again")
        XCTAssertNil(store.claim(id: a.id, now: date(2026, 10, 17, 7, 4)), "nor does a second system callback")
    }

    func testStopAtTheSystemAlertMeansNothingStartsLater() {
        let store = store()
        let a = alarm(7, 0)
        store.save(a, now: date(2026, 10, 17, 6, 0))
        store.answer(id: a.id, now: date(2026, 10, 17, 7, 1))
        XCTAssertTrue(store.due(at: date(2026, 10, 17, 7, 2)).isEmpty)
        XCTAssertNil(store.claim(id: a.id, now: date(2026, 10, 17, 7, 2)))
    }

    /// A system callback arriving long after the alarm (the Mac asleep through it) used to
    /// answer it and play nothing, so it was never shown as missed (TBX-1000000506, C2-15).
    func testALateSystemCallbackLeavesTheAlarmToBeShownAsMissed() {
        let store = store()
        let a = alarm(7, 0)
        store.save(a, now: date(2026, 10, 17, 6, 0))
        XCTAssertNil(store.claim(id: a.id, now: date(2026, 10, 17, 7, 25)), "a late alarm is not played")
        let fires = store.due(at: date(2026, 10, 17, 7, 26))
        XCTAssertEqual(fires.count, 1, "the late alarm vanished without a missed notice")
        XCTAssertEqual(fires.first?.isLate, true)
    }

    /// Stop at the system alert while a snooze was pending kept the snooze, which rang later
    /// (TBX-1000000506, C2-16).
    func testStopAtTheSystemAlertCancelsAPendingSnooze() {
        let store = store()
        let a = alarm(7, 0, repeats: AlarmRepeat.everyDay)
        store.save(a, now: date(2026, 10, 17, 6, 0))
        _ = store.due(at: date(2026, 10, 17, 7, 0))
        store.snooze(id: a.id, now: date(2026, 10, 17, 7, 1))
        XCTAssertNotNil(store.alarms[0].snoozedUntil, "precondition: snoozed")
        store.answer(id: a.id, now: date(2026, 10, 17, 7, 2))
        XCTAssertNil(store.alarms[0].snoozedUntil, "Stop kept the snooze")
        XCTAssertTrue(store.due(at: date(2026, 10, 17, 7, 12)).isEmpty, "the snooze rang after Stop")
    }

    func testStorePersistsAcrossLaunches() {
        let defaults = ThrowawayDefaults.make("alarms.persist")
        let cal = calendar(newYork)
        let first = AlarmStore(defaults: defaults, calendar: { cal })
        let a = alarm(6, 45, repeats: AlarmRepeat.weekdays)
        first.save(a, now: date(2026, 10, 17, 6, 0))
        first.startTimer(duration: 300, label: "Tea", choice: choice, now: date(2026, 10, 17, 6, 0))
        let second = AlarmStore(defaults: defaults, calendar: { cal })
        XCTAssertEqual(second.alarms.map(\.id), [a.id])
        XCTAssertEqual(second.alarms.first?.repeatDays, AlarmRepeat.weekdays)
        XCTAssertEqual(second.timer?.displayLabel, "Tea")
        XCTAssertEqual(second.timer?.endsAt, date(2026, 10, 17, 6, 5))
    }

    /// Alarms this build cannot read (saved by a newer one, as `.radio` was added) are set aside,
    /// not replaced by an empty list at the next edit (TBX-1000000480 C2-14).
    func testUnreadableAlarmsAreSetAsideNotOverwritten() {
        let defaults = ThrowawayDefaults.make("alarms.unreadable")
        let cal = calendar(newYork)
        let saved = Data(#"{"alarms":[{"kind":"from-a-newer-baton"}],"answered":{}}"#.utf8)
        defaults.set(saved, forKey: AlarmStore.storageKey)
        let store = AlarmStore(defaults: defaults, calendar: { cal })
        XCTAssertTrue(store.alarms.isEmpty)
        store.save(alarm(7, 0), now: date(2026, 10, 17, 6, 0))
        XCTAssertEqual(defaults.data(forKey: AlarmStore.storageKey + ".unreadable"), saved)
    }

    // MARK: Timer

    func testTimerPauseAndResumeKeepTheRemainingTime() {
        let store = store()
        let start = date(2026, 10, 17, 9, 0)
        store.startTimer(duration: 600, choice: choice, now: start)
        store.pauseTimer(now: start.addingTimeInterval(120))
        XCTAssertEqual(store.timer?.remaining(at: start.addingTimeInterval(500)), 480, "paused time does not count")
        XCTAssertNil(store.nextDue(after: start.addingTimeInterval(500)))
        XCTAssertTrue(store.due(at: start.addingTimeInterval(700)).isEmpty, "a paused timer never ends")
        store.resumeTimer(now: start.addingTimeInterval(1000))
        XCTAssertEqual(store.timer?.endsAt, start.addingTimeInterval(1480))
        XCTAssertTrue(store.due(at: start.addingTimeInterval(1479)).isEmpty)
        let fires = store.due(at: start.addingTimeInterval(1480))
        XCTAssertEqual(fires.map(\.kind), [.timer])
        XCTAssertNil(store.timer, "an ended timer goes away")
    }

    func testCancelledTimerNeverFires() {
        let store = store()
        let start = date(2026, 10, 17, 9, 0)
        store.startTimer(duration: 5, choice: choice, now: start)
        store.cancelTimer()
        XCTAssertTrue(store.due(at: start.addingTimeInterval(10)).isEmpty)
    }

    func testTimerFaceAndDurationBounds() {
        XCTAssertEqual(BatonTimer.clockFace(65), "1:05")
        XCTAssertEqual(BatonTimer.clockFace(3723), "1:02:03")
        XCTAssertEqual(BatonTimer.clockFace(4.2), "0:05", "rounds up, as a countdown should")
        XCTAssertEqual(BatonTimer(duration: 0, choice: choice, startedAt: Date()).duration, 1)
    }

    // MARK: What plays

    func testLongQueueIsCutAroundWhereItStarts() {
        let songs = (0 ..< 250).map { NavidromeSong(id: "s\($0)", title: "Song \($0)") }
        let picked = AlarmChoice.queue(songs, at: 200, source: .init(label: "Mix", kind: .playlist, id: "p1"), isBook: false)!
        XCTAssertEqual(picked.songs.count, AlarmChoice.maxSongs)
        XCTAssertEqual(picked.songs[picked.startIndex].id, "s200")
        XCTAssertEqual(picked.kind, .playlist)
        XCTAssertEqual(AlarmChoice.queue(songs, at: 10, source: nil, isBook: false)?.songs.first?.id, "s10")
    }

    func testMissingLocalFilesAreDroppedAndTheStartMoves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-alarm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = dir.appendingPathComponent("chapter-3.m4a")
        try Data([0]).write(to: present)
        let gone = dir.appendingPathComponent("chapter-2.m4a")
        let songs = [NavidromeSong(id: "server-1", title: "On the server"),
                     NavidromeSong(id: gone.absoluteString, title: "Chapter 2"),
                     NavidromeSong(id: present.absoluteString, title: "Chapter 3")]
        let choice = AlarmChoice(title: "Book", kind: .book, songs: songs, startIndex: 1)
        let resolved = AlarmCenter.dropMissingFiles(choice)
        XCTAssertEqual(resolved.songs.map(\.title), ["On the server", "Chapter 3"])
        XCTAssertEqual(resolved.startIndex, 1, "starts at the next chapter still here")
    }
}
