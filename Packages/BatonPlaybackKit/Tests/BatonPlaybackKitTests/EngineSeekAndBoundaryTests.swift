import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// Seek and gapless-boundary behaviour of the engine, proven on the rendered audio.
///
/// The two-tone fixture is the trick: the first half of the track is 440 Hz, the second
/// 880 Hz, so "the seek landed" is a *spectral* fact about the output — not a state flag
/// that could pass while the audio plays the wrong place (the exact class of lie the
/// CLAUDE.md habits warn about).
@MainActor
final class EngineSeekAndBoundaryTests: XCTestCase {

    /// Seek into the spooled region: no re-request (the load count stays 1), and the
    /// rendered audio after the seek is the *target's* audio.
    func testInSpoolSeekLandsOnTargetAudio() async throws {
        let wav = EngineTestSignals.twoToneWAV(firstHz: 440, secondHz: 880, secondsEach: 3)
        let server = try EngineHTTPServer(payload: wav, contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }

        let track = EnginePlaybackController.Track(
            id: "twotone", url: server.url, duration: 6, supportsTimeOffset: false
        )
        harness.controller.play(track)
        // Local server: the whole file spools + schedules far ahead of the playhead.
        try await harness.waitUntil(timeout: 15) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 5.5
        }

        harness.controller.seek(to: 4.0) // into the 880 Hz half
        try await harness.waitUntil(timeout: 10) {
            abs(harness.controller.currentTime - 4.0) < 0.3
                && harness.pipeline.aheadSeconds(on: harness.controller.activeDeckForTesting) > 0.5
        }
        let samples = try await harness.renderSeconds(1.0)

        XCTAssertEqual(harness.controller.loadCountForTesting, 1,
                       "a backwards-reachable seek must reposition in the spool, not re-request the stream")
        let steady = Array(samples.dropFirst(2_000))
        let at880 = EngineTestSignals.goertzelPower(samples: steady, sampleRate: 44_100, frequency: 880)
        let at440 = EngineTestSignals.goertzelPower(samples: steady, sampleRate: 44_100, frequency: 440)
        XCTAssertGreaterThan(at880, at440 * 10,
                             "after seeking to 4 s the output must be the second tone (880), not the first")
    }

    /// The unreachable direction reuses `StreamSeek.strategy` → `.reload`: the engine
    /// re-requests (here: refetch + decode-discard, since plain HTTP has no
    /// `timeOffset`), and the playhead + audio still land on the target.
    func testUnreachableSeekReloadsAndLands() async throws {
        let wav = EngineTestSignals.twoToneWAV(firstHz: 440, secondHz: 880, secondsEach: 3)
        // Stall after ~1 s of audio so the 4 s target is genuinely outside the spool.
        let server = try EngineHTTPServer(payload: wav, delivery: .stallAfter(bytes: 90_000), contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }

        let track = EnginePlaybackController.Track(
            id: "twotone", url: server.url, duration: 6, supportsTimeOffset: false
        )
        harness.controller.play(track)
        try await harness.waitUntil(timeout: 15) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 0.5
        }

        server.releaseStall() // the reload's fresh request must be able to complete
        harness.controller.seek(to: 4.0)
        try await harness.waitUntil(timeout: 15) {
            harness.controller.loadCountForTesting == 2
                && harness.pipeline.aheadSeconds(on: harness.controller.activeDeckForTesting) > 0.5
        }
        let samples = try await harness.renderSeconds(1.0)
        let steady = Array(samples.dropFirst(2_000))
        let at880 = EngineTestSignals.goertzelPower(samples: steady, sampleRate: 44_100, frequency: 880)
        let at440 = EngineTestSignals.goertzelPower(samples: steady, sampleRate: 44_100, frequency: 440)
        XCTAssertGreaterThan(at880, at440 * 10, "the reloaded seek must land on the 880 Hz half")
        XCTAssertEqual(harness.controller.nowPlaying?.id, "twotone",
                       "a seek must never change the track (the old spurious-EOF bug)")
    }

    // `testGaplessBoundaryHasNoSilentGap` used to live here: two servers, two tracks
    // scheduled back-to-back on one deck, and a 512-frame RMS scan proving the rendered
    // boundary carried no dropout. It is deleted with `rollIntoGaplessNext` (Stage 5 /
    // TBX-2876) — the roll only ever fired for a multi-track queue, and production always
    // handed the engine exactly one track.
    //
    // What is lost, stated plainly: this was the only proof the engine's gapless boundary
    // ever worked, and re-establishing it is part of the cost of any future standalone
    // engine. Gapless *as a user feature* is unaffected — it is the host's AVQueuePlayer
    // preload path, which has its own coverage.
    //
    // What is NOT lost is the end-of-track path itself: `handleTrackAudioEnded` is still
    // the production route for every engine track, still carries the §2.1 spurious-end
    // guard, and still hands off through `onPlaybackEnded`.
    //
    // That path had **no** coverage of its own — these two deleted tests were the only
    // things that ever drove a track to its natural end, incidentally, while asserting
    // about the queue. `EngineEndOfTrackTests` was written to cover it directly.
}
