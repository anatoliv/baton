import AVFoundation
import XCTest
import BatonDSP
@testable import BatonPlaybackKit

/// The indicator, end to end: does the thing the **UI actually reads** show the real beat
/// while a track is *streaming*?
///
/// `EngineStreamedMeteringTests` proves the tap fills a `LevelSnapshot`. That is one wire
/// short of the claim. `NowPlayingBars` doesn't read a snapshot — it reads
/// `AudioLevelMonitor.isLive` and `.levels`. So this closes the last gap: engine → tap →
/// snapshot → monitor, on an HTTP source, and asserts what a bar would actually draw.
///
/// Why this test is written the way it is: on the shipping engine the bars *looked*
/// reactive and measurably weren't — the on-screen heights matched the canned animation's
/// constants exactly, because the tap never ran for streams and the meter silently read
/// zeros. Two habits come from that and are enforced below:
///
/// 1. **Prove the source, not just the symptom.** A non-zero level could come from the
///    offline envelope fallback (`TrackLevelTimeline`) rather than from live audio. Each
///    test asserts no envelope exists for the track, so the only possible origin is the tap.
/// 2. **Assert spectral truth, not liveness.** A meter pinned at a constant is "live" and
///    useless. A low tone must weight the low band and a high tone the high band.
@MainActor
final class EngineNowPlayingBarsTests: XCTestCase {

    private func makeMonitor() -> AudioLevelMonitor {
        AudioLevelMonitor(defaults: UserDefaults(suiteName: "baton.bars.\(UUID().uuidString)")!)
    }

    /// A single WAV whose first half is quiet and second half loud — a 24 dB step inside
    /// one track, which is the cheapest signal that separates "moving" from "following".
    private static func steppedLoudnessWAV(
        frequency: Double, secondsEach: Double, sampleRate: Double = 44_100
    ) -> Data {
        let framesEach = Int(secondsEach * sampleRate)
        var samples: [Int16] = []
        samples.reserveCapacity(framesEach * 2)
        for (amplitude, count) in [(0.03, framesEach), (0.5, framesEach)] {
            for i in 0 ..< count {
                let value = amplitude * sin(2 * .pi * frequency * Double(i) / sampleRate)
                samples.append(Int16(max(-32767, min(32767, value * 32767))))
            }
        }
        return EngineTestSignals.wavForTesting(samples: samples, sampleRate: Int(sampleRate))
    }

    override func setUp() async throws {
        TrackLevelTimeline.clear()
    }

    /// Stream a tone over HTTP, point the monitor at the engine's snapshot, and read what
    /// the bars would draw.
    private func monitorReading(forTone hz: Double, id: String) async throws -> BandLevels {
        let wav = EngineTestSignals.sineWAV(frequency: hz, seconds: 3)
        let server = try EngineHTTPServer(payload: wav, contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 48_000)
        defer { harness.shutdown() }

        let monitor = makeMonitor()
        // The app wires these two lines; everything else here is the engine doing its job.
        harness.controller.startMetering(into: monitor.snapshot)
        monitor.retain()

        let track = EnginePlaybackController.Track(
            id: id, url: server.url, duration: 3, supportsTimeOffset: false
        )
        harness.controller.play([track])
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.0
        }
        _ = try await harness.renderSeconds(1.5)

        // The envelope fallback must be empty — otherwise a passing assertion below could
        // be reading precomputed audio instead of the live stream.
        XCTAssertFalse(
            TrackLevelTimeline.hasEnvelope(id: id),
            "an offline envelope exists for this track, so a non-zero level would not prove the tap ran"
        )

