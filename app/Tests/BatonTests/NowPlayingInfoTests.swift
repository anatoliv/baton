import MediaPlayer
import XCTest
@testable import Baton

/// Covers `MusicNowPlayingCenter.nowPlayingInfo` — the pure track→Now-Playing-dict mapping
/// (Control Center / media keys / Bluetooth remotes read this), extracted from `update` so it's
/// testable without the OS `MPNowPlayingInfoCenter` singleton.
final class NowPlayingInfoTests: XCTestCase {
    private func song(title: String = "So What", artist: String? = "Miles Davis", album: String? = "Kind of Blue") -> NavidromeSong {
        NavidromeSong(id: "s1", title: title, artist: artist, album: album, duration: 544)
    }

    func testMapsCoreMetadata() {
        let info = MusicNowPlayingCenter.nowPlayingInfo(song: song(), isPlaying: true, currentTime: 12, duration: 544)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "So What")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Miles Davis")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Kind of Blue")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 544)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
    }

    func testPlaybackRateReflectsState() {
        let playing = MusicNowPlayingCenter.nowPlayingInfo(song: song(), isPlaying: true, currentTime: 0, duration: 100)
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
        let paused = MusicNowPlayingCenter.nowPlayingInfo(song: song(), isPlaying: false, currentTime: 0, duration: 100)
        XCTAssertEqual(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
    }

    func testUnknownDurationIsOmitted() {
        // A live stream reports duration 0 — the key must be absent, not 0, or the OS scrubber
        // shows a bogus zero-length track.
        let info = MusicNowPlayingCenter.nowPlayingInfo(song: song(), isPlaying: true, currentTime: 5, duration: 0)
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
    }

    func testMissingArtistIsEmptyString() {
        let info = MusicNowPlayingCenter.nowPlayingInfo(song: song(artist: nil), isPlaying: true, currentTime: 0, duration: 100)
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "")
    }

    func testMissingAlbumIsOmitted() {
        let info = MusicNowPlayingCenter.nowPlayingInfo(song: song(album: nil), isPlaying: true, currentTime: 0, duration: 100)
        XCTAssertNil(info[MPMediaItemPropertyAlbumTitle])
    }

    func testNegativeElapsedIsClampedToZero() {
        let info = MusicNowPlayingCenter.nowPlayingInfo(song: song(), isPlaying: true, currentTime: -3, duration: 100)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
    }
}
