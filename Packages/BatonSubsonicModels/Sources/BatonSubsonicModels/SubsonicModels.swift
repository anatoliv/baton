import Foundation

// MARK: - Subsonic / Navidrome domain types
//
// The small, Sendable value types the rest of the app (StreamingPlaybackController,
// the `music_*` MCP tools, every browse surface) works with. They deliberately expose
// only the fields we use — not the full Subsonic schema — so the wire shape (the
// `*Wire` decoders in the app's NavidromeModels.swift) can evolve without churn.
//
// This is the second leaf of the  module-boundary split (after BatonDSP): the
// foundational model layer, extracted so it has no dependency on the app. Everything
// here is `public` (call sites are unchanged — the app re-exports the module) and
// explicitly `Sendable` (a `public` type gets no implicit Sendable conformance across
// a module boundary under `SWIFT_STRICT_CONCURRENCY: complete`).

/// One playable track resolved from the Navidrome (Subsonic) library.
/// The provenance/streaming model of a playable row. Library tracks resolve through the Subsonic
/// stream/download endpoints from an opaque id; podcast episodes stream directly from the remote
/// enclosure URL that doubles as their id. Behaviour (stream URL, resume, scrobble) branches on
/// this rather than on ad-hoc id string tests.
public enum MediaKind: Hashable, Sendable {
    case libraryTrack
    case podcastEpisode

    /// Classify a raw playable id. A client-side podcast episode carries its remote enclosure URL
    /// as its id (an absolute http(s) string); anything else is an opaque Subsonic library id.
    /// Used where only the id string is in hand (e.g. stream/cover resolution).
    public init(id: String) {
        self = (id.hasPrefix("http://") || id.hasPrefix("https://")) ? .podcastEpisode : .libraryTrack
    }
}

