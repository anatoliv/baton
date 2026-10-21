import BatonPlaybackKit
import Foundation
import UserNotifications

/// Alarms and the timer as scheduled local notifications (TBX-11171, specs/alarm-and-timer.md):
/// the iPhone's way on iOS 18 to 25, and the Mac's way when Baton is not running.
///
/// A notification is a sound and a banner, once, at most 30 seconds of sound. Tapping it, or
/// Play, opens Baton, and Baton plays the chosen item. While Baton runs, its own clock plays the
/// item and the notification is not presented (`shouldPresent`), so nothing happens twice.
@MainActor
final class AlarmNotificationBridge: AlarmSystemBridge {
    nonisolated static let alarmCategory = "baton.alarm"
    nonisolated static let alarmSnoozeCategory = "baton.alarm.snoozable"
    nonisolated static let timerCategory = "baton.timer"
    nonisolated static let playAction = "baton.alarm.play"
    nonisolated static let snoozeAction = "baton.alarm.snooze"
    nonisolated static let idKey = "batonAlarmID"
    nonisolated static let requestPrefix = "baton.alarm."
    nonisolated static let chime = "BatonAlarmChime.caf"
    /// A gentle alarm's chime, rising over its first 20 seconds.
    nonisolated static let gentleChime = "BatonAlarmChimeGentle.caf"

    /// The sound for an alarm, by its id and whether it is gentle: a clip of its track when the
    /// app made one, else the chime ("" is the system's sound). The Mac's default: the chime,
    /// faded for a gentle alarm.
    var soundName: (UUID, Bool) -> String = { _, gentle in gentle ? AlarmNotificationBridge.gentleChime : AlarmNotificationBridge.chime }
    /// Makes the clips (the iPhone's `AlarmClipStore.prepare`). True when a sound changed, so the
    /// requests are made again with it.
    var prepare: ((AlarmStore) async -> Bool)?

    private var center: UNUserNotificationCenter { .current() }

    init() {}

    /// Adds Baton's alarm categories to whatever categories are already registered (spoken
    /// summaries on the Mac), rather than replacing them.
    static func registerCategories() async {
        let play = UNNotificationAction(identifier: playAction, title: "Play", options: [.foreground])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Snooze", options: [])
        let ours: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: alarmCategory, actions: [play], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: alarmSnoozeCategory, actions: [play, snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: timerCategory, actions: [play], intentIdentifiers: [], options: []),
        ]
        let existing = await UNUserNotificationCenter.current().notificationCategories()
        let kept = existing.filter { category in !ours.contains { $0.identifier == category.identifier } }
        UNUserNotificationCenter.current().setNotificationCategories(kept.union(ours))
    }

    func authorize() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return status == .authorized || status == .provisional
    }

    func silence(id: UUID) {
        let prefix = Self.requestPrefix + id.uuidString
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Schedules at once with the sounds ready now, then cuts the clips and, when one was made,
    /// schedules again with it, so a stream being fetched never holds a timer back.
    func sync(_ store: AlarmStore) async {
        await apply(store)
        if let prepare, await prepare(store) { await apply(store) }
    }

    private func apply(_ store: AlarmStore) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.requestPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        for request in Self.requests(for: store, now: Date(), soundName: soundName) {
            try? await center.add(request)
        }
    }

    /// The requests that stand for the store's alarms and timer. Pure apart from the clock, so
    /// it is what a test reads.
    static func requests(for store: AlarmStore, now: Date, soundName: (UUID, Bool) -> String) -> [UNNotificationRequest] {
        let calendar = store.calendar()
        var requests: [UNNotificationRequest] = []
        for alarm in store.alarms where alarm.isEnabled {
            let content = content(title: alarm.displayLabel, body: "Baton will play \(alarm.choice.summary).",
                                  id: alarm.id, category: alarm.snoozeEnabled ? alarmSnoozeCategory : alarmCategory,
                                  sound: soundName(alarm.id, alarm.gentleWake))
            if alarm.repeats {
                for day in alarm.repeatDays.sorted() {
                    let trigger = UNCalendarNotificationTrigger(
                        dateMatching: DateComponents(hour: alarm.hour, minute: alarm.minute, weekday: day), repeats: true)
                    requests.append(UNNotificationRequest(identifier: "\(requestPrefix)\(alarm.id.uuidString).\(day)",
                                                          content: content, trigger: trigger))
                }
            } else if let next = alarm.nextOccurrence(after: max(now, alarm.armedAt), calendar: calendar) {
                let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
                requests.append(UNNotificationRequest(identifier: "\(requestPrefix)\(alarm.id.uuidString).once", content: content,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
            }
            if let snoozed = alarm.snoozedUntil, snoozed > now {
                requests.append(UNNotificationRequest(
                    identifier: "\(requestPrefix)\(alarm.id.uuidString).snooze", content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: snoozed.timeIntervalSince(now), repeats: false)))
            }
        }
        if let timer = store.timer, let endsAt = timer.endsAt, endsAt > now {
            let content = content(title: timer.displayLabel, body: "Timer done. Baton will play \(timer.choice.summary).",
                                  id: timer.id, category: timerCategory, sound: soundName(timer.id, false))
            requests.append(UNNotificationRequest(
                identifier: "\(requestPrefix)\(timer.id.uuidString).timer", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, endsAt.timeIntervalSince(now)), repeats: false)))
        }
        return requests
    }

    private static func content(title: String, body: String, id: UUID, category: String, sound: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = [idKey: id.uuidString]
        content.sound = sound.isEmpty ? .default : UNNotificationSound(named: UNNotificationSoundName(sound))
        // Without the Time Sensitive entitlement the system treats this as an ordinary active
        // notification; with it, it breaks through a Focus. See the spec's fallback section.
        content.interruptionLevel = .timeSensitive
        return content
    }

    // MARK: Answering

    /// The alarm a notification stands for, or nil when it is not one of Baton's.
    nonisolated static func alarmID(in content: UNNotificationContent) -> UUID? {
        guard content.categoryIdentifier.hasPrefix("baton.alarm") || content.categoryIdentifier == timerCategory,
              let raw = content.userInfo[idKey] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    /// What the person did with one of Baton's alarm notifications.
    enum Response: Equatable { case play(UUID), snooze(UUID), dismissed(UUID) }

    nonisolated static func response(_ response: UNNotificationResponse) -> Response? {
        guard let id = alarmID(in: response.notification.request.content) else { return nil }
        switch response.actionIdentifier {
        case snoozeAction: return .snooze(id)
        case UNNotificationDismissActionIdentifier: return .dismissed(id)
        default: return .play(id)
        }
    }

    /// Carry out a response on the app's center.
    static func handle(_ response: Response, center: AlarmCenter) {
        switch response {
        case let .play(id): center.playFromSystem(id: id)
        case let .snooze(id): center.snoozedAtSystem(id: id)
        case let .dismissed(id): center.stoppedAtSystem(id: id)
        }
    }
}
