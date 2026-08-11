#if !os(watchOS)
import AVFoundation
import XCTest
@testable import BatonPlaybackKit
@testable import BatonDSP

/// Profiles measured from real decoded audio, not from mocked samples.
///
/// `SonicAnalyzer` is already tested against synthesized buffers; what is untested until
/// here is everything between a file on disk and those buffers — the reader settings, the
/// stereo fold-down, the length cap, and the persistence that stops a library being
/// re-decoded on every launch.
final class SonicProfileStoreTests: XCTestCase {
    /// Writes a real WAV so `AVAssetReader` has something genuine to decode.
    private func writeTone(frequency: Double, seconds: Double, channels: AVAudioChannelCount,
                           name: String) throws -> URL {
        let rate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try XCTUnwrap(buffer.floatChannelData)[channel]
            for frame in 0..<Int(frames) {
                data[frame] = 0.5 * sinf(2 * .pi * Float(frequency) * Float(frame) / Float(rate))
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testProfilesARealFileAndDistinguishesBrightFromDark() throws {
        let dark = try writeTone(frequency: 120, seconds: 2, channels: 1, name: "dark")
        let bright = try writeTone(frequency: 7_000, seconds: 2, channels: 1, name: "bright")
        defer { for url in [dark, bright] { try? FileManager.default.removeItem(at: url) } }

        let darkProfile = try XCTUnwrap(SonicProfileStore.analyze(url: dark, seconds: 90))
        let brightProfile = try XCTUnwrap(SonicProfileStore.analyze(url: bright, seconds: 90))
        XCTAssertGreaterThan(brightProfile.brightness, darkProfile.brightness,
                             "a 7 kHz file must profile brighter than a 120 Hz one")
        XCTAssertGreaterThan(darkProfile.energy, 0)
    }

    func testStereoIsFoldedDownRatherThanReadAsTwiceTheAudio() throws {
        // Interleaved stereo read as mono would treat each frame's two channels as two
        // consecutive samples — halving the apparent period and doubling every frequency,
        // which would quietly make every stereo track profile as brighter than it is.
        let mono = try writeTone(frequency: 500, seconds: 2, channels: 1, name: "mono")
        let stereo = try writeTone(frequency: 500, seconds: 2, channels: 2, name: "stereo")
        defer { for url in [mono, stereo] { try? FileManager.default.removeItem(at: url) } }

        let monoProfile = try XCTUnwrap(SonicProfileStore.analyze(url: mono, seconds: 90))
        let stereoProfile = try XCTUnwrap(SonicProfileStore.analyze(url: stereo, seconds: 90))
        XCTAssertEqual(stereoProfile.brightness, monoProfile.brightness, accuracy: 0.05,
                       "the same tone in stereo must profile like the mono version")
    }

    func testAnUnreadableFileHasNoProfileRatherThanThrowing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).wav")
        XCTAssertNil(SonicProfileStore.analyze(url: missing, seconds: 90))
    }

    func testProfilesPersistAcrossStoreInstances() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let tone = try writeTone(frequency: 300, seconds: 2, channels: 1, name: "persist")
        defer { try? FileManager.default.removeItem(at: tone) }

        let first = SonicProfileStore(storeURL: storeURL)
        let analyzed = await first.analyzeLocal(id: "song-1", url: tone)
        let measured = try XCTUnwrap(analyzed)

        // A second store reading the same file must not need to decode anything.
        let second = SonicProfileStore(storeURL: storeURL)
        let loaded = await second.profile(for: "song-1")
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded, measured, "profile did not survive a restart")
        let present = await second.hasProfile(for: "song-1")
        XCTAssertTrue(present)
    }

    func testClearingRemovesProfilesFromDiskToo() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let tone = try writeTone(frequency: 300, seconds: 2, channels: 1, name: "clear")
        defer { try? FileManager.default.removeItem(at: tone) }

        let store = SonicProfileStore(storeURL: storeURL)
        _ = await store.analyzeLocal(id: "song-1", url: tone)
        await store.clear()
        let stillThere = await store.hasProfile(for: "song-1")
        XCTAssertFalse(stillThere)
        let reopened = SonicProfileStore(storeURL: storeURL)
        let cameBack = await reopened.hasProfile(for: "song-1")
        XCTAssertFalse(cameBack, "cleared profiles came back from disk")
    }
}
#endif
