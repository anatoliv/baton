import AVFoundation
import XCTest
import BatonDSP
@testable import BatonPlaybackKit

/// **The claim this whole experiment exists to prove**: the equalizer audibly applies to
/// a *streamed* (HTTP, non-file) source in the new engine.
///
/// The AVPlayer engine structurally cannot do this — `MTAudioProcessingTap` never runs
/// for HTTP-streamed items (verified on-device; see the design doc), so the shipped EQ
/// has only ever filtered downloaded files. These tests stream real bytes over a local
/// HTTP server (including the chunked, length-less delivery a cold Navidrome transcode
/// uses), render the graph offline, and *measure the output*: a −12 dB cut must actually
/// remove ~12 dB. State flags can lie; RMS can't.
@MainActor
final class EngineStreamedEQTests: XCTestCase {

    /// A 1 kHz sine streamed over HTTP with a parametric band centred on it: the cut
    /// must attenuate the rendered output by the band's gain, within tolerance.
    func testEQCutAttenuatesStreamedTone() async throws {
        let wav = EngineTestSignals.sineWAV(frequency: 1_000, seconds: 4)

        func renderedRMS(eqEnabled: Bool) async throws -> Double {
            let server = try EngineHTTPServer(payload: wav, contentType: "audio/wav")
            defer { server.stop() }
            let harness = try EngineRenderHarness(sampleRate: 44_100)
            defer { harness.shutdown() }

            var bands = MusicEqualizer.defaultBands()
            // Band index 5 is 1 kHz in the default layout — cut it hard.
            bands[5] = EQBand(frequency: 1_000, q: 1.0, gainDB: -12)
            harness.controller.applyEQ(bands: bands, enabled: eqEnabled)

            let track = EnginePlaybackController.Track(
                id: "tone", url: server.url, duration: 4, supportsTimeOffset: false
            )
            harness.controller.play([track])
            // Everything is local, so the whole 4 s schedules quickly; waiting for it
            // makes the render deterministic.
            try await harness.waitUntil(timeout: 15) {
                harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 2.5
            }
            let samples = try await harness.renderSeconds(2.0)
            // Skip the first half-second: codec/converter spin-up and the fade of the
            // mixer settling are not the claim under test.
            let steady = Array(samples.dropFirst(Int(0.5 * 44_100)))
            return EngineTestSignals.rms(steady)
        }

        let flat = try await renderedRMS(eqEnabled: false)
        let cut = try await renderedRMS(eqEnabled: true)

        XCTAssertGreaterThan(flat, 0.05, "the streamed tone must actually render audibly")
        let ratioDB = 20 * log10(cut / flat)
        print("EQ tone cut measured: \(ratioDB) dB (flat RMS \(flat), cut RMS \(cut))")
        // −12 dB nominal; allow generous tolerance for filter skirt + resampling.
        XCTAssertLessThan(ratioDB, -8, "EQ cut did not apply to the streamed source (measured \(ratioDB) dB)")
        XCTAssertGreaterThan(ratioDB, -16, "attenuation wildly exceeds the band gain (measured \(ratioDB) dB)")
    }

    /// The same claim on the load-bearing format and delivery shape: a real MP3 served
    /// **chunked with no Content-Length** — how a still-encoding transcode arrives. A
    /// full-spectrum −12 dB cut must measurably attenuate the rendered music.
    func testEQAppliesToChunkedMP3Stream() async throws {
        let mp3 = try mp3FixtureData()

        func renderedRMS(eqEnabled: Bool) async throws -> Double {
            let server = try EngineHTTPServer(payload: mp3, delivery: .chunked)
            defer { server.stop() }
            let harness = try EngineRenderHarness(sampleRate: 48_000)
            defer { harness.shutdown() }

            let cutAll = EQLimits.frequencies.map { EQBand(frequency: $0, q: 1.0, gainDB: -12) }
            harness.controller.applyEQ(bands: cutAll, enabled: eqEnabled)

            let track = EnginePlaybackController.Track(
                id: "mp3", url: server.url, duration: 68, supportsTimeOffset: false
            )
            harness.controller.play([track])
            try await harness.waitUntil(timeout: 20) {
                harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 3.0
            }
            let samples = try await harness.renderSeconds(2.5)
            let steady = Array(samples.dropFirst(Int(0.5 * 48_000)))
            return EngineTestSignals.rms(steady)
        }

        let flat = try await renderedRMS(eqEnabled: false)
        let cut = try await renderedRMS(eqEnabled: true)

        XCTAssertGreaterThan(flat, 0.01, "the streamed MP3 must actually render audio — decode failed?")
        let ratioDB = 20 * log10(cut / flat)
        print("EQ MP3 cut measured: \(ratioDB) dB (flat RMS \(flat), cut RMS \(cut))")
        // Ten overlapping −12 dB bands attenuate broadband music heavily; anything less
        // than ~6 dB would mean the EQ is not in the streamed path.
        XCTAssertLessThan(ratioDB, -6, "EQ did not apply to the chunked MP3 stream (measured \(ratioDB) dB)")
    }

    /// Toggling the EQ is `bypass`, not a reload: same stream, toggle mid-flight, and
    /// the output changes — the old engine had to re-fetch the track to do this.
    func testEQLiveToggleNeedsNoReload() async throws {
        let wav = EngineTestSignals.sineWAV(frequency: 1_000, seconds: 6)
        let server = try EngineHTTPServer(payload: wav, contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }

        var bands = MusicEqualizer.defaultBands()
        bands[5] = EQBand(frequency: 1_000, q: 1.0, gainDB: -12)
        harness.controller.applyEQ(bands: bands, enabled: false)

        let track = EnginePlaybackController.Track(
            id: "tone", url: server.url, duration: 6, supportsTimeOffset: false
        )
        harness.controller.play([track])
        try await harness.waitUntil(timeout: 15) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 4.5
        }
        let before = try await harness.renderSeconds(1.5)
        harness.controller.applyEQ(bands: bands, enabled: true) // live toggle
        let after = try await harness.renderSeconds(1.5)

        let loads = harness.controller.loadCountForTesting
        XCTAssertEqual(loads, 1, "an EQ toggle must not reload the stream")
        let beforeRMS = EngineTestSignals.rms(Array(before.dropFirst(4_410)))
        let afterRMS = EngineTestSignals.rms(Array(after.dropFirst(4_410)))
        let ratioDB = 20 * log10(afterRMS / beforeRMS)
        XCTAssertLessThan(ratioDB, -8, "toggling the EQ on had no audible effect (measured \(ratioDB) dB)")
    }
}
