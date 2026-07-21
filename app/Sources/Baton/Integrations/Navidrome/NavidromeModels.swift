import Foundation

// The Subsonic/Navidrome *domain* value types (NavidromeSong, NavidromeAlbum,
// ReplayGain, NavidromeError, …) now live in the BatonSubsonicModels SPM module — the
// second leaf of the  module-boundary split. Re-exported so every existing call
// site keeps referring to them unqualified. The Subsonic *wire* decoders below stay in
// the app (they map onto the domain types via each `toDomain()`).
@_exported import BatonSubsonicModels

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
    let randomSongs: SongsWire?
    let lyricsList: LyricsListWire?
    let openSubsonicExtensions: [OpenSubsonicExtensionWire]?

    var isOK: Bool {
        status == "ok"
    }
}

/// Parse a Subsonic/RFC3339 timestamp ("2024-01-15T10:30:00.000Z", with or without fractional
/// seconds) into a `Date`. Navidrome emits ISO8601. A fresh formatter per call keeps it free of
/// shared-state / Sendable concerns on the decoding thread (dates are sparse in a response).
enum SubsonicDate {
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// OpenSubsonic `ItemGenre` — `{ "name": "Jazz" }` entries in a `genres[]` array.
struct ItemGenreWire: Decodable {
    let name: String?
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
    let owner: String?
    let comment: String?
    let created: String?
    let changed: String?

    enum CodingKeys: String, CodingKey {
        case id, name, songCount, duration, coverArt, entry, owner, comment, created, changed
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
            songs: (entry ?? []).map { $0.toDomain() },
            owner: owner,
            comment: comment,
            created: SubsonicDate.parse(created),
            changed: SubsonicDate.parse(changed)
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
    let starred: String?
    let musicBrainzId: String?
    let roles: [String]?
    func toDomain() -> NavidromeArtist {
        NavidromeArtist(
            id: id,
            name: name ?? "(unknown)",
            albumCount: albumCount,
            coverArtID: coverArt,
            imageURLString: artistImageUrl,
            isLiked: starred != nil,
            musicBrainzID: musicBrainzId,
            roles: roles ?? []
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
    // Extended metadata (OpenSubsonic `AlbumID3`).
    let genre: String?
    let genres: [ItemGenreWire]?
    let playCount: Int?
    let played: String?
    let created: String?
    let releaseTypes: [String]?
    let isCompilation: Bool?
    let originalReleaseDate: ReleaseDateWire?
    let musicBrainzId: String?
    let displayArtist: String?

    /// OpenSubsonic `originalReleaseDate` — `{ "year": 1975, "month": 9, "day": 27 }`.
    struct ReleaseDateWire: Decodable {
        let year: Int?
        let month: Int?
        let day: Int?
        var formatted: String? {
            guard let year else { return nil }
            if let month, let day {
                return String(format: "%04d-%02d-%02d", year, month, day)
            }
            return String(year)
        }
    }

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
            userRating: userRating,
            genre: genre,
            genres: (genres ?? []).compactMap(\.name),
            playCount: playCount,
            played: SubsonicDate.parse(played),
            created: SubsonicDate.parse(created),
            releaseTypes: releaseTypes ?? [],
            isCompilation: isCompilation ?? false,
            originalReleaseDate: originalReleaseDate?.formatted,
            musicBrainzID: musicBrainzId,
            displayArtist: displayArtist
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
    // Extended metadata (Subsonic + OpenSubsonic `Child`).
    let year: Int?
    let discNumber: Int?
    let genre: String?
    let genres: [ItemGenreWire]?
    let bitRate: Int?
    let suffix: String?
    let contentType: String?
    let size: Int?
    let samplingRate: Int?
    let bitDepth: Int?
    let channelCount: Int?
    let playCount: Int?
    let played: String?
    let bpm: Int?
    let comment: String?
    let musicBrainzId: String?
    let displayArtist: String?

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
            track: track,
            year: year,
            discNumber: discNumber,
            genre: genre,
            genres: (genres ?? []).compactMap(\.name),
            bitRate: bitRate,
            suffix: suffix,
            contentType: contentType,
            size: size,
            samplingRate: samplingRate,
            bitDepth: bitDepth,
            channelCount: channelCount,
            playCount: playCount,
            played: SubsonicDate.parse(played),
            bpm: bpm,
            comment: comment,
            musicBrainzID: musicBrainzId,
            displayArtist: displayArtist
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
