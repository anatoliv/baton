import ActivityKit
import AlarmKit
import AppIntents
import BatonPlaybackKit
import Foundation
import SwiftUI

/// Alarms and the timer as AlarmKit alarms, on iOS 26 and later (TBX-11171,
/// specs/alarm-and-timer.md). The system rings them with the chosen track's clip (or Baton's
/// chime) on the Lock Screen and in the Dynamic Island whether Baton runs or not. The API
/// shapes here were read from the AlarmKit module interface in the iOS 27 SDK.
///
/// Snooze on: the alert's one button of Baton's is Snooze (a 9-minute countdown) and the system
/// Stop runs `StopBatonAlarmIntent`. Snooze off, and every timer: the button is Play, which
/// opens Baton and plays the item (`PlayBatonAlarmIntent`).
@available(iOS 26.0, *)
@MainActor
final class AlarmKitBridge: AlarmSystemBridge {
    typealias Configuration = AlarmManager.AlarmConfiguration<BatonAlarmMetadata>

    private let manager = AlarmManager.shared
    /// The sound for an alarm: the clip of its track, else Baton's chime, else "" for AlarmKit's
    /// own alarm sound (`AlarmClipStore.soundName`, TBX-1000000410), by id and whether the alarm
    /// is gentle (the faded clip or chime, TBX-1000000445). Empty until wired.
    var soundName: (UUID, Bool) -> String = { _, _ in "" }
    /// Makes the clips (`AlarmClipStore.prepare`). True when a sound changed, so the sync
    /// schedules again with it.
    var prepare: ((AlarmStore) async -> Bool)?
    /// The store's alarm and timer ids, read live so an alert can be matched to its alarm even
    /// before the first sync of a fresh launch.
    var storeIDs: () -> Set<UUID> = { [] }
    /// What was last scheduled per AlarmKit id, kept across launches: a launch must not cancel
    /// and reschedule alarms it has no reason to touch (a ringing one stops if it does).
    private let defaults: UserDefaults
    private static let scheduledKey = "baton.alarms.alarmkit.scheduled"
    /// The timer AlarmKit holds and the sound it was given, as "<id> <sound>", so a clip made
    /// after the timer started replaces the chime once, and a launch leaves it alone.
    private static let timerSoundKey = "baton.alarms.alarmkit.timerSound"
    private var timerSound: String? {
        get { defaults.string(forKey: Self.timerSoundKey) }
        set { defaults.set(newValue, forKey: Self.timerSoundKey) }
    }
    private var scheduled: [UUID: String] {
        get {
            (defaults.dictionary(forKey: Self.scheduledKey) as? [String: String] ?? [:])
                .reduce(into: [:]) { result, pair in if let id = UUID(uuidString: pair.key) { result[id] = pair.value } }
        }
        set {
            defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) }), forKey: Self.scheduledKey)
        }
    }
    private var updatesTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    /// Called when AlarmKit's permission changes (granted later in Settings), to sync again.
    var onAuthorizationChange: (() -> Void)?
    /// Called when one of Baton's alarms is alerting while Baton runs.
    var onAlerting: ((UUID) -> Void)?

    nonisolated static let tint = Color(red: 0xE9 / 255, green: 0x83 / 255, blue: 0x45 / 255)

    init(defaults: UserDefaults = BatonStorage.defaults) {
        self.defaults = defaults
    }

    var isAuthorized: Bool { manager.authorizationState == .authorized }

    var permission: MobileAlarms.Permission {
        switch manager.authorizationState {
        case .authorized: .allowed
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .unavailable
        }
    }

    func authorize() async -> Bool {
        switch manager.authorizationState {
        case .authorized: return true
        case .denied: return false
        case .notDetermined: return await Self.requestAuthorization() == .authorized
        @unknown default: return false
        }
    }

    // AlarmManager is not Sendable, so its async calls are made from outside the main actor,
    // through `AlarmManager.shared`, with the configuration built there too.
    nonisolated private static func requestAuthorization() async -> AlarmManager.AuthorizationState? {
        try? await AlarmManager.shared.requestAuthorization()
    }

    nonisolated private static func schedule(id: UUID, _ make: @Sendable () -> Configuration) async -> Bool {
        (try? await AlarmManager.shared.schedule(id: id, configuration: make())) != nil
    }

    /// Watch AlarmKit's alarms while Baton runs, so one that starts alerting (or was already
    /// alerting when Baton opened) is answered by playing.
    func startWatching() {
        guard updatesTask == nil else { return }
        authorizationTask = Task { @MainActor [weak self] in
            for await _ in AlarmManager.shared.authorizationUpdates {
                self?.onAuthorizationChange?()
            }
        }
        updatesTask = Task { @MainActor [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                guard let self else { return }
                for alarm in alarms where alarm.state == .alerting {
                    if let storeID = self.storeID(forAlarmKitID: alarm.id) { self.onAlerting?(storeID) }
                }
            }
        }
    }

    /// Alarms that have rung and are not finished, as Baton store ids, for the moment Baton
    /// opens: ringing now, or counting down a snooze the system took (a timer's countdown is
    /// the timer running, not a ring, so it is left out).
    func rungStoreIDs(timerID: UUID?) -> [UUID] {
        ((try? manager.alarms) ?? []).compactMap { alarm in
            guard let storeID = storeID(forAlarmKitID: alarm.id) else { return nil }
            switch alarm.state {
            case .alerting: return storeID
            case .countdown where storeID != timerID: return storeID
            default: return nil
            }
        }
    }

    func silence(id: UUID) {
        try? manager.stop(id: id)
        try? manager.stop(id: Self.snoozeID(for: id))
    }

    /// The AlarmKit id of a snooze of the alarm `id`: a fixed alarm of its own, since a
    /// relative schedule cannot say "once, nine minutes from now".
    nonisolated static func snoozeID(for id: UUID) -> UUID {
        var bytes = id.uuid
        bytes.15 ^= 0x5A
        return UUID(uuid: bytes)
    }

    private func storeID(forAlarmKitID id: UUID) -> UUID? {
        let known = storeIDs()
        if known.contains(id) { return id }
        let original = Self.snoozeID(for: id)
        return known.contains(original) ? original : nil
    }

    /// Schedules at once with the sounds ready now (the chime for a clip still being cut), then
    /// cuts the clips and, when one was made, schedules again so the alarm rings the track. A
    /// stream can take many seconds to fetch, and a timer must not start late waiting for it.
    func sync(_ store: AlarmStore) async {
        guard isAuthorized else { return }
        await apply(store)
        if let prepare, await prepare(store) { await apply(store) }
    }

    private func apply(_ store: AlarmStore) async {
        var desired: [UUID: (fingerprint: String, configuration: @Sendable () -> Configuration)] = [:]
        let now = Date()
        for alarm in store.alarms where alarm.isEnabled {
            let sound = soundName(alarm.id, alarm.gentleWake)
            desired[alarm.id] = (Self.fingerprint(alarm, sound: sound), { @Sendable in Self.configuration(for: alarm, sound: sound) })
            if let snoozed = alarm.snoozedUntil, snoozed > now {
                desired[Self.snoozeID(for: alarm.id)] = ("snooze \(snoozed.timeIntervalSinceReferenceDate) \(sound)",
                                                         { @Sendable in Self.snoozeConfiguration(for: alarm, until: snoozed, sound: sound) })
            }
        }
        let existing = (try? manager.alarms) ?? []

        // The timer is synced by state rather than by fingerprint: pause and resume act on the
        // alarm AlarmKit already has.
        if let timer = store.timer {
            let current = existing.first { $0.id == timer.id }
            let sound = soundName(timer.id, false)
            let given = "\(timer.id.uuidString) \(sound)"
            let held: AlarmSystemTimerPlan.Held = switch current?.state {
            case nil: .none
            case .countdown?: .countdown
            case .paused?: .paused
            default: .other
            }
            switch AlarmSystemTimerPlan.action(timer.state, held: held, now: now, givenSound: given, recordedSound: timerSound) {
            case .resume: try? manager.resume(id: timer.id)
            case .pause: try? manager.pause(id: timer.id)
            case .schedule, .reschedule:
                guard case let .running(endsAt) = timer.state else { break }
                // Counting down with the chime while the clip was cut: the same end, the track's sound.
                if current != nil { try? manager.cancel(id: timer.id) }
                let duration = endsAt.timeIntervalSince(now)
                if await Self.schedule(id: timer.id, { @Sendable in Self.configuration(for: timer, duration: duration, sound: sound) }) {
                    timerSound = given
                }
            case .none: break
            }
        } else {
            timerSound = nil
        }

        let stopped = store.stoppedByUser.reduce(into: Set<UUID>()) { $0.formUnion([$1, Self.snoozeID(for: $1)]) }
        let plan = AlarmSystemSyncPlan.plan(
            existing: existing.map { .init(id: $0.id, isActive: $0.state != .scheduled) },
            desired: desired.mapValues(\.fingerprint), lastScheduled: scheduled,
            managedElsewhere: Set([store.timer?.id].compactMap { $0 }), stoppedByUser: stopped)
        var record = scheduled
        for id in plan.cancel {
            try? manager.cancel(id: id)
            record[id] = nil
        }
        for id in plan.schedule {
            guard let item = desired[id] else { continue }
            record[id] = await Self.schedule(id: id, item.configuration) ? item.fingerprint : nil
        }
        // Forget fingerprints of alarms AlarmKit no longer holds and nothing scheduled again.
        let held = Set(existing.map(\.id)).union(plan.schedule)
        record = record.filter { held.contains($0.key) && !plan.cancel.subtracting(plan.schedule).contains($0.key) }
        scheduled = record
    }

    // MARK: Configurations

    nonisolated private static func fingerprint(_ alarm: BatonAlarm, sound: String) -> String {
        "\(alarm.hour):\(alarm.minute) \(alarm.repeatDays.sorted()) \(alarm.displayLabel) \(alarm.snoozeEnabled) \(alarm.choice.summary) \(sound)"
    }

    nonisolated private static func metadata(id: UUID, label: String, choice: AlarmChoice, isTimer: Bool) -> BatonAlarmMetadata {
        BatonAlarmMetadata(storeID: id, label: label, playing: choice.summary, symbol: choice.symbol, isTimer: isTimer)
    }

    nonisolated private static func alert(title: String, snooze: Bool) -> AlarmPresentation.Alert {
        let button = snooze
            ? AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
            : AlarmButton(text: "Play", textColor: .white, systemImageName: "play.fill")
        let behavior: AlarmPresentation.Alert.SecondaryButtonBehavior = snooze ? .countdown : .custom
        let resource = LocalizedStringResource(stringLiteral: title)
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(title: resource, secondaryButton: button, secondaryButtonBehavior: behavior)
        }
        return AlarmPresentation.Alert(title: resource,
                                       stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
                                       secondaryButton: button, secondaryButtonBehavior: behavior)
    }

    nonisolated private static func attributes(_ presentation: AlarmPresentation, metadata: BatonAlarmMetadata) -> AlarmAttributes<BatonAlarmMetadata> {
        AlarmAttributes(presentation: presentation, metadata: metadata, tintColor: tint)
    }

    nonisolated static func configuration(for alarm: BatonAlarm, sound: String) -> Configuration {
        let weekdays: [Locale.Weekday] = alarm.repeatDays.sorted().compactMap(Self.weekday)
        let schedule = Alarm.Schedule.relative(.init(time: .init(hour: alarm.hour, minute: alarm.minute),
                                                     repeats: weekdays.isEmpty ? .never : .weekly(weekdays)))
        let presentation = AlarmPresentation(
            alert: alert(title: alarm.displayLabel, snooze: alarm.snoozeEnabled),
            countdown: alarm.snoozeEnabled ? .init(title: "Snoozing") : nil)
        return Configuration(
            countdownDuration: alarm.snoozeEnabled ? .init(preAlert: nil, postAlert: BatonAlarm.snoozeInterval) : nil,
            schedule: schedule,
            attributes: attributes(presentation, metadata: metadata(id: alarm.id, label: alarm.displayLabel,
                                                                    choice: alarm.choice, isTimer: false)),
            stopIntent: StopBatonAlarmIntent(alarmID: alarm.id),
            secondaryIntent: alarm.snoozeEnabled ? nil : PlayBatonAlarmIntent(alarmID: alarm.id),
            sound: alertSound(sound))
    }

    nonisolated static func snoozeConfiguration(for alarm: BatonAlarm, until date: Date, sound: String) -> Configuration {
        let presentation = AlarmPresentation(alert: alert(title: alarm.displayLabel, snooze: false))
        return Configuration(
            schedule: .fixed(date),
            attributes: attributes(presentation, metadata: metadata(id: alarm.id, label: alarm.displayLabel,
                                                                    choice: alarm.choice, isTimer: false)),
            stopIntent: StopBatonAlarmIntent(alarmID: alarm.id),
            secondaryIntent: PlayBatonAlarmIntent(alarmID: alarm.id),
            sound: alertSound(sound))
    }

    nonisolated static func configuration(for timer: BatonTimer, duration: TimeInterval, sound: String) -> Configuration {
        let presentation = AlarmPresentation(
            alert: alert(title: timer.displayLabel, snooze: false),
            countdown: .init(title: LocalizedStringResource(stringLiteral: timer.displayLabel)),
            paused: .init(title: "Paused", resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.fill")))
        return Configuration.timer(
            duration: max(1, duration),
            attributes: attributes(presentation, metadata: metadata(id: timer.id, label: timer.displayLabel,
                                                                    choice: timer.choice, isTimer: true)),
            stopIntent: StopBatonAlarmIntent(alarmID: timer.id),
            secondaryIntent: PlayBatonAlarmIntent(alarmID: timer.id),
            sound: alertSound(sound))
    }

    /// The system's own alarm sound for an empty name (no clip and no chime, or the DEBUG
    /// `BATON_DEBUG_ALARM_SOUND=default` switch), else the named file in `Library/Sounds` or the
    /// bundle.
    nonisolated static func alertSound(_ name: String) -> AlertConfiguration.AlertSound {
        name.isEmpty ? .default : .named(name)
    }

    /// `Calendar` weekday (1 = Sunday) to AlarmKit's `Locale.Weekday`.
    nonisolated static func weekday(_ day: Int) -> Locale.Weekday? {
        switch day {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        case 7: .saturday
        default: nil
        }
    }
}
