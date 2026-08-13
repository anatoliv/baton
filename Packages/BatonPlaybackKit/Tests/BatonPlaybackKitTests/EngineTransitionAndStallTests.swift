import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// Stall behaviour. Wall-clock-driven, so the renders here are *paced* — pulled at roughly
/// realtime — and the assertions scan the output rather than index into exact positions.
///
/// The crossfade half of this file went with the engine's queue (Stage 5 / TBX-2876); the
/// note below says what that cost.
@MainActor
final class EngineTransitionAndStallTests: XCTestCase {

    // `testCrossfadeOverlapsAndNeverGoesSilent` used to live here, and it was a good test:
    // two local servers, real decode, a paced render, and a Goertzel scan proving the two
    // tones actually overlapped and that no half-second window across the transition went
    // silent. It is deleted with the engine's crossfade (Stage 5 / TBX-2876), because the
    // capability it proved could not run in production — the ramp was gated on the engine's
    // own `crossfadeSeconds`, which nothing outside this suite ever set.
    //
    // Recording what is lost, because it is not nothing: this was the only evidence the
    // engine could crossfade at all, and it is the proof a future standalone adopter would
    // have to write again. Crossfade *as a user feature* is untouched — it lives on the
    // host's AVPlayer path, where `maybeStartCrossfade` still runs and is still tested.

    /// A slow-but-open connection: the server stops sending mid-track with the socket
    /// open. The engine must (1) report buffering — from facts, not `timeControlStatus`
    /// — and (2) resume seamlessly when bytes flow again, with no reload.
    func testStallReportsBufferingAndRecovers() async throws {
        let rate = 44_100.0
        // 20 s mono WAV ≈ 1.76 MB; stall after ~2 s of audio (44 B header + 2 s bytes).
        let wav = EngineTestSignals.sineWAV(frequency: 440, seconds: 20)
        let server = try EngineHTTPServer(payload: wav, delivery: .stallAfter(bytes: 180_000), contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: rate)
        defer { harness.shutdown() }

        harness.controller.stallTimeoutSeconds = 120 // keep the watchdog out of this test
        let track = EnginePlaybackController.Track(
            id: "stall", url: server.url, duration: 20, supportsTimeOffset: false
        )
        harness.controller.play(track)

        // Phase 1: initial buffering clears — the ~2 s that arrived starts playing.
        // (The claim under test is the *mid-stream* stall, not the cold start.)
        try await harness.waitUntil(timeout: 10) {
            harness.controller.state == .playing && !harness.controller.isBuffering
        }

        // Phase 2: render (paced) until the playhead consumes what arrived and the
        // transport clock notices the deck has run dry.
        _ = try await harness.renderPaced(maxSeconds: 15) { !harness.controller.isBuffering }
        XCTAssertTrue(harness.controller.isBuffering, "the deck ran dry mid-download but buffering was never reported")
        XCTAssertEqual(harness.controller.state, .playing, "a stall is buffering, not an error")

        server.releaseStall()
        _ = try await harness.renderPaced(maxSeconds: 15) { harness.controller.isBuffering }
        XCTAssertFalse(harness.controller.isBuffering, "bytes resumed but buffering never cleared")
        XCTAssertEqual(harness.controller.loadCountForTesting, 1, "recovery from a byte stall must not reload the stream")

        // And the audio genuinely continues: fresh rendered output carries the tone.
        let after = try await harness.renderSeconds(0.5)
        XCTAssertGreaterThan(EngineTestSignals.rms(Array(after.dropFirst(2_000))), 0.1,
                             "playback did not actually continue after the stall cleared")
    }
}
