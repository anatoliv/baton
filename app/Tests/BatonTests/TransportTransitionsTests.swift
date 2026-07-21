import XCTest
@testable import Baton

/// Covers the pure crossfade + gapless-preload collaborators extracted from
/// `StreamingPlaybackController`: the blend curve, the trigger window, the prefetch gate,
/// and the preload-URL choice. The AVFoundation player wiring and the actual gap-free audio stay
/// in the controller and need on-device validation — this pins the decision/math around them.
final class TransportTransitionsTests: XCTestCase {
    // MARK: - Crossfade window

    func testNoFadeWhenWindowZero() {
        XCTAssertFalse(Crossfade.inWindow(currentTime: 100, duration: 100, window: 0))
    }

    func testFadeOnlyInsideTheWindow() {
        // window 6 s, 200 s track → fade starts at 194 s.
        XCTAssertFalse(Crossfade.inWindow(currentTime: 193.9, duration: 200, window: 6))
        XCTAssertTrue(Crossfade.inWindow(currentTime: 194, duration: 200, window: 6))
        XCTAssertTrue(Crossfade.inWindow(currentTime: 200, duration: 200, window: 6))
    }

    func testTrackShorterThanWindowPlusOneHardCuts() {
        // A 6 s track with a 6 s window: duration is not > window + 1, so never fade.
        XCTAssertFalse(Crossfade.inWindow(currentTime: 6, duration: 6, window: 6))
        XCTAssertFalse(Crossfade.inWindow(currentTime: 6.9, duration: 6.9, window: 6))
    }

    // MARK: - Crossfade gain ramp

    func testGainsStartAndEnd() {
        let start = Crossfade.gains(step: 0, of: 24, startOut: 0.8, targetIn: 0.6)
        XCTAssertEqual(start.out, 0.8, accuracy: 1e-6)   // outgoing full
        XCTAssertEqual(start.in, 0.0, accuracy: 1e-6)    // incoming silent
        let end = Crossfade.gains(step: 24, of: 24, startOut: 0.8, targetIn: 0.6)
        XCTAssertEqual(end.out, 0.0, accuracy: 1e-6)     // outgoing silent
        XCTAssertEqual(end.in, 0.6, accuracy: 1e-6)      // incoming full
    }

    func testGainsAreLinearAtMidpoint() {
        let mid = Crossfade.gains(step: 12, of: 24, startOut: 1.0, targetIn: 1.0)
        XCTAssertEqual(mid.out, 0.5, accuracy: 1e-6)
        XCTAssertEqual(mid.in, 0.5, accuracy: 1e-6)
    }

    // MARK: - Gapless prefetch gate

    func testPrefetchAllowedUnlessWifiOnlyAndMetered() {
        XCTAssertTrue(GaplessPreload.shouldPrefetch(wifiOnly: false, metered: true))
        XCTAssertTrue(GaplessPreload.shouldPrefetch(wifiOnly: true, metered: false))
        XCTAssertTrue(GaplessPreload.shouldPrefetch(wifiOnly: false, metered: false))
        XCTAssertFalse(GaplessPreload.shouldPrefetch(wifiOnly: true, metered: true))
    }

    // MARK: - Preload URL choice

    func testPreloadPrefersLocalFileOverStream() {
        let file = URL(fileURLWithPath: "/tmp/track.m4a")
        // An offline download resolves to a file: URL — use it directly, ignore any cache.
        XCTAssertEqual(GaplessPreload.preloadURL(stream: file, cached: nil), file)
    }

    func testPreloadPrefersCacheOverStream() {
        let stream = URL(string: "https://music.example.com/stream?id=1")!
        let cached = URL(fileURLWithPath: "/tmp/cache/1.m4a")
        XCTAssertEqual(GaplessPreload.preloadURL(stream: stream, cached: cached), cached)
    }

    func testPreloadFallsBackToStreamWhenNoCache() {
        let stream = URL(string: "https://music.example.com/stream?id=1")!
        XCTAssertEqual(GaplessPreload.preloadURL(stream: stream, cached: nil), stream)
    }

