import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import Observation

/// The platform's way of making an alarm arrive when Baton is not running: AlarmKit on an iPhone
/// with iOS 26, a local notification on older iPhones and on the Mac.
@MainActor
public protocol AlarmSystemBridge: AnyObject {
    /// Make the system's copies match the store: schedule what is on, remove what is not.
    func sync(_ store: AlarmStore) async
    /// Baton is playing the item itself, so the system's alert for `id` should not sound too.
    func silence(id: UUID)
    /// Ask for permission to ring (AlarmKit's prompt, or notifications'). True when allowed.
    func authorize() async -> Bool
}

/// Baton's own clock: while the app runs, it wakes when the next alarm or timer is due and
/// hands what has come due to `onFire`.
///
/// It naps at most `maxNap` at a time and looks again, so a clock or time zone change, or a
/// Mac waking from sleep, is noticed within that even without a notification. It also listens
/// for the system's clock and time zone notifications.
@MainActor
public final class AlarmClock {
    private let store: AlarmStore
    private let now: () -> Date
    private let onFire: ([AlarmFire]) -> Void
    /// Whether the app can play right now. When it cannot, what is due is left unanswered for
    /// the system's alert and for the moment the app comes to the front.
    public var canAnswer: () -> Bool = { true }
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var observers: [NSObjectProtocol] = []
    public var maxNap: TimeInterval = 30

    public init(store: AlarmStore, now: @escaping () -> Date = Date.init, onFire: @escaping ([AlarmFire]) -> Void) {
        self.store = store
        self.now = now
        self.onFire = onFire
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = store.addObserver { [weak self] in self?.reschedule() }
        let names: [Notification.Name] = [
            .NSSystemClockDidChange, .NSSystemTimeZoneDidChange,
            Notification.Name("UIApplicationSignificantTimeChangeNotification"),
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
        check()
    }

    public func stop() {
        task?.cancel()
        task = nil
        if let token { store.removeObserver(token) }
        token = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Answer whatever is due now, then sleep until the next thing.
    public func check() {
        if canAnswer() {
            let fires = store.due(at: now())
            if !fires.isEmpty { onFire(fires) }
        }
        reschedule()
    }

    private func reschedule() {
        task?.cancel()
        task = nil
        guard token != nil else { return }
        let current = now()
        guard let next = store.nextDue(after: current) else { return }
        let nap = min(maxNap, max(0.02, next.timeIntervalSince(current)))
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(nap))
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }
}

/// What happens when an alarm or timer goes off, on either app: the chosen item plays, the
/// Clock-style ringing state is up for Stop, Snooze or Keep Playing, and a late one is shown as
/// missed instead (TBX-11171, specs/alarm-and-timer.md).
@MainActor
@Observable
public final class AlarmCenter {
    public let store: AlarmStore
    @ObservationIgnored private let player: StreamingPlaybackController
    @ObservationIgnored public var system: AlarmSystemBridge? {
        didSet { scheduleSync() }
    }
    /// Plays and stops the chime, for when nothing else would sound. Each app supplies its own.
    @ObservationIgnored public var playChime: (() -> Void)?
    @ObservationIgnored public var stopChime: (() -> Void)?
    /// Tells the person something (a toast on the Mac, a banner on the phone).
    @ObservationIgnored public var notify: ((String) -> Void)?
    /// Gives an alarm's queue back with only what can still play. The default drops local files
    /// that are gone (a removed clipping, book chapter or download); each app may do better.
    @ObservationIgnored public var resolve: @MainActor (AlarmChoice) -> (songs: [NavidromeSong], startIndex: Int) = { AlarmCenter.dropMissingFiles($0) }
    @ObservationIgnored public var now: () -> Date = Date.init
    /// Whether Baton can start playing now. On the iPhone that is "in front, or already playing":
    /// a suspended app that wakes for a moment cannot start audio, and must not quiet the
    /// system's alert in the attempt (the iOS 26.5 simulator walk saw exactly that, 2026-10-17).
    @ObservationIgnored public var canPlayInApp: @MainActor () -> Bool = { true }
    /// How long after the time Baton waits for playback before sounding the chime instead.
    @ObservationIgnored public var chimeFallbackDelay: TimeInterval = 10
    /// Tunes in a radio station chosen for an alarm, and stops it. Radio plays
    /// through its own engine, not the queue, so each app supplies these.
    @ObservationIgnored public var playRadio: (@MainActor (AlarmChoice.Station) -> Void)?
    @ObservationIgnored public var stopRadio: (@MainActor () -> Void)?
    @ObservationIgnored public var radioIsPlaying: @MainActor () -> Bool = { false }
    /// Brings the full Now Playing player forward: the ringing's "Keep playing, open player"
    ///. The phone closes whatever sheet is up first; the Mac fronts its window.
    @ObservationIgnored public var showPlayer: (@MainActor () -> Void)?

