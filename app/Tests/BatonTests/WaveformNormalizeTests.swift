import XCTest
@testable import Baton

/// Covers `WaveformExtractor.normalizeBars` — the pure reduction behind the scrubber's
/// waveform (empty-bucket fill + 0…1 normalization), extracted from the AVAssetReader loop
/// so it's testable without a real audio file. (W-49 unit sweep)
final class WaveformNormalizeTests: XCTestCase {
    func testNormalizesToLoudestBar() {
        let bars = WaveformExtractor.normalizeBars(peaks: [0.25, 0.5, 1.0, 0.75], counts: [1, 1, 1, 1])
        XCTAssertEqual(bars, [0.25, 0.5, 1.0, 0.75])
    }

    func testScalesUpWhenPeakBelowOne() {
        // Loudest bar is 0.5 → everything scales so the max becomes 1.
        let bars = WaveformExtractor.normalizeBars(peaks: [0.1, 0.5, 0.25], counts: [1, 1, 1])
        XCTAssertEqual(bars![0], 0.2, accuracy: 1e-6)
        XCTAssertEqual(bars![1], 1.0, accuracy: 1e-6)
        XCTAssertEqual(bars![2], 0.5, accuracy: 1e-6)
    }

    func testEmptyBucketsInheritLastRealValue() {
        // Buckets 2 and 3 got no samples → they take bucket 1's value (0.8) before normalizing.
        let bars = WaveformExtractor.normalizeBars(peaks: [0.4, 0.8, 0.0, 0.0], counts: [1, 1, 0, 0])
        // max is 0.8 → [0.5, 1, 1, 1]
        XCTAssertEqual(bars!, [0.5, 1.0, 1.0, 1.0])
    }

    func testAllSilentReturnsNil() {
        XCTAssertNil(WaveformExtractor.normalizeBars(peaks: [0, 0, 0], counts: [1, 1, 1]))
    }

    func testClampsAboveOne() {
        // A degenerate peak above the max can't push a bar past 1.
        let bars = WaveformExtractor.normalizeBars(peaks: [2.0, 1.0], counts: [1, 1])
        XCTAssertEqual(bars, [1.0, 0.5])
    }
}
