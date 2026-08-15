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
    /// Content that is already a file on this device — currently the bundled demo
    /// library. Its id is a `file://` URL, so it needs no server to resolve.
    case localFile

    /// Classify a raw playable id. A client-side podcast episode carries its remote enclosure URL
    /// as its id (an absolute http(s) string); a local file carries its own file URL; anything
    /// else is an opaque Subsonic library id. Used where only the id string is in hand (e.g.
    /// stream/cover resolution).
    public init(id: String) {
        if id.hasPrefix("http://") || id.hasPrefix("https://") {
            self = .podcastEpisode
        } else if id.hasPrefix("file://") {
            self = .localFile
        } else {
            self = .libraryTrack
        }
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
    ///
    /// Goes through `DisplayName` rather than testing `isEmpty` itself. An importer's
    /// placeholder is not empty — it is the literal string "[unknown]" — so the emptiness
    /// check passed it straight through, and the MCP `music_now_playing` payload was still
    /// answering "Paused: [unknown] — Clair de Lune" in 0.16.15, after the views had
    /// stopped. This property is the single place the four agent-facing strings that use it
    /// share, so the rule belongs here and not at each call site.
    public var displayLine: String {
        let title = DisplayName.title(title)
        if let artist = DisplayName.artist(artist) { return "\(artist) — \(title)" }
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

    // MARK: - LRC metadata

    /// The tags an LRC file carries about itself rather than about the song.
    ///
    /// `[ar:]` artist, `[ti:]` title, `[al:]` album, `[au:]` author, `[by:]` transcriber,
    /// `[re:]`/`[ve:]`/`[tool:]` the editor that wrote it, `[length:]` the running time, and
    /// `[offset:]` a global timing shift in **milliseconds**.
    private static let metadataKeys: Set<String> = [
        "ar", "ti", "al", "au", "by", "re", "ve", "tool", "length", "offset", "id", "#",
    ]

    /// Splits `[key:value]` into its parts, or nil when the line is ordinary lyric text.
    ///
    /// Only a whole line counts. A lyric that happens to contain a bracket mid-sentence is
    /// not metadata, and neither is `[Chorus]`, which has no colon and is a real thing people
    /// write in lyric sheets.
    public static func metadataTag(in text: String) -> (key: String, value: String)? {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 else { return nil }
        let inner = line.dropFirst().dropLast()
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        let key = inner[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard metadataKeys.contains(key) else { return nil }
        return (key, inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// Drops the LRC header tags and applies `[offset:]` to any timings.
    ///
    /// Servers hand back whatever is embedded in the file. Navidrome's `getLyricsBySongId`
    /// splits an LRC blob into lines and reports the header as lines like any other, so
    /// "Riders on the Storm" opened with `[offset:-47682]` sitting above the first verse —
    /// a piece of the file's plumbing presented as something the song says. LRCLIB's own
    /// synced parser already skipped these; nothing did for plain lyrics or for a server's.
    ///
    /// The offset is in milliseconds and is signed the way LRC defines it: a *negative*
    /// value means the words come earlier, so it is subtracted. Applied here rather than at
    /// display time because a stripped-but-unapplied offset silently loses a real timing
    /// correction — and this one was 47 seconds.
    public func normalizingLRCMetadata() -> NavidromeLyrics {
        var offset = 0.0
        var kept: [Line] = []
        for line in lines {
            if let tag = Self.metadataTag(in: line.text) {
                if tag.key == "offset", let milliseconds = Double(tag.value) {
                    offset = milliseconds / 1000
                }
                continue
            }
            kept.append(line)
        }
        guard offset != 0 else { return NavidromeLyrics(synced: synced, lines: kept) }
        return NavidromeLyrics(
            synced: synced,
            // Clamped at zero: a large negative offset can push the opening lines before the
            // start of the track, and a line that wants to highlight at -3 s never highlights.
            lines: kept.map { Line(start: $0.start.map { max(0, $0 - offset) }, text: $0.text) }
        )
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
/// A folder on the server, as `getIndexes`/`getMusicDirectory` see it. Distinct from the
/// tag-based views: this is the file system's opinion of the library, which for a
/// folder-organized collection is often the *owner's* opinion of it too.
public struct NavidromeFolder: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A list the *server* both ordered and bucketed — `getArtists` and `getIndexes` return
/// their items already grouped under index letters.
///
/// Those letters used to be thrown away on the grounds that "the A–Z rail rebuilds its own
/// letters from the data, so the server's grouping carries nothing the names don't". That
/// is only true when the client's bucketing rule and the server's collation agree, and on
/// a mixed-script library they do not: Navidrome ordered 2,657 albums and ~40 index
/// buckets its way, the client re-derived buckets from display names its way, and the rail
/// ended up reading `# Z Λ B Д И К Л М О П С Т I デ ル 周 喵 浜 락 무 G A T B …` — letters in
/// an order the rows underneath them do not follow.
///
/// Keeping the server's buckets makes the rail agree with the list by construction, in any
/// locale and any script, because whoever ordered the rows is the one naming the letters.
public struct ServerIndexedList<Element: Identifiable & Sendable>: Sendable {
    /// One index letter and the items filed under it, in the server's order.
    public struct Bucket: Sendable {
        public let letter: String
        public let items: [Element]

        public init(letter: String, items: [Element]) {
            self.letter = letter
            self.items = items
        }
    }

    public let buckets: [Bucket]

    public init(buckets: [Bucket]) {
        self.buckets = buckets
    }

    /// The flat list, in the order the buckets give — what every existing caller wants.
    public var items: [Element] { buckets.flatMap(\.items) }

    /// Non-empty buckets paired with the id of their first item, which is what a rail
    /// needs to scroll to. Empty buckets are dropped: a letter that scrolls nowhere is a
    /// dead target, and servers do report them.
    public var indexTargets: [(letter: String, firstID: Element.ID)] {
        buckets.compactMap { bucket in
            guard let first = bucket.items.first else { return nil }
            return (bucket.letter, first.id)
        }
    }
}

/// One folder's contents: subfolders first, then songs — the order a Finder window
/// would show them, which is the mental model folder browsing exists to honour.
public struct NavidromeDirectory: Sendable {
    public let id: String
    public let name: String
    public var folders: [NavidromeFolder]
    public var songs: [NavidromeSong]

    public init(id: String, name: String, folders: [NavidromeFolder], songs: [NavidromeSong]) {
        self.id = id
        self.name = name
        self.folders = folders
        self.songs = songs
    }
}

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

    /// True when the server specifically said the item does not exist — Subsonic error 70
    /// ("the requested data was not found"), or a plain HTTP 404.
    ///
    /// Worth distinguishing from every other failure: a caller looking up items by id wants
    /// to report *which ids are wrong*, and treating a transport or auth failure the same way
    /// would blame perfectly correct ids during an outage.
    public var isNotFound: Bool {
        switch self {
        case let .subsonic(code, _): code == 70
        case let .http(status): status == 404
        default: false
        }
    }

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
