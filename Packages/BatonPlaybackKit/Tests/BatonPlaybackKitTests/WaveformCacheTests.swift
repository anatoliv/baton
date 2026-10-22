import AVFoundation
import XCTest
@testable import BatonPlaybackKit

@MainActor
final class WaveformCacheTests: XCTestCase {
    func testDifferentBarCountsForOneSongUseDistinctCacheEntries() async throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "stream-fixture", withExtension: "mp3", subdirectory: "Fixtures"
        ))
        let songID = "waveform-counts-\(UUID().uuidString)"
        WaveformExtractor.resetForTesting()
        defer {
            WaveformExtractor.resetForTesting()
            removeDiskEntries(for: songID, counts: [60, 120])
        }

        let compact = await WaveformExtractor.bars(forSongID: songID, url: url, count: 60)
        let fullScreen = await WaveformExtractor.bars(forSongID: songID, url: url, count: 120)

        XCTAssertEqual(compact?.count, 60)
        XCTAssertEqual(fullScreen?.count, 120)
    }

    /// Bars cached by earlier releases were computed with the stereo bucketing bug (C1-19), so
    /// neither earlier file name is read; both are recomputed and the old files removed.
    func testCachesFromBeforeTheStereoFixAreRecomputedAndRemoved() async throws {
        let legacyID = "waveform-legacy-\(UUID().uuidString)"
        let countedID = "waveform-counted-\(UUID().uuidString)"
        let stale = Array(repeating: Float(0.25), count: 60)
        try writeStale(stale, to: legacyDiskURL(for: legacyID))
        try writeStale(stale, to: preFixDiskURL(for: countedID, count: 60))

        let probe = ExtractionProbe()
        WaveformExtractor.resetForTesting { _, count in
            await probe.extract(count: count)
        }
        defer {
            WaveformExtractor.resetForTesting()
            removeDiskEntries(for: legacyID, counts: [60])
            removeDiskEntries(for: countedID, counts: [60])
        }

        let unusedURL = URL(fileURLWithPath: "/waveform-test-does-not-exist")
        let fromLegacy = await WaveformExtractor.bars(forSongID: legacyID, url: unusedURL, count: 60)
        let fromCounted = await WaveformExtractor.bars(forSongID: countedID, url: unusedURL, count: 60)
        let extractionCalls = await probe.callCount()

        XCTAssertNotEqual(fromLegacy, stale)
        XCTAssertNotEqual(fromCounted, stale)
        XCTAssertEqual(extractionCalls, 2, "an old cache was used instead of recomputing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDiskURL(for: legacyID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preFixDiskURL(for: countedID, count: 60).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskURL(for: countedID, count: 60).path))
    }

    /// A stereo track loud for its first half and near silent for its second. Samples are
    /// interleaved, and bucketing them by sample against a length in frames spread the first
    /// half over every bar and put the second half in the last (C1-19).
    func testAStereoTracksSecondHalfLandsInTheSecondHalfOfTheBars() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-stereo-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeStereoLoudThenQuiet(to: url, seconds: 4)
        let songID = "waveform-stereo-\(UUID().uuidString)"
        WaveformExtractor.resetForTesting()
        defer {
            WaveformExtractor.resetForTesting()
            removeDiskEntries(for: songID, counts: [20])
        }

        let extracted = await WaveformExtractor.bars(forSongID: songID, url: url, count: 20)
        let bars = try XCTUnwrap(extracted)
        XCTAssertEqual(bars.count, 20)
        let firstHalf = bars[0 ..< 9].min() ?? 0
        let secondHalf = bars[11 ..< 20].max() ?? 1
        XCTAssertGreaterThan(firstHalf, 0.8, "the loud half: \(bars)")
        XCTAssertLessThan(secondHalf, 0.2, "the quiet half drew as loud: \(bars)")
    }

    func testConcurrentSameCountRequestsShareOneExtraction() async {
        let probe = ExtractionProbe()
        WaveformExtractor.resetForTesting { _, count in
            await probe.extract(count: count)
        }
        let songID = "waveform-in-flight-\(UUID().uuidString)"
        defer {
            WaveformExtractor.resetForTesting()
            removeDiskEntries(for: songID, counts: [60])
        }

        let unusedURL = URL(fileURLWithPath: "/waveform-test-does-not-exist")
        async let first = WaveformExtractor.bars(forSongID: songID, url: unusedURL, count: 60)
        async let second = WaveformExtractor.bars(forSongID: songID, url: unusedURL, count: 60)
        let results = await [first, second]
        let extractionCalls = await probe.callCount()

        XCTAssertEqual(results[0]?.count, 60)
        XCTAssertEqual(results[1]?.count, 60)
        XCTAssertEqual(extractionCalls, 1)
    }

    private func writeStale(_ bars: [Float], to url: URL) throws {
        try JSONEncoder().encode(bars).write(to: url, options: .atomic)
    }

    private func removeDiskEntries(for songID: String, counts: [Int]) {
        try? FileManager.default.removeItem(at: legacyDiskURL(for: songID))
        for count in counts {
            try? FileManager.default.removeItem(at: diskURL(for: songID, count: count))
            try? FileManager.default.removeItem(at: preFixDiskURL(for: songID, count: count))
        }
    }

    private func writeStereoLoudThenQuiet(to url: URL, seconds: Double) throws {
        let rate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0 ..< 2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0 ..< Int(frames) {
                let amplitude: Float = i < Int(frames) / 2 ? 0.8 : 0.05
                samples[i] = amplitude * Float(sin(2 * Double.pi * 330 * Double(i) / rate))
            }
        }
        try file.write(from: buffer)
    }

    private func legacyDiskURL(for songID: String) -> URL {
        waveformDiskDirectory().appendingPathComponent(songID + ".json")
    }

    private func diskURL(for songID: String, count: Int) -> URL {
        waveformDiskDirectory().appendingPathComponent("\(songID)-\(count).v2.json")
    }

    private func preFixDiskURL(for songID: String, count: Int) -> URL {
        waveformDiskDirectory().appendingPathComponent("\(songID)-\(count).json")
    }

    private func waveformDiskDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Tonebox/waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor ExtractionProbe {
    private var calls = 0

    func extract(count: Int) async -> [Float]? {
        calls += 1
        try? await Task.sleep(for: .milliseconds(50))
        return Array(repeating: 0.5, count: count)
    }

    func callCount() -> Int { calls }
}