public struct NavidromeSong: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let artist: String?
    public let album: String?
    public var albumID: String?
    /// Track length in whole seconds, when the server reports it.
    public let duration: Int?
    /// Cover-art id (feed to `coverArtURL(id:)`), when present.
    public let coverArtID: String?
    /// A *direct* artwork URL that bypasses the Subsonic cover-art path. Set for client-side
    /// podcast episodes, whose art is a plain web image (no `coverArtID`); nil for library
    /// tracks, which resolve art from `coverArtID`. When present, every now-playing surface
    /// prefers it (see `displayArtworkURL(...)`).
    public var artworkURL: URL?
    /// Whether the current user has "liked" (starred) this track. Runtime/display
    /// state refreshed from the server; deliberately NOT persisted in the queue.
    public var isLiked: Bool = false
    /// The current user's 1–5 rating (nil / 0 = unrated). Same: server-refreshed,
    /// not persisted in the queue snapshot.
    public var userRating: Int?
    /// Pre-measured loudness (ReplayGain / R128) from the server, used to even out
    /// track-to-track volume. Nil when the server/file has no gain data.
    public var replayGain: ReplayGain?
    /// 1-based track number within its album, when the server reports it (Subsonic `track`).
    public var track: Int?

    // MARK: Extended library metadata (Subsonic / OpenSubsonic `Child`)

    /// Release year of the track, when the server reports it.
    public var year: Int?
    /// 1-based disc number within a multi-disc album (OpenSubsonic `discNumber`).
    public var discNumber: Int?
    /// Primary genre name (Subsonic `genre`); `genres` carries the full OpenSubsonic list.
    public var genre: String?
    /// All genre names for the track (OpenSubsonic `genres[]`), falling back to `[genre]`.
    public var genres: [String] = []
    /// Encoded bitrate in kbps (Subsonic `bitRate`) — the lossy-quality signal for the badge.
    public var bitRate: Int?
    /// File extension / format, e.g. "flac", "mp3" (Subsonic `suffix`).
    public var suffix: String?
    /// MIME content type, e.g. "audio/flac" (Subsonic `contentType`).
    public var contentType: String?
    /// File size in bytes (Subsonic `size`).
    public var size: Int?
    /// Sample rate in Hz, e.g. 44100 / 96000 (OpenSubsonic `samplingRate`) — the hi-res signal.
    public var samplingRate: Int?
    /// Bit depth, e.g. 16 / 24 (OpenSubsonic `bitDepth`).
    public var bitDepth: Int?
    /// Channel count, e.g. 2 (OpenSubsonic `channelCount`).
    public var channelCount: Int?
    /// Server-side play count for this track (Subsonic `playCount`). Dynamic — not persisted.
    public var playCount: Int?
    /// When the track was last played (OpenSubsonic `played`). Dynamic — not persisted.
    public var played: Date?
    /// Beats per minute (OpenSubsonic `bpm`).
    public var bpm: Int?
    /// Free-text comment (OpenSubsonic `comment`).
    public var comment: String?
    /// MusicBrainz recording id (OpenSubsonic `musicBrainzId`).
    public var musicBrainzID: String?
    /// The server's formatted multi-artist string (OpenSubsonic `displayArtist`), e.g.
    /// "A feat. B". Prefer `displayArtistName` for display, which falls back to `artist`.
    public var displayArtist: String?

    public init(
        id: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        albumID: String? = nil,
        duration: Int? = nil,
        coverArtID: String? = nil,
        artworkURL: URL? = nil,
        isLiked: Bool = false,
        userRating: Int? = nil,
        replayGain: ReplayGain? = nil,
        track: Int? = nil,
        year: Int? = nil,
        discNumber: Int? = nil,
        genre: String? = nil,
        genres: [String] = [],
        bitRate: Int? = nil,
        suffix: String? = nil,
        contentType: String? = nil,
        size: Int? = nil,
        samplingRate: Int? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil,
        playCount: Int? = nil,
        played: Date? = nil,
        bpm: Int? = nil,
        comment: String? = nil,
        musicBrainzID: String? = nil,
        displayArtist: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumID = albumID
        self.duration = duration
        self.coverArtID = coverArtID
        self.artworkURL = artworkURL
        self.isLiked = isLiked
        self.userRating = userRating
        self.replayGain = replayGain
        self.track = track
        self.year = year
        self.discNumber = discNumber
        self.genre = genre
        self.genres = genres.isEmpty ? [genre].compactMap { $0 } : genres
        self.bitRate = bitRate
        self.suffix = suffix
        self.contentType = contentType
        self.size = size
        self.samplingRate = samplingRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.playCount = playCount
        self.played = played
        self.bpm = bpm
        self.comment = comment
        self.musicBrainzID = musicBrainzID
        self.displayArtist = displayArtist
    }

    /// The formatted multi-artist string when the server supplies one, else the plain `artist`.
    public var displayArtistName: String? {
        if let displayArtist, !displayArtist.isEmpty { return displayArtist }
        return artist
    }

    /// A compact quality/format badge string, e.g. "FLAC · 24/96", "FLAC", or "MP3 320".
    /// Lossless formats show bit-depth/sample-rate (kHz) when known; lossy formats show kbps.
    /// Nil when there's nothing meaningful to show.
    public var qualityLabel: String? {
        let fmt = suffix?.uppercased()
        let lossless = ["FLAC", "ALAC", "WAV", "AIFF", "APE", "WV", "DSF", "DFF"]
        if let fmt, lossless.contains(fmt) {
            if let bitDepth, let samplingRate {
                return "\(fmt) · \(bitDepth)/\(samplingRate / 1000)"
            }
            if let samplingRate { return "\(fmt) · \(samplingRate / 1000)kHz" }
            return fmt
        }
        if let fmt, let bitRate, bitRate > 0 { return "\(fmt) \(bitRate)" }
        if let bitRate, bitRate > 0 { return "\(bitRate) kbps" }
        return fmt
    }

    /// What kind of media this row represents. Derived from `id` — a client-side podcast episode
    /// carries its enclosure URL as its id (an absolute http(s) string), whereas a library track
    /// carries an opaque Subsonic id. This is the single source of truth for that distinction:
    /// stream resolution, resume/progress routing, and the now-playing scrobble guard all read it
    /// rather than re-testing the id's prefix inline.
    public var mediaKind: MediaKind { MediaKind(id: id) }

    /// True for a client-side podcast episode (its id is a remote enclosure URL streamed directly),
    /// false for a Subsonic library track.
    public var isPodcastEpisode: Bool { mediaKind == .podcastEpisode }

    /// "Artist — Title" for one-line display / agent responses.
    public var displayLine: String {
        if let artist, !artist.isEmpty { return "\(artist) — \(title)" }
        return title
    }

    /// The artwork URL a now-playing surface should show: a direct `artworkURL` (podcasts)
    /// wins; otherwise the Subsonic cover-art URL built from `coverArtID` at the requested
    /// size via `resolve`. Nil when the song has no art of either kind.
    public func displayArtworkURL(size: Int, resolve: (_ coverArtID: String, _ size: Int) -> URL?) -> URL? {
        if let artworkURL { return artworkURL }
        guard let coverArtID else { return nil }
        return resolve(coverArtID, size)
    }

    /// Persist identity/metadata + ReplayGain (static, safe to cache) — rating/like state
    /// is always re-fetched from the server, so a stale persisted queue never carries
    /// wrong like/rating values.
    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, albumID, duration, coverArtID, artworkURL, replayGain, track
        // Static metadata is safe to cache; dynamic like/rating/playCount/played are re-fetched.
        case year, discNumber, genre, genres, bitRate, suffix, contentType, size
        case samplingRate, bitDepth, channelCount, bpm, comment, musicBrainzID, displayArtist
    }
}

