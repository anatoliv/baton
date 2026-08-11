import Foundation

private let navidromeLog = Logger(subsystem: "io.tonebox.baton", category: "Navidrome")

/// How the client authenticates each Subsonic request.
public enum NavidromeAuthMode: String, Codable, CaseIterable, Sendable {
    /// Universal Subsonic auth: `t = md5(password + salt)`, `s = salt`. The
    /// plaintext password is never sent — only the per-request md5.
    case tokenSalt
    /// OpenSubsonic `apikeyauth` extension: a server-issued key sent as `apiKey`.
    /// Used only when the server advertises the extension.
    case apiKey
}

/// Immutable, `Sendable` bundle the client authenticates with. Built from
/// `AIConfig` (server URL + username in UserDefaults, secret in Keychain) at the
/// call site, so a credential change takes effect on the next client build.
public struct NavidromeCredentials: Equatable, Sendable {
    public var baseURL: URL
    public var username: String
    /// Password (`.tokenSalt`) or API key (`.apiKey`).
    public var secret: String
    public var authMode: NavidromeAuthMode
    /// Extra HTTP headers for every API/download request to this server (reverse-proxy
    /// auth like Cloudflare Access). Streaming AVURLAssets get them separately via
    /// `StreamingPlaybackController.streamAsset`.
    public var customHeaders: [String: String]

    public init(baseURL: URL, username: String, secret: String, authMode: NavidromeAuthMode,
                customHeaders: [String: String] = [:]) {
        self.baseURL = baseURL
        self.username = username
        self.secret = secret
        self.authMode = authMode
        self.customHeaders = customHeaders
    }
}

/// Client identification sent with every request. Conditional per platform so server
/// activity logs distinguish the Mac and iPhone apps.
#if os(iOS)
let batonClientUserAgent = "Baton (iOS; Navidrome-Integration)"
#else
let batonClientUserAgent = "Baton (macOS; Navidrome-Integration)"
#endif

/// Hand-rolled Subsonic / OpenSubsonic client for Navidrome. Mirrors the
/// `URLSessionJiraClient` idiom (request builders, a `perform` wrapper with typed
/// error mapping, `async/await` throughout) and stays a `Sendable` value type so
/// it can be built on demand and passed across actors.
///
/// Only the endpoints Tonebox needs are implemented: `ping`,
/// `getOpenSubsonicExtensions`, `search3`, `getPlaylists`, `getPlaylist`, plus
/// signed URL builders for `stream` and `getCoverArt` (handed to `AVPlayer` /
/// image loaders rather than fetched here).
public struct NavidromeClient: Sendable {
    public let credentials: NavidromeCredentials
    public let session: URLSession

    /// Subsonic protocol version we advertise (`v`). 1.16.1 is the last classic
    /// Subsonic level; OpenSubsonic servers accept it and layer extensions on top.
    private let apiVersion = "1.16.1"
    /// Client identifier (`c`) — shows up in the server's play/activity logs and as
    /// `changedBy` on the saved play queue, which is how the handoff offer tells
    /// "another Baton" from "this device".
    #if os(iOS)
    private let clientName = "baton-ios"
    #else
    private let clientName = "baton"
    #endif

    /// A stable salt+token computed once per client, so repeated URLs for the same resource
    /// (especially artwork) are byte-identical and URLCache/AsyncImage actually cache them
    /// instead of refetching on every recomputation. Subsonic permits salt reuse.
    private let cachedSalt: String
    private let cachedToken: String

    public init(credentials: NavidromeCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
        self.cachedSalt = Self.makeSalt()
        self.cachedToken = Self.token(password: credentials.secret, salt: cachedSalt)
    }

    // MARK: - Auth primitives (pure — unit-tested directly)

