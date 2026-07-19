import Foundation

// MARK: - Domain types

//
// The small, Sendable value types the rest of the app (StreamingPlaybackController,
// the `music_*` MCP tools) works with. They deliberately expose only the fields we
// use — not the full Subsonic schema — so the wire shape can evolve without churn.

/// One playable track resolved from the Navidrome (Subsonic) library.
struct NavidromeSong: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    var albumID: String?
    /// Track length in whole seconds, when the server reports it.
    let duration: Int?
    /// Cover-art id (feed to `coverArtURL(id:)`), when present.
    let coverArtID: String?
    /// A *direct* artwork URL that bypasses the Subsonic cover-art path. Set for client-side
    /// podcast episodes, whose art is a plain web image (no `coverArtID`); nil for library
    /// tracks, which resolve art from `coverArtID`. When present, every now-playing surface
    /// prefers it (see `displayArtworkURL(...)`).
    var artworkURL: URL?
    /// Whether the current user has "liked" (starred) this track. Runtime/display
    /// state refreshed from the server; deliberately NOT persisted in the queue.
    var isLiked: Bool = false
    /// The current user's 1–5 rating (nil / 0 = unrated). Same: server-refreshed,
    /// not persisted in the queue snapshot.
    var userRating: Int?
    /// Pre-measured loudness (ReplayGain / R128) from the server, used to even out
    /// track-to-track volume. Nil when the server/file has no gain data.
    var replayGain: ReplayGain?
    /// 1-based track number within its album, when the server reports it (Subsonic `track`).
    var track: Int?

    /// "Artist — Title" for one-line display / agent responses.
    var displayLine: String {
        if let artist, !artist.isEmpty { return "\(artist) — \(title)" }
        return title
    }

    /// The artwork URL a now-playing surface should show: a direct `artworkURL` (podcasts)
    /// wins; otherwise the Subsonic cover-art URL built from `coverArtID` at the requested
    /// size via `resolve`. Nil when the song has no art of either kind.
    func displayArtworkURL(size: Int, resolve: (_ coverArtID: String, _ size: Int) -> URL?) -> URL? {
        if let artworkURL { return artworkURL }
        guard let coverArtID else { return nil }
        return resolve(coverArtID, size)
    }

    /// Persist identity/metadata + ReplayGain (static, safe to cache) — rating/like state
    /// is always re-fetched from the server, so a stale persisted queue never carries
    /// wrong like/rating values.
    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, albumID, duration, coverArtID, artworkURL, replayGain, track
    }
}

/// OpenSubsonic per-track loudness metadata (dB gains + linear peaks) for normalization.
struct ReplayGain: Hashable, Codable {
    var trackGain: Double?
    var albumGain: Double?
    var trackPeak: Double?
    var albumPeak: Double?
}

/// A search / browse album hit.
struct NavidromeAlbum: Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String?
    var artistID: String?
    var songCount: Int?
    /// Total album length in whole seconds, when the server reports it.
    var duration: Int?
    var coverArtID: String?
    var year: Int?
    var isLiked: Bool = false
    var userRating: Int?
}

/// A genre with its item counts (for browse).
struct NavidromeGenre: Identifiable, Hashable {
    var id: String {
        name
    }

    let name: String
    let songCount: Int?
    let albumCount: Int?
}

/// Lyrics for a track — `synced` when each line carries a start time (karaoke).
struct NavidromeLyrics: Equatable {
    var synced: Bool
    var lines: [Line]

    struct Line: Equatable {
        /// Start time in seconds, when synced.
        var start: Double?
        var text: String
    }

    var isEmpty: Bool {
        lines.isEmpty
    }
}

/// A search artist hit.
struct NavidromeArtist: Identifiable, Hashable {
    let id: String
    let name: String
    var albumCount: Int?
    /// Server cover-art id for the artist portrait (feed to `coverArtURL(id:)`), when
    /// the server provides one. Falls back to a monogram avatar in the UI.
    var coverArtID: String?
    /// A direct portrait URL (`artistImageUrl`), often external/last.fm — used only if
    /// `coverArtID` is absent.
    var imageURLString: String?
}

/// Extra artist detail from `getArtistInfo2` — biography + a portrait image.
struct NavidromeArtistInfo: Hashable {
    let biography: String?
    let imageURL: URL?
}

/// `search3` result set, split by kind.
struct NavidromeSearchResults {
    var songs: [NavidromeSong]
    var albums: [NavidromeAlbum]
    var artists: [NavidromeArtist]

    static let empty = NavidromeSearchResults(songs: [], albums: [], artists: [])
}

