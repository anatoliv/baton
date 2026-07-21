import XCTest
@testable import Baton

/// The speaking-HUD controls on `SpeechPlaybackEngine`: pause / resume / cancel, the `isPaused`
/// state, and the `currentText` label. Native speech is async, so the "still speaking" assertions
/// are guarded on `isSpeaking` (as the existing ducking tests are).
@MainActor
final class SpeechControlsTests: XCTestCase {
    private final class FakeDuck: SpeechDucking {
        var begins = 0, ends = 0
        func beginSpeechDuck() { begins += 1 }
        func endSpeechDuck() { ends += 1 }
    }

    func testCancelStopsAndRestores() {
        let engine = SpeechPlaybackEngine()
        let duck = FakeDuck()
        engine.ducking = duck
        engine.speakNative("a spoken summary long enough to still be playing when cancelled")
        engine.cancel()
        XCTAssertFalse(engine.isSpeaking)
        XCTAssertFalse(engine.isPaused)
        XCTAssertNil(engine.currentText)
        XCTAssertEqual(duck.begins, duck.ends, "cancel restores the ducked music")
    }

    func testPauseResumeTogglesState() {
        let engine = SpeechPlaybackEngine()
        engine.ducking = FakeDuck()
        engine.speakNative("first utterance, long enough to still be playing while we pause it")
        guard engine.isSpeaking else { return } // native speech may finish too fast to test
        XCTAssertFalse(engine.isPaused)
        engine.pause()
        XCTAssertTrue(engine.isPaused)
        engine.resume()
        XCTAssertFalse(engine.isPaused)
        engine.togglePause()
        XCTAssertTrue(engine.isPaused)
        engine.stop()
    }

    func testCurrentTextReflectsWhatIsSpeaking() {
        let engine = SpeechPlaybackEngine()
        engine.ducking = FakeDuck()
        engine.speakNative("the summary text shown in the HUD")
        if engine.isSpeaking {
            XCTAssertEqual(engine.currentText, "the summary text shown in the HUD")
        }
        engine.stop()
    }

    func testPauseIsNoOpWhenIdle() {
        let engine = SpeechPlaybackEngine()
        engine.ducking = FakeDuck()
        engine.pause()
        XCTAssertFalse(engine.isPaused)
        engine.resume()
        XCTAssertFalse(engine.isPaused)
    }

    func testCancelClearsPausedState() {
        let engine = SpeechPlaybackEngine()
        engine.ducking = FakeDuck()
        engine.speakNative("long enough to pause then cancel while still paused mid-utterance")
        guard engine.isSpeaking else { return }
        engine.pause()
        XCTAssertTrue(engine.isPaused)
        engine.cancel()
        XCTAssertFalse(engine.isPaused)
        XCTAssertFalse(engine.isSpeaking)
    }
}