    // MARK: - Fade envelope

    func testFadeRampStartMidEnd() {
        // Fade out 1.0 → 0.0 over 20 steps.
        XCTAssertEqual(Fade.multiplier(step: 0, of: 20, start: 1, target: 0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Fade.multiplier(step: 10, of: 20, start: 1, target: 0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Fade.multiplier(step: 20, of: 20, start: 1, target: 0), 0.0, accuracy: 1e-6)
    }

    func testFadeLandsExactlyOnTarget() {
        // A partial fade (e.g. resuming mid-fade) still ends exactly on target at the last step.
        XCTAssertEqual(Fade.multiplier(step: 20, of: 20, start: 0.3, target: 1), 1.0, accuracy: 1e-6)
    }

    // MARK: - Effective volume

    func testEffectiveVolumeMultipliesFactors() {
        // 50% user level, unity loudness, full fade → 0.5.
        XCTAssertEqual(PlaybackVolume.effective(percent: 50, loudness: 1, fade: 1), 0.5, accuracy: 1e-6)
    }

    func testEffectiveVolumeAppliesLoudnessAndFade() {
        // 100% user, 0.8 loudness (attenuating a hot track), 0.5 fade → 0.4.
        XCTAssertEqual(PlaybackVolume.effective(percent: 100, loudness: 0.8, fade: 0.5), 0.4, accuracy: 1e-6)
    }

    func testEffectiveVolumeZeroWhenMuted() {
        // A fully faded-out envelope is silent regardless of the other factors.
        XCTAssertEqual(PlaybackVolume.effective(percent: 100, loudness: 1.5, fade: 0), 0, accuracy: 1e-6)
    }

    // MARK: - Resume from saved position

    func testResumesMidTrack() {
        // 120 s episode saved at 40 s → resume there.
        XCTAssertTrue(PlaybackResume.shouldResume(offset: 40, duration: 120))
    }

    func testDoesNotResumeNearStart() {
        // A near-start offset (≤ 2 s) isn't worth a seek — start from the top.
        XCTAssertFalse(PlaybackResume.shouldResume(offset: 1.5, duration: 120))
        XCTAssertFalse(PlaybackResume.shouldResume(offset: 2, duration: 120))
    }

    func testDoesNotResumeNearEnd() {
        // Within the last 5 s the episode is essentially finished — don't drop into the tail.
        XCTAssertFalse(PlaybackResume.shouldResume(offset: 116, duration: 120))
        XCTAssertFalse(PlaybackResume.shouldResume(offset: 119, duration: 120))
    }

    func testDoesNotResumeWhenDurationUnknown() {
        // Duration not yet known (≤ 1) → can't validate the offset, so start fresh.
        XCTAssertFalse(PlaybackResume.shouldResume(offset: 5, duration: 0))
    }

    // MARK: - End-of-track boundary

    func testAtEndWithinTolerance() {
        // Within 0.35 s of a 180 s track's end counts as ended.
        XCTAssertTrue(TrackBoundary.isAtEnd(currentTime: 179.7, duration: 180))
        XCTAssertTrue(TrackBoundary.isAtEnd(currentTime: 180, duration: 180))
    }

    func testNotAtEndBeforeTolerance() {
        XCTAssertFalse(TrackBoundary.isAtEnd(currentTime: 179.6, duration: 180))
        XCTAssertFalse(TrackBoundary.isAtEnd(currentTime: 90, duration: 180))
    }

    func testUnknownDurationHasNoEnd() {
        // A live stream / not-yet-known length (≤ 1 s) never reads as "at end".
        XCTAssertFalse(TrackBoundary.isAtEnd(currentTime: 0.5, duration: 0))
        XCTAssertFalse(TrackBoundary.isAtEnd(currentTime: 1, duration: 1))
    }

    func testCustomTolerance() {
        XCTAssertTrue(TrackBoundary.isAtEnd(currentTime: 178, duration: 180, tolerance: 5))
        XCTAssertFalse(TrackBoundary.isAtEnd(currentTime: 174, duration: 180, tolerance: 5))
    }
}