/// OpenSubsonic per-track loudness metadata (dB gains + linear peaks) for normalization.
public struct ReplayGain: Hashable, Codable, Sendable {
    public var trackGain: Double?
    public var albumGain: Double?
    public var trackPeak: Double?
    public var albumPeak: Double?

    public init(trackGain: Double? = nil, albumGain: Double? = nil, trackPeak: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.albumGain = albumGain
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
    }
}

/// A search / browse album hit.
public struct NavidromeAlbum: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let artist: String?
    public var artistID: String?
    public var songCount: Int?
    /// Total album length in whole seconds, when the server reports it.
    public var duration: Int?
    public var coverArtID: String?
    public var year: Int?
    public var isLiked: Bool = false
    public var userRating: Int?

    // MARK: Extended metadata (Subsonic / OpenSubsonic `AlbumID3`)

    /// Primary genre name; `genres` carries the full OpenSubsonic list.
    public var genre: String?
    public var genres: [String] = []
    /// Server-side play count for the album. Dynamic.
    public var playCount: Int?
    /// When the album was last played (OpenSubsonic `played`). Dynamic.
    public var played: Date?
    /// When the album was added to the library (Subsonic `created`) — for "recently added".
    public var created: Date?
    /// Release types, e.g. ["album"], ["ep"], ["single"] (OpenSubsonic `releaseTypes`).
    public var releaseTypes: [String] = []
    /// Whether this is a compilation / "Various Artists" album (OpenSubsonic `isCompilation`).
    public var isCompilation: Bool = false
    /// Full original release date "YYYY-MM-DD" when the server supplies it (finer than `year`).
    public var originalReleaseDate: String?
    /// MusicBrainz release-group id (OpenSubsonic `musicBrainzId`).
    public var musicBrainzID: String?
    /// Formatted multi-artist string (OpenSubsonic `displayArtist`).
    public var displayArtist: String?

    public init(
        id: String,
        name: String,
        artist: String? = nil,
        artistID: String? = nil,
        songCount: Int? = nil,
        duration: Int? = nil,
        coverArtID: String? = nil,
        year: Int? = nil,
        isLiked: Bool = false,
        userRating: Int? = nil,
        genre: String? = nil,
        genres: [String] = [],
        playCount: Int? = nil,
        played: Date? = nil,
        created: Date? = nil,
        releaseTypes: [String] = [],
        isCompilation: Bool = false,
        originalReleaseDate: String? = nil,
        musicBrainzID: String? = nil,
        displayArtist: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistID = artistID
        self.songCount = songCount
        self.duration = duration
        self.coverArtID = coverArtID
        self.year = year
        self.isLiked = isLiked
        self.userRating = userRating
        self.genre = genre
        self.genres = genres.isEmpty ? [genre].compactMap { $0 } : genres
        self.playCount = playCount
        self.played = played
        self.created = created
        self.releaseTypes = releaseTypes
        self.isCompilation = isCompilation
        self.originalReleaseDate = originalReleaseDate
        self.musicBrainzID = musicBrainzID
        self.displayArtist = displayArtist
    }

    /// The formatted multi-artist string when present, else the plain `artist`.
    public var displayArtistName: String? {
        if let displayArtist, !displayArtist.isEmpty { return displayArtist }
        return artist
    }

    /// A short release-type badge ("EP", "Single", "Compilation"), or nil for a plain album.
    public var releaseTypeLabel: String? {
        if isCompilation { return "Compilation" }
        guard let raw = releaseTypes.first?.lowercased() else { return nil }
        switch raw {
        case "album": return nil
        case "ep": return "EP"
        case "single": return "Single"
        default: return raw.capitalized
        }
    }
}

/// A genre with its item counts (for browse).
public struct NavidromeGenre: Identifiable, Hashable, Sendable {
    public var id: String {
        name
    }

    public let name: String
    public let songCount: Int?
    public let albumCount: Int?

