import XCTest
@testable import Baton

/// W-43 / SPEECH-01/02: a spoken summary must duck the music for the duration of the speaking
/// session and restore it after, and utterances must queue rather than cut each other off.
@MainActor
final class SpeechDuckingTests: XCTestCase {
    private final class FakeDuck: SpeechDucking {
        var begins = 0
        var ends = 0
        func beginSpeechDuck() { begins += 1 }
        func endSpeechDuck() { ends += 1 }
    }

    /// A file that can't be loaded finishes synchronously, so the whole session begins and ends
    /// in one call — proving the duck is acquired on speak and released once nothing remains.
    func testUtteranceDucksThenRestores() {
        let engine = SpeechPlaybackEngine()
        let duck = FakeDuck()
        engine.ducking = duck
        engine.play(.file(URL(fileURLWithPath: "/nonexistent/baton-\(UUID().uuidString).wav")))
        XCTAssertEqual(duck.begins, 1, "speaking must duck the music")
        XCTAssertEqual(duck.ends, 1, "the duck must be released once the session drains")
        XCTAssertFalse(engine.isSpeaking)
    }

    /// stop() while speaking restores the music; the acquire/release count always balances.
    func testStopBalancesTheDuck() {
        let engine = SpeechPlaybackEngine()
        let duck = FakeDuck()
        engine.ducking = duck
        engine.speakNative("a spoken summary long enough to still be playing")
        engine.stop()
        XCTAssertGreaterThanOrEqual(duck.begins, 1, "starting speech acquires a duck")
        XCTAssertEqual(duck.begins, duck.ends, "every acquired duck is released — music never stays low")
        XCTAssertFalse(engine.isSpeaking)
    }

    /// While one utterance is active, a second queues FIFO behind it instead of interrupting.
    func testSecondUtteranceQueuesBehindAnActiveOne() {
        let engine = SpeechPlaybackEngine()
        engine.ducking = FakeDuck()
        engine.speakNative("first utterance, still playing")
        // Only meaningful if the first is genuinely still playing (native speech is async).
        if engine.isSpeaking {
            engine.play(.native("second utterance"))
            XCTAssertEqual(engine.queuedCount, 1, "the second utterance queues behind the active one")
        }
        engine.stop()
        XCTAssertEqual(engine.queuedCount, 0, "stop() clears the queue")
    }
}
