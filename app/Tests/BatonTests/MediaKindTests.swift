import XCTest
@testable import Baton

///  / STRUCT-06: the podcast-vs-library distinction is a single typed classifier
/// (`MediaKind`), so stream resolution, resume routing, and the crossfade/scrobble guards
/// all agree instead of each re-testing the id string.
final class MediaKindTests: XCTestCase {
    private func song(id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "T", artist: "A", album: nil, duration: nil, coverArtID: nil)
    }

    func testHTTPSEnclosureIDIsPodcastEpisode() {
        XCTAssertEqual(MediaKind(id: "https://feeds.example.com/ep/42.mp3"), .podcastEpisode)
        XCTAssertTrue(song(id: "https://feeds.example.com/ep/42.mp3").isPodcastEpisode)
    }

    func testHTTPEnclosureIDIsPodcastEpisode() {
        XCTAssertEqual(MediaKind(id: "http://feeds.example.com/ep/42.mp3"), .podcastEpisode)
    }

    func testOpaqueSubsonicIDIsLibraryTrack() {
        XCTAssertEqual(MediaKind(id: "ac1f2b9e-1234"), .libraryTrack)
        XCTAssertFalse(song(id: "ac1f2b9e-1234").isPodcastEpisode)
        XCTAssertEqual(song(id: "ac1f2b9e-1234").mediaKind, .libraryTrack)
    }

    /// The bundled demo library carries each track's own file URL as its id, which is
    /// what lets it resolve and play with no server configured at all.
    func testFileURLIsALocalFile() {
        XCTAssertEqual(MediaKind(id: "file:///var/containers/Bundle/Application/X/Baton.app/demo-1.m4a"),
                       .localFile)
    }

    /// A library id that merely mentions "file" is still an opaque Subsonic id — the
    /// classifier keys on the scheme prefix, not a substring.
    func testIDContainingFileIsStillALibraryTrack() {
        XCTAssertEqual(MediaKind(id: "profile-track-77"), .libraryTrack)
    }

    /// A Subsonic id that merely contains "http" but isn't a URL must not be misread as a podcast.
    func testIDContainingHTTPSubstringIsLibraryTrack() {
        XCTAssertEqual(MediaKind(id: "track-https-remix"), .libraryTrack)
    }
}
