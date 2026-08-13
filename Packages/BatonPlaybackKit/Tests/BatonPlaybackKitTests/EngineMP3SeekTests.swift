import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Seeking a real MP3 that the server will **not** serve at an offset.
///
/// `supportsTimeOffset == false` is the plain-file case: the seek cannot ask the server to
/// start elsewhere, so the engine re-fetches from byte zero and decode-discards to the
/// playhead. It is the path a non-transcoded library MP3 takes, and it was reported failing
/// on a real library with `AudioFileStreamParseBytes failed (1954115647)` — `'typ?'`,
/// `kAudioFileStreamError_UnsupportedFileType`, which is the parser saying it could not tell
/// what the bytes were.
///
/// Nothing covered it. The MP3 fixture is played by the decoder, EQ and metering suites, and
/// seeks are covered on synthetic WAVs — so "real MP3 + seek + no timeOffset", the one
/// combination in the report, was the gap between them.
@MainActor
final class EngineMP3SeekTests: XCTestCase {

    /// The fixture is 68 s at 48 kHz.
    private let rate = 48_000.0

    /// The suffix is the load-bearing field here: it is what says the frames are
    /// self-framing, and so whether a seek may ask for a byte range at all.
    private func mp3Song() -> NavidromeSong {
        var song = NavidromeSong(id: "mp3", title: "fixture", artist: "t", album: nil,
                                 duration: 68, coverArtID: nil)
        song.suffix = "mp3"
        return song
    }

    func testSeekingAnMP3TheServerWontOffsetKeepsPlaying() async throws {
        let mp3 = try mp3FixtureData()
        let server = try EngineHTTPServer(payload: mp3, contentType: "audio/mpeg")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: rate)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120

