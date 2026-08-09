import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// Crossfade and stall behaviour. These are the wall-clock-driven behaviours (the ramp
/// steps and the transport clock sleep real time), so the renders here are *paced* —
/// pulled at roughly realtime — and the assertions scan the output rather than index
/// into exact positions.
@MainActor
final class EngineTransitionAndStallTests: XCTestCase {

    /// Crossfade: entering the window starts the next track on the second deck and
    /// ramps the two past each other. Proof on the audio: somewhere the two tones
    /// coexist, the output ends on the second tone alone, and no window across the
    /// transition is silent (the  "fade into silence" class).
    func testCrossfadeOverlapsAndNeverGoesSilent() async throws {
        let rate = 44_100.0
        let serverA = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 6), contentType: "audio/wav")
        let serverB = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 660, seconds: 6), contentType: "audio/wav")
        defer { serverA.stop(); serverB.stop() }
        let harness = try EngineRenderHarness(sampleRate: rate)
        defer { harness.shutdown() }

        harness.controller.crossfadeSeconds = 1.5
        let tracks = [
            EnginePlaybackController.Track(id: "a", url: serverA.url, duration: 6, supportsTimeOffset: false),
            EnginePlaybackController.Track(id: "b", url: serverB.url, duration: 6, supportsTimeOffset: false),
        ]
        harness.controller.play(tracks)
        try await harness.waitUntil(timeout: 15) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 3.0
        }

        // Render paced (the ramp and the 4 Hz clock live on the wall clock) long enough
        // for the fade to complete plus a clean tail of the second track. No early exit:
        // at promotion `currentTime` legitimately jumps to the incoming track's position
        // (it has been playing quietly through the pre-roll and ramp, same semantics as
        // the old engine), so a time-based exit condition fires the moment it promotes.
        let samples = try await harness.renderPaced(maxSeconds: 10)
        XCTAssertEqual(harness.controller.currentIndex, 1, "the crossfade must promote to the next track")
        XCTAssertEqual(harness.controller.state, .playing)

        // Scan half-second windows for the three phases.
        let window = Int(0.5 * rate)
        var sawFirstAlone = false, sawOverlap = false, sawSecondAlone = false
        var start = 0
        // Reference powers from a clean stretch of each tone.
        while start + window <= samples.count {
            let slice = Array(samples[start ..< start + window])
            let p440 = EngineTestSignals.goertzelPower(samples: slice, sampleRate: rate, frequency: 440)
            let p660 = EngineTestSignals.goertzelPower(samples: slice, sampleRate: rate, frequency: 660)
            let present440 = p440 > 1e-4, present660 = p660 > 1e-4
            if present440, !present660 { sawFirstAlone = true }
            if present440, present660, sawFirstAlone { sawOverlap = true }
            if present660, !present440, sawOverlap {
                sawSecondAlone = true
                break
            }
            start += window
        }
        XCTAssertTrue(sawFirstAlone, "never saw the first track alone — playback didn't start cleanly")
        XCTAssertTrue(sawOverlap, "the two tracks never overlapped — that is a cut, not a crossfade")
        XCTAssertTrue(sawSecondAlone, "the fade never completed to the second track alone")

        // No silence during the transition: from the first frame to the last, every
        // half-second window must carry signal (the fade holds the outgoing track until
        // the incoming one is audible — by construction here, but the output must agree).
        var scan = Int(0.5 * rate)
        while scan + window <= samples.count {
            let rms = EngineTestSignals.rms(Array(samples[scan ..< scan + window]))
            XCTAssertGreaterThan(rms, 0.03,
                                 "silent window at \(Double(scan) / rate)s during the crossfade")
            scan += window
        }
    }

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
        harness.controller.play([track])

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
