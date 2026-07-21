import XCTest
@testable import Baton

/// : speak_summary hardening — case-insensitive category, gated auto-play, temp cleanup.
@MainActor
final class SpeechHardeningTests: XCTestCase {
    override func setUp() {
        SpeechConfig.defaults = UserDefaults(suiteName: "speech-test-\(UUID().uuidString)")!
    }
    override func tearDown() { SpeechConfig.defaults = .standard }

    func testCategoryLookupIsCaseInsensitive() {
        let lower = SpeechConfig.resolve(category: "ops", explicitVoice: nil, engineOverride: nil)
        let upper = SpeechConfig.resolve(category: "OPS", explicitVoice: nil, engineOverride: nil)
        XCTAssertEqual(lower, upper)
        XCTAssertEqual(upper.voice, "am_fenrir", "OPS should resolve to the ops voice, not default")
    }

    func testAutoPlayOffByDefault() {
        XCTAssertFalse(SpeechConfig.allowAutoPlay)
    }

    func testSummaryCharCapIsBounded() {
        XCTAssertEqual(SpeechConfig.maxSummaryChars, 2000)
    }

    func testSweepDeletesStaleClips() throws {
        let dir = BatonMCPSpeakTools.tempDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0, 1, 2]).write(to: f)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        BatonMCPSpeakTools.sweepStaleTempFiles(olderThan: 0, now: Date().addingTimeInterval(3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path), "stale clip should be swept")
    }
}
