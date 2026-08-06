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

public struct SubsonicEnvelope: Decodable {
    public let response: SubsonicResponse
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

public struct SubsonicResponse: Decodable {
    public let status: String
    public let version: String?
    public let error: SubsonicWireError?
    public let searchResult3: SearchResult3Wire?
    public let starred2: SearchResult3Wire?
    public let song: SongWire?
    public let artistInfo2: ArtistInfo2Wire?
    public let albumList2: AlbumListWire?
    public let artists: ArtistsWire?
    public let artist: ArtistDetailWire?
    public let genres: GenresWire?
    public let playlists: PlaylistsWire?
    public let playlist: PlaylistWire?
    public let album: AlbumDetailWire?
    public let similarSongs2: SongsWire?
    public let songsByGenre: SongsWire?
    public let randomSongs: SongsWire?
    public let lyricsList: LyricsListWire?
    public let openSubsonicExtensions: [OpenSubsonicExtensionWire]?
    public let playQueue: PlayQueueWire?
    public let bookmarks: BookmarksWire?

    public var isOK: Bool {
        status == "ok"
    }
}

/// Parse a Subsonic/RFC3339 timestamp ("2024-01-15T10:30:00.000Z", with or without fractional
/// seconds) into a `Date`. Navidrome emits ISO8601. A fresh formatter per call keeps it free of
/// shared-state / Sendable concerns on the decoding thread (dates are sparse in a response).
public enum SubsonicDate {
    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// OpenSubsonic `ItemGenre` — `{ "name": "Jazz" }` entries in a `genres[]` array.
public struct ItemGenreWire: Decodable {
    public let name: String?
}

public struct SubsonicWireError: Decodable {
    public let code: Int
    public let message: String?
}

public struct OpenSubsonicExtensionWire: Decodable {
    public let name: String
    public let versions: [Int]?
}

public struct ArtistInfo2Wire: Decodable {
    public let biography: String?
    public let largeImageUrl: String?
    public func toDomain() -> NavidromeArtistInfo {
        let bio = biography?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NavidromeArtistInfo(
            biography: (bio?.isEmpty ?? true) ? nil : bio,
            imageURL: Self.cleanImageURL(largeImageUrl)
        )
    }

    /// last.fm hands Navidrome a blank "star" placeholder image for artists it can't
    /// match (its hash is well-known). It's a valid URL that loads a grey nothing, so
    /// treat it as absent — callers fall back to real cover art instead.
    public static func cleanImageURL(_ raw: String?) -> URL? {
        guard let raw, !raw.contains("2a96cbd8b46e442fc41c2b86b821562f") else { return nil }
        return URL(string: raw)
    }
}

public struct SearchResult3Wire: Decodable {
    public let artist: [ArtistWire]?
    public let album: [AlbumWire]?
    public let song: [SongWire]?
}

public struct PlaylistsWire: Decodable {
    public let playlist: [PlaylistWire]?
}

public struct PlaylistWire: Decodable {
    public let id: String
    public let name: String?
    public let songCount: Int?
    public let duration: Int?
    public let isPublic: Bool?
    public let coverArt: String?
    public let entry: [SongWire]?
    public let owner: String?
    public let comment: String?
    public let created: String?
    public let changed: String?

    enum CodingKeys: String, CodingKey {
        case id, name, songCount, duration, coverArt, entry, owner, comment, created, changed
        case isPublic = "public"
    }

