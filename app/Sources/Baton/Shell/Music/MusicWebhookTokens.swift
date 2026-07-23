import BatonSubsonicModels
import Foundation

/// Token sets for running a **webhook action** on any library item — the counterpart to
/// `PodcastWebhookTokens` for songs, albums, artists, and playlists.
///
/// Each item type exposes the metadata that makes sense for it; a template's unknown tokens are
/// stripped, so an action written for one type run on another just fills what it can. Only songs
/// carry audio URLs, and those (`{streamUrl}` / `{downloadUrl}`) embed Subsonic credentials — they
/// are produced here but only *sent* when the action's `allowCredentialedURLs` is on, enforced in
/// `WebhookActionStore.run`.
enum MusicWebhookTokens {
    // MARK: - Reference (shown in the editor)

    struct TokenRef {
        let token: String
        let description: String
        /// True for credential-bearing tokens, so the editor can flag them and gate on the toggle.
        var credentialed: Bool = false
    }

    /// Grouped for the editor's token list. The union across item types — an action fills whatever
    /// matches the item it's run on.
    static let reference: [(kind: String, tokens: [TokenRef])] = [
        ("Song", [
            .init(token: "title", description: "Song title"),
            .init(token: "artist", description: "Artist"),
            .init(token: "album", description: "Album"),
            .init(token: "id", description: "Song id (server-scoped)"),
            .init(token: "genre", description: "Primary genre"),
            .init(token: "year", description: "Year"),
            .init(token: "trackNumber", description: "Track number"),
            .init(token: "durationSec", description: "Duration in seconds"),
            .init(token: "format", description: "File format (flac, mp3…)"),
            .init(token: "coverUrl", description: "Cover-art URL (signed)", credentialed: true),
            .init(token: "streamUrl", description: "Transcoded audio URL (carries credentials)", credentialed: true),
            .init(token: "downloadUrl", description: "Original file URL (carries credentials)", credentialed: true),
        ]),
        ("Album", [
            .init(token: "album", description: "Album name"),
            .init(token: "artist", description: "Album artist"),
            .init(token: "id", description: "Album id"),
            .init(token: "genre", description: "Genre"),
            .init(token: "year", description: "Year"),
            .init(token: "trackCount", description: "Number of tracks"),
        ]),
        ("Artist", [
            .init(token: "artist", description: "Artist name"),
            .init(token: "id", description: "Artist id"),
            .init(token: "albumCount", description: "Number of albums"),
            .init(token: "musicBrainzId", description: "MusicBrainz id, when known"),
        ]),
        ("Playlist", [
            .init(token: "playlist", description: "Playlist name"),
            .init(token: "id", description: "Playlist id"),
            .init(token: "trackCount", description: "Number of tracks"),
        ]),
    ]

    // MARK: - Token production

    /// Tokens for a library song. Always computes the credential-bearing URLs; whether they are
    /// actually sent is decided by the action's toggle, enforced in the store — this keeps the
    /// security boundary in one place rather than scattered across call sites.
    static func song(_ song: NavidromeSong) -> [String: String] {
        var out: [String: String] = [
            "title": song.title,
            "artist": song.artist ?? "",
            "album": song.album ?? "",
            "id": song.id,
            "genre": song.genre ?? "",
            "year": song.year.map(String.init) ?? "",
            "trackNumber": song.track.map(String.init) ?? "",
            "durationSec": song.duration.map(String.init) ?? "",
            "format": song.suffix ?? "",
        ]
        // Credentialed — populated here, gated at send time.
        if let stream = try? NavidromeConfig.makeClient().streamURL(songID: song.id) {
            out["streamUrl"] = stream.absoluteString
        }
        if let download = try? NavidromeConfig.makeClient().downloadURL(songID: song.id) {
            out["downloadUrl"] = download.absoluteString
        }
        if let cover = song.coverArtID,
           let client = try? NavidromeConfig.makeClient(),
           let url = client.coverArtURL(id: cover) {
            out["coverUrl"] = url.absoluteString
        }
        return out
    }

    static func album(_ album: NavidromeAlbum) -> [String: String] {
        [
            "album": album.name,
            "artist": album.artist ?? "",
            "id": album.id,
            "genre": album.genre ?? "",
            "year": album.year.map(String.init) ?? "",
            "trackCount": album.songCount.map(String.init) ?? "",
        ]
    }

    static func artist(_ artist: NavidromeArtist) -> [String: String] {
        [
            "artist": artist.name,
            "id": artist.id,
            "albumCount": artist.albumCount.map(String.init) ?? "",
            "musicBrainzId": artist.musicBrainzID ?? "",
        ]
    }

    static func playlist(_ playlist: NavidromePlaylist) -> [String: String] {
        [
            "playlist": playlist.name,
            "id": playlist.id,
            "trackCount": String(playlist.songCount),
        ]
    }
}
