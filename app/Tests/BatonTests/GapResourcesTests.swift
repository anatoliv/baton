import Foundation
import Testing
@testable import Baton

/// Covers the three read-only library/history MCP resources added alongside the
/// live `now-playing` / `queue` resources: `baton://library/playlists`,
/// `baton://library/liked`, and `baton://history/recent`.
@MainActor
@Suite("Gap MCP resources")
struct GapResourcesTests {
    private func song(_ id: String, artist: String? = nil) -> NavidromeSong {
        NavidromeSong(id: id, title: "T\(id)", artist: artist, album: nil, albumID: nil, duration: nil, coverArtID: nil)
    }

    /// Decode the `text` of the single content block of a `resources/read` result.
    private func readJSON(_ result: [String: Any]?) throws -> [String: Any] {
        let result = try #require(result)
        let contents = try #require(result["contents"] as? [[String: Any]])
        let text = try #require(contents.first?["text"] as? String)
        let data = try #require(text.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("list() exposes all five resource URIs")
    func listCoversAll() {
        let uris = BatonMCPResources.list().compactMap { $0["uri"] as? String }
        #expect(uris.count == 5)
        #expect(Set(uris) == Set([
            BatonMCPConstants.nowPlayingURI,
            BatonMCPConstants.queueURI,
            BatonMCPResources.libraryPlaylistsURI,
            BatonMCPResources.libraryLikedURI,
            BatonMCPResources.historyRecentURI,
        ]))
        // Every entry carries a human title + the JSON mime type.
        for entry in BatonMCPResources.list() {
            #expect((entry["name"] as? String)?.isEmpty == false)
            #expect(entry["mimeType"] as? String == "application/json")
        }
    }

    @Test("An unknown URI returns nil")
    func unknownURIReturnsNil() {
        let music = MusicModel()
        #expect(BatonMCPResources.read(uri: "baton://nope", music: music) == nil)
    }

    @Test("library/playlists returns well-formed JSON (empty-state)")
    func playlistsEmptyState() throws {
        let music = MusicModel()
        let json = try readJSON(BatonMCPResources.read(uri: BatonMCPResources.libraryPlaylistsURI, music: music))
        let playlists = try #require(json["playlists"] as? [Any])
        #expect(playlists.isEmpty)
    }

    @Test("library/liked returns well-formed JSON with the three top-level keys (empty-state)")
    func likedEmptyState() throws {
        let music = MusicModel()
        let json = try readJSON(BatonMCPResources.read(uri: BatonMCPResources.libraryLikedURI, music: music))
        #expect(json["songs"] as? [Any] != nil)
        #expect(json["albums"] as? [Any] != nil)
        #expect(json["artists"] as? [Any] != nil)
        #expect((json["songs"] as? [Any])?.isEmpty == true)
    }

    @Test("history/recent returns well-formed JSON reflecting seeded plays")
    func recentReflectsHistory() throws {
        let music = MusicModel()
        music.musicHistory.clear() // start from a known-empty local history
        // Seed the (real) local history the way MusicPlayHistoryTests does.
        music.musicHistory.record(song("a", artist: "X"))
        music.musicHistory.record(song("b", artist: "X"))
        music.musicHistory.record(song("c", artist: "Y"))

        let json = try readJSON(BatonMCPResources.read(uri: BatonMCPResources.historyRecentURI, music: music))
        let recent = try #require(json["recent"] as? [[String: Any]])
        let topTracks = try #require(json["top_tracks"] as? [[String: Any]])
        let topArtists = try #require(json["top_artists"] as? [[String: Any]])

        #expect(recent.count == 3)
        // Most-recent first — matches recentlyPlayed ordering.
        #expect(recent.first?["id"] as? String == "c")
        #expect(!topTracks.isEmpty)
        #expect(topTracks.first?["play_count"] != nil)
        // X has two plays (a + b), so it ranks first among artists.
        #expect(topArtists.first?["artist"] as? String == "X")
        #expect(topArtists.first?["play_count"] as? Int == 2)

        music.musicHistory.clear()
    }

    @Test("history/recent is well-formed with no plays (empty-state)")
    func recentEmptyState() throws {
        let music = MusicModel()
        music.musicHistory.clear()
        let json = try readJSON(BatonMCPResources.read(uri: BatonMCPResources.historyRecentURI, music: music))
        #expect((json["recent"] as? [Any])?.isEmpty == true)
        #expect(json["top_tracks"] as? [Any] != nil)
        #expect(json["top_artists"] as? [Any] != nil)
    }
}