    /// The alarm or timer going off now, for the ringing screen.
    public private(set) var ringing: AlarmFire?
    /// The last one that went off while nothing could play it.
    public private(set) var missed: AlarmFire?
    /// The last thing said about an alarm (missed, or nothing left to play), for a banner.
    public private(set) var notice: String?

    @ObservationIgnored private var clock: AlarmClock?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?

    public init(store: AlarmStore, player: StreamingPlaybackController) {
        self.store = store
        self.player = player
        store.addObserver { [weak self] in self?.scheduleSync() }
    }

    /// Start the in-app clock and bring the system copies in step.
    public func start() {
        guard clock == nil else { return }
        let clock = AlarmClock(store: store, now: { [weak self] in self?.now() ?? Date() }) { [weak self] fires in
            self?.handle(fires, fromSystem: false)
        }
        clock.canAnswer = { [weak self] in self?.canPlayInApp() ?? true }
        self.clock = clock
        clock.start()
        scheduleSync()
    }

    public func stop() {
        clock?.stop()
        clock = nil
    }

    /// The app came to the front: anything due plays now (within the grace), as Clock would.
    public func appBecameActive() { clock?.check() }

    /// Ask the system for permission to ring, and when it is given, bring the system copies in
    /// step at once: a sync made while the prompt was still up found no permission and
    /// scheduled nothing. True when allowed (or when there is no system path).
    @discardableResult
    public func requestPermission() async -> Bool {
        guard let system else { return true }
        let allowed = await system.authorize()
        if allowed { scheduleSync() }
        return allowed
    }

    /// Bring the system's copies in step now (Baton came to the front, permission changed).
    public func syncNow() { scheduleSync() }