        let track = EnginePlaybackController.Track(
            id: "mp3", url: server.url, duration: 68, supportsTimeOffset: false
        )
        harness.controller.play(track)
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 2.0
        }

        // Half way in, which is where the report seeks.
        harness.controller.seek(to: 34)
        try await harness.waitUntil(timeout: 30) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.0
        }
        if case .error(let message) = harness.controller.state {
            XCTFail("the seek left the engine in error: \(message)")
            return
        }

        // Audio, not just a state — the failure under test stops sound while the transport
        // still claims to be playing.
        //
        // Paced, not free-running: the playhead is published by a 4 Hz clock, so rendering
        // 1.5 s of audio in fifty milliseconds of wall clock proves the deck is fed but
        // leaves `currentTime` sitting exactly on the seek target with no tick having run.
        let samples = try await harness.renderPaced(maxSeconds: 1.2)
        XCTAssertGreaterThan(EngineTestSignals.rms(Array(samples.dropFirst(Int(0.25 * rate)))), 0.001,
                             "no audio rendered after seeking a non-offsettable MP3")
        XCTAssertGreaterThan(harness.controller.currentTime, 34.2,
                             "the playhead did not advance from the seek target")
    }

    /// A seek past the spool asks the server for the bytes at the target, instead of
    /// re-fetching the prefix and decoding it away.
    ///
    /// This is the fix for the hour-long sets: at 40 minutes in, fetch-from-zero means tens
    /// of megabytes and forty minutes of decoding before one sample can be scheduled, which
    /// is why those tracks never started. A stored file is byte-range seekable — the same
    /// fact that gets `format` dropped from its URL — so the seek asks for the byte the
    /// parser says holds that second.
    func testSeekPastTheSpoolAsksForTheBytesItWants() async throws {
        let mp3 = try mp3FixtureData()
        let server = try EngineHTTPServer(payload: mp3, delivery: .rangeCapable(bytesPerSecond: 200_000), contentType: "audio/mpeg")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: rate)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120

        // `song` carries the suffix, which is what says the frames are self-framing.
        let track = EnginePlaybackController.Track(
            id: "mp3", url: server.url, duration: 68,
            song: mp3Song(), supportsTimeOffset: false
        )
        harness.controller.play(track)
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 2.0
        }

        harness.controller.seek(to: 55)
        try await harness.waitUntil(timeout: 30) { harness.controller.loadCountForTesting == 2 }
        try await harness.waitUntil(timeout: 30) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.0
        }

        // The claim, in the only terms that can't be faked: the second request named a byte
        // well into the file rather than starting over.
        let starts = server.requestedRangeStarts
        XCTAssertEqual(starts.count, 1, "the seek should have made exactly one ranged request")
        let start = try XCTUnwrap(starts.first)
        XCTAssertGreaterThan(start, mp3.count / 2,
                             "a seek to 55 s of 68 s asked for byte \(start) of \(mp3.count) — that is the prefix again")

        if case .error(let message) = harness.controller.state {
            return XCTFail("the ranged seek left the engine in error: \(message)")
        }
        let samples = try await harness.renderPaced(maxSeconds: 1.2)
        XCTAssertGreaterThan(EngineTestSignals.rms(Array(samples.dropFirst(Int(0.25 * rate)))), 0.001,
                             "the ranged seek produced no audio")
        XCTAssertGreaterThan(harness.controller.currentTime, 55,
                             "the playhead must read the target, not the stream's own zero")
    }

    /// The fallback, which matters because plenty of servers ignore `Range`: the engine must
    /// still land at the target and still play. It costs the prefix over the wire either way
    /// — the point is that it is never *wrong*, only sometimes slower.
    ///
    /// The server here is throttled to about twelve times the track's own bitrate, which is
    /// what makes the seek target genuinely unspooled at the moment of the seek. It also
    /// means the discarded prefix takes real seconds to arrive, which is the honest cost of
    /// this path and the reason the ranged one exists.
    func testAServerThatIgnoresRangeStillLandsOnTheTarget() async throws {
        let mp3 = try mp3FixtureData()
        let server = try EngineHTTPServer(payload: mp3, delivery: .ignoresRange(bytesPerSecond: 200_000), contentType: "audio/mpeg")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: rate)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120

        let track = EnginePlaybackController.Track(
            id: "mp3", url: server.url, duration: 68,
            song: mp3Song(), supportsTimeOffset: false
        )
        harness.controller.play(track)
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 2.0
        }

        harness.controller.seek(to: 55)
        try await harness.waitUntil(timeout: 30) { harness.controller.loadCountForTesting == 2 }
        try await harness.waitUntil(timeout: 30) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.0
        }
        if case .error(let message) = harness.controller.state {
            return XCTFail("the seek left the engine in error when the server ignored Range: \(message)")
        }
        let samples = try await harness.renderPaced(maxSeconds: 1.2)
        XCTAssertGreaterThan(EngineTestSignals.rms(Array(samples.dropFirst(Int(0.25 * rate)))), 0.001,
                             "no audio after a seek the server refused to serve as a range")
        XCTAssertGreaterThan(harness.controller.currentTime, 55,
                             "the playhead must still read the target when the range was ignored")
    }

    /// The same seek against a stream whose bytes are NOT already spooled, which is the
    /// harder half: the seek target is past everything downloaded, so it cannot be served
    /// from the spool and the engine must re-request and decode-discard its way there.
    func testSeekingBeyondTheSpoolReloadsAndKeepsPlaying() async throws {
        let mp3 = try mp3FixtureData()
        // Deliver slowly enough that a seek to 55 s lands well past what has arrived.
        let server = try EngineHTTPServer(payload: mp3, delivery: .chunked, contentType: "audio/mpeg")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: rate)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120

        let track = EnginePlaybackController.Track(
            id: "mp3", url: server.url, duration: 68, supportsTimeOffset: false
        )
        harness.controller.play(track)
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 2.0
        }

        harness.controller.seek(to: 55)
        try await harness.waitUntil(timeout: 30) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.0
        }
        if case .error(let message) = harness.controller.state {
            XCTFail("the seek left the engine in error: \(message)")
            return
        }
        let samples = try await harness.renderPaced(maxSeconds: 1.2)
        XCTAssertGreaterThan(EngineTestSignals.rms(Array(samples.dropFirst(Int(0.25 * rate)))), 0.001,
                             "no audio rendered after a seek that had to re-fetch")
    }
}
