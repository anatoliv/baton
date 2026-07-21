import XCTest
@testable import Baton

/// : characterization tests pinning the exact current behaviour of the controller's riskiest
/// PURE logic — ReplayGain loudness math and queue-advance decisions — so a later refactor
/// can't silently change it. Values are computed from first principles, not copied from the impl.
@MainActor
final class LoudnessAdvanceCharacterizationTests: XCTestCase {
    private typealias C = StreamingPlaybackController

    private func song(track: Double? = nil, album: Double? = nil, tPeak: Double? = nil, aPeak: Double? = nil) -> NavidromeSong {
        var s = NavidromeSong(id: "s", title: "T", artist: "A", album: nil, duration: 100, coverArtID: nil)
        s.replayGain = ReplayGain(trackGain: track, albumGain: album, trackPeak: tPeak, albumPeak: aPeak)
        return s
    }

    // MARK: normalizationGain — pure ReplayGain math

    func testOffAndMissingDataAreUnityGain() {
        XCTAssertEqual(C.normalizationGain(for: song(track: -6), mode: .off, preampDB: 0), 1)
        let noRG = NavidromeSong(id: "s", title: "T", artist: "A", album: nil, duration: 100, coverArtID: nil)
        XCTAssertEqual(C.normalizationGain(for: noRG, mode: .track, preampDB: 0), 1)
    }

    func testTrackGainIsTenToTheGainOverTwenty() {
        // -6 dB → 10^(-6/20) ≈ 0.5012
        XCTAssertEqual(C.normalizationGain(for: song(track: -6), mode: .track, preampDB: 0), 0.5012, accuracy: 0.001)
        // +6 dB → ≈ 1.9953
        XCTAssertEqual(C.normalizationGain(for: song(track: 6), mode: .track, preampDB: 0), 1.9953, accuracy: 0.001)
    }

    func testPeakClampPreventsClipping() {
        // +12 dB would be ≈3.98, but a 0.9 peak caps it at 1/0.9 ≈ 1.111 so it can't clip.
        XCTAssertEqual(C.normalizationGain(for: song(track: 12, tPeak: 0.9), mode: .track, preampDB: 0), 1.111, accuracy: 0.001)
    }

    func testPreampIsAddedInDecibels() {
        // 0 dB gain + 6 dB preamp → 10^(6/20) ≈ 1.9953
        XCTAssertEqual(C.normalizationGain(for: song(track: 0), mode: .track, preampDB: 6), 1.9953, accuracy: 0.001)
    }

    func testHugeBoostIsCappedAtFour() {
        // +30 dB → ≈31.6, capped at 4 so it can't blast the speakers.
        XCTAssertEqual(C.normalizationGain(for: song(track: 30), mode: .track, preampDB: 0), 4, accuracy: 0.0001)
    }

    func testAlbumModeFallsBackToTrackGain() {
        // Album mode with no album gain uses the track gain: -3 dB → ≈0.7079.
        XCTAssertEqual(C.normalizationGain(for: song(track: -3), mode: .album, preampDB: 0), 0.7079, accuracy: 0.001)
    }

    // MARK: loudnessMultiplier — applies the -6 dB headroom, clamped to [0,1]

    func testMultiplierAppliesHeadroomAndClampsToOne() {
        XCTAssertEqual(C.loudnessMultiplier(for: song(track: 0), mode: .off, preampDB: 0), 1)
        // norm 1 × 0.5 headroom = 0.5
        XCTAssertEqual(C.loudnessMultiplier(for: song(track: 0), mode: .track, preampDB: 0), 0.5, accuracy: 0.001)
        // norm ≈1.995 × 0.5 ≈ 0.9977 (still under the 1.0 ceiling)
        XCTAssertEqual(C.loudnessMultiplier(for: song(track: 6), mode: .track, preampDB: 0), 0.9977, accuracy: 0.001)
        // a big boost × headroom still clamps to 1.0, never above
        XCTAssertEqual(C.loudnessMultiplier(for: song(track: 30), mode: .track, preampDB: 0), 1, accuracy: 0.0001)
    }

    // MARK: onTrackEnd / onManualNext — queue-advance decisions

    func testOnTrackEndRepeatModes() {
        XCTAssertEqual(C.onTrackEnd(current: 0, count: 0, repeatMode: .off), .stop)   // empty
        XCTAssertEqual(C.onTrackEnd(current: 1, count: 3, repeatMode: .one), .replay)  // repeat-one
        XCTAssertEqual(C.onTrackEnd(current: 1, count: 3, repeatMode: .off), .play(2)) // mid, advance
        XCTAssertEqual(C.onTrackEnd(current: 2, count: 3, repeatMode: .off), .stop)    // end, stop
        XCTAssertEqual(C.onTrackEnd(current: 2, count: 3, repeatMode: .all), .play(0)) // end, wrap
    }

    func testOnManualNextRepeatModes() {
        XCTAssertEqual(C.onManualNext(current: 0, count: 0, repeatMode: .all), .stop)   // empty
        XCTAssertEqual(C.onManualNext(current: 1, count: 3, repeatMode: .off), .play(2)) // mid
        XCTAssertEqual(C.onManualNext(current: 2, count: 3, repeatMode: .off), .stop)    // end, off → stop
        XCTAssertEqual(C.onManualNext(current: 2, count: 3, repeatMode: .all), .play(0)) // end, all → wrap
        XCTAssertEqual(C.onManualNext(current: 2, count: 3, repeatMode: .one), .play(0)) // end, one → wrap
    }
}
