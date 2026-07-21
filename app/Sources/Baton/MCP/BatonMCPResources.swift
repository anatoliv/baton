import Foundation

/// MCP resources for live playback state plus read-only library/history snapshots:
/// `baton://now-playing`, `baton://queue`, `baton://library/playlists`,
/// `baton://library/liked`, and `baton://history/recent`.
/// A client reads these once and then relies on `notifications/resources/updated` to
/// know when to re-read (see `BatonMCPServer`).
@MainActor
enum BatonMCPResources {
    /// Read-only library/history resource URIs. (The live playback URIs live on
    /// `BatonMCPConstants`.)
    static let libraryPlaylistsURI = "baton://library/playlists"
    static let libraryLikedURI = "baton://library/liked"
    static let historyRecentURI = "baton://history/recent"

    /// Cap each list in the library/history snapshots so a large library/history
    /// doesn't blow up a single resource read.
    private static let listLimit = 50

    /// The `resources/list` payload.
    static func list() -> [[String: Any]] {
        [
            [
                "uri": BatonMCPConstants.nowPlayingURI,
                "name": "Now Playing",
                "description": "The current track, playback state, and queue position (live).",
                "mimeType": "application/json",
            ],
            [
                "uri": BatonMCPConstants.queueURI,
                "name": "Queue",
                "description": "The ordered play queue with the current index and its source.",
                "mimeType": "application/json",
            ],
            [
                "uri": libraryPlaylistsURI,
                "name": "Playlists",
                "description": "The user's playlists (id, name, and song count).",
                "mimeType": "application/json",
            ],
            [
                "uri": libraryLikedURI,
                "name": "Liked",
                "description": "The user's starred songs, albums, and artists.",
                "mimeType": "application/json",
            ],
            [
                "uri": historyRecentURI,
                "name": "Recently Played",
                "description": "Recently played tracks plus top tracks and top artists.",
                "mimeType": "application/json",
            ],
        ]
    }

    /// Resolve a `resources/read` for one of the music URIs. Returns nil for an
    /// unknown URI so the caller can emit a proper JSON-RPC error.
    static func read(uri: String, music: MusicModel) -> [String: Any]? {
        let json: String
        switch uri {
        case BatonMCPConstants.nowPlayingURI:
            json = nowPlayingJSON(music)
        case BatonMCPConstants.queueURI:
            json = queueJSON(music)
        case libraryPlaylistsURI:
            json = playlistsJSON(music)
        case libraryLikedURI:
            json = likedJSON(music)
        case historyRecentURI:
            json = recentJSON(music)
        default:
            return nil
        }
        return [
            "contents": [[
                "uri": uri,
                "mimeType": "application/json",
                "text": json,
            ]],
        ]
    }

    /// The `baton://now-playing` body — the `music_now_playing` payload plus playhead.
    static func nowPlayingJSON(_ music: MusicModel) -> String {
        let player = music.music
        var out: [String: Any] = [
            "state": BatonMCPToolCatalog.musicStateLabel(player.state),
            "summary": player.nowPlayingSummary,
            "queue_length": player.queue.count,
            "queue_index": player.currentIndex,
            "position_seconds": Int(player.currentTime.rounded()),
            "duration_seconds": Int(player.duration.rounded()),
            "volume_percent": player.volumePercent,
        ]
        if let song = player.nowPlaying { out["now_playing"] = BatonMCPToolCatalog.songJSON(song) }
        return BatonMCPToolCatalog.jsonText(out)
    }

    /// The `baton://queue` body — the full ordered queue with the current index.
    static func queueJSON(_ music: MusicModel) -> String {
        let player = music.music
        var out: [String: Any] = [
            "current_index": player.currentIndex,
            "queue": player.queue.map(BatonMCPToolCatalog.songJSON),
        ]
        if let source = player.queueSource {
            out["queue_source"] = ["label": source.label, "kind": source.kind.rawValue, "id": source.id ?? ""]
        }
        return BatonMCPToolCatalog.jsonText(out)
    }

