import BatonPlaybackKit
import UserNotifications
import XCTest
@testable import Baton

/// C3-19: the system keeps 64 pending notifications per app and drops the rest
/// without an error. Ten daily alarms want 70; whichever came last in the list was lost, which
/// could be tomorrow morning's alarm or a timer due in a minute. The soonest 64 are kept.
@MainActor
final class AlarmNotificationCapTests: XCTestCase {
    private let song = NavidromeSong(id: "song-1", title: "Variatio 4", artist: "Kimiko Ishizaka")

    func testTheSoonestRequestsAreKeptWithinTheSystemsCap() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarm-cap"), calendar: { calendar })
        let now = Date()
        for hour in 5..<15 {
            store.save(BatonAlarm(hour: hour, minute: 0, repeatDays: Set(1...7), choice: .song(song)), now: now)
        }
        let timer = store.startTimer(duration: 60, choice: .song(song), now: now)

        let made = AlarmNotificationBridge.requests(for: store, now: now, soundName: { _, _ in AlarmNotificationBridge.chime })
        XCTAssertEqual(made.count, AlarmNotificationBridge.maximumPending)
        XCTAssertEqual(made.first?.identifier, "\(AlarmNotificationBridge.requestPrefix)\(timer.id.uuidString).timer",
                       "the timer due in a minute comes first")
        let all = AlarmNotificationBridge.requests(for: store, now: now, soundName: { _, _ in AlarmNotificationBridge.chime },
                                                   limit: .max)
        XCTAssertEqual(all.count, 71)
        func fires(_ request: UNNotificationRequest) -> Date {
            if let trigger = request.trigger as? UNCalendarNotificationTrigger {
                return calendar.nextDate(after: now, matching: trigger.dateComponents, matchingPolicy: .nextTime) ?? .distantFuture
            }
            return now + ((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval ?? 0)
        }
        let latestKept = try XCTUnwrap(made.map(fires).max())
        for dropped in all.dropFirst(made.count) {
            XCTAssertGreaterThanOrEqual(fires(dropped), latestKept, "\(dropped.identifier) is further away than everything kept")
        }
    }
}
