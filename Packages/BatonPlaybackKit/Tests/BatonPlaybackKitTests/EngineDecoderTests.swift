import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// Format-level truth for the decode stage, feeding the doc's format matrix: what
/// `AudioFileStream` + `AVAudioConverter` actually deliver for the payloads Baton
/// serves, measured rather than assumed.
final class EngineDecoderTests: XCTestCase {

    /// The load-bearing format: a real MP3 (48 kHz stereo, the demo-library fixture)
    /// parsed in stream-sized chunks must announce its format and decode real PCM.
    func testMP3StreamDecodes() throws {
        let data = try mp3FixtureData()
        let decoder = try AudioStreamDecoder()
        var decodedFrames = 0
        var offset = 0
        let chunk = 32 * 1024
        while offset < min(data.count, 512 * 1024) { // half a MB is plenty of proof
            let end = min(offset + chunk, data.count)
            for buffer in try decoder.parse(data[offset ..< end]) {
                decodedFrames += Int(buffer.frameLength)
                XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
            }
            offset = end
        }
        let format = try XCTUnwrap(decoder.pcmFormat)
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertGreaterThan(decodedFrames, 48_000, "at least a second of PCM must decode from 512 KB of MP3")
        XCTAssertNotNil(decoder.estimatedBytesPerSecond, "packetized formats must estimate a byte rate for seek mapping")
    }

    /// The seek index: once packets have flowed, a mid-track frame maps to a byte
    /// offset inside the file — the primitive the in-spool seek stands on.
    func testMP3SeekTargetMapsIntoTheFile() throws {
        let data = try mp3FixtureData()
        let decoder = try AudioStreamDecoder()
        var offset = 0
        while offset < min(data.count, 256 * 1024) {
            let end = min(offset + 32 * 1024, data.count)
            _ = try decoder.parse(data[offset ..< end])
            offset = end
        }
        let target = try XCTUnwrap(decoder.seekTarget(forFrame: 30 * 48_000)) // 30 s in
        XCTAssertGreaterThan(target.byteOffset, 0)
        XCTAssertLessThan(target.byteOffset, Int64(data.count), "a 30 s target must map inside the 68 s file")
    }

    /// WAV/LPCM: format announced with an exact byte rate (seek mapping needs no
    /// estimate at all for CBR PCM).
    func testWAVDecodesWithExactByteRate() throws {
        let data = EngineTestSignals.sineWAV(frequency: 440, seconds: 2)
        let decoder = try AudioStreamDecoder()
        var decodedFrames = 0
        for buffer in try decoder.parse(data) {
            decodedFrames += Int(buffer.frameLength)
        }
        XCTAssertEqual(decoder.pcmFormat?.sampleRate, 44_100)
        XCTAssertEqual(decoder.estimatedBytesPerSecond, 2 * 44_100, "mono 16-bit LPCM is exactly 88 200 B/s")
        XCTAssertGreaterThan(decodedFrames, Int(1.9 * 44_100))
    }

    /// The honest failure mode for a payload Core Audio cannot parse (an Ogg header).
    ///
    /// **Measured platform behaviour:** `AudioFileStreamParseBytes` does *not* error on
    /// 64 KB of Ogg-shaped bytes — it returns `noErr` and simply never announces a
    /// format (it is still "sniffing"). So the clean failure cannot live in the parser;
    /// it lives one level up: a stream that **ends** without ever yielding a format is
    /// reported as a decode error by `TrackStreamSource`, never as a silent empty track
    /// — silence-with-no-error being the failure shape this codebase treats as the worst
    /// one (see `StreamSeek.nativelyPlayable`).
    func testUnsupportedPayloadFailsCleanly() async throws {
        var ogg = Data("OggS".utf8)
        // Deterministic pseudo-noise body — enough bytes that the parser must commit.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0 ..< 64 * 1024 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            ogg.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        // Parser level: no error, but no format either — document the platform truth.
        let decoder = try AudioStreamDecoder()
        if let produced = try? decoder.parse(ogg) {
            XCTAssertTrue(produced.isEmpty, "Ogg bytes must never 'decode'")
            XCTAssertNil(decoder.pcmFormat, "Ogg bytes must never announce a PCM format")
        }
        // Source level: the end-to-end guarantee — a clean, *reported* failure.
        let server = try EngineHTTPServer(payload: ogg, contentType: "application/ogg")
        defer { server.stop() }
        let source = TrackStreamSource(url: server.url)
        try await source.start()
        do {
            _ = try await source.nextChunk()
            XCTFail("an unparseable stream must throw, not deliver chunks")
        } catch let error as TrackStreamSource.SourceError {
            guard case .decode = error else {
                return XCTFail("expected a decode error, got \(error)")
            }
        }
        await source.cancel()
    }
}
