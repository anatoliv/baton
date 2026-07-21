import XCTest
@testable import Baton

/// Pins the ListenBrainz `listen` wire shape built by `MusicScrobbler.payload` — the JSON
/// object submitted to `submit-listens`. A wrong key or a `listened_at` on a "now playing"
/// ping is silently rejected by the server, so the shape is worth locking.
final class ListenBrainzPayloadTests: XCTestCase {
    private func scrobble(
        artist: String = "Miles Davis",
        title: String = "So What",
        album: String? = "Kind of Blue",
        duration: Int? = 544,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Scrobble {
        let song = NavidromeSong(id: "s1", title: title, artist: artist, album: album, duration: duration)
        return Scrobble(song: song, startedAt: startedAt)
    }

    func testCompletedListenShape() throws {
        let p = MusicScrobbler.payload(for: scrobble(), includeTimestamp: true)
        XCTAssertEqual(p["listened_at"] as? Int, 1_700_000_000)
        let meta = try XCTUnwrap(p["track_metadata"] as? [String: Any])
        XCTAssertEqual(meta["artist_name"] as? String, "Miles Davis")
        XCTAssertEqual(meta["track_name"] as? String, "So What")
        XCTAssertEqual(meta["release_name"] as? String, "Kind of Blue")
        let info = try XCTUnwrap(meta["additional_info"] as? [String: Any])
        XCTAssertEqual(info["submission_client"] as? String, "Baton")
        // duration is reported to ListenBrainz in milliseconds.
        XCTAssertEqual(info["duration_ms"] as? Int, 544_000)
    }

    func testNowPlayingHasNoTimestamp() {
        // A "playing_now" ping must NOT carry listened_at or the server rejects it.
        let p = MusicScrobbler.payload(for: scrobble(), includeTimestamp: false)
        XCTAssertNil(p["listened_at"])
        XCTAssertNotNil(p["track_metadata"])
    }

    func testMissingAlbumOmitsReleaseName() throws {
        let p = MusicScrobbler.payload(for: scrobble(album: nil), includeTimestamp: true)
        let meta = try XCTUnwrap(p["track_metadata"] as? [String: Any])
        XCTAssertNil(meta["release_name"])
    }

    func testMissingDurationOmitsDurationMs() throws {
        let p = MusicScrobbler.payload(for: scrobble(duration: nil), includeTimestamp: true)
        let meta = try XCTUnwrap(p["track_metadata"] as? [String: Any])
        let info = try XCTUnwrap(meta["additional_info"] as? [String: Any])
        XCTAssertNil(info["duration_ms"])
        // submission_client is always present even when duration is absent.
        XCTAssertEqual(info["submission_client"] as? String, "Baton")
    }

    func testBlankArtistFallsBackToUnknown() throws {
        // Scrobble's own init substitutes "Unknown Artist" for a blank artist; the payload carries it.
        let p = MusicScrobbler.payload(for: scrobble(artist: "   "), includeTimestamp: true)
        let meta = try XCTUnwrap(p["track_metadata"] as? [String: Any])
        XCTAssertEqual(meta["artist_name"] as? String, "Unknown Artist")
    }
}