    private func scheduleSync() {
        guard let system else { return }
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self, weak system] in
            // Coalesce a burst of edits (a toggle flicked twice) into one system update.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let system else { return }
            await system.sync(self.store)
        }
    }

    // MARK: Going off

    /// The system says `id` went off and the person wants it played (AlarmKit's Play, a
    /// notification tap). Plays it unless it was already answered.
    public func playFromSystem(id: UUID) {
        guard let fire = store.claim(id: id, now: now()) else {
            // Already playing from the in-app clock: just make sure the ringing is answered.
            if ringing?.alarmID == id { keepPlaying() }
            return
        }
        handle([fire], fromSystem: true)
    }

    /// The system's alert for `id` is sounding while Baton runs (AlarmKit's updates).
    ///
    /// Not yet answered: Baton plays it and quiets the alert. Already ringing in Baton: the
    /// alert is quieted. Otherwise it is a system snooze coming round again, which Baton never
    /// heard about, so it plays as a fresh occurrence.
    public func systemIsAlerting(id: UUID) {
        guard canPlayInApp() else { return }
        if let fire = store.claim(id: id, now: now()) {
            handle([fire], fromSystem: false)
        } else if ringing?.alarmID == id {
            system?.silence(id: id)
        } else if let alarm = store.alarm(id: id) {
            handle([AlarmFire(kind: .alarm, alarmID: id, occurrence: now(), label: alarm.displayLabel, choice: alarm.choice,
                              snoozeEnabled: alarm.snoozeEnabled, isLate: false)], fromSystem: false)
        }
    }

    /// The person pressed Stop on the system's alert.
    public func stoppedAtSystem(id: UUID) {
        store.answer(id: id, now: now())
        if ringing?.alarmID == id { stopRinging() }
    }

    /// The system snoozed `id` itself (a notification's Snooze action).
    public func snoozedAtSystem(id: UUID) {
        store.answer(id: id, now: now())
        store.snooze(id: id, now: now())
    }

    func handle(_ fires: [AlarmFire], fromSystem: Bool) {
        guard let fire = fires.last(where: { !$0.isLate }) else {
            if let late = fires.last {
                missed = late
                say("\(late.label) went off at \(Self.timeString(late.occurrence)), more than \(Int(AlarmStore.lateGrace / 60)) minutes ago, so Baton did not start \(late.choice.title) now.")
            }
            return
        }
        // Quiet the system copy whichever way this arrived: an AlarmKit alert answered by Play
        // was seen still sounding until Baton stopped it (simulator walk, 2026-10-17).
        system?.silence(id: fire.alarmID)
        if fire.choice.kind == .radio, let station = fire.choice.station {
            ringing = fire
            if let playRadio {
                player.pause()
                playRadio(station)
                armChimeFallback(for: fire)
            } else {
                say("\(fire.label): radio can't start here, so Baton rang instead.")
                playChime?()
            }
            return
        }
        let (songs, index) = resolve(fire.choice)
        ringing = fire
        guard !songs.isEmpty else {
            say("\(fire.label): \(fire.choice.title) is no longer on this device.")
            playChime?()
            return
        }
        player.play(songs, startAt: index, source: fire.choice.source)
        armChimeFallback(for: fire)
    }

    private func armChimeFallback(for fire: AlarmFire) {
        fallbackTask?.cancel()
        guard playChime != nil else { return }
        let delay = chimeFallbackDelay
        fallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.ringing == fire, !self.player.isPlaying, !self.radioIsPlaying() else { return }
            self.playChime?()
        }
    }

    // MARK: Answering the ringing

    /// Stop: the music stops, as Clock's Stop silences the alarm.
    public func stopRinging() {
        guard let fire = ringing else { return }
        finishRinging()
        pausePlayback(for: fire)
    }

    /// Snooze: the music pauses and it goes off again in nine minutes. A timer has no snooze in
    /// Clock; here it starts a nine-minute timer for the same item, so the ringing card's
    /// Snooze means the same thing for both.
    public func snoozeRinging() {
        guard let fire = ringing else { return }
        finishRinging()
        pausePlayback(for: fire)
        switch fire.kind {
        case .alarm: store.snooze(id: fire.alarmID, now: now())
        case .timer: store.startTimer(duration: BatonAlarm.snoozeInterval, label: fire.label, choice: fire.choice, now: now())
        }
    }

    /// Whether the ringing card offers Snooze: always for a timer, and for an alarm whose Snooze
    /// is on.
    public static func offersSnooze(_ fire: AlarmFire) -> Bool { fire.kind == .timer || fire.snoozeEnabled }

    /// "Keep playing, open player": the ringing goes, the music carries on and the full player
    /// comes forward, so the person is never left on the screen they were on.
    public func keepPlayingAndShowPlayer() {
        guard ringing != nil else { return }
        finishRinging()
        showPlayer?()
    }

    private func pausePlayback(for fire: AlarmFire) {
        if fire.choice.kind == .radio { stopRadio?() }
        player.pause()
    }

    /// Dismiss the ringing and let the music carry on.
    public func keepPlaying() {
        guard ringing != nil else { return }
        finishRinging()
    }

    public func dismissNotice() {
        missed = nil
        notice = nil
    }

    private func say(_ text: String) {
        notice = text
        notify?(text)
    }

    private func finishRinging() {
        fallbackTask?.cancel()
        fallbackTask = nil
        stopChime?()
        ringing = nil
    }

    // MARK: Helpers

    /// Drops local files that no longer exist and moves the start to the first item left at or
    /// after the chosen one.
    public nonisolated static func dropMissingFiles(_ choice: AlarmChoice) -> (songs: [NavidromeSong], startIndex: Int) {
        var kept: [NavidromeSong] = []
        var start: Int?
        for (index, song) in choice.songs.enumerated() {
            if MediaKind(id: song.id) == .localFile, let url = URL(string: song.id), url.isFileURL,
               !FileManager.default.fileExists(atPath: url.path) { continue }
            if start == nil, index >= choice.startIndex { start = kept.count }
            kept.append(song)
        }
        return (kept, start ?? max(0, kept.count - 1))
    }

    public nonisolated static func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// What a system sync does with the alarms the system already holds (TBX-11171 review): a pure
