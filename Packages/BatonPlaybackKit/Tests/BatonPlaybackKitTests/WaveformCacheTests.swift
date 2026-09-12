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

    func testLegacyCacheFallsBackOnlyWhenItsCountMatches() async throws {
        let matchingID = "waveform-legacy-match-\(UUID().uuidString)"
        let mismatchedID = "waveform-legacy-mismatch-\(UUID().uuidString)"
        let matchingBars = (0..<60).map { Float($0) / 60 }
        let mismatchedBars = Array(repeating: Float(0.5), count: 60)
        try writeLegacy(matchingBars, for: matchingID)
        try writeLegacy(mismatchedBars, for: mismatchedID)

        let probe = ExtractionProbe()
        WaveformExtractor.resetForTesting { _, count in
            await probe.extract(count: count)
        }
        defer {
            WaveformExtractor.resetForTesting()
            removeDiskEntries(for: matchingID, counts: [60])
            removeDiskEntries(for: mismatchedID, counts: [120])
        }

        let unusedURL = URL(fileURLWithPath: "/waveform-test-does-not-exist")
        let matching = await WaveformExtractor.bars(forSongID: matchingID, url: unusedURL, count: 60)
        let mismatched = await WaveformExtractor.bars(forSongID: mismatchedID, url: unusedURL, count: 120)
        let extractionCalls = await probe.callCount()

        XCTAssertEqual(matching, matchingBars)
        XCTAssertEqual(mismatched?.count, 120)
        XCTAssertEqual(extractionCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskURL(for: matchingID, count: 60).path))
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

    private func writeLegacy(_ bars: [Float], for songID: String) throws {
        let data = try JSONEncoder().encode(bars)
        try data.write(to: legacyDiskURL(for: songID), options: .atomic)
    }

    private func removeDiskEntries(for songID: String, counts: [Int]) {
        try? FileManager.default.removeItem(at: legacyDiskURL(for: songID))
        for count in counts { try? FileManager.default.removeItem(at: diskURL(for: songID, count: count)) }
    }

    private func legacyDiskURL(for songID: String) -> URL {
        waveformDiskDirectory().appendingPathComponent(songID + ".json")
    }

    private func diskURL(for songID: String, count: Int) -> URL {
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