        monitor.sampleNow()
        return monitor.levels
    }

    /// The headline: on a streamed source the monitor the UI reads goes live, with no
    /// envelope in play. On the AVPlayer engine this is exactly what never happened.
    func testTheMonitorGoesLiveOnAStreamedSource() async throws {
        let wav = EngineTestSignals.sineWAV(frequency: 300, seconds: 3)
        let server = try EngineHTTPServer(payload: wav, contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 48_000)
        defer { harness.shutdown() }

        let monitor = makeMonitor()
        harness.controller.startMetering(into: monitor.snapshot)
        monitor.retain()
        XCTAssertFalse(monitor.isLive, "nothing has rendered yet")

        let track = EnginePlaybackController.Track(
            id: "live", url: server.url, duration: 3, supportsTimeOffset: false
        )
        harness.controller.play([track])
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.0
        }
        _ = try await harness.renderSeconds(1.5)

        monitor.sampleNow()
        XCTAssertTrue(monitor.isLive, "the bars would still be drawing their canned loop")
        XCTAssertGreaterThan(monitor.levels.peak, 0)
        XCTAssertFalse(TrackLevelTimeline.hasEnvelope(id: "live"),
                       "the reading must come from the live tap, not the offline fallback")
    }

    /// Spectral truth: what the bars draw has to be *this* audio, not merely motion.
    func testTheBarsFollowTheSpectrumOfTheStream() async throws {
        let low = try await monitorReading(forTone: 120, id: "low")
        XCTAssertGreaterThan(low.peak, 0)
        XCTAssertGreaterThan(low.low, low.high, "a streamed 120 Hz tone must weight the low bar")

        let high = try await monitorReading(forTone: 8_000, id: "high")
        XCTAssertGreaterThan(high.peak, 0)
        XCTAssertGreaterThan(high.high, high.low, "a streamed 8 kHz tone must weight the high bar")
    }

    /// The bars must move *with the music*, not merely be non-zero. A track that steps
    /// from quiet to loud has to read quiet then loud — the property the canned animation
    /// can never have, and the one that makes the indicator honest.
    func testTheBarsTrackDynamicsWithinAStreamedTrack() async throws {
        // One continuous stream: 1.5 s quiet (≈ −30 dBFS), then 1.5 s loud (≈ −6 dBFS).
        // Built as a single WAV rather than two concatenated files — two WAVs glued
        // together would put a second RIFF header mid-payload and decode as garbage.
        let joined = Self.steppedLoudnessWAV(frequency: 440, secondsEach: 1.5)

        let server = try EngineHTTPServer(payload: joined, contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 48_000)
        defer { harness.shutdown() }

        let monitor = makeMonitor()
        harness.controller.startMetering(into: monitor.snapshot)
        monitor.retain()

        let track = EnginePlaybackController.Track(
            id: "dynamics", url: server.url, duration: 3, supportsTimeOffset: false
        )
        harness.controller.play([track])
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 2.5
        }

        _ = try await harness.renderSeconds(1.2)      // inside the quiet half
        monitor.sampleNow()
        let quietReading = monitor.levels.peak

        _ = try await harness.renderSeconds(1.2)      // inside the loud half
        monitor.sampleNow()
        let loudReading = monitor.levels.peak

        XCTAssertGreaterThan(quietReading, 0, "even −30 dBFS must lift the bars off the floor")
        XCTAssertGreaterThan(
            loudReading, quietReading * 1.3,
            "the bars did not respond to a 24 dB step — they are not following the music"
        )
        XCTAssertFalse(TrackLevelTimeline.hasEnvelope(id: "dynamics"))
    }

    /// Silence must read as silence. A meter that never falls is as dishonest as one that
    /// never moves — and this is what lets `NowPlayingBars` fall back rather than freeze.
    func testSilenceReadsAsNotLive() async throws {
        let wav = EngineTestSignals.sineWAV(frequency: 440, seconds: 2, amplitude: 0)
        let server = try EngineHTTPServer(payload: wav, contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 48_000)
        defer { harness.shutdown() }

        let monitor = makeMonitor()
        harness.controller.startMetering(into: monitor.snapshot)
        monitor.retain()

        let track = EnginePlaybackController.Track(
            id: "silent", url: server.url, duration: 2, supportsTimeOffset: false
        )
        harness.controller.play([track])
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.0
        }
        _ = try await harness.renderSeconds(1.0)

        monitor.sampleNow()
        XCTAssertFalse(monitor.isLive, "silent audio must not report a live signal")
    }
}
