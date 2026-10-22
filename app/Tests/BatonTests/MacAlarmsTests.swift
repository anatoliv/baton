import AVFoundation
import AppKit
import SwiftUI
import XCTest
@testable import Baton

/// The Mac's in-app Alarm and Timer. macOS has no AlarmKit
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

    /// Two chimes at once (an alarm and a timer together, or two alarms whose songs are missing)
    /// must not leave the first one looping after Stop. The second chime used to replace the
    /// first without stopping it, and Stop only reached the newest.
    /// Real `NSSound`s on a silent file, kept by the test so a dropped one can still be asked.
    func testASecondChimeStopsTheFirstAndStopLeavesNoneRinging() throws {
        let model = MusicModel(environment: .testing)
        defer { model.music.stop() }
        let alarms = MacAlarms(player: model.music, defaults: ThrowawayDefaults.make("mac-alarms-chime"))
        let silent = try tone("chime")
        var made: [NSSound] = []
        alarms.makeChime = {
            let sound = NSSound(contentsOf: silent, byReference: true)
            if let sound { made.append(sound) }
            return sound
        }
        alarms.start(model: model, systemNotifications: false)
        defer {
            alarms.center.stop()
            made.forEach { $0.stop() }
        }

        alarms.center.playChime?()
        let first = try XCTUnwrap(made.first)
        XCTAssertTrue(first.isPlaying, "the first chime rings (a sound that never played proves nothing below)")
        alarms.center.playChime?()
        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(made[1].isPlaying, "the second chime rings")
        XCTAssertFalse(first.isPlaying, "the second chime replaced the first and left it looping")

        alarms.center.stopChime?()
        XCTAssertEqual(made.filter(\.isPlaying).count, 0, "Stop left a chime ringing")
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
        // About 322 pt with all three; without Snooze it would be about 283 (took
        // the title bar's empty band, about 33 pt, out of the card's height).
        XCTAssertGreaterThan(card.fittingSize.height, 300, "Keep playing, Snooze and Stop need the room: \(card.fittingSize)")
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

    /// The floating ringing card reads in full. Mac 0.20.13 opened it as a strip
    /// about 100 pt wide: the card had only a maximum width, and the panel took the card's minimum,
    /// so the label read "Al…", the time "•••" and the buttons were icons only. Here a timer and
    /// then an alarm go off, each first with short words and then with a label and a track name
    /// long enough to need two lines: the card is at least 320 pt wide, the panel is exactly the
    /// card's size, the time and the three answers fit across it, and the long lines wrap onto a
    /// second line rather than being cut off.
    func testRingingCardIsWideEnoughToReadInFull() throws {
        let model = MusicModel(environment: .testing)
        defer { model.music.stop() }
        let alarms = MacAlarms(player: model.music, defaults: ThrowawayDefaults.make("mac-alarms-width"))
        alarms.start(model: model, systemNotifications: false)
        defer { alarms.center.stop() }
        let url = try tone("card").absoluteString
        let shortSong = NavidromeSong(id: url, title: "Up", artist: "Baton")
        let longSong = NavidromeSong(id: url, title: "Everything in Its Right Place (Live in Berlin)", artist: "Radiohead")
        let longLabel = "Take the bread out of the oven and turn it off"

        func ringTimer(_ label: String, _ song: NavidromeSong) throws -> CGSize {
            alarms.store.startTimer(duration: 1, label: label, choice: .song(song))
            waitUntil { alarms.center.ringing != nil }
            return try ringingCardSize(alarms, "timer")
        }
        func ringAlarm(_ label: String, _ song: NavidromeSong) throws -> CGSize {
            let alarm = BatonAlarm(hour: 6, minute: 45, label: label, choice: .song(song))
            alarms.store.save(alarm)
            alarms.center.systemIsAlerting(id: alarm.id)
            XCTAssertEqual(alarms.center.ringing?.kind, .alarm)
            let size = try ringingCardSize(alarms, "alarm")
            alarms.store.delete(id: alarm.id)
            return size
        }

        for (what, ring) in [("timer", ringTimer), ("alarm", ringAlarm)] {
            let short = try ring("Tea", shortSong)
            stopRinging(alarms)
            let long = try ring(longLabel, longSong)
            stopRinging(alarms)
            XCTAssertEqual(long.width, short.width, accuracy: 1, "the \(what)'s card keeps its width for long words")
            // A second line of the title2 label and of the headline "Then play" is about 38 pt.
            XCTAssertGreaterThan(long.height - short.height, 30,
                                 "the \(what)'s long label and track wrap onto a second line, not cut off: \(short) → \(long)")
        }
    }

    private func stopRinging(_ alarms: MacAlarms) {
        alarms.center.stopRinging()
        waitUntil(3) { !ringingPanelVisible }
    }

    /// The ringing panel's size, after checking it reads in full.
    private func ringingCardSize(_ alarms: MacAlarms, _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> CGSize {
        waitUntil(3) { ringingPanelVisible }
        let fire = try XCTUnwrap(alarms.center.ringing, file: file, line: line)
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.level == .floating },
                                  file: file, line: line)
        let host = try XCTUnwrap(panel.contentView, file: file, line: line)
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        XCTAssertGreaterThanOrEqual(fit.width, 320, "the \(what)'s card is wide enough to read: \(fit)", file: file, line: line)
        XCTAssertEqual(panel.frame.width, fit.width, accuracy: 1, "the panel is the card's width: \(panel.frame.size)", file: file, line: line)
        XCTAssertEqual(panel.frame.height, fit.height, accuracy: 1, "and its height, so nothing is cut off", file: file, line: line)

        // The one-line parts, in the card's own fonts, fit across it: the card's width less the
        // panel's 8 pt and the card's 20 pt padding on each side.
        let column = fit.width - 2 * 8 - 2 * 20
        let oneLine: [(String, AnyView)] = [
            ("the time", AnyView(Text(AlarmCenter.timeString(fire.occurrence))
                .font(AlarmRingingCard.floatingTimeFont).monospacedDigit())),
            ("Keep playing", AnyView(Button {} label: { Label("Keep playing, open player", systemImage: "play.circle.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large))),
            ("Snooze", AnyView(Button {} label: { Label("Snooze 9 min", systemImage: "zzz") }
                .buttonStyle(.bordered).controlSize(.large))),
            ("Stop", AnyView(Button(role: .destructive) {} label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.bordered).controlSize(.large))),
        ]
        for (part, view) in oneLine {
            let ideal = NSHostingView(rootView: view.fixedSize()).fittingSize.width
            XCTAssertLessThanOrEqual(ideal, column, "\(part) fits on one line across the \(what)'s card",
                                     file: file, line: line)
        }
        return panel.frame.size
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
