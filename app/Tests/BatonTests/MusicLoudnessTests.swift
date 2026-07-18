import Foundation
import Testing
@testable import Baton

/// Pure ReplayGain → linear-volume math for track-to-track loudness normalization.
@MainActor
@Suite("Loudness normalization")
struct MusicLoudnessTests {
    private func song(track: Double? = nil, album: Double? = nil, trackPeak: Double? = nil, albumPeak: Double? = nil) -> NavidromeSong {
        NavidromeSong(
            id: "s", title: "t", artist: nil, album: nil, albumID: nil, duration: nil, coverArtID: nil,
            replayGain: ReplayGain(trackGain: track, albumGain: album, trackPeak: trackPeak, albumPeak: albumPeak)
        )
    }

    private func gain(_ song: NavidromeSong, _ mode: StreamingPlaybackController.LoudnessMode, preamp: Double = 0) -> Float {
        StreamingPlaybackController.normalizationGain(for: song, mode: mode, preampDB: preamp)
    }

    @Test("Off always returns unity")
    func off() {
        #expect(gain(song(track: -6), .off) == 1)
    }

    @Test("No ReplayGain data returns unity (library without tags plays normally)")
    func noData() {
        let bare = NavidromeSong(id: "s", title: "t", artist: nil, album: nil, albumID: nil, duration: nil, coverArtID: nil)
        #expect(gain(bare, .track) == 1)
        #expect(gain(bare, .album) == 1)
    }

    @Test("Track gain is applied as 10^(dB/20)")
    func trackGain() {
        // -6 dB ≈ 0.501 linear.
        #expect(abs(gain(song(track: -6), .track) - 0.5012) < 0.001)
    }

    @Test("Album mode uses albumGain")
    func albumGain() {
        let s = song(track: -6, album: -3)
        #expect(abs(gain(s, .album) - 0.7079) < 0.001) // -3 dB
        #expect(abs(gain(s, .track) - 0.5012) < 0.001) // -6 dB
    }

    @Test("Pre-amp adds to the gain")
    func preamp() {
        // 0 dB gain + 6 dB preamp ≈ 1.995 linear, but no peak → capped at 4, so ~1.995.
        #expect(abs(gain(song(track: 0), .track, preamp: 6) - 1.9953) < 0.001)
    }

    @Test("Peak clamps a boost so it can't clip")
    func peakClamp() {
        // +12 dB is ~3.98 linear, but a 0.9 peak allows at most 1/0.9 = 1.111.
        let clamped = gain(song(track: 12, trackPeak: 0.9), .track)
        #expect(abs(clamped - 1.1111) < 0.001)
    }

    @Test("Falls back to album gain/peak when track values are absent")
    func trackFallsBackToAlbum() {
        #expect(abs(gain(song(album: -6), .track) - 0.5012) < 0.001)
    }
}