    public func toDomain() -> NavidromePlaylist {
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
public struct AlbumDetailWire: Decodable {
    public let id: String
    public let name: String?
    public let song: [SongWire]?
}

public struct ArtistWire: Decodable {
    public let id: String
    public let name: String?
    public let albumCount: Int?
    public let coverArt: String?
    public let artistImageUrl: String?
    public let starred: String?
    public let musicBrainzId: String?
    public let roles: [String]?
    public func toDomain() -> NavidromeArtist {
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

public struct AlbumWire: Decodable {
    public let id: String
    public let name: String?
    public let title: String?
    public let artist: String?
    public let artistId: String?
    public let songCount: Int?
    public let duration: Int?
    public let coverArt: String?
    public let year: Int?
    public let starred: String?
    public let userRating: Int?
    // Extended metadata (OpenSubsonic `AlbumID3`).
    public let genre: String?
    public let genres: [ItemGenreWire]?
    public let playCount: Int?
    public let played: String?
    public let created: String?
    public let releaseTypes: [String]?
    public let isCompilation: Bool?
    public let originalReleaseDate: ReleaseDateWire?
    public let musicBrainzId: String?
    public let displayArtist: String?

    /// OpenSubsonic `originalReleaseDate` — `{ "year": 1975, "month": 9, "day": 27 }`.
    public struct ReleaseDateWire: Decodable {
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

    public func toDomain() -> NavidromeAlbum {
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

public struct SongWire: Decodable {
    public let id: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let albumId: String?
    public let duration: Int?
    public let coverArt: String?
    public let starred: String?
    public let userRating: Int?
    public let track: Int?
    public let replayGain: ReplayGainWire?
    // Extended metadata (Subsonic + OpenSubsonic `Child`).
    public let year: Int?
    public let discNumber: Int?
    public let genre: String?
    public let genres: [ItemGenreWire]?
    public let bitRate: Int?
    public let suffix: String?
    public let contentType: String?
    public let size: Int?
    public let samplingRate: Int?
    public let bitDepth: Int?
    public let channelCount: Int?
    public let playCount: Int?
    public let played: String?
    public let bpm: Int?
    public let comment: String?
    public let musicBrainzId: String?
    public let displayArtist: String?

    public struct ReplayGainWire: Decodable {
        let trackGain: Double?
        let albumGain: Double?
        let trackPeak: Double?
        let albumPeak: Double?
    }

    public func toDomain() -> NavidromeSong {
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
public struct AlbumListWire: Decodable {
    public let album: [AlbumWire]?
}

/// Generic `{ song: [...] }` body (used by `getSimilarSongs2`).
public struct SongsWire: Decodable {
    public let song: [SongWire]?
}

/// `getLyricsBySongId` → `lyricsList.structuredLyrics[]`.
public struct LyricsListWire: Decodable {
    public let structuredLyrics: [StructuredLyricsWire]?

    public struct StructuredLyricsWire: Decodable {
        let synced: Bool?
        let line: [LineWire]?
        struct LineWire: Decodable {
            let start: Int? // milliseconds
            let value: String?
        }
    }

    /// The first (typically only) lyric set → domain, or nil if none.
    public func toDomain() -> NavidromeLyrics? {
        guard let first = structuredLyrics?.first, let lines = first.line, !lines.isEmpty else { return nil }
        return NavidromeLyrics(
            synced: first.synced ?? false,
            lines: lines.map { NavidromeLyrics.Line(start: $0.start.map { Double($0) / 1000 }, text: $0.value ?? "") }
        )
    }
}

/// `getArtists` → `artists.index[].artist[]` (alphabetical index buckets).
public struct ArtistsWire: Decodable {
    public let index: [IndexWire]?
    public struct IndexWire: Decodable {
        let artist: [ArtistWire]?
    }

    public func flatArtists() -> [NavidromeArtist] {
        (index ?? []).flatMap { ($0.artist ?? []).map { $0.toDomain() } }
    }
}

/// `getArtist` → `artist.album[]` (an artist's albums).
public struct ArtistDetailWire: Decodable {
    public let id: String
    public let name: String?
    public let album: [AlbumWire]?
}

/// `getGenres` → `genres.genre[]`.
public struct GenresWire: Decodable {
    public let genre: [GenreWire]?
    public struct GenreWire: Decodable {
        let value: String
        let songCount: Int?
        let albumCount: Int?
        func toDomain() -> NavidromeGenre {
            NavidromeGenre(name: value, songCount: songCount, albumCount: albumCount)
        }
    }
}
