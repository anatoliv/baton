import AVFoundation
import AppKit
import SwiftUI
import XCTest
@testable import Baton

/// The Mac's in-app Alarm and Timer (TBX-11171, specs/alarm-and-timer.md). macOS has no AlarmKit
/// for apps, so Baton's own clock is the alarm: a timer set through the Mac's `MacAlarms` ends,
/// the app's real player plays the chosen track, the floating ringing card comes up over every
/// Space, and Stop pauses the music and takes the card down. No notification is scheduled here.
@MainActor
final class MacAlarmsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-mac-alarm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func tone(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000 * 30)!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    private func waitUntil(_ seconds: Double = 8, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private var ringingPanelVisible: Bool {
        NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0.level == .floating }
    }

    func testTimerEndsAndTheMacPlaysTheChosenTrackThenStopPausesIt() throws {
        let model = MusicModel(environment: .testing)
        defer { model.music.stop() }
        let alarms = MacAlarms(player: model.music, defaults: ThrowawayDefaults.make("mac-alarms"))
        alarms.start(model: model, systemNotifications: false)
        defer { alarms.center.stop() }
        let url = try tone("wake")
        let song = NavidromeSong(id: url.absoluteString, title: "Wake Up", artist: "Baton")

        let timer = alarms.store.startTimer(duration: 1, label: "Tea", choice: .song(song))
        XCTAssertFalse(model.music.isPlaying)
        waitUntil { model.music.isPlaying && model.music.nowPlaying?.id == song.id }

        XCTAssertEqual(model.music.nowPlaying?.title, "Wake Up", "the chosen track plays when the timer ends")
        XCTAssertTrue(model.music.isPlaying)
        XCTAssertEqual(alarms.center.ringing?.alarmID, timer.id)
        XCTAssertEqual(alarms.center.ringing?.label, "Tea")
        XCTAssertNil(alarms.store.timer, "an ended timer goes away")
        waitUntil(3) { ringingPanelVisible }
        XCTAssertTrue(ringingPanelVisible, "the ringing card floats over every Space")

        alarms.center.stopRinging()
        XCTAssertFalse(model.music.isPlaying, "Stop stops the music, as Clock's Stop silences the alarm")
        waitUntil(3) { !ringingPanelVisible }
        XCTAssertFalse(ringingPanelVisible)
    }

    func testNowPlayingChoiceIsTheQueueFromTheCurrentTrack() throws {
        let model = MusicModel(environment: .testing)
        defer { model.music.stop() }
        let songs = try (1 ... 3).map { n in
            NavidromeSong(id: try tone("q\(n)").absoluteString, title: "Track \(n)", artist: "Baton")
        }
        XCTAssertNil(MacAlarms.nowPlaying(model), "nothing in the player, nothing to offer")
        model.music.play(songs, startAt: 1, source: .init(label: "Morning", kind: .playlist, id: "p1"))
        let choice = try XCTUnwrap(MacAlarms.nowPlaying(model))
        XCTAssertEqual(choice.kind, .playlist)
        XCTAssertEqual(choice.songs.map(\.title), ["Track 1", "Track 2", "Track 3"])
        XCTAssertEqual(choice.songs[choice.startIndex].title, "Track 2")
        XCTAssertEqual(choice.subtitle, "From Morning")
    }

    /// The ringing card's three answers: it offers Keep playing, open player,
    /// Snooze 9 min and Stop; "open player" takes the card down, leaves the music playing and asks
    /// the Baton window for its full-screen player; Snooze on a timer starts nine minutes more.
    func testRingCardOffersThreeAnswersAndOpenPlayerKeepsPlaying() throws {
        let model = MusicModel(environment: .testing)
        defer { model.music.stop() }
        let alarms = MacAlarms(player: model.music, defaults: ThrowawayDefaults.make("mac-alarms-ring"))
        let router = BatonCommandRouter()
        alarms.router = router
        alarms.start(model: model, systemNotifications: false)
        defer { alarms.center.stop() }
        let song = NavidromeSong(id: try tone("ring").absoluteString, title: "Wake Up", artist: "Baton")

        alarms.store.startTimer(duration: 1, label: "Tea", choice: .song(song))
        waitUntil { model.music.isPlaying && alarms.center.ringing != nil }
        waitUntil(3) { ringingPanelVisible }
        // The card's buttons are read by an accessibility client in the probe
        // (scripts/probe-alarm-timer.sh); in-process, SwiftUI builds no accessibility tree. Here,
        // the panel holds the card, and the card is tall enough for its three answers.
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.level == .floating })
        let card = try XCTUnwrap(panel.contentView)
        XCTAssertGreaterThan(card.fittingSize.height, 330, "Keep playing, Snooze and Stop need the room: \(card.fittingSize)")
        XCTAssertTrue(AlarmCenter.offersSnooze(try XCTUnwrap(alarms.center.ringing)), "a timer's card offers Snooze")

        let before = router.showNowPlayingToken
        alarms.center.keepPlayingAndShowPlayer()
        XCTAssertNil(alarms.center.ringing)
        XCTAssertTrue(model.music.isPlaying, "the music carries on")
        XCTAssertGreaterThan(router.showNowPlayingToken, before, "the Baton window is asked for its player")
        waitUntil(3) { !ringingPanelVisible }
        XCTAssertFalse(ringingPanelVisible)

        // Again, and Snooze: the music pauses and a nine-minute timer for the same item starts.
        alarms.store.startTimer(duration: 1, label: "Tea", choice: .song(song))
        waitUntil { alarms.center.ringing != nil }
        alarms.center.snoozeRinging()
        XCTAssertFalse(model.music.isPlaying)
        let snoozed = try XCTUnwrap(alarms.store.timer)
        XCTAssertEqual(snoozed.duration, 9 * 60)
        XCTAssertEqual(snoozed.choice, .song(song))
        alarms.store.cancelTimer()
        waitUntil(3) { !ringingPanelVisible }
        XCTAssertFalse(ringingPanelVisible, "Snooze takes the card down too")
    }

    /// The popover's quick sheet: "Then play" defaults to what the player holds,
    /// a preset selects and Start starts it. The probe photographs the popover itself.
    func testThePopoverSheetOffersPresetsAndDefaultsToWhatIsPlaying() throws {
        let model = MusicModel(environment: .testing)
        defer { model.music.stop() }
        let alarms = MacAlarms(player: model.music, defaults: ThrowawayDefaults.make("mac-alarms-popover"))
        alarms.start(model: model, systemNotifications: false)
        defer { alarms.center.stop() }
        let song = NavidromeSong(id: try tone("now").absoluteString, title: "Now Playing Song", artist: "Baton")
        model.music.play([song], source: .init(label: song.title, kind: .song, id: song.id))
        model.music.pause()

        // What the popover's sheet starts from: Then play is what the player holds, paused or not.
        let context = alarms.sheetContext
        let setup = AlarmQuickSetup(mode: .timer, nowPlaying: context.nowPlaying(), lastPlayed: context.lastPlayed())
        XCTAssertEqual(setup.thenPlay?.title, "Now Playing Song")
        XCTAssertEqual(AlarmQuickSetup.presetMinutes, [5, 10, 15, 30, 60])

        // And the sheet itself lays out at the popover's size.
        let host = NSHostingView(rootView: AlarmQuickSheet(request: .list, context: context) {})
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 580)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)

        // A preset and Start, as the popover's buttons do.
        setup.selectPreset(minutes: 5)
        XCTAssertNil(alarms.store.timer, "selecting a preset starts nothing")
        setup.startTimer(in: alarms.store)
        XCTAssertEqual(alarms.store.timer?.duration, 300)
        XCTAssertEqual(alarms.store.timer?.choice.title, "Now Playing Song")
        alarms.store.cancelTimer()
        XCTAssertNil(alarms.store.timer)
    }
}
