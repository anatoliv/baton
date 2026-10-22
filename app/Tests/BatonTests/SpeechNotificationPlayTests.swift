import BatonSpeech
import XCTest
@testable import Baton

/// Play on a summary's notification, after the same summary was already spoken (
/// A-8). Speaking now consumes and deletes the staged clip, so the notification's Play pointed at
/// a file that was gone and did nothing at all. It now plays that summary from the replay cache,
/// or, when the cache holds a later one, says its words in the built-in voice.
@MainActor
final class SpeechNotificationPlayTests: XCTestCase {
    private var suite: UserDefaults!

    override func setUp() {
        suite = UserDefaults(suiteName: ThrowawayDefaults.name("speech-notification-play"))!
        SpeechConfig.defaults = suite
    }

    override func tearDown() {
        SpeechConfig.defaults = .standard
    }

    func testPlayOnANotificationWhoseClipWasAlreadySpokenReplaysThatSummary() throws {
        let engine = SpeechPlaybackEngine()
        defer { engine.cancel() }
        let url = try BatonMCPSpeakTools.writeTemp(SpeechTestClip.toneWAV(seconds: 0.4))
        engine.play(.file(url), text: "The build passed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "speaking now consumes the staged clip")
        engine.stop()

        engine.playNotified(fileURL: url, text: "The build passed.")

        XCTAssertTrue(engine.isSpeaking, "Play on the notification was silent")
        XCTAssertEqual(engine.currentText, "The build passed.")
    }

    func testWhenTheCacheHoldsALaterSummaryTheNotificationSpeaksItsOwnWords() throws {
        SpeechConfig.fallbackEnabled = true
        let engine = SpeechPlaybackEngine()
        defer { engine.cancel() }
        let first = try BatonMCPSpeakTools.writeTemp(SpeechTestClip.toneWAV(seconds: 0.4))
        engine.play(.file(first), text: "The build passed.")
        engine.stop()
        let later = try BatonMCPSpeakTools.writeTemp(SpeechTestClip.toneWAV(seconds: 0.4))
        engine.play(.file(later), text: "The deploy finished.")
        engine.stop()

        engine.playNotified(fileURL: first, text: "The build passed.")

        XCTAssertTrue(engine.isSpeaking, "Play on the notification was silent")
        XCTAssertEqual(engine.currentText, "The build passed.", "a different summary was played for this notification")
    }

    /// A clip still on disk plays as it always did.
    func testAClipStillOnDiskPlaysThatClip() throws {
        let engine = SpeechPlaybackEngine()
        defer { engine.cancel() }
        let staged = SpeechTestClip.toneWAV(seconds: 0.4)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baton-notify-\(UUID().uuidString).wav")
        try staged.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        engine.playNotified(fileURL: url, text: "The build passed.")

        XCTAssertTrue(engine.isSpeaking)
        XCTAssertEqual(engine.duration ?? 0, 0.4, accuracy: 0.05, "the staged clip is what plays")
    }
}
