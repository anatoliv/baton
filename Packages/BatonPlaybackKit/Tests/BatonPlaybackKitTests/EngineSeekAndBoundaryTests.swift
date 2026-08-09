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
        harness.controller.play([track])
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
        harness.controller.play([track])
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
        XCTAssertEqual(harness.controller.currentIndex, 0, "a seek must never advance the queue (the old spurious-EOF bug)")
    }

    /// Gapless: two tracks scheduled back-to-back on one deck. The rendered boundary
    /// must contain **no silent gap** — asserted on the audio, window by window — and
    /// the logical state must advance exactly once, via the boundary callback.
    func testGaplessBoundaryHasNoSilentGap() async throws {
        let serverA = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 3), contentType: "audio/wav")
        let serverB = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 660, seconds: 3), contentType: "audio/wav")
        defer { serverA.stop(); serverB.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }

        let tracks = [
            EnginePlaybackController.Track(id: "a", url: serverA.url, duration: 3, supportsTimeOffset: false),
            EnginePlaybackController.Track(id: "b", url: serverB.url, duration: 3, supportsTimeOffset: false),
        ]
        harness.controller.play(tracks)
        // Both tracks fit inside the 8 s high-water mark, so the feeder rolls into
        // track B and schedules all of it before we render a single frame.
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 5.8
        }

        let samples = try await harness.renderSeconds(5.5)
        // Let the boundary's .dataPlayedBack callback (a main-actor hop) settle.
        try await harness.waitUntil(timeout: 5) { harness.controller.gaplessAdvanceCountForTesting == 1 }

        XCTAssertEqual(harness.controller.currentIndex, 1, "the queue must have advanced at the audio boundary")
        XCTAssertEqual(harness.controller.loadCountForTesting, 1, "a gapless advance must not reload")

        let rate = 44_100.0
        func window(_ from: Double, _ seconds: Double) -> [Float] {
            let start = Int(from * rate), count = Int(seconds * rate)
            return Array(samples[start ..< min(start + count, samples.count)])
        }
        // The right audio on each side of the boundary…
        let before = window(1.0, 1.0)
        XCTAssertGreaterThan(
            EngineTestSignals.goertzelPower(samples: before, sampleRate: rate, frequency: 440),
            EngineTestSignals.goertzelPower(samples: before, sampleRate: rate, frequency: 660) * 10
        )
        let after = window(4.0, 1.0)
        XCTAssertGreaterThan(
            EngineTestSignals.goertzelPower(samples: after, sampleRate: rate, frequency: 660),
            EngineTestSignals.goertzelPower(samples: after, sampleRate: rate, frequency: 440) * 10
        )
        // …and no dropout across it: every 512-frame window (~11.6 ms) around the
        // boundary keeps signal. A sine at 0.5 amplitude has RMS ≈ 0.35; a rendered gap
        // would show a window near zero.
        let windowFrames = 512
        var scan = Int(2.5 * rate)
        let scanEnd = Int(3.5 * rate)
        while scan + windowFrames <= scanEnd {
            let rms = EngineTestSignals.rms(Array(samples[scan ..< scan + windowFrames]))
            XCTAssertGreaterThan(
                rms, 0.1,
                "silent window at \(Double(scan) / rate)s — the 'gapless' boundary rendered a gap"
            )
            scan += windowFrames
        }
    }
}
