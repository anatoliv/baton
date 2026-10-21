import BatonPlaybackKit
import UserNotifications
import XCTest
@testable import BatonMobile

/// The iPhone's iOS 18 to 25 fallback, and the Mac's when Baton is not running: the
/// notification requests that stand for the store's alarms and timer. Wall-clock calendar
/// triggers for alarms, so DST and time zone changes need nothing extra; a time interval for the
/// timer; nothing for what is off or paused.
@MainActor
final class AlarmNotificationRequestTests: XCTestCase {
    private let song = NavidromeSong(id: "song-1", title: "Variatio 4", artist: "Kimiko Ishizaka")

    private func store() -> AlarmStore {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return AlarmStore(defaults: ThrowawayDefaults.make("alarm-requests"), calendar: { calendar })
    }

    private func requests(_ store: AlarmStore, now: Date) -> [UNNotificationRequest] {
        AlarmNotificationBridge.requests(for: store, now: now, soundName: { _ in AlarmNotificationBridge.chime })
    }

    func testRepeatingAlarmHasOneRepeatingTriggerPerDay() throws {
        let store = store()
        let now = Date()
        store.save(BatonAlarm(hour: 6, minute: 45, repeatDays: AlarmRepeat.weekdays, choice: .song(song)), now: now)
        let made = requests(store, now: now)
        XCTAssertEqual(made.count, 5)
        let triggers = made.compactMap { $0.trigger as? UNCalendarNotificationTrigger }
        XCTAssertEqual(triggers.count, 5)
        XCTAssertTrue(triggers.allSatisfy { $0.repeats && $0.dateComponents.hour == 6 && $0.dateComponents.minute == 45 })
        XCTAssertEqual(Set(triggers.compactMap(\.dateComponents.weekday)), AlarmRepeat.weekdays)
        let content = try XCTUnwrap(made.first?.content)
        XCTAssertEqual(content.categoryIdentifier, AlarmNotificationBridge.alarmSnoozeCategory, "Snooze on: Play and Snooze")
        XCTAssertNotNil(AlarmNotificationBridge.alarmID(in: content))
        XCTAssertTrue(content.body.contains("Variatio 4"))
    }

    func testOneOffAlarmFiresOnceAndASnoozeAddsItsOwn() throws {
        let store = store()
        let now = Date()
        let alarm = BatonAlarm(hour: 7, minute: 0, snoozeEnabled: false, choice: .song(song))
        store.save(alarm, now: now)
        var made = requests(store, now: now)
        XCTAssertEqual(made.count, 1)
        let trigger = try XCTUnwrap(made.first?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        XCTAssertNotNil(trigger.dateComponents.day, "a one-off names its date")
        XCTAssertEqual(made.first?.content.categoryIdentifier, AlarmNotificationBridge.alarmCategory, "Snooze off: Play only")

        store.snooze(id: alarm.id, now: now)
        made = requests(store, now: now)
        let snooze = try XCTUnwrap(made.first { $0.trigger is UNTimeIntervalNotificationTrigger }?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(snooze.timeInterval, BatonAlarm.snoozeInterval, accuracy: 1)
    }

    func testOffAlarmAndPausedTimerScheduleNothing() {
        let store = store()
        let now = Date()
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm, now: now)
        store.setEnabled(false, id: alarm.id)
        store.startTimer(duration: 300, choice: .song(song), now: now)
        store.pauseTimer(now: now)
        XCTAssertTrue(requests(store, now: now).isEmpty)
    }

    func testRunningTimerRingsWhenItEnds() throws {
        let store = store()
        let now = Date()
        store.startTimer(duration: 90, label: "Tea", choice: .song(song), now: now)
        let made = requests(store, now: now.addingTimeInterval(30))
        let trigger = try XCTUnwrap(made.first?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 60, accuracy: 0.5)
        XCTAssertEqual(made.first?.content.title, "Tea")
        XCTAssertEqual(made.first?.content.categoryIdentifier, AlarmNotificationBridge.timerCategory)
    }

    /// iOS 18 to 25 ring the clip of the chosen track when one was cut, else the chime, else the
    /// system's sound.
    func testRequestsRingTheClipElseTheChimeElseTheSystemSound() throws {
        let store = store()
        let now = Date()
        let clipped = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        let chimed = BatonAlarm(hour: 8, minute: 0, choice: .song(song))
        let plain = BatonAlarm(hour: 9, minute: 0, choice: .song(song))
        for alarm in [clipped, chimed, plain] { store.save(alarm, now: now) }
        let clip = AlarmClipStore.fileName(for: clipped.id)
        let made = AlarmNotificationBridge.requests(for: store, now: now) { id in
            switch id {
            case clipped.id: clip
            case chimed.id: AlarmNotificationBridge.chime
            default: ""
            }
        }
        func sound(_ alarm: BatonAlarm) throws -> UNNotificationSound {
            let request = try XCTUnwrap(made.first { AlarmNotificationBridge.alarmID(in: $0.content) == alarm.id })
            return try XCTUnwrap(request.content.sound)
        }
        XCTAssertEqual(clip, "baton-alarm-\(clipped.id.uuidString).caf")
        XCTAssertEqual(try sound(clipped), UNNotificationSound(named: UNNotificationSoundName(clip)))
        XCTAssertEqual(try sound(chimed), UNNotificationSound(named: UNNotificationSoundName(AlarmNotificationBridge.chime)))
        XCTAssertEqual(try sound(plain), UNNotificationSound.default)
        XCTAssertNotEqual(try sound(clipped), try sound(chimed))
    }

    /// A timer and an alarm at once: both are scheduled, and cancelling one
    /// leaves the other's requests.
    func testATimerAndAnAlarmAreScheduledTogetherAndCancelledApart() {
        let store = store()
        let now = Date()
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm, now: now)
        store.startTimer(duration: 600, choice: .song(song), now: now)
        var ids = requests(store, now: now).map(\.identifier)
        XCTAssertEqual(ids.filter { $0.hasSuffix(".timer") }.count, 1, ids.description)
        XCTAssertEqual(ids.filter { $0.contains(alarm.id.uuidString) }.count, 1, ids.description)

        store.cancelTimer()
        ids = requests(store, now: now).map(\.identifier)
        XCTAssertEqual(ids, ["\(AlarmNotificationBridge.requestPrefix)\(alarm.id.uuidString).once"])

        store.startTimer(duration: 600, choice: .song(song), now: now)
        store.setEnabled(false, id: alarm.id)
        ids = requests(store, now: now).map(\.identifier)
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(ids.first?.hasSuffix(".timer") == true, ids.description)
    }
}