/// A playlist. `songs` is empty in the list view (`getPlaylists`) and populated
/// by `getPlaylist(id:)`.
struct NavidromePlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let songCount: Int
    /// Total play time in seconds, when the server provides it.
    var duration: Int?
    var isPublic: Bool = false
    /// Server-generated cover art id (a mosaic of member tracks), when the server
    /// provides one. Feed to `coverArtURL(id:)`.
    var coverArtID: String?
    var songs: [NavidromeSong] = []
}

// MARK: - Errors

/// A Navidrome/Subsonic client failure. Mirrors `JiraClientError`: transport vs.
/// HTTP vs. protocol-level (Subsonic `status: failed`) faults are distinct so the
/// UI and the `music_*` tools can give the user an actionable message.
enum NavidromeError: Error, LocalizedError, Equatable {
    /// No server URL / credentials configured yet.
    case notConfigured
    /// The configured base URL could not form a valid request URL.
    case invalidURL
    /// Networking failed before an HTTP response (offline, TLS, timeout).
    case transport(String)
    /// A non-2xx HTTP status.
    case http(status: Int)
    /// Wrong username/password or an invalid/revoked API key
    /// (Subsonic error 40 / 41 / 44).
    case unauthorized
    /// Any other Subsonic protocol error (`status: failed`).
    case subsonic(code: Int, message: String)
    /// The response body didn't decode as a Subsonic JSON envelope.
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No music server is configured. Add one in Settings → Music."
        case .invalidURL:
            "The music server URL is invalid."
        case let .transport(detail):
            "Couldn't reach the music server: \(detail)"
        case let .http(status):
            "The music server returned HTTP \(status)."
        case .unauthorized:
            "The music server rejected your credentials. Use your Navidrome username (this is often NOT your email address) and password — check them in the Navidrome web UI."
        case let .subsonic(code, message):
            "Music server error \(code): \(message)"
        case let .decoding(detail):
            "Couldn't read the music server's response: \(detail)"
        }
    }
}

// MARK: - Wire types (Subsonic JSON envelope)

//
// Subsonic wraps every response in `{ "subsonic-response": { ... } }`. We decode a
// single broad struct with optional bodies rather than one type per endpoint — the
// handful of endpoints we call keeps it small, and it mirrors how the API actually
// overloads one envelope.

struct SubsonicEnvelope: Decodable {
    let response: SubsonicResponse
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SubsonicResponse: Decodable {
    let status: String
    let version: String?
    let error: SubsonicWireError?
    let searchResult3: SearchResult3Wire?
    let starred2: SearchResult3Wire?
    let song: SongWire?
    let artistInfo2: ArtistInfo2Wire?
    let albumList2: AlbumListWire?
    let artists: ArtistsWire?
    let artist: ArtistDetailWire?
    let genres: GenresWire?
    let playlists: PlaylistsWire?
    let playlist: PlaylistWire?
    let album: AlbumDetailWire?
    let similarSongs2: SongsWire?
    let songsByGenre: SongsWire?
    let lyricsList: LyricsListWire?
    let openSubsonicExtensions: [OpenSubsonicExtensionWire]?

    var isOK: Bool {
        status == "ok"
    }
}

struct SubsonicWireError: Decodable {
    let code: Int
    let message: String?
}

struct OpenSubsonicExtensionWire: Decodable {
    let name: String
    let versions: [Int]?
}

struct ArtistInfo2Wire: Decodable {
    let biography: String?
    let largeImageUrl: String?
    func toDomain() -> NavidromeArtistInfo {
        let bio = biography?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NavidromeArtistInfo(
            biography: (bio?.isEmpty ?? true) ? nil : bio,
            imageURL: Self.cleanImageURL(largeImageUrl)
        )
    }

    /// last.fm hands Navidrome a blank "star" placeholder image for artists it can't
    /// match (its hash is well-known). It's a valid URL that loads a grey nothing, so
    /// treat it as absent — callers fall back to real cover art instead.
    static func cleanImageURL(_ raw: String?) -> URL? {
        guard let raw, !raw.contains("2a96cbd8b46e442fc41c2b86b821562f") else { return nil }
        return URL(string: raw)
    }
}

struct SearchResult3Wire: Decodable {
    let artist: [ArtistWire]?
    let album: [AlbumWire]?
    let song: [SongWire]?
}

struct PlaylistsWire: Decodable {
    let playlist: [PlaylistWire]?
}

struct PlaylistWire: Decodable {
    let id: String
    let name: String?
    let songCount: Int?
    let duration: Int?
    let isPublic: Bool?
    let coverArt: String?
    let entry: [SongWire]?