    public init(name: String, songCount: Int? = nil, albumCount: Int? = nil) {
        self.name = name
        self.songCount = songCount
        self.albumCount = albumCount
    }
}

/// Lyrics for a track — `synced` when each line carries a start time (karaoke).
public struct NavidromeLyrics: Equatable, Sendable {
    public var synced: Bool
    public var lines: [Line]

    public struct Line: Equatable, Sendable {
        /// Start time in seconds, when synced.
        public var start: Double?
        public var text: String

        public init(start: Double? = nil, text: String) {
            self.start = start
            self.text = text
        }
    }

    public var isEmpty: Bool {
        lines.isEmpty
    }

    public init(synced: Bool, lines: [Line]) {
        self.synced = synced
        self.lines = lines
    }
}

/// A search artist hit.
public struct NavidromeArtist: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public var albumCount: Int?
    /// Server cover-art id for the artist portrait (feed to `coverArtURL(id:)`), when
    /// the server provides one. Falls back to a monogram avatar in the UI.
    public var coverArtID: String?
    /// A direct portrait URL (`artistImageUrl`), often external/last.fm — used only if
    /// `coverArtID` is absent.
    public var imageURLString: String?
    /// Whether the current user follows/starred this artist (Subsonic `starred`). Dynamic.
    public var isLiked: Bool = false
    /// MusicBrainz artist id (OpenSubsonic `musicBrainzId`).
    public var musicBrainzID: String?
    /// The artist's roles in the library, e.g. ["artist", "albumartist", "composer"]
    /// (OpenSubsonic `roles`).
    public var roles: [String] = []

    public init(
        id: String,
        name: String,
        albumCount: Int? = nil,
        coverArtID: String? = nil,
        imageURLString: String? = nil,
        isLiked: Bool = false,
        musicBrainzID: String? = nil,
        roles: [String] = []
    ) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.coverArtID = coverArtID
        self.imageURLString = imageURLString
        self.isLiked = isLiked
        self.musicBrainzID = musicBrainzID
        self.roles = roles
    }
}

/// Extra artist detail from `getArtistInfo2` — biography + a portrait image.
public struct NavidromeArtistInfo: Hashable, Sendable {
    public let biography: String?
    public let imageURL: URL?

    public init(biography: String? = nil, imageURL: URL? = nil) {
        self.biography = biography
        self.imageURL = imageURL
    }
}

/// `search3` result set, split by kind.
public struct NavidromeSearchResults: Sendable {
    public var songs: [NavidromeSong]
    public var albums: [NavidromeAlbum]
    public var artists: [NavidromeArtist]

    public static let empty = NavidromeSearchResults(songs: [], albums: [], artists: [])

    public init(songs: [NavidromeSong], albums: [NavidromeAlbum], artists: [NavidromeArtist]) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
    }
}

/// A playlist. `songs` is empty in the list view (`getPlaylists`) and populated
/// by `getPlaylist(id:)`.
public struct NavidromePlaylist: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let songCount: Int
    /// Total play time in seconds, when the server provides it.
    public var duration: Int?
    public var isPublic: Bool = false
    /// Server-generated cover art id (a mosaic of member tracks), when the server
    /// provides one. Feed to `coverArtURL(id:)`.
    public var coverArtID: String?
    public var songs: [NavidromeSong] = []
    /// The playlist's owner username (Subsonic `owner`).
    public var owner: String?
    /// The playlist description / comment (Subsonic `comment`).
    public var comment: String?
    /// When the playlist was created (Subsonic `created`).
    public var created: Date?
    /// When the playlist was last modified (Subsonic `changed`).
    public var changed: Date?

    public init(
        id: String,
        name: String,
        songCount: Int,
        duration: Int? = nil,
        isPublic: Bool = false,
        coverArtID: String? = nil,
        songs: [NavidromeSong] = [],
        owner: String? = nil,
        comment: String? = nil,
        created: Date? = nil,
        changed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.duration = duration
        self.isPublic = isPublic
        self.coverArtID = coverArtID
        self.songs = songs
        self.owner = owner
        self.comment = comment
        self.created = created
        self.changed = changed
    }
}

// MARK: - Errors

/// A Navidrome/Subsonic client failure. Mirrors `JiraClientError`: transport vs.
/// HTTP vs. protocol-level (Subsonic `status: failed`) faults are distinct so the
/// UI and the `music_*` tools can give the user an actionable message.
public enum NavidromeError: Error, LocalizedError, Equatable, Sendable {
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

    public var errorDescription: String? {
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
