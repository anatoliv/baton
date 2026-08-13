import AVFoundation
import XCTest
import BatonDSP
@testable import BatonPlaybackKit

/// The second half of the prize: **live level metering on a streamed source**.
///
/// The AVPlayer engine's meter rides the same tap as the EQ, so it too never ran for
/// HTTP streams — the shipped app falls back to a precomputed offline envelope
/// (`TrackLevelTimeline`). Here the meter is `installTap` on the EQ node's output, fed
/// by the same `LevelAnalyzer` → `LevelSnapshot` chain the UI already consumes; these
/// tests prove it publishes real, spectrally sensible levels while the source is a plain
/// HTTP stream.
@MainActor
final class EngineStreamedMeteringTests: XCTestCase {

    /// Streaming a real MP3 over HTTP, the tap must publish non-silent levels.
    func testTapPublishesLevelsForStreamedMP3() async throws {
        let server = try EngineHTTPServer(payload: try mp3FixtureData(), delivery: .chunked)
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 48_000)
        defer { harness.shutdown() }

        let snapshot = LevelSnapshot()
        harness.controller.startMetering(into: snapshot)

        let track = EnginePlaybackController.Track(
            id: "mp3", url: server.url, duration: 68, supportsTimeOffset: false
        )
        harness.controller.play(track)
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 2.0
        }
        _ = try await harness.renderSeconds(1.5)

        let levels = snapshot.load()
        XCTAssertGreaterThan(
            levels.peak, 0,
            "the tap rendered a streamed MP3 but published silence — metering is not in the streamed path"
        )
    }

    /// Spectral sanity, same discipline as `TapMeteringTests`: a streamed low tone must
    /// weight the low bands; a streamed high tone the high bands. This is what separates
    /// a real meter from a flag that happens to be non-zero.
    func testStreamedToneLandsInTheRightBand() async throws {
        func levels(forTone hz: Double) async throws -> BandLevels {
            let wav = EngineTestSignals.sineWAV(frequency: hz, seconds: 3)
            let server = try EngineHTTPServer(payload: wav, contentType: "audio/wav")
            defer { server.stop() }
            let harness = try EngineRenderHarness(sampleRate: 44_100)
            defer { harness.shutdown() }
            let snapshot = LevelSnapshot()
            harness.controller.startMetering(into: snapshot)
            let track = EnginePlaybackController.Track(
                id: "tone", url: server.url, duration: 3, supportsTimeOffset: false
            )
            harness.controller.play(track)
            try await harness.waitUntil(timeout: 15) {
                harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.5
            }
            _ = try await harness.renderSeconds(1.2)
            return snapshot.load()
        }

        let low = try await levels(forTone: 120)   // below the 200 Hz crossover
        XCTAssertGreaterThan(low.peak, 0)
        XCTAssertGreaterThan(low.low, low.high, "a 120 Hz tone must weight the low band")

        let high = try await levels(forTone: 8_000) // above the 4 kHz crossover
        XCTAssertGreaterThan(high.peak, 0)
        XCTAssertGreaterThan(high.high, high.low, "an 8 kHz tone must weight the high band")
    }
}