    enum CodingKeys: String, CodingKey {
        case id, name, songCount, duration, coverArt, entry
        case isPublic = "public"
    }

    func toDomain() -> NavidromePlaylist {
        NavidromePlaylist(
            id: id,
            name: name ?? "(untitled)",
            songCount: songCount ?? (entry?.count ?? 0),
            duration: duration,
            isPublic: isPublic ?? false,
            coverArtID: coverArt,
            songs: (entry ?? []).map { $0.toDomain() }
        )
    }
}

/// `getAlbum` detail — an album with its ordered song list.
struct AlbumDetailWire: Decodable {
    let id: String
    let name: String?
    let song: [SongWire]?
}

struct ArtistWire: Decodable {
    let id: String
    let name: String?
    let albumCount: Int?
    let coverArt: String?
    let artistImageUrl: String?
    func toDomain() -> NavidromeArtist {
        NavidromeArtist(
            id: id,
            name: name ?? "(unknown)",
            albumCount: albumCount,
            coverArtID: coverArt,
            imageURLString: artistImageUrl
        )
    }
}

struct AlbumWire: Decodable {
    let id: String
    let name: String?
    let title: String?
    let artist: String?
    let artistId: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    let year: Int?
    let starred: String?
    let userRating: Int?
    func toDomain() -> NavidromeAlbum {
        NavidromeAlbum(
            id: id,
            name: name ?? title ?? "(untitled)",
            artist: artist,
            artistID: artistId,
            songCount: songCount,
            duration: duration,
            coverArtID: coverArt,
            year: year,
            isLiked: starred != nil,
            userRating: userRating
        )
    }
}

struct SongWire: Decodable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let albumId: String?
    let duration: Int?
    let coverArt: String?
    let starred: String?
    let userRating: Int?
    let track: Int?
    let replayGain: ReplayGainWire?

    struct ReplayGainWire: Decodable {
        let trackGain: Double?
        let albumGain: Double?
        let trackPeak: Double?
        let albumPeak: Double?
    }

    func toDomain() -> NavidromeSong {
        NavidromeSong(
            id: id,
            title: title ?? "(untitled)",
            artist: artist,
            album: album,
            albumID: albumId,
            duration: duration,
            coverArtID: coverArt,
            isLiked: starred != nil,
            userRating: userRating,
            replayGain: replayGain.map {
                ReplayGain(trackGain: $0.trackGain, albumGain: $0.albumGain,
                           trackPeak: $0.trackPeak, albumPeak: $0.albumPeak)
            },
            track: track
        )
    }
}

/// `getAlbumList2` → `albumList2.album[]`.
struct AlbumListWire: Decodable {
    let album: [AlbumWire]?
}

/// Generic `{ song: [...] }` body (used by `getSimilarSongs2`).
struct SongsWire: Decodable {
    let song: [SongWire]?
}

/// `getLyricsBySongId` → `lyricsList.structuredLyrics[]`.
struct LyricsListWire: Decodable {
    let structuredLyrics: [StructuredLyricsWire]?

    struct StructuredLyricsWire: Decodable {
        let synced: Bool?
        let line: [LineWire]?
        struct LineWire: Decodable {
            let start: Int? // milliseconds
            let value: String?
        }
    }

    /// The first (typically only) lyric set → domain, or nil if none.
    func toDomain() -> NavidromeLyrics? {
        guard let first = structuredLyrics?.first, let lines = first.line, !lines.isEmpty else { return nil }
        return NavidromeLyrics(
            synced: first.synced ?? false,
            lines: lines.map { NavidromeLyrics.Line(start: $0.start.map { Double($0) / 1000 }, text: $0.value ?? "") }
        )
    }
}

/// `getArtists` → `artists.index[].artist[]` (alphabetical index buckets).
struct ArtistsWire: Decodable {
    let index: [IndexWire]?
    struct IndexWire: Decodable {
        let artist: [ArtistWire]?
    }

    func flatArtists() -> [NavidromeArtist] {
        (index ?? []).flatMap { ($0.artist ?? []).map { $0.toDomain() } }
    }
}

/// `getArtist` → `artist.album[]` (an artist's albums).
struct ArtistDetailWire: Decodable {
    let id: String
    let name: String?
    let album: [AlbumWire]?
}

/// `getGenres` → `genres.genre[]`.
struct GenresWire: Decodable {
    let genre: [GenreWire]?
    struct GenreWire: Decodable {
        let value: String
        let songCount: Int?
        let albumCount: Int?
        func toDomain() -> NavidromeGenre {
            NavidromeGenre(name: value, songCount: songCount, albumCount: albumCount)
        }
    }
}