    /// Subsonic token: `md5(password + salt)`, lowercase hex. Canonical vector
    /// (`sesame` + `c19b2d` → `26719a1196d2a940705a59634eb18eab`) is locked by a test.
    public static func token(password: String, salt: String) -> String {
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh random salt (≥ 6 chars, per spec). 16 hex chars from 8 random bytes.
    public static func makeSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0 ... 255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The auth + housekeeping query items shared by every request. For
    /// `.tokenSalt` this generates a new salt each call (`u`/`t`/`s`); for
    /// `.apiKey` it sends the key alone.
    public func baseQueryItems(json: Bool) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
        ]
        if json { items.append(URLQueryItem(name: "f", value: "json")) }
        switch credentials.authMode {
        case .apiKey:
            items.append(URLQueryItem(name: "apiKey", value: credentials.secret))
        case .tokenSalt:
            items.append(URLQueryItem(name: "u", value: credentials.username))
            items.append(URLQueryItem(name: "t", value: cachedToken)) // stable per client
            items.append(URLQueryItem(name: "s", value: cachedSalt))
        }
        return items
    }

    /// Builds a fully-signed `<base>/rest/<endpoint>` URL. `json` controls whether
    /// `f=json` is appended — off for binary endpoints (`stream`, `getCoverArt`).
    public func makeURL(_ endpoint: String, query: [URLQueryItem] = [], json: Bool = true) throws -> URL {
        let full = credentials.baseURL.appendingPathComponent("rest/\(endpoint)")
        guard var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
            throw NavidromeError.invalidURL
        }
        components.queryItems = baseQueryItems(json: json) + query
        // `URLComponents` percent-encodes `&` and `=` in values but leaves `;` and `+`
        // alone, because both are legal in a query component per RFC 3986. Servers
        // disagree: Go's `url.ParseQuery` (Navidrome) rejects a bare `;` outright with
        // "invalid semicolon separator in query", and `+` decodes as a space. A song
        // title containing either — "rock; roll", "a+b" — therefore breaks the request
        // or silently searches for the wrong string. Encode them ourselves.
        if let encoded = components.percentEncodedQuery {
            components.percentEncodedQuery = encoded
                .replacingOccurrences(of: ";", with: "%3B")
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw NavidromeError.invalidURL }
        return url
    }

    // MARK: - Signed URL builders (not fetched here)

    /// Self-authenticating stream URL for `AVPlayer` (`AVURLAsset(url:)`). Subsonic
    /// auth lives in the query string, so no request headers are needed.
    ///
    /// Requests `format=mp3` so Navidrome serves audio AVFoundation can always
    /// decode: Ogg/Opus/WMA (and some FLAC edge cases) don't decode natively and
    /// play as silence-with-no-error. Files that are already MP3 stream as-is
    /// (Navidrome only transcodes when the source differs).
    /// `maxBitRate` (kbps) asks the server to cap the transcode bitrate — the per-network
    /// quality control a phone needs on cellular (0/nil = server default, no cap).
    /// `format: nil` keeps the historical `mp3` request; pass `"raw"` for the original file.
    public func streamURL(songID: String, maxBitRate: Int? = nil, format: String? = nil) throws -> URL {
        var query = [
            URLQueryItem(name: "id", value: songID),
            URLQueryItem(name: "format", value: format ?? "mp3"),
        ]
        if let maxBitRate, maxBitRate > 0 {
            query.append(URLQueryItem(name: "maxBitRate", value: String(maxBitRate)))
        }
        return try makeURL("stream.view", query: query, json: false)
    }

    /// The ORIGINAL file (download.view — no transcode) for offline downloads, so a FLAC library
    /// isn't stored as lossy MP3 at the server's default bitrate.
    public func downloadURL(songID: String) throws -> URL {
        try makeURL("download.view", query: [URLQueryItem(name: "id", value: songID)], json: false)
    }

    /// Signed cover-art URL. `size` (px) is optional; nil returns full size.
    public func coverArtURL(id: String, size: Int? = nil) -> URL? {
        var query = [URLQueryItem(name: "id", value: id)]
        if let size { query.append(URLQueryItem(name: "size", value: String(size))) }
        return try? makeURL("getCoverArt.view", query: query, json: false)
    }

    // MARK: - JSON endpoints

    /// Liveness + credential check. Throws on any transport / auth / protocol
    /// failure; returns normally on `status: ok`.
    public func ping() async throws {
        _ = try await performJSON("ping.view")
    }

    /// OpenSubsonic extension names the server advertises (empty on a classic
    /// Subsonic server that lacks the endpoint). Used to pick the auth mode.
    public func openSubsonicExtensions() async throws -> [String] {
        let response = try await performJSON("getOpenSubsonicExtensions.view")
        return (response.openSubsonicExtensions ?? []).map(\.name)
    }

    /// Fold a search term the way Navidrome folds the text it indexes.
    ///
    /// Navidrome writes a normalised `full_text` column and matches against that, so a
    /// title stored as `best of øneheart` is indexed as `oneheart`. Sending the literal
    /// `øneheart` therefore matches **nothing** — the search silently fails on exactly the
    /// characters a user is most likely to copy from a track name.
    ///
    /// `.diacriticInsensitive` covers composed forms (ë→e, é→e, ö→o) but not letters that
    /// are distinct in their own right, so those need an explicit map: `ø` does not
    /// decompose to `o` + a combining stroke.
    public static func foldedForSearch(_ term: String) -> String {
        let mapped = term.reduce(into: "") { out, ch in
            switch ch {
            case "ø": out += "o"
            case "Ø": out += "O"
            case "æ": out += "ae"
            case "Æ": out += "AE"
            case "œ": out += "oe"
            case "Œ": out += "OE"
            case "ð": out += "d"
            case "Ð": out += "D"
            case "þ": out += "th"
            case "Þ": out += "TH"
            case "ł": out += "l"
            case "Ł": out += "L"
            case "đ": out += "d"
            case "Đ": out += "D"
            case "ß": out += "ss"
            default: out.append(ch)
            }
        }
        return mapped.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
    }

    /// `search3` — auto-complete-style search across artists, albums, songs.
    public func search3(
        query: String,
        songCount: Int = 20,
        albumCount: Int = 10,
        artistCount: Int = 10
    ) async throws -> NavidromeSearchResults {
        let response = try await performJSON("search3.view", query: [
            URLQueryItem(name: "query", value: Self.foldedForSearch(query)),
            URLQueryItem(name: "songCount", value: String(songCount)),
            URLQueryItem(name: "albumCount", value: String(albumCount)),
            URLQueryItem(name: "artistCount", value: String(artistCount)),
        ])
        return Self.mapSearchResults(response.searchResult3)
    }

    /// An album's ordered songs (`getAlbum`). Used to play an album in track order
    /// rather than as loose search hits.
    public func getAlbum(id: String) async throws -> [NavidromeSong] {
        let response = try await performJSON("getAlbum.view", query: [
            URLQueryItem(name: "id", value: id),
        ])
        return (response.album?.song ?? []).map { $0.toDomain() }
    }

    /// All playlists (metadata only; `songs` is empty — call `getPlaylist`).
    public func getPlaylists() async throws -> [NavidromePlaylist] {
        let response = try await performJSON("getPlaylists.view")
        return (response.playlists?.playlist ?? []).map { $0.toDomain() }
    }

    /// One playlist with its ordered songs.
    public func getPlaylist(id: String) async throws -> NavidromePlaylist {
        let response = try await performJSON("getPlaylist.view", query: [
            URLQueryItem(name: "id", value: id),
        ])
        guard let wire = response.playlist else {
            throw NavidromeError.subsonic(code: 70, message: "Playlist not found")
        }
        return wire.toDomain()
    }

    // MARK: - Ratings (server-side, per-user — the pipeline signal)

    /// "Like" a track/album/artist (`star`). Persists on the server.
    public func star(id: String) async throws {
        _ = try await performJSON("star.view", query: [URLQueryItem(name: "id", value: id)])
    }

    /// Remove a like (`unstar`).
    public func unstar(id: String) async throws {
        _ = try await performJSON("unstar.view", query: [URLQueryItem(name: "id", value: id)])
    }

    /// Set a 1–5 rating (`setRating`); `rating: 0` clears it.
    public func setRating(id: String, rating: Int) async throws {
        _ = try await performJSON("setRating.view", query: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "rating", value: String(max(0, min(rating, 5)))),
        ])
    }

    /// Fresh metadata for one song (`getSong`), including the current user's
    /// server-side `starred` (like) and `userRating`. Used to reconcile the
    /// now-playing display with the server after a relaunch.
    public func getSong(id: String) async throws -> NavidromeSong {
        let response = try await performJSON("getSong.view", query: [URLQueryItem(name: "id", value: id)])
        guard let song = response.song else { throw NavidromeError.subsonic(code: -1, message: "No song in response") }
        return song.toDomain()
    }

    // MARK: - Browse

    /// All starred ("liked") items for the current user (`getStarred2`).
    public func getStarred2() async throws -> NavidromeSearchResults {
        let response = try await performJSON("getStarred2.view")
        return Self.mapSearchResults(response.starred2)
    }

    /// Album lists by kind (`getAlbumList2`): `newest`, `frequent`, `recent`,
    /// `starred`, `highest`, `random`, `alphabeticalByName`, …
    /// `genre` / `fromYear` / `toYear` are the parameters the `byGenre` and
    /// `byYear` types require — without them those two kinds return an error or
    /// the whole library, so they're part of the same call rather than a variant.
    public func getAlbumList2(
        type: String,
        size: Int = 50,
        offset: Int = 0,
        genre: String? = nil,
        fromYear: Int? = nil,
        toYear: Int? = nil
    ) async throws -> [NavidromeAlbum] {
        var query = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let genre { query.append(URLQueryItem(name: "genre", value: genre)) }
        if let fromYear { query.append(URLQueryItem(name: "fromYear", value: String(fromYear))) }
        if let toYear { query.append(URLQueryItem(name: "toYear", value: String(toYear))) }
        let response = try await performJSON("getAlbumList2.view", query: query)
        return (response.albumList2?.album ?? []).map { $0.toDomain() }
    }

    /// The folder tree's roots (`getIndexes`), flat — the order the server gave them.
    public func getIndexes() async throws -> [NavidromeFolder] {
        try await getFolderIndex().items
    }

    /// The folder tree's roots with the server's own A–Z buckets kept, for the rail.
    public func getFolderIndex() async throws -> ServerIndexedList<NavidromeFolder> {
        let response = try await performJSON("getIndexes.view", query: [])
        return ServerIndexedList(buckets: (response.indexes?.index ?? []).map { bucket in
            .init(letter: bucket.name ?? "#",
                  items: (bucket.artist ?? []).map { NavidromeFolder(id: $0.id, name: $0.name) })
        })
    }

    /// One folder's contents (`getMusicDirectory`): subfolders and playable songs.
    public func getMusicDirectory(id: String) async throws -> NavidromeDirectory {
        let response = try await performJSON("getMusicDirectory.view",
                                             query: [URLQueryItem(name: "id", value: id)])
        let wire = response.directory
        let children = wire?.child ?? []
        return NavidromeDirectory(
            id: wire?.id ?? id,
            name: wire?.name ?? "Folder",
            folders: children.compactMap { $0.folder.map { NavidromeFolder(id: $0.id, name: $0.name) } },
            songs: children.compactMap { $0.song?.toDomain() }
        )
    }

    /// All artists (`getArtists`), flat — the order the server's index buckets give.
    public func getArtists() async throws -> [NavidromeArtist] {
        try await getArtistIndex().items
    }

    /// All artists with the server's own index letters kept, for the rail.
    public func getArtistIndex() async throws -> ServerIndexedList<NavidromeArtist> {
        let response = try await performJSON("getArtists.view")
        return response.artists?.indexed() ?? ServerIndexedList(buckets: [])
    }

    /// One artist's albums (`getArtist`).
    public func getArtistAlbums(id: String) async throws -> [NavidromeAlbum] {
        let response = try await performJSON("getArtist.view", query: [URLQueryItem(name: "id", value: id)])
        return (response.artist?.album ?? []).map { $0.toDomain() }
    }

    /// Library genres (`getGenres`).
    public func getGenres() async throws -> [NavidromeGenre] {
        let response = try await performJSON("getGenres.view")
        return (response.genres?.genre ?? []).map { $0.toDomain() }
    }

    /// Songs in a genre (`getSongsByGenre`).
    public func getSongsByGenre(_ genre: String, count: Int = 60) async throws -> [NavidromeSong] {
        let response = try await performJSON("getSongsByGenre.view", query: [
            URLQueryItem(name: "genre", value: genre),
            URLQueryItem(name: "count", value: String(count)),
        ])
        return (response.songsByGenre?.song ?? []).map { $0.toDomain() }
    }

    /// Biography + portrait for an artist (`getArtistInfo2`).
    public func getArtistInfo(id: String) async throws -> NavidromeArtistInfo {
        let response = try await performJSON("getArtistInfo2.view", query: [URLQueryItem(name: "id", value: id)])
        return (response.artistInfo2 ?? ArtistInfo2Wire(biography: nil, largeImageUrl: nil)).toDomain()
    }

    /// Songs similar to a track/artist (`getSimilarSongs2`) — powers radio/discovery.
    public func getSimilarSongs(id: String, count: Int = 50) async throws -> [NavidromeSong] {
        let response = try await performJSON("getSimilarSongs2.view", query: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: String(count)),
        ])
        return (response.similarSongs2?.song ?? []).map { $0.toDomain() }
    }

    /// Random songs from the library (`getRandomSongs`) — the autoplay fallback when the server has
    /// no similarity data (Navidrome's getSimilarSongs2 needs a Last.fm agent, so it's often empty),
    /// so "continuous radio" keeps playing instead of stopping dead at the queue's end.
    public func getRandomSongs(
        count: Int = 50,
        genre: String? = nil,
        fromYear: Int? = nil,
        toYear: Int? = nil
    ) async throws -> [NavidromeSong] {
        var query = [URLQueryItem(name: "size", value: String(count))]
        if let genre { query.append(URLQueryItem(name: "genre", value: genre)) }
        if let fromYear { query.append(URLQueryItem(name: "fromYear", value: String(fromYear))) }
        if let toYear { query.append(URLQueryItem(name: "toYear", value: String(toYear))) }
        let response = try await performJSON("getRandomSongs.view", query: query)
        return (response.randomSongs?.song ?? []).map { $0.toDomain() }
    }

    /// Structured (optionally time-synced) lyrics for a song (`getLyricsBySongId`).
    /// Returns nil when the server has no lyrics for the track.
    public func getLyrics(songID: String) async throws -> NavidromeLyrics? {
        let response = try await performJSON("getLyricsBySongId.view", query: [
            URLQueryItem(name: "id", value: songID),
        ])
        return response.lyricsList?.toDomain()
    }

    // MARK: - Scrobble (play counts / "recently & most played")

    /// Records a play (`scrobble`). `submission: false` marks "now playing";
    /// `true` counts it as played. Best-effort — a scrobble failure never blocks
    /// playback.
    /// `time` is Unix milliseconds when the track STARTED — Subsonic accepts it precisely so an
    /// offline/delayed flush credits the play at the real listen time, not at flush time.
    public func scrobble(id: String, submission: Bool = true, time: Int? = nil) async throws {
        var query = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "submission", value: submission ? "true" : "false"),
        ]
        if let time { query.append(URLQueryItem(name: "time", value: String(time))) }
        _ = try await performJSON("scrobble.view", query: query)
    }

    /// Reports how much of a track actually **played**, once it is left.
    ///
    /// Rides on the "now playing" scrobble (`submission=false`), which by design does not touch
    /// play counts — this only needs to reach the server's access log, where the listening
    /// pipeline reads it. Subsonic servers ignore query parameters they don't know, so
    /// `listened` / `trackDuration` are inert to the server and meaningful downstream.
    ///
    /// It exists because **no server-side signal can answer "did they listen"**. The access log
    /// records bytes delivered, and a long track buffers completely within a few minutes however
    /// briefly the listener stays — so every long track looks fully played. Only the client knows.
    public func reportListen(id: String, listenedSeconds: Int, trackDuration: Int?) async throws {
        var query = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "submission", value: "false"),
            URLQueryItem(name: "listened", value: String(max(0, listenedSeconds))),
        ]
        if let trackDuration, trackDuration > 0 {
            query.append(URLQueryItem(name: "trackDuration", value: String(trackDuration)))
        }
        _ = try await performJSON("scrobble.view", query: query)
    }

    // MARK: - Playlist CRUD

    /// Creates a playlist with optional initial songs (`createPlaylist`). Returns
    /// the created playlist.
    public func createPlaylist(name: String, songIDs: [String] = []) async throws -> NavidromePlaylist {
        var query = [URLQueryItem(name: "name", value: name)]
        query.append(contentsOf: songIDs.map { URLQueryItem(name: "songId", value: $0) })
        let response = try await performJSON("createPlaylist.view", query: query)
        // Some servers return the new playlist; fall back to a stub if not.
        if let wire = response.playlist { return wire.toDomain() }
        return NavidromePlaylist(id: "", name: name, songCount: songIDs.count, songs: [])
    }

    /// Updates a playlist (`updatePlaylist`): rename, comment, public flag, add songs
    /// by id, remove songs by track index. Any nil argument is left unchanged.
    public func updatePlaylist(
        id: String,
        name: String? = nil,
        comment: String? = nil,
        isPublic: Bool? = nil,
        songIDsToAdd: [String] = [],
        songIndexesToRemove: [Int] = []
    ) async throws {
        var query = [URLQueryItem(name: "playlistId", value: id)]
        if let name { query.append(URLQueryItem(name: "name", value: name)) }
        if let comment { query.append(URLQueryItem(name: "comment", value: comment)) }
        if let isPublic { query.append(URLQueryItem(name: "public", value: isPublic ? "true" : "false")) }
        query.append(contentsOf: songIDsToAdd.map { URLQueryItem(name: "songIdToAdd", value: $0) })
        query.append(contentsOf: songIndexesToRemove.map { URLQueryItem(name: "songIndexToRemove", value: String($0)) })
        _ = try await performJSON("updatePlaylist.view", query: query)
    }

    /// Replaces a playlist's tracks with `songIDs` in the given order — used to persist a
    /// drag-reorder. Subsonic `createPlaylist` with a `playlistId` overwrites the contents
    /// with exactly the supplied ordered list (Navidrome updates in place). Passing `name`
    /// keeps the title from being reset by the overwrite (the shared flag is re-asserted
    /// separately via `updatePlaylist`, since `createPlaylist` doesn't take it).
    public func setPlaylistSongs(id: String, songIDs: [String], name: String? = nil) async throws {
        var query = [URLQueryItem(name: "playlistId", value: id)]
        if let name { query.append(URLQueryItem(name: "name", value: name)) }
        query.append(contentsOf: songIDs.map { URLQueryItem(name: "songId", value: $0) })
        _ = try await performJSON("createPlaylist.view", query: query)
    }

    /// Replaces a playlist's tracks with `songIDs` in order, sending them in bounded batches so
    /// large playlists don't overflow the request-line/proxy URL limit. The
    /// first batch overwrites via `setPlaylistSongs` (createPlaylist), and each subsequent batch
    /// appends in order via `updatePlaylist(songIDsToAdd:)` — so the final server order equals the
    /// concatenation of the batches, i.e. exactly `songIDs`. `chunkSize` keeps each request well
    /// under typical 8 KB request-line ceilings (an id + `&songId=` is ~40 bytes → ~4 KB at 100).
    public func setPlaylistSongsChunked(id: String, songIDs: [String], name: String? = nil, chunkSize: Int = 100) async throws {
        precondition(chunkSize > 0, "chunkSize must be positive")
        let batches = stride(from: 0, to: songIDs.count, by: chunkSize).map { start in
            Array(songIDs[start ..< min(start + chunkSize, songIDs.count)])
        }
        // Empty playlist: still overwrite so a clear-all reorder persists.
        try await setPlaylistSongs(id: id, songIDs: batches.first ?? [], name: name)
        for batch in batches.dropFirst() {
            try await updatePlaylist(id: id, songIDsToAdd: batch)
        }
    }

    /// Deletes a playlist (`deletePlaylist`).
    public func deletePlaylist(id: String) async throws {
        _ = try await performJSON("deletePlaylist.view", query: [URLQueryItem(name: "id", value: id)])
    }

    /// Shared mapping for `search3` / `getStarred2` result bodies.
    public static func mapSearchResults(_ wire: SearchResult3Wire?) -> NavidromeSearchResults {
        NavidromeSearchResults(
            songs: (wire?.song ?? []).map { $0.toDomain() },
            albums: (wire?.album ?? []).map { $0.toDomain() },
            artists: (wire?.artist ?? []).map { $0.toDomain() }
        )
    }

    // MARK: - Transport

    /// One retry with a short backoff for an idempotent GET — a single transient blip
    /// (timeout, dropped connection) shouldn't fail an otherwise-fine read.
    public static func dataWithOneRetry(session: URLSession, request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where
            error.code == .timedOut || error.code == .networkConnectionLost || error.code == .cannotConnectToHost {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return try await session.data(for: request)
        }
    }

    func performJSON(_ endpoint: String, query: [URLQueryItem] = []) async throws -> SubsonicResponse {
        let url = try makeURL(endpoint, query: query)
        var request = URLRequest(url: url)
        request.setValue(batonClientUserAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in credentials.customHeaders { request.setValue(value, forHTTPHeaderField: name) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.dataWithOneRetry(session: session, request: request)
        } catch {
            navidromeLog
                .error(
                    "\(endpoint, privacy: .public) transport failed: \(error.localizedDescription, privacy: .public)"
                )
            throw NavidromeError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            navidromeLog.error("\(endpoint, privacy: .public): non-HTTP response")
            throw NavidromeError.transport("Non-HTTP response")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            navidromeLog.error("\(endpoint, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
            // A reverse proxy in front of Navidrome answers 401/403 for bad credentials — map
            // it to the actionable "check your credentials" error, not a generic HTTP code.
            if http.statusCode == 401 || http.statusCode == 403 { throw NavidromeError.unauthorized }
            throw NavidromeError.http(status: http.statusCode)
        }

        let envelope: SubsonicEnvelope
        do {
            envelope = try JSONDecoder().decode(SubsonicEnvelope.self, from: data)
        } catch {
            navidromeLog
                .error("\(endpoint, privacy: .public): decode failed: \(error.localizedDescription, privacy: .public)")
            throw NavidromeError.decoding(error.localizedDescription)
        }
        let subsonic = envelope.response
        guard subsonic.isOK else {
            let code = subsonic.error?.code ?? -1
            let message = subsonic.error?.message ?? "Unknown error"
            // The server's error text is safe to log (no secrets); the username
            // lives in the query, never logged. Makes "check logs" actionable.
            navidromeLog
                .error(
                    "\(endpoint, privacy: .public): Subsonic error \(code, privacy: .public) — \(message, privacy: .public)"
                )
            // 40 wrong credentials · 41 token auth unsupported · 44 invalid creds.
            if code == 40 || code == 41 || code == 44 {
                throw NavidromeError.unauthorized
            }
            throw NavidromeError.subsonic(code: code, message: message)
        }
        return subsonic
    }
}
