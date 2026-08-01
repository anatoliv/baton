import XCTest
@testable import Baton

/// The crossfade readiness gate.
///
/// Before this existed, `CrossfadeRamp.begin` called `play()` on the incoming player and
/// immediately started a wall-clock gain ramp — assuming audio was flowing the instant
/// `play()` returned. It isn't. Navidrome transcodes on the fly (Baton requests
/// `format=mp3`), so a cold start on a long Opus file takes seconds, and the outgoing
/// track would fade to silence while the incoming one was still buffering.
///
/// The rule: hold the outgoing track at full volume until audio is *confirmed* flowing;
/// if it never arrives, hard-cut rather than hang or fade into nothing.
final class CrossfadeReadinessTests: XCTestCase {
    // MARK: - Ready only when audio is genuinely flowing

    func testReadyRequiresTheClockToHaveAdvanced() {
        // readyToPlay + likelyToKeepUp are true, but no audio has been rendered yet:
        // AVPlayerItem reports readyToPlay once the asset is understood, which can
        // precede any decoded sample. Waiting is correct here.
        XCTAssertEqual(
            Crossfade.readiness(isReadyToPlay: true, likelyToKeepUp: true, elapsedTime: 0, waited: 0),
            .wait,
            "readyToPlay alone must not start the blend — that is the original bug"
        )
    }

    func testReadyWhenStatusKeepUpAndClockAllAgree() {
        XCTAssertEqual(
            Crossfade.readiness(isReadyToPlay: true, likelyToKeepUp: true, elapsedTime: 0.08, waited: 0.4),
            .ready
        )
    }

    func testStillBufferingWaitsEvenIfTheClockMoved() {
        XCTAssertEqual(
            Crossfade.readiness(isReadyToPlay: true, likelyToKeepUp: false, elapsedTime: 0.05, waited: 1.0),
            .wait,
            "a stream that can't keep up would stutter through the blend"
        )
    }

    func testNotReadyToPlayWaits() {
        XCTAssertEqual(
            Crossfade.readiness(isReadyToPlay: false, likelyToKeepUp: true, elapsedTime: 0.2, waited: 0.5),
            .wait
        )
    }

    // MARK: - Bounded wait

    func testTimesOutRatherThanHangingForever() {
        XCTAssertEqual(
            Crossfade.readiness(isReadyToPlay: false, likelyToKeepUp: false, elapsedTime: 0, waited: 5.0),
            .timedOut,
            "an unbounded wait would freeze the transport on a dead stream"
        )
    }

    func testTimeoutIsConfigurableAndBoundaryIsInclusive() {
        XCTAssertEqual(
            Crossfade.readiness(isReadyToPlay: false, likelyToKeepUp: false, elapsedTime: 0, waited: 2.0, timeout: 2.0),
            .timedOut
        )
        XCTAssertEqual(
            Crossfade.readiness(isReadyToPlay: false, likelyToKeepUp: false, elapsedTime: 0, waited: 1.99, timeout: 2.0),
            .wait
        )
    }

    func testReadyWinsOverTimeout() {
        // Audio arriving on the very last poll must blend, not hard-cut.
        XCTAssertEqual(
            Crossfade.readiness(isReadyToPlay: true, likelyToKeepUp: true, elapsedTime: 0.01, waited: 99, timeout: 5),
            .ready
        )
    }

    // MARK: - Pre-roll ahead of the window

    func testPreRollStartsEarlierThanTheAudibleWindow() {
        // Waiting for readiness *inside* the window would eat the window and truncate the
        // blend against the end of the track.
        let w = Crossfade.preRollWindow(window: 6, expectedLatency: 2, duration: 600)
        XCTAssertEqual(w, 8, accuracy: 0.001)
    }

    func testPreRollNeverExceedsHalfTheTrack() {
        // A wild latency estimate must not start the pre-roll near the beginning of a short track.
        let w = Crossfade.preRollWindow(window: 6, expectedLatency: 60, duration: 30)
        XCTAssertLessThanOrEqual(w, 15.0)
    }

    func testPreRollIsZeroWhenCrossfadeIsOff() {
        XCTAssertEqual(Crossfade.preRollWindow(window: 0, expectedLatency: 3, duration: 600), 0)
    }

    func testNegativeLatencyEstimateIsIgnored() {
        XCTAssertEqual(Crossfade.preRollWindow(window: 6, expectedLatency: -5, duration: 600), 6, accuracy: 0.001)
    }

    // MARK: - Manual skip constant (reserved; the skip blend itself is not wired yet)
    //
    // Wiring it into next() would defer the queue advance until the ramp completes, so
    // music_next and the UI would report the OLD track for the blend duration —
    // testNextAdvancesAndStopsPastEnd correctly rejects that. The transport must advance
    // synchronously and blend only the audio; that refactor is deliberately separate.

    func testManualSkipConstantIsFastEnoughToFeelInstant() {
        XCTAssertLessThanOrEqual(Crossfade.manualSkipSeconds, 0.5,
                                 "a skip is a request for the next track NOW")
        XCTAssertGreaterThan(Crossfade.manualSkipSeconds, 0.1,
                             "but long enough to remove the click of a hard cut")
    }
}