/// decision, so the rule that matters most is tested without AlarmKit.
///
/// Baton runs `sync` at every launch, background launches included (a book refresh, an alarm's
/// Stop, a push). Before this rule it knew nothing after a launch and cancelled and rescheduled
/// every alarm, which silenced one that was ringing and threw away a system snooze.
///
/// - An alarm ringing, counting down (a snooze, or the timer) or paused is never cancelled unless
///   the person deleted it, switched it off or cancelled it (`stoppedByUser`). An edit to it waits
///   until it is back to merely scheduled.
/// - A scheduled alarm whose fingerprint matches what was last scheduled (kept across launches)
///   is left alone. A changed one is cancelled and scheduled again.
/// - One the store no longer wants is cancelled when only scheduled.
public enum AlarmSystemSyncPlan {
    public struct Existing: Equatable, Sendable {
        public var id: UUID
        /// Ringing, counting down or paused: something the person may be in the middle of.
        public var isActive: Bool
        public init(id: UUID, isActive: Bool) {
            self.id = id
            self.isActive = isActive
        }
    }

    public struct Result: Equatable, Sendable {
        public var cancel: Set<UUID> = []
        /// Ids to schedule fresh (cancelled first when listed in `cancel` too).
        public var schedule: Set<UUID> = []
    }

    /// - Parameters:
    ///   - existing: what the system holds now.
    ///   - desired: what the store wants scheduled, by system id, with a fingerprint of how.
    ///   - lastScheduled: the fingerprints last scheduled, as saved across launches.
    ///   - managedElsewhere: ids synced by their own rule (the running timer's pause and resume).
    ///   - stoppedByUser: system ids the person deleted, switched off or cancelled.
    public static func plan(existing: [Existing], desired: [UUID: String], lastScheduled: [UUID: String],
                            managedElsewhere: Set<UUID> = [], stoppedByUser: Set<UUID>) -> Result {
        var result = Result()
        let existingIDs = Set(existing.map(\.id))
        for alarm in existing where !managedElsewhere.contains(alarm.id) {
            guard let fingerprint = desired[alarm.id] else {
                if !alarm.isActive || stoppedByUser.contains(alarm.id) { result.cancel.insert(alarm.id) }
                continue
            }
            if lastScheduled[alarm.id] == fingerprint || alarm.isActive { continue }
            result.cancel.insert(alarm.id)
            result.schedule.insert(alarm.id)
        }
        for id in desired.keys where !existingIDs.contains(id) {
            result.schedule.insert(id)
        }
        return result
    }
}

/// What a sync does to the running timer the system holds (AlarmKit). The timer is synced by
/// state rather than by fingerprint, since pause and resume act on the alarm AlarmKit already
/// has; and when its sound changed (the track's clip was cut after it started with the chime) it
/// is cancelled and scheduled again for the same end, once.
public enum AlarmSystemTimerPlan {
    /// The system's copy of the timer.
    public enum Held: Equatable, Sendable { case none, countdown, paused, other }
    public enum Action: Equatable, Sendable { case none, resume, pause, schedule, reschedule }

    /// - Parameters:
    ///   - state: the store's timer.
    ///   - givenSound: the sound it should ring now.
    ///   - recordedSound: the sound it was last scheduled with, as saved across launches (nil
    ///     when unknown), so a launch with an unchanged sound leaves it alone.
    public static func action(_ state: BatonTimer.State, held: Held, now: Date, givenSound: String,
                              recordedSound: String?) -> Action {
        switch (state, held) {
        case (.running, .paused): return .resume
        case (.paused, .countdown): return .pause
        case let (.running(endsAt), .none) where endsAt > now: return .schedule
        case let (.running(endsAt), .countdown) where recordedSound != givenSound && endsAt.timeIntervalSince(now) > 3:
            return .reschedule
        default: return .none
        }
    }
}
