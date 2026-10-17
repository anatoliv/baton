import AVFoundation
import AppKit
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
}
