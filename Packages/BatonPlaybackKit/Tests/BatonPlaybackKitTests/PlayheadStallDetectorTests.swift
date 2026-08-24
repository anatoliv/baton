import XCTest
@testable import BatonPlaybackKit

/// The rules for "playing, but nothing is coming out".
///
/// The bug these pin: Baton 0.16.23, left idle overnight, showed `state == .playing` with
/// the playhead frozen at 0:00 and no error, no buffering indicator and no watchdog armed.
/// macOS had stopped the AUHAL across sleep without posting a configuration change, so
/// nothing re-anchored — and the existing dry-detector could not see it, because the deck
/// was fully stocked. `aheadSeconds` was positive the whole time. Pause/resume and skipping
/// to a fresh track both failed to recover it; only relaunching did.
///
/// So the cases below are mostly about *not* firing: the detector's value is entirely in
/// being trustworthy enough to trigger an engine restart, and a false positive interrupts
/// healthy playback.
final class PlayheadStallDetectorTests: XCTestCase {

    /// Drive `ticks` clock ticks with a fixed frame count, returning how many fired.
    private func stalls(_ detector: inout PlayheadStallDetector,
                        frames: Int64,
                        ticks: Int,
                        queued: Bool = true,
                        playing: Bool = true,
                        interval: TimeInterval = 0.25) -> Int {
        var fired = 0
        for _ in 0 ..< ticks {
            if detector.observe(playedFrames: frames, hasQueuedAudio: queued,
                                intendsToPlay: playing, elapsed: interval) {
                fired += 1
            }
        }
        return fired
    }

    // MARK: - The failure it exists for

    func testAFrozenPlayheadWithAudioQueuedIsAStall() {
        var detector = PlayheadStallDetector()
        // 2 s threshold at 0.25 s per tick: one baseline tick, then eight to cross it.
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 9), 1,
                       "a deck with audio queued and a playhead that never moves is the whole bug")
    }

    func testItDoesNotFireBeforeTheThreshold() {
        var detector = PlayheadStallDetector()
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 8), 0,
                       "fired inside 2 s — a scheduling hiccup between ticks would restart the engine")
    }

    func testItFiresOncePerStallRatherThanEveryTick() {
        var detector = PlayheadStallDetector()
        // Twice the threshold's worth of ticks must not mean a restart every tick: the
        // recovery is a graph restart, and one stall must buy exactly one of them.
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 17), 2,
                       "a continuing stall must re-arm, not repeat every tick")
    }

    // MARK: - What must never fire

    func testAdvancingPlaybackIsNeverAStall() {
        var detector = PlayheadStallDetector()
        var frames: Int64 = 0
        var fired = 0
        for _ in 0 ..< 200 {
            frames += 11_025   // 0.25 s at 44.1 kHz
            if detector.observe(playedFrames: frames, hasQueuedAudio: true,
                                intendsToPlay: true, elapsed: 0.25) { fired += 1 }
        }
        XCTAssertEqual(fired, 0, "healthy playback was called a stall")
    }

    /// Buffering at the start of a track: intending to play, nothing queued yet. That is
    /// the *dry* detector's case, and both firing would mean two recoveries for one fault.
    func testADrainedDeckIsTheDryDetectorsBusinessNotThisOne() {
        var detector = PlayheadStallDetector()
        XCTAssertEqual(stalls(&detector, frames: 0, ticks: 40, queued: false), 0,
                       "an empty deck cannot answer this question and must not be asked it")
    }

    /// The end of a track drains the deck by design — the final buffer plays out and
    /// nothing is queued behind it.
    func testTheEndOfATrackIsNotAStall() {
        var detector = PlayheadStallDetector()
        var frames: Int64 = 1_000_000
        var fired = 0
        for tick in 0 ..< 40 {
            let queued = tick < 4          // the last of the audio plays out, then nothing
            if queued { frames += 11_025 }
            if detector.observe(playedFrames: frames, hasQueuedAudio: queued,
                                intendsToPlay: true, elapsed: 0.25) { fired += 1 }
        }
        XCTAssertEqual(fired, 0, "a track that simply ended was reported as a stall")
    }

    func testAPausedTransportIsNotAStall() {
        var detector = PlayheadStallDetector()
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 40, playing: false), 0,
                       "a paused deck does not render, and that is not a fault")
    }

    /// A stall must be observed *continuously*. A deck that alternates between draining and
    /// playing is a slow network, and the dry-detector's ladder already owns that.
    func testAnInterruptedStallDoesNotAccumulate() {
        var detector = PlayheadStallDetector()
        var fired = 0
        for _ in 0 ..< 20 {
            // Seven frozen-but-queued ticks (short of the eight needed), then a drain that
            // clears the accumulator.
            for _ in 0 ..< 7 {
                if detector.observe(playedFrames: 44_100, hasQueuedAudio: true,
                                    intendsToPlay: true, elapsed: 0.25) { fired += 1 }
            }
            _ = detector.observe(playedFrames: 44_100, hasQueuedAudio: false,
                                 intendsToPlay: true, elapsed: 0.25)
        }
        XCTAssertEqual(fired, 0, "partial stalls accumulated across gaps into a false positive")
    }

    /// An engine restart resets the render clock — a player node's `sampleTime` was measured
    /// jumping *backwards* ~34k frames across `AVAudioEngine.pause()`. A detector that read
    /// that as "not moving" would fire on the recovery it had just requested, and loop.
    func testARenderClockResetReadsAsProgressNotAsAStall() {
        var detector = PlayheadStallDetector()
        _ = stalls(&detector, frames: 500_000, ticks: 4)     // settle on a baseline
        XCTAssertFalse(detector.observe(playedFrames: 12_000, hasQueuedAudio: true,
                                        intendsToPlay: true, elapsed: 0.25),
                       "a backwards jump is a restarted clock, not a frozen one")
        XCTAssertEqual(stalls(&detector, frames: 12_000, ticks: 7), 0,
                       "the reset must also re-baseline rather than count from the old reading")
    }

    // MARK: - Bookkeeping

    func testResetRequiresAFreshBaselineBeforeItCanFireAgain() {
        var detector = PlayheadStallDetector()
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 9), 1)
        detector.reset()
        // After a reset the first tick is a baseline again, so a stall costs the full
        // threshold — not one tick because the accumulator survived.
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 8), 0,
                       "reset() left state behind and the next stall fired early")
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 1), 1)
    }

    /// The threshold is in seconds, not in ticks — the clock's period is a separate
    /// decision and must be able to change without moving the stall window with it.
    func testTheThresholdIsMeasuredInSecondsRatherThanTicks() {
        var detector = PlayheadStallDetector()
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 2, interval: 1.0), 0)
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 1, interval: 1.0), 1,
                       "2 s of frozen playhead is 2 s at any tick rate")
    }

    func testTheThresholdIsConfigurable() {
        var detector = PlayheadStallDetector(stalledAfterSeconds: 5)
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 20), 0)
        XCTAssertEqual(stalls(&detector, frames: 44_100, ticks: 1), 1)
    }
}
