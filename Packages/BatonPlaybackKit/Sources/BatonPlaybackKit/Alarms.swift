import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import Observation

// Clock-style Alarm and Timer that play a chosen Baton item (TBX-11171, specs/alarm-and-timer.md).
//
// This file is the part both apps agree on: what an alarm and a timer are, when one is next
// due, what it plays, and the store that keeps them. How each platform makes the time arrive
// (AlarmKit, a notification, or the app's own clock) is outside it, so all of the date logic can
// be tested without a device.

/// What an alarm or timer plays: a snapshot of a queue, kept with the alarm so that the time can
/// come with no library and no network.
public struct AlarmChoice: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case song, queue, book, album, playlist }

    public var title: String
    public var subtitle: String?
    public var kind: Kind
    public var songs: [NavidromeSong]
    public var startIndex: Int
    public var source: StreamingPlaybackController.QueueSource?

    /// A long queue is cut to this many items around where it starts. An alarm is a moment, not
    /// a library; this keeps the stored JSON small.
    public static let maxSongs = 100

    public init(title: String, subtitle: String? = nil, kind: Kind, songs: [NavidromeSong],
                startIndex: Int = 0, source: StreamingPlaybackController.QueueSource? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        let window = Self.window(count: songs.count, start: startIndex)
        self.songs = Array(songs[window])
        self.startIndex = max(0, min(startIndex - window.lowerBound, max(0, self.songs.count - 1)))
        self.source = source
    }

    /// One song, played on its own.
    public static func song(_ song: NavidromeSong) -> AlarmChoice {
        AlarmChoice(title: song.title, subtitle: song.artist, kind: .song, songs: [song],
                    source: .init(label: song.title, kind: .song, id: song.id))
    }

    /// The song at `index` with the rest of its queue, the way the player holds it.
    public static func queue(_ songs: [NavidromeSong], at index: Int,
                             source: StreamingPlaybackController.QueueSource?, isBook: Bool) -> AlarmChoice? {
        guard songs.indices.contains(index) else { return nil }
        let song = songs[index]
        let kind: Kind
        switch (isBook, source?.kind) {
        case (true, _): kind = .book
        case (_, .album?): kind = .album
        case (_, .playlist?): kind = .playlist
        default: kind = songs.count > 1 ? .queue : .song
        }
        let title = isBook ? (song.album ?? song.title) : song.title
        let subtitle: String? = isBook ? song.title : (source.map { "From \($0.label)" } ?? song.artist)
        return AlarmChoice(title: title, subtitle: subtitle, kind: kind, songs: songs, startIndex: index, source: source)
    }

    /// The range of a queue of `count` kept for a start at `start`: from the start onwards, and
    /// nothing before it once the queue is too long.
    static func window(count: Int, start: Int) -> Range<Int> {
        guard count > maxSongs else { return 0 ..< count }
        let lower = max(0, min(start, count - maxSongs))
        return lower ..< lower + maxSongs
    }

    /// The SF Symbol for the kind of thing that plays.
    public var symbol: String {
        switch kind {
        case .song: "music.note"
        case .queue: "list.bullet"
        case .book: "book"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        }
    }

    /// What the alarm's "Play" row says.
    public var summary: String {
        [title, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Repeat days as `Calendar` weekdays: 1 is Sunday, 7 is Saturday, whatever the locale's first day.
public enum AlarmRepeat {
    public static let everyDay: Set<Int> = Set(1 ... 7)
    public static let weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public static let weekend: Set<Int> = [1, 7]

    /// The days in the order the locale shows a week.
    public static func ordered(_ calendar: Calendar = .autoupdatingCurrent) -> [Int] {
        (0 ..< 7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    /// Clock's words for a repeat: "Never", "Every day", "Weekdays", "Weekends", "Every Monday",
    /// or the short names in week order ("Mon Wed Fri").
    public static func summary(_ days: Set<Int>, calendar: Calendar = .autoupdatingCurrent) -> String {
        let days = days.filter { (1 ... 7).contains($0) }
        switch days {
        case []: return "Never"
        case everyDay: return "Every day"
        case weekdays: return "Weekdays"
        case weekend: return "Weekends"
        default: break
        }
        if days.count == 1, let day = days.first {
            return "Every \(calendar.weekdaySymbols[day - 1])"
        }
        return ordered(calendar).filter(days.contains).map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")
    }
}

/// One alarm, as Clock has them: a wall-clock time, repeat days, a label, Snooze, on or off.
public struct BatonAlarm: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var hour: Int
    public var minute: Int
    /// `Calendar` weekdays (1 = Sunday). Empty means once.
    public var repeatDays: Set<Int>
    public var label: String
    public var snoozeEnabled: Bool
    public var isEnabled: Bool
    public var choice: AlarmChoice
    /// When the alarm was last switched on or edited. An occurrence before this was never
    /// scheduled, so it cannot be due or missed.
    public var armedAt: Date
    /// Set by Snooze; the alarm goes off again then.
    public var snoozedUntil: Date?

    public static let defaultLabel = "Alarm"
    public static let snoozeInterval: TimeInterval = 9 * 60

    public init(id: UUID = UUID(), hour: Int, minute: Int, repeatDays: Set<Int> = [], label: String = "",
                snoozeEnabled: Bool = true, isEnabled: Bool = true, choice: AlarmChoice, armedAt: Date = Date()) {
        self.id = id
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
        self.repeatDays = repeatDays.filter { (1 ... 7).contains($0) }
        self.label = label
        self.snoozeEnabled = snoozeEnabled
        self.isEnabled = isEnabled
        self.choice = choice
        self.armedAt = armedAt
    }

    public var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultLabel : trimmed
    }

    public var repeats: Bool { !repeatDays.isEmpty }

    private func components(weekday: Int?) -> DateComponents {
        DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday)
    }

    /// The next time this alarm's clock time comes round after `date`, ignoring on/off and snooze.
    ///
    /// Wall-clock, like Clock: 7:00 is 7:00 in whatever time zone the calendar is in. A time that
    /// spring-forward skips comes at the first valid time after it (`.nextTime`); a time that
    /// fall-back repeats comes once, on its first pass (`.first`).
    public func nextOccurrence(after date: Date, calendar: Calendar) -> Date? {
        let days: [Int?] = repeatDays.isEmpty ? [nil] : repeatDays.sorted().map { $0 }
        return days.compactMap {
            calendar.nextDate(after: date, matching: components(weekday: $0),
                              matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        }.min()
    }

    /// The latest time this alarm's clock time came round at or before `date`.
    public func previousOccurrence(atOrBefore date: Date, calendar: Calendar) -> Date? {
        // `nextDate(after:)` is exclusive, so look from just after `date` for an occurrence
        // exactly at it to count.
        guard let next = nextOccurrence(after: date.addingTimeInterval(-1), calendar: calendar) else { return nil }
        if next <= date { return next }
        let days: [Int?] = repeatDays.isEmpty ? [nil] : repeatDays.sorted().map { $0 }
        return days.compactMap {
            calendar.nextDate(after: date, matching: components(weekday: $0),
                              matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .backward)
        }.max()
    }

    /// When this alarm next goes off after `date`: the snooze if it is sooner, nil when off.
    public func nextFire(after date: Date, calendar: Calendar) -> Date? {
        guard isEnabled else { return nil }
        let scheduled = nextOccurrence(after: max(date, armedAt), calendar: calendar)
        if let snoozedUntil, snoozedUntil > date {
            return [snoozedUntil, scheduled].compactMap { $0 }.min()
        }
        return scheduled
    }
}

/// The timer: one countdown, running or paused, that plays a chosen item when it ends.
public struct BatonTimer: Codable, Identifiable, Equatable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    public var id: UUID
    public var duration: TimeInterval
    public var label: String
    public var choice: AlarmChoice
    public var state: State

    public static let defaultLabel = "Timer"
    /// Clock's timer starts at one second and stops short of a day.
    public static let durationRange: ClosedRange<TimeInterval> = 1 ... (24 * 3600 - 1)

    public init(id: UUID = UUID(), duration: TimeInterval, label: String = "", choice: AlarmChoice, startedAt: Date) {
        self.id = id
        let duration = min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        self.duration = duration
        self.label = label
        self.choice = choice
        self.state = .running(endsAt: startedAt.addingTimeInterval(duration))
    }

    public var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultLabel : trimmed
    }

    public var isPaused: Bool { if case .paused = state { true } else { false } }

    public var endsAt: Date? { if case let .running(endsAt) = state { endsAt } else { nil } }

    public func remaining(at date: Date) -> TimeInterval {
        switch state {
        case let .running(endsAt): max(0, endsAt.timeIntervalSince(date))
        case let .paused(remaining): remaining
        }
    }

    public mutating func pause(at date: Date) {
        guard case .running = state else { return }
        state = .paused(remaining: remaining(at: date))
    }

    public mutating func resume(at date: Date) {
        guard case let .paused(remaining) = state else { return }
        state = .running(endsAt: date.addingTimeInterval(remaining))
    }

    /// "1:02:03" or "4:05", Clock's countdown face.
    public static func clockFace(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// One alarm or timer going off.
public struct AlarmFire: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable { case alarm, timer }
    public var kind: Kind
    public var alarmID: UUID
    /// The time it was due.
    public var occurrence: Date
    public var label: String
    public var choice: AlarmChoice
    public var snoozeEnabled: Bool
    /// Due longer ago than the store's grace: shown as missed, plays nothing.
    public var isLate: Bool

    public var id: String { "\(alarmID.uuidString)@\(occurrence.timeIntervalSinceReferenceDate)" }
}

/// Alarms and the timer, kept in Baton's defaults domain (device-local, never synced).
///
/// The store is the single source: AlarmKit alarms, notification requests and the in-app
/// clock are all rebuilt from it. Every occurrence is answered once (`due`, `claim`), whichever
/// of those paths reaches it first.
@MainActor
@Observable
public final class AlarmStore {
    public private(set) var alarms: [BatonAlarm] = []
    public private(set) var timer: BatonTimer?
    /// The last occurrence answered per alarm or timer id (played, stopped, missed).
    @ObservationIgnored private var answered: [UUID: Date] = [:]
    /// Bumped on every change, for anyone keeping a copy in step (the system schedulers).
    public private(set) var revision = 0

    /// How late an occurrence may be and still play. Longer than that, it is missed.
    public static let lateGrace: TimeInterval = 10 * 60
    public static let storageKey = "baton.alarms.v1"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored public var calendar: () -> Calendar
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    private struct Snapshot: Codable {
        var alarms: [BatonAlarm]
        var timer: BatonTimer?
        var answered: [UUID: Date]
        var stoppedByUser: Set<UUID>?
    }

    /// Alarms and timers the person deleted, switched off or cancelled. Only these may take a
    /// ringing, snoozing or paused system alarm away; an alarm that merely went off (a one-off
    /// switching itself off, an ended timer) leaves the system's copy to finish.
    public private(set) var stoppedByUser: Set<UUID> = []

    public init(defaults: UserDefaults = BatonStorage.defaults, key: String = AlarmStore.storageKey,
                calendar: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.defaults = defaults
        self.key = key
        self.calendar = calendar
        if let data = defaults.data(forKey: key), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            alarms = snapshot.alarms
            timer = snapshot.timer
            answered = snapshot.answered
            stoppedByUser = snapshot.stoppedByUser ?? []
        }
        sortAlarms()
    }

    /// Calls `observer` after every change. Returns a token for `removeObserver`.
    @discardableResult
    public func addObserver(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func removeObserver(_ token: UUID) { observers[token] = nil }

    private func changed() {
        sortAlarms()
        revision += 1
        if let data = try? JSONEncoder().encode(Snapshot(alarms: alarms, timer: timer, answered: answered, stoppedByUser: stoppedByUser)) {
            defaults.set(data, forKey: key)
        }
        for observer in observers.values { observer() }
    }

    private func sortAlarms() {
        alarms.sort { ($0.hour, $0.minute, $0.id.uuidString) < ($1.hour, $1.minute, $1.id.uuidString) }
    }

    public func alarm(id: UUID) -> BatonAlarm? { alarms.first { $0.id == id } }

    // MARK: Alarms

    /// Adds or replaces an alarm. Saving re-arms it from `now`, as saving in Clock does.
    public func save(_ alarm: BatonAlarm, now: Date = Date()) {
        var alarm = alarm
        alarm.armedAt = now
        alarm.snoozedUntil = nil
        stoppedByUser.remove(alarm.id)
        if let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[index] = alarm
        } else {
            alarms.append(alarm)
        }
        changed()
    }

    public func delete(id: UUID) {
        alarms.removeAll { $0.id == id }
        answered[id] = nil
        stoppedByUser.insert(id)
        changed()
    }

    public func setEnabled(_ enabled: Bool, id: UUID, now: Date = Date()) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].isEnabled = enabled
        alarms[index].snoozedUntil = nil
        if enabled {
            alarms[index].armedAt = now
            stoppedByUser.remove(id)
        } else {
            stoppedByUser.insert(id)
        }
        changed()
    }

    /// Snooze: off now, on again in nine minutes.
    public func snooze(id: UUID, now: Date = Date()) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].isEnabled = true
        alarms[index].snoozedUntil = now.addingTimeInterval(BatonAlarm.snoozeInterval)
        changed()
    }

    // MARK: Timer

    @discardableResult
    public func startTimer(duration: TimeInterval, label: String = "", choice: AlarmChoice, now: Date = Date()) -> BatonTimer {
        let timer = BatonTimer(duration: duration, label: label, choice: choice, startedAt: now)
        self.timer = timer
        changed()
        return timer
    }

    public func pauseTimer(now: Date = Date()) {
        guard timer?.isPaused == false else { return }
        timer?.pause(at: now)
        changed()
    }

    public func resumeTimer(now: Date = Date()) {
        guard timer?.isPaused == true else { return }
        timer?.resume(at: now)
        changed()
    }

    public func cancelTimer() {
        guard let timer else { return }
        answered[timer.id] = nil
        stoppedByUser.insert(timer.id)
        self.timer = nil
        changed()
    }

    // MARK: When things are due

    /// The soonest moment anything is due after `now`, for a clock to sleep until.
    public func nextDue(after now: Date) -> Date? {
        let calendar = calendar()
        let alarmTimes = alarms.compactMap { $0.nextFire(after: now, calendar: calendar) }
        return (alarmTimes + [timer?.endsAt].compactMap { $0 }).min()
    }

    /// The latest occurrence of `alarm` at or before `now` that it was armed for, the snooze
    /// included. Nil when it has none (off, or armed since).
    private func latestOccurrence(of alarm: BatonAlarm, atOrBefore now: Date, calendar: Calendar) -> Date? {
        guard alarm.isEnabled else { return nil }
        var candidates: [Date] = []
        if let p = alarm.previousOccurrence(atOrBefore: now, calendar: calendar), p > alarm.armedAt { candidates.append(p) }
        if let s = alarm.snoozedUntil, s <= now { candidates.append(s) }
        return candidates.max()
    }

    /// Everything that has come due by `now` and not been answered, answered here and returned.
    ///
    /// One-off alarms switch off, snoozes clear and an ended timer goes away, as in Clock. An
    /// occurrence more than `lateGrace` ago comes back with `isLate`, to be shown as missed.
    public func due(at now: Date) -> [AlarmFire] { collectDue(at: now, only: nil) }

    private func collectDue(at now: Date, only: UUID?) -> [AlarmFire] {
        let calendar = calendar()
        var fires: [AlarmFire] = []
        var didChange = false
        for index in alarms.indices {
            let alarm = alarms[index]
            if let only, alarm.id != only { continue }
            guard let occurrence = latestOccurrence(of: alarm, atOrBefore: now, calendar: calendar) else { continue }
            if let last = answered[alarm.id], last >= occurrence { continue }
            answered[alarm.id] = occurrence
            fires.append(AlarmFire(kind: .alarm, alarmID: alarm.id, occurrence: occurrence, label: alarm.displayLabel,
                                   choice: alarm.choice, snoozeEnabled: alarm.snoozeEnabled,
                                   isLate: now.timeIntervalSince(occurrence) > Self.lateGrace))
            if alarm.snoozedUntil.map({ $0 <= now }) == true { alarms[index].snoozedUntil = nil }
            if !alarm.repeats { alarms[index].isEnabled = false }
            didChange = true
        }
        if let timer, only == nil || only == timer.id, let endsAt = timer.endsAt, endsAt <= now {
            fires.append(AlarmFire(kind: .timer, alarmID: timer.id, occurrence: endsAt, label: timer.displayLabel,
                                   choice: timer.choice, snoozeEnabled: false,
                                   isLate: now.timeIntervalSince(endsAt) > Self.lateGrace))
            self.timer = nil
            didChange = true
        }
        if didChange { changed() }
        return fires.sorted { $0.occurrence < $1.occurrence }
    }

    /// A system path (an AlarmKit button, a notification) reporting that `id` went off. Returns
    /// the occurrence to play, or nil when it was already answered or is unknown.
    ///
    /// Also answers it, so the in-app clock and a second system callback leave it alone.
    public func claim(id: UUID, now: Date = Date()) -> AlarmFire? {
        // The timer has already gone from the store when the in-app clock answered it.
        if let timer, timer.id == id {
            let fire = AlarmFire(kind: .timer, alarmID: id, occurrence: timer.endsAt.map { min($0, now) } ?? now,
                                 label: timer.displayLabel, choice: timer.choice, snoozeEnabled: false, isLate: false)
            self.timer = nil
            answered[id] = now
            changed()
            return fire
        }
        guard let fire = collectDue(at: now, only: id).first, !fire.isLate else { return nil }
        return fire
    }

    /// The person stopped it at the system alert: answer it so nothing starts later.
    public func answer(id: UUID, now: Date = Date()) {
        if timer?.id == id { timer = nil }
        _ = collectDue(at: now, only: id)
        answered[id] = max(answered[id] ?? .distantPast, now)
        changed()
    }
}