    /// The `baton://library/playlists` body — the user's playlists (id/name/song_count).
    /// Empty when the library hasn't been loaded yet (no network).
    static func playlistsJSON(_ music: MusicModel) -> String {
        let playlists = music.musicLibrary.playlists.prefix(listLimit).map { playlist -> [String: Any] in
            ["id": playlist.id, "name": playlist.name, "song_count": playlist.songCount]
        }
        return BatonMCPToolCatalog.jsonText(["playlists": Array(playlists)])
    }

    /// The `baton://library/liked` body — the user's starred songs/albums/artists.
    /// Empty arrays when the starred set hasn't been loaded yet (no network).
    static func likedJSON(_ music: MusicModel) -> String {
        let starred = music.musicLibrary.starred
        let out: [String: Any] = [
            "songs": starred.songs.prefix(listLimit).map(BatonMCPToolCatalog.songJSON),
            "albums": starred.albums.prefix(listLimit).map(albumJSON),
            "artists": starred.artists.prefix(listLimit).map(artistJSON),
        ]
        return BatonMCPToolCatalog.jsonText(out)
    }

    /// The `baton://history/recent` body — recently played tracks plus top tracks
    /// and top artists (all-time). Local history; empty when nothing has played yet.
    static func recentJSON(_ music: MusicModel) -> String {
        let history = music.musicHistory
        let recent = history.recentlyPlayed.prefix(listLimit).map(BatonMCPToolCatalog.songJSON)
        let topTracks = history.topTracks(since: .distantPast, limit: listLimit).map { entry -> [String: Any] in
            var song = BatonMCPToolCatalog.songJSON(entry.song)
            song["play_count"] = entry.count
            return song
        }
        let topArtists = history.topArtists(since: .distantPast, limit: listLimit).map { entry -> [String: Any] in
            ["artist": entry.artist, "play_count": entry.count]
        }
        let out: [String: Any] = [
            "recent": Array(recent),
            "top_tracks": topTracks,
            "top_artists": topArtists,
        ]
        return BatonMCPToolCatalog.jsonText(out)
    }

    // MARK: - Album / artist JSON (song JSON is shared via BatonMCPToolCatalog)

    /// A starred album as JSON (mirrors `BatonMCPToolCatalog.songJSON`'s shape).
    private static func albumJSON(_ album: NavidromeAlbum) -> [String: Any] {
        var out: [String: Any] = ["id": album.id, "name": album.name]
        if let artist = album.artist { out["artist"] = artist }
        if let display = album.displayArtist, display != album.artist { out["display_artist"] = display }
        if let songCount = album.songCount { out["song_count"] = songCount }
        if let duration = album.duration { out["duration_seconds"] = duration }
        if let year = album.year { out["year"] = year }
        let genres = album.genres.isEmpty ? [album.genre].compactMap { $0 } : album.genres
        if !genres.isEmpty { out["genres"] = genres }
        if let type = album.releaseTypeLabel { out["release_type"] = type }
        if let plays = album.playCount { out["play_count"] = plays }
        if let rating = album.userRating, rating > 0 { out["rating"] = rating }
        out["liked"] = album.isLiked
        if let date = album.originalReleaseDate { out["original_release_date"] = date }
        if let played = album.played { out["last_played"] = ISO8601DateFormatter().string(from: played) }
        if let created = album.created { out["added"] = ISO8601DateFormatter().string(from: created) }
        if let mbid = album.musicBrainzID { out["musicbrainz_id"] = mbid }
        return out
    }

    /// A starred artist as JSON.
    private static func artistJSON(_ artist: NavidromeArtist) -> [String: Any] {
        var out: [String: Any] = ["id": artist.id, "name": artist.name]
        if let albumCount = artist.albumCount { out["album_count"] = albumCount }
        out["liked"] = artist.isLiked
        if !artist.roles.isEmpty { out["roles"] = artist.roles }
        if let mbid = artist.musicBrainzID { out["musicbrainz_id"] = mbid }
        return out
    }
}
