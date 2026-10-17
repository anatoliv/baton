import AVFoundation
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The in-app half of Alarm and Timer: Baton's own clock waking for what is due, and
/// the center playing the chosen item through a real player, with Stop, Snooze and the
/// once-only rule between the in-app and system paths.
@MainActor
final class AlarmClockTests: XCTestCase {
    private var dir: URL!
    private var controllers: [StreamingPlaybackController] = []
    private var tracks: [NavidromeSong] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-tbx-11171-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tracks = try (1 ... 2).map { n in
            let url = try Self.tone(in: dir, named: "wake-\(n)", seconds: 30)
            return NavidromeSong(id: url.absoluteString, title: "Wake \(n)", artist: "Baton")
        }
    }

    override func tearDownWithError() throws {
        controllers.forEach { $0.stop() }
        controllers = []
        try? FileManager.default.removeItem(at: dir)
    }

    private nonisolated static func tone(in dir: URL, named name: String, seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("\(name).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(8_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    private func controller() -> StreamingPlaybackController {
        let c = StreamingPlaybackController(
            streamURLProvider: { URL(string: $0)! },
            coverArtURLProvider: { _ in nil },
            defaults: UserDefaults(suiteName: ThrowawayDefaults.name("tbx11171.alarm"))!,
            systemNowPlaying: false
        )
        c.gaplessEnabled = false
        c.crossfadeSeconds = 0
        controllers.append(c)
        return c
    }

    private func waitUntil(_ condition: () -> Bool, seconds: Double = 8) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private final class FakeSystem: AlarmSystemBridge {
        var silenced: [UUID] = []
        var syncs = 0
        func sync(_ store: AlarmStore) async { syncs += 1 }
        func silence(id: UUID) { silenced.append(id) }
        func authorize() async -> Bool { true }
    }

    /// The clock sleeps until a one-second timer ends and hands it over, in real time.
    func testClockWakesForATimerInRealTime() {
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.clock"))
        var fired: [AlarmFire] = []
        let clock = AlarmClock(store: store) { fired += $0 }
        clock.start()
        defer { clock.stop() }
        store.startTimer(duration: 1, label: "Tea", choice: .song(tracks[0]))
        waitUntil({ !fired.isEmpty }, seconds: 5)
        XCTAssertEqual(fired.map(\.kind), [.timer])
        XCTAssertEqual(fired.first?.label, "Tea")
        XCTAssertNil(store.timer)
    }

    /// An alarm a moment ahead: the clock wakes for it (no 30-second nap in the way).
    func testClockWakesForAnAlarmInRealTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.clock2"), calendar: { cal })
        // The next whole minute; the clock is given a "now" a little before it.
        let real = Date()
        let minuteStart = cal.nextDate(after: real, matching: DateComponents(second: 0), matchingPolicy: .nextTime)!
        let offset = minuteStart.timeIntervalSince(real) - 1.5
        let parts = cal.dateComponents([.hour, .minute], from: minuteStart)
        store.save(BatonAlarm(hour: parts.hour!, minute: parts.minute!, choice: .song(tracks[0])),
                   now: real.addingTimeInterval(offset - 10))
        var fired: [AlarmFire] = []
        let clock = AlarmClock(store: store, now: { Date().addingTimeInterval(offset) }) { fired += $0 }
        clock.start()
        defer { clock.stop() }
        XCTAssertTrue(fired.isEmpty)
        waitUntil({ !fired.isEmpty }, seconds: 5)
        XCTAssertEqual(fired.map(\.occurrence), [minuteStart])
        XCTAssertFalse(store.alarms[0].isEnabled)
    }

    /// The whole in-app path: a timer ends, the chosen track plays from the real player, the
    /// system's copy is told to stay quiet, and Stop pauses it.
    func testTimerEndingPlaysTheChosenTrackAndStopPausesIt() {
        let player = controller()
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.center"))
        let center = AlarmCenter(store: store, player: player)
        let system = FakeSystem()
        center.system = system
        center.start()
        defer { center.stop() }
        let timer = store.startTimer(duration: 1, choice: .song(tracks[1]))
        waitUntil({ player.isPlaying && player.nowPlaying?.id == tracks[1].id })
        XCTAssertEqual(player.nowPlaying?.title, "Wake 2")
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(center.ringing?.alarmID, timer.id)
        XCTAssertEqual(system.silenced, [timer.id])
        center.stopRinging()
        XCTAssertNil(center.ringing)
        XCTAssertFalse(player.isPlaying)
    }

    /// Snooze pauses the music and the alarm comes back in nine minutes; a system callback for
    /// the occurrence already played starts nothing a second time.
    func testSnoozeAndTheOnceOnlyRule() {
        let player = controller()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.snooze"), calendar: { cal })
        let center = AlarmCenter(store: store, player: player)
        var now = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 6, minute: 0))!
        center.now = { now }
        let alarm = BatonAlarm(hour: 7, minute: 0, repeatDays: AlarmRepeat.everyDay, choice: .song(tracks[0]))
        store.save(alarm, now: now)
        now = now.addingTimeInterval(3600)
        center.handle(store.due(at: now), fromSystem: false)
        waitUntil { player.isPlaying }
        XCTAssertTrue(player.isPlaying)
        center.playFromSystem(id: alarm.id)
        XCTAssertEqual(player.nowPlaying?.id, tracks[0].id)
        XCTAssertNil(center.ringing, "the system tap on an occurrence already playing just answers the ringing")
        center.handle(store.due(at: now), fromSystem: false)
        XCTAssertNil(center.ringing, "nothing new is due")

        // Ring again, then snooze.
        player.pause()
        store.snooze(id: alarm.id, now: now)
        now = now.addingTimeInterval(BatonAlarm.snoozeInterval)
        center.handle(store.due(at: now), fromSystem: false)
        XCTAssertNotNil(center.ringing)
        center.snoozeRinging()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(store.nextDue(after: now), now.addingTimeInterval(BatonAlarm.snoozeInterval))
    }

    /// Nothing left to play (the book was removed): the chime sounds and the alarm still rings.
    func testRemovedItemSoundsTheChime() {
        let player = controller()
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.gone"))
        let center = AlarmCenter(store: store, player: player)
        var chimed = 0
        var notices: [String] = []
        center.playChime = { chimed += 1 }
        center.notify = { notices.append($0) }
        let gone = NavidromeSong(id: dir.appendingPathComponent("removed.m4a").absoluteString, title: "Chapter 1", album: "A Book")
        let fire = AlarmFire(kind: .alarm, alarmID: UUID(), occurrence: Date(), label: "Alarm",
                             choice: AlarmChoice(title: "A Book", kind: .book, songs: [gone]), snoozeEnabled: true, isLate: false)
        center.handle([fire], fromSystem: false)
        XCTAssertEqual(chimed, 1)
        XCTAssertNotNil(center.ringing)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(notices.first, "Alarm: A Book is no longer on this device.")
        XCTAssertEqual(center.notice, notices.first)
    }

    /// A Baton that cannot play now (an iPhone in the background, not playing) leaves what is due
    /// for the system's alert and quiets nothing; once it can, the same occurrence plays.
    func testNothingIsAnsweredWhileBatonCannotPlay() {
        let player = controller()
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.gate"))
        let center = AlarmCenter(store: store, player: player)
        let system = FakeSystem()
        center.system = system
        var canPlay = false
        center.canPlayInApp = { canPlay }
        center.start()
        defer { center.stop() }
        let timer = store.startTimer(duration: 1, choice: .song(tracks[0]))
        waitUntil({ false }, seconds: 2)
        XCTAssertNil(center.ringing)
        XCTAssertTrue(system.silenced.isEmpty, "the system's alert is left to ring")
        XCTAssertNotNil(store.timer, "the ended timer is still unanswered")
        center.systemIsAlerting(id: timer.id)
        XCTAssertTrue(system.silenced.isEmpty)
        canPlay = true
        center.appBecameActive()
        waitUntil { player.isPlaying }
        XCTAssertEqual(center.ringing?.alarmID, timer.id)
        XCTAssertEqual(player.nowPlaying?.id, tracks[0].id)
        XCTAssertEqual(system.silenced, [timer.id])
    }

    /// An alarm saved while the permission prompt was still up was synced with no permission;
    /// granting it must sync again, or the first alarm never reaches the system (seen on the
    /// iOS 26.5 simulator walk, 2026-10-17).
    func testGrantingPermissionSyncsAgain() async {
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.permission"))
        let center = AlarmCenter(store: store, player: controller())
        let system = FakeSystem()
        center.system = system
        try? await Task.sleep(for: .milliseconds(400))
        let before = system.syncs
        let allowed = await center.requestPermission()
        XCTAssertTrue(allowed)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(system.syncs, before + 1)
    }

    /// A snooze the system took (AlarmKit's Snooze button, which Baton never hears about): Baton
    /// opened during it, half an hour after the first ring, plays the track rather than calling
    /// the alarm missed (TBX-11171 review).
    func testOpeningDuringASystemSnoozePlaysInsteadOfMissing() {
        let player = controller()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.syssnooze"), calendar: { cal })
        let center = AlarmCenter(store: store, player: player)
        var now = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 6, minute: 0))!
        center.now = { now }
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(tracks[0]))
        store.save(alarm, now: now)
        now = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 7, minute: 30))!
        center.systemIsAlerting(id: alarm.id)
        waitUntil { player.isPlaying }
        XCTAssertEqual(player.nowPlaying?.id, tracks[0].id)
        XCTAssertEqual(center.ringing?.alarmID, alarm.id)
        XCTAssertNil(center.missed)
        XCTAssertNil(center.notice)
    }

    /// A late one (the Mac asleep at the time) plays nothing and is shown as missed.
    func testLateFireIsMissedNotPlayed() {
        let player = controller()
        let store = AlarmStore(defaults: ThrowawayDefaults.make("alarms.late"))
        let center = AlarmCenter(store: store, player: player)
        let fire = AlarmFire(kind: .alarm, alarmID: UUID(), occurrence: Date().addingTimeInterval(-3600), label: "Alarm",
                             choice: .song(tracks[0]), snoozeEnabled: true, isLate: true)
        center.handle([fire], fromSystem: false)
        XCTAssertNil(center.ringing)
        XCTAssertEqual(center.missed, fire)
        XCTAssertNil(player.nowPlaying)
    }
}
