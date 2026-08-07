import Foundation
import Observation
import OSLog
import BatonSubsonicKit

private let musicStoreLog = Logger(subsystem: "io.tonebox.baton", category: "MusicLibrary")

/// How to sort/scope the Albums browse tab. Most map directly to a `getAlbumList2`
/// server sort; `tracks` and `duration` have no API equivalent, so they fetch a
/// name-sorted base list and re-order it client-side (see `clientComparator`).
public enum AlbumSort: String, CaseIterable, Identifiable, MusicSortField, Sendable {
    case newest, recent, frequent, name, artist, tracks, duration, starred, highest, random, year

    public var id: String {
        rawValue
    }

    /// The Subsonic `getAlbumList2` `type` value to fetch with.
    public var apiType: String {
        switch self {
        case .newest: "newest"
        case .recent: "recent"
        case .frequent: "frequent"
        case .starred: "starred"
        case .highest: "highest"
        case .random: "random"
        case .artist: "alphabeticalByArtist"
        // Name plus the client-sorted ones fetch an A→Z base list. Year is client-side
        // too: the API's `byYear` needs a from/to range, which is a filter pretending to
        // be a sort — re-ordering the fetched list matches what people actually mean.
        case .name, .tracks, .duration, .year: "alphabeticalByName"
        }
    }

    /// A client-side re-order applied after fetching (nil = keep server order).
    public var clientComparator: ((NavidromeAlbum, NavidromeAlbum) -> Bool)? {
        switch self {
        case .name: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .tracks: { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        case .duration: { ($0.duration ?? 0) > ($1.duration ?? 0) }
        // Newest year first; unknown years sink to the bottom rather than posing as 0 AD.
        case .year: { ($0.year ?? Int.min) > ($1.year ?? Int.min) }
        default: nil
        }
    }

    public var label: String {
        switch self {
        case .newest: "Recently added"
        case .recent: "Recently played"
        case .frequent: "Most played"
        case .name: "Name"
        case .artist: "Artist"
        case .tracks: "Tracks"
        case .duration: "Play time"
        case .starred: "Liked"
        case .highest: "Top rated"
        case .random: "Random"
        case .year: "Year"
        }
    }
}

/// Optimistic like + rating state for one item, keyed by id.
public struct MusicRatingState: Equatable, Sendable {
    public var isLiked: Bool
    public var userRating: Int?
}

/// View-model for the full music player: search + browse state, the playlist list,
/// and optimistic like/rating + playlist mutations that write through to the
/// server. Owned by `AppModel` (`musicLibrary`); backed by the configured
/// `NavidromeClient`. Ratings are the shared signal an external pipeline reads, so
/// every like/rating change persists on the server.
@MainActor
@Observable
public final class MusicLibraryStore {
    public private(set) var searchResults = NavidromeSearchResults.empty
    public private(set) var albums: [NavidromeAlbum] = []
    public private(set) var artists: [NavidromeArtist] = []
    public private(set) var starred = NavidromeSearchResults.empty
    public private(set) var playlists: [NavidromePlaylist] = []
    public private(set) var genres: [NavidromeGenre] = []

    public var albumSort: AlbumSort = .newest
    public private(set) var isLoading = false
    /// Last user-facing error (rating write failure, load failure). Cleared on the
    /// next successful action; surfaced by the UI as a transient notice.
    public var lastError: String?

    /// Optimistic like/rating overrides keyed by item id — decouples a rating tap
    /// from whichever collection the song currently lives in (search, starred,
    /// album detail, …). Views read `ratingState(for:)`.
    public private(set) var ratingOverrides: [String: MusicRatingState] = [:]

    private let clientProvider: () throws -> NavidromeClient

    public init(clientProvider: @escaping () throws -> NavidromeClient = { try NavidromeConfig.makeClient() }) {
        self.clientProvider = clientProvider
    }

    /// Demo mode: the library is served from content bundled in the app rather
    /// than a server. Set by seeding, and checked by every load so a demo session
    /// never reaches for a Navidrome that isn't there.
    ///
    /// This exists because the app is useless without a server — App Review opens
    /// it, sees a connect screen, and has nothing to connect to. Seeding the real
    /// store (rather than adding a parallel demo code path) means every screen,
    /// the player and the agent all work unchanged.
    public private(set) var isDemo = false

    /// Demo cover art, keyed by the id the views ask for. Local files, since a demo
    /// session has no server to fetch artwork from.
    private var demoArtwork: [String: URL] = [:]

    /// Every bundled track. Kept separate from `starred` so the demo doesn't have to
    /// pretend its whole catalogue is "Liked" just to have somewhere to live.
    public private(set) var demoSongs: [NavidromeSong] = []

    /// Fills the library from a bundled catalogue and switches to demo mode.
    ///
    /// `liked` is the subset to show under Liked — a couple of tracks, so that screen
    /// demonstrates the feature instead of being an empty dead end.
    public func seedDemo(
        songs: [NavidromeSong],
        albums: [NavidromeAlbum],
        liked: [NavidromeSong] = [],
        artwork: [String: URL] = [:]
    ) {
        isDemo = true
        demoArtwork = artwork
        demoSongs = songs
        self.albums = albums
        starred = NavidromeSearchResults(songs: liked, albums: [], artists: [])
        searchResults = .empty
        // Derive the artist list from the bundle. Leaving it empty made the Artists
        // screen a dead end in demo mode — the browse path a reviewer is most likely
        // to try after the album grid.
        artists = Set(songs.compactMap(\.artist)).sorted().map { name in
            var artist = NavidromeArtist(id: "demo-artist-\(name)", name: name)
            artist.albumCount = albums.filter { $0.artist == name }.count
            artist.coverArtID = songs.first { $0.artist == name }?.coverArtID
            return artist
        }
        playlists = []
        isLoading = false
        lastError = nil
    }

    /// Leaves demo mode and empties everything the demo put there.
    public func exitDemo() {
        isDemo = false
        demoArtwork = [:]
        demoSongs = []
        albums = []
        starred = .empty
        searchResults = .empty
    }

    /// The bundled tracks belonging to a demo artist id (`demo-artist-<name>`).
    private func demoSongsForArtist(_ id: String) -> [NavidromeSong] {
        guard let name = artists.first(where: { $0.id == id })?.name else { return [] }
        return demoSongs.filter { $0.artist == name }
    }

    /// Demo-mode search: filter the bundled catalogue, since there is no server.
    private func searchDemo(_ query: String) {
        let needle = NavidromeClient.foldedForSearch(query).lowercased()
        guard !needle.isEmpty else { searchResults = .empty; return }
        let songs = demoSongs.filter {
            let hay = NavidromeClient.foldedForSearch("\($0.title) \($0.artist ?? "") \($0.album ?? "")").lowercased()
            return hay.contains(needle)
        }
        searchResults = NavidromeSearchResults(
            songs: songs,
            albums: albums.filter { NavidromeClient.foldedForSearch($0.name).lowercased().contains(needle) },
            artists: []
        )
    }

    public var isConfigured: Bool {
        NavidromeConfig.isConfigured
    }

    // MARK: - Cover art (render-safe — no per-call Keychain read)

    /// Cached credentials so `coverArtURL` doesn't read the Keychain on every
    /// SwiftUI render. `NavidromeConfig.credentials()` hits `SecItemCopyMatching`
    /// (slow), and cover art is requested once per visible row/card each render —
    /// calling it inline stalls the main thread. Resolved once, then reused.
    @ObservationIgnored private var cachedCredentials: NavidromeCredentials?
    @ObservationIgnored private var credentialsResolved = false
    /// Built cover-art URLs keyed by "id#size". Cached so the URL is STABLE across
    /// renders — the signed URL contains a fresh salt each build, so without this
    /// `AsyncImage` would treat every render as a new URL and refetch the image.
    @ObservationIgnored private var coverURLCache: [String: URL] = [:]

    /// A signed cover-art URL, safe to call during view rendering: no Keychain
    /// access after the first resolve, and a stable URL per id+size so images load
    /// once instead of on every frame.
    public func coverArtURL(id: String, size: Int? = nil) -> URL? {
        if isDemo { return demoArtwork[id] }
        let key = "\(id)#\(size ?? 0)"
        if let cached = coverURLCache[key] { return cached }
        if !credentialsResolved {
            cachedCredentials = NavidromeConfig.credentials()
            credentialsResolved = true
        }
        guard let credentials = cachedCredentials else { return nil }
        let url = NavidromeClient(credentials: credentials).coverArtURL(id: id, size: size)
        if let url { coverURLCache[key] = url }
        return url
    }

    /// Forgets the cached connection + cover URLs — call after connect/disconnect.
    public func refreshConnection() {
        credentialsResolved = false
        cachedCredentials = nil
        coverURLCache.removeAll()
    }

    /// The active server changed: every browse result and optimistic rating override was sourced
    /// from the *previous* server (Subsonic ids, playlists, and stars are all per-server), so drop
    /// them before the caller reloads from the new one — otherwise a switch shows the old server's
    /// albums/artists/playlists until each view happens to refetch. Also forgets the cached
    /// connection (`refreshConnection`). `lastError` is cleared so a failure from
    /// the old server doesn't linger over the new connection. `albumSort` is a user preference, kept.
    public func resetForServerChange() {
        searchResults = .empty
        albums = []
        artists = []
        starred = .empty
        playlists = []
        genres = []
        ratingOverrides.removeAll()
        lastError = nil
        refreshConnection()
    }

    // MARK: - Rating state

    /// The effective like/rating for a song — an optimistic override if present,
    /// else the value the server last returned on the model.
    public func ratingState(for song: NavidromeSong) -> MusicRatingState {
        ratingOverrides[song.id] ?? MusicRatingState(isLiked: song.isLiked, userRating: song.userRating)
    }

    public func isLiked(_ song: NavidromeSong) -> Bool {
        ratingState(for: song).isLiked
    }

    public func rating(_ song: NavidromeSong) -> Int {
        ratingState(for: song).userRating ?? 0
    }

    /// Star rating (0–5) for any rateable entity by id (song / album), honoring an
    /// optimistic override, else the entity's own `userRating`.
    public func rating(id: String, userRating: Int?) -> Int {
        ratingOverrides[id]?.userRating ?? userRating ?? 0
    }

    /// Set the star rating for any entity id. Optimistic; reverts on failure.
    /// `userRating`/`isLiked` seed the pre-change baseline for the revert.
    public func setRating(id: String, userRating: Int?, isLiked: Bool, rating: Int) async {
        let clamped = max(0, min(rating, 5))
        let baseline = ratingOverrides[id] ?? MusicRatingState(isLiked: isLiked, userRating: userRating)
        ratingOverrides[id] = MusicRatingState(isLiked: baseline.isLiked, userRating: clamped == 0 ? nil : clamped)
        do {
            try await clientProvider().setRating(id: id, rating: clamped)
        } catch {
            ratingOverrides[id] = baseline
            reportFailure(error)
        }
    }

    // MARK: - Search + browse

    public func search(_ query: String) async {
        if isDemo { searchDemo(query); return }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { searchResults = .empty; return }
        await run { client in self.searchResults = try await client.search3(
            query: trimmed,
            songCount: 50,
            albumCount: 30,
            artistCount: 30
        ) }
    }

    /// Subsonic caps a getAlbumList2 page at 500; a big library has more, so we page through
    /// them all instead of silently showing an arbitrary (sort-dependent) 500.
    static let albumPageSize = 500
    static let albumFetchCeiling = 20_000 // safety bound for a pathological library

    public func loadAlbums() async {
        if isDemo { return }   // already seeded from the bundle

        let sort = albumSort
        await run { client in
            var all: [NavidromeAlbum] = []
            var offset = 0
            while true {
                let page = try await client.getAlbumList2(type: sort.apiType, size: Self.albumPageSize, offset: offset)
                all.append(contentsOf: page)
                if page.count < Self.albumPageSize || all.count >= Self.albumFetchCeiling { break }
                offset += Self.albumPageSize
            }
            if let comparator = sort.clientComparator { all.sort(by: comparator) }
            self.albums = all
        }
    }

    public func loadArtists() async {
        if isDemo { return }

        await run { client in self.artists = try await client.getArtists() }
    }

    public func loadStarred() async {
        if isDemo { return }

        await run { client in self.starred = try await client.getStarred2() }
    }

    public func loadPlaylists() async {
        if isDemo { return }

        await run { client in self.playlists = try await client.getPlaylists() }
    }

    /// Force-refetch every core collection — the ⌘R "Refresh Library" path, for a server whose
    /// content changed underneath an open Baton. Runs concurrently; each `load*` reconciles its store.
    public func reloadAll() async {
        async let albums: Void = loadAlbums()
        async let artists: Void = loadArtists()
        async let playlists: Void = loadPlaylists()
        async let starred: Void = loadStarred()
        _ = await (albums, artists, playlists, starred)
    }

    public func loadGenres() async {
        if isDemo {
            // Derive the genre list from the bundle rather than reaching for a server.
            let names = Set(demoSongs.compactMap(\.genre))
            genres = names.sorted().map { name in
                NavidromeGenre(name: name,
                               songCount: demoSongs.filter { $0.genre == name }.count,
                               albumCount: 1)
            }
            return
        }
        await run { client in self.genres = try await client.getGenres() }
    }

    /// Songs in a genre — powers the per-genre "Daily Mix" cards.
    public func songsByGenre(_ genre: String, count: Int = 60) async -> [NavidromeSong] {
        if isDemo { return demoSongs.filter { $0.genres.contains(genre) || $0.genre == genre } }
        return await (try? clientProvider().getSongsByGenre(genre, count: count)) ?? []
    }

    public func artistAlbums(id: String) async -> [NavidromeAlbum] {
        if isDemo { return albums }
        return await (try? clientProvider().getArtistAlbums(id: id)) ?? []
    }

    public func albumSongs(id: String) async -> [NavidromeSong] {
        if isDemo { return demoSongs.filter { $0.albumID == id } }
        return await (try? clientProvider().getAlbum(id: id)) ?? []
    }

    /// Aggregate stats for an artist (album/track counts + total seconds), summed from
    /// the artist's albums. Cached per id so the dense Artists list can lazy-load stats
    /// for visible rows without refetching.
    public struct ArtistStats: Equatable, Sendable {
        public var albums: Int
        public var tracks: Int
        public var seconds: Int
        /// A representative cover-art id (first album that has one) — the real artwork
        /// to show for the artist when the server's artist portrait is a placeholder.
        public var coverArtID: String?
    }

    @ObservationIgnored private var artistStatsCache: [String: ArtistStats] = [:]

    public func artistStats(id: String) async -> ArtistStats {
        if isDemo {
            let mine = demoSongsForArtist(id)
            return ArtistStats(albums: albums.count, tracks: mine.count,
                               seconds: mine.reduce(0) { $0 + ($1.duration ?? 0) },
                               coverArtID: mine.first?.coverArtID)
        }
        if let cached = artistStatsCache[id] { return cached }
        let albums = await artistAlbums(id: id)
        let stats = ArtistStats(
            albums: albums.count,
            tracks: albums.reduce(0) { $0 + ($1.songCount ?? 0) },
            seconds: albums.reduce(0) { $0 + ($1.duration ?? 0) },
            coverArtID: albums.first(where: { $0.coverArtID != nil })?.coverArtID
        )
        artistStatsCache[id] = stats
        return stats
    }

    /// Every song by an artist, in album order — for Play all / Queue / Save-as-playlist
    /// / Mark-all-for-removal. Sequential per album (kept simple; called on demand).
    public func artistSongs(id: String) async -> [NavidromeSong] {
        if isDemo { return demoSongsForArtist(id) }
        let albums = await artistAlbums(id: id)
        var songs: [NavidromeSong] = []
        for album in albums { songs.append(contentsOf: await albumSongs(id: album.id)) }
        return songs
    }

    /// Biography + portrait for an artist (`getArtistInfo2`), nil on failure.
    public func artistInfo(id: String) async -> NavidromeArtistInfo? {
        // No biography to fetch without a server; nil renders as "no bio", not an error.
        if isDemo { return nil }
        return try? await clientProvider().getArtistInfo(id: id)
    }

    /// Whether the artist is in the user's starred ("followed") set. Reads the
    /// already-loaded `starred` list — call `loadStarred()` first if it's empty.
    public func isArtistFollowed(id: String) -> Bool {
        starred.artists.contains { $0.id == id }
    }

    /// Follow / unfollow (star / unstar) an artist on the server, then refresh
    /// the starred set so `isArtistFollowed` stays accurate.
    public func setArtistFollowed(id: String, followed: Bool) async {
        do {
            let client = try clientProvider()
            if followed { try await client.star(id: id) } else { try await client.unstar(id: id) }
            await loadStarred()
        } catch {
            reportFailure(error)
        }
    }

    public func playlist(id: String) async -> NavidromePlaylist? {
        try? await clientProvider().getPlaylist(id: id)
    }

    /// Structured/synced lyrics for a song (nil when the server has none).
    public func lyrics(for songID: String) async -> NavidromeLyrics? {
        await (try? clientProvider().getLyrics(songID: songID)) ?? nil
    }

    /// The folder tree's roots — the file system's opinion of the library, for people
    /// whose collections are organized that way on disk. Empty in demo mode and on
    /// failure alike; the Folders screen states its own empty case.
    public func folderRoots() async -> [NavidromeFolder] {
        guard !isDemo, let client = try? clientProvider() else { return [] }
        return (try? await client.getIndexes()) ?? []
    }

    /// One folder's contents, or nil when the server can't answer.
    public func directory(id: String) async -> NavidromeDirectory? {
        guard !isDemo, let client = try? clientProvider() else { return nil }
        return try? await client.getMusicDirectory(id: id)
    }

    /// Songs similar to a seed (song or artist id) — powers radio/discovery.
    public func similarSongs(seedID: String) async -> [NavidromeSong] {
        if isDemo { return demoSongs.filter { $0.id != seedID }.shuffled() }
        guard let client = try? clientProvider() else { return [] }
        // Prefer true "similar" tracks. Many self-hosted Navidrome servers have no Last.fm agent,
        // so getSimilarSongs2 returns nothing — fall back to random library tracks so autoplay
        // ("continuous radio") keeps playing instead of stopping at the queue's end. (autoplay fix)
        let similar = (try? await client.getSimilarSongs(id: seedID)) ?? []
        if !similar.isEmpty { return similar }
        return (try? await client.getRandomSongs()) ?? []
    }

    /// A one-off album list of a given `getAlbumList2` kind (newest / random / frequent …),
    /// returned directly without touching the browse `albums` state — for Home shelves.
    public func albums(type: String, size: Int = 14) async -> [NavidromeAlbum] {
        if isDemo { return albums }
        return await (try? clientProvider().getAlbumList2(type: type, size: size)) ?? []
    }

    /// Lifetime top tracks **from the server**, so the ranking counts every device.
    ///
    /// This is the cross-device half of listening history and it needs no infrastructure:
    /// Navidrome already keeps a per-user `playCount` on every song, fed by whichever
    /// client scrobbled it. A phone's local log only knows what that phone played, which
    /// is why "my top tracks" used to differ between a Mac and an iPhone belonging to the
    /// same person.
    ///
    /// The limit is that Subsonic exposes a running *count* and a last-played timestamp,
    /// not an event log — so this can answer "most played ever", and cannot answer "most
    /// played this week". Time-windowed stats stay local, and the UI says which is which.
    public func serverTopSongs(limit: Int = 50) async -> [NavidromeSong] {
        if isDemo { return demoSongs.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) } }
        guard let client = try? clientProvider() else { return [] }
        // `frequent` is the server's own most-played ordering; taking songs from those
        // albums and re-sorting by per-song count turns an album ranking into a track one.
        let albums = (try? await client.getAlbumList2(type: "frequent", size: 20)) ?? []
        var songs: [NavidromeSong] = []
        var seen = Set<String>()
        for album in albums {
            for song in await albumSongs(id: album.id) where seen.insert(song.id).inserted {
                songs.append(song)
            }
        }
        return Array(
            songs.filter { ($0.playCount ?? 0) > 0 }
                .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
                .prefix(limit)
        )
    }

    /// Songs gathered from the first albums of a `getAlbumList2` list (newest / highest /
    /// frequent / random) — the basis for the auto "Made for You" mixes. Deduped; capped
    /// so a mix is a few dozen tracks, not the whole library.
    public func mixSongs(type: String, albumLimit: Int = 14, songLimit: Int = 60) async -> [NavidromeSong] {
        // The demo catalogue *is* the library, so every "kind" of mix draws from it.
        // Shuffled, so the cards still differ from one another.
        if isDemo { return demoSongs.shuffled() }
        guard let client = try? clientProvider() else { return [] }
        let albums = (try? await client.getAlbumList2(type: type, size: albumLimit)) ?? []
        var songs: [NavidromeSong] = []
        var seen = Set<String>()
        for album in albums {
            for song in await albumSongs(id: album.id) where seen.insert(song.id).inserted {
                songs.append(song)
            }
            if songs.count >= songLimit { break }
        }
        return Array(songs.prefix(songLimit))
    }

    // MARK: - Ratings (optimistic + server write + revert)

    public func toggleLike(_ song: NavidromeSong) async {
        let current = ratingState(for: song)
        let next = MusicRatingState(isLiked: !current.isLiked, userRating: current.userRating)
        ratingOverrides[song.id] = next
        do {
            let client = try clientProvider()
            if next.isLiked { try await client.star(id: song.id) } else { try await client.unstar(id: song.id) }
        } catch {
            ratingOverrides[song.id] = current // revert
            reportFailure(error)
        }
    }

    /// The effective like state for any starrable entity by id (album / artist / song) — an
    /// optimistic override if present, else the entity's own snapshot.
    public func isLiked(id: String, isLiked: Bool) -> Bool {
        ratingOverrides[id]?.isLiked ?? isLiked
    }

    /// Toggle like for any starrable entity by id (album / artist / song). Updates the optimistic
    /// `@Observable` override so the heart flips at once, then stars/unstars on the server
    /// (reverting on failure). `currentLiked`/`userRating` seed the baseline when no override exists.
    public func toggleLike(id: String, currentLiked: Bool, userRating: Int?) async {
        let base = ratingOverrides[id] ?? MusicRatingState(isLiked: currentLiked, userRating: userRating)
        let next = MusicRatingState(isLiked: !base.isLiked, userRating: base.userRating)
        ratingOverrides[id] = next
        do {
            let client = try clientProvider()
            if next.isLiked { try await client.star(id: id) } else { try await client.unstar(id: id) }
        } catch {
            ratingOverrides[id] = base // revert
            reportFailure(error)
        }
    }

    public func setRating(_ song: NavidromeSong, rating: Int) async {
        let clamped = max(0, min(rating, 5))
        let current = ratingState(for: song)
        ratingOverrides[song.id] = MusicRatingState(isLiked: current.isLiked, userRating: clamped == 0 ? nil : clamped)
        do {
            try await clientProvider().setRating(id: song.id, rating: clamped)
        } catch {
            ratingOverrides[song.id] = current // revert
            reportFailure(error)
        }
    }

    /// "Delete" a track the only way Subsonic allows: unlike it and set the lowest
    /// rating (1), the server-side signal an external pipeline reads to prune it.
    /// (There is no delete-file API.) Optimistic, reverts on failure.
    public func markForRemoval(_ song: NavidromeSong) async {
        let current = ratingState(for: song)
        ratingOverrides[song.id] = MusicRatingState(isLiked: false, userRating: 1)
        do {
            let client = try clientProvider()
            try await client.setRating(id: song.id, rating: 1)
            if current.isLiked { try await client.unstar(id: song.id) }
        } catch {
            ratingOverrides[song.id] = current // revert
            reportFailure(error)
        }
    }

    /// Pull the current server-side like + rating for one song and seed the
    /// override, so the now-playing display reflects the server after a relaunch
    /// (the persisted queue only carries a stale snapshot, and overrides don't
    /// persist). Silent on failure — a stale display is better than a visible error.
    public func refreshRating(for song: NavidromeSong) async {
        guard let client = try? clientProvider() else { return }
        guard let fresh = try? await client.getSong(id: song.id) else { return }
        ratingOverrides[song.id] = MusicRatingState(isLiked: fresh.isLiked, userRating: fresh.userRating)
    }

    // MARK: - Playlist CRUD

    @discardableResult
    public func createPlaylist(name: String, songIDs: [String] = []) async -> NavidromePlaylist? {
        do {
            let playlist = try await clientProvider().createPlaylist(name: name, songIDs: songIDs)
            await loadPlaylists()
            return playlist
        } catch {
            reportFailure(error)
            return nil
        }
    }

    public func renamePlaylist(id: String, to name: String) async {
        await mutatePlaylist { try await $0.updatePlaylist(id: id, name: name) }
    }

    public func setPlaylistPublic(id: String, isPublic: Bool) async {
        await mutatePlaylist { try await $0.updatePlaylist(id: id, isPublic: isPublic) }
    }

    /// Adds `songIDs` to a playlist, skipping tracks already present (Subsonic's append
    /// otherwise creates duplicates). Returns the number actually added (0 = all were
    /// already there).
    @discardableResult
    public func addToPlaylist(id: String, songIDs: [String]) async -> Int {
        var added = 0
        await mutatePlaylist { client in
            let existing = Set(((try? await client.getPlaylist(id: id))?.songs ?? []).map(\.id))
            let fresh = songIDs.filter { !existing.contains($0) }
            guard !fresh.isEmpty else { return }
            // Add in chunks so a large bulk-add stays well under the GET URL length limit.
            for start in stride(from: 0, to: fresh.count, by: 100) {
                let chunk = Array(fresh[start ..< min(start + 100, fresh.count)])
                try await client.updatePlaylist(id: id, songIDsToAdd: chunk)
                added += chunk.count
            }
        }
        return added
    }

    public func removeFromPlaylist(id: String, indexes: [Int]) async {
        await mutatePlaylist { try await $0.updatePlaylist(id: id, songIndexesToRemove: indexes) }
    }

    /// Persist a drag-reorder: overwrite the playlist's tracks with `songIDs` in this order,
    /// preserving the title (passed to the overwrite) and re-asserting the shared flag
    /// afterwards (the `createPlaylist` overwrite doesn't carry it).
    public func reorderPlaylist(id: String, songIDs: [String], name: String?, isPublic: Bool) async {
        await mutatePlaylist { client in
            try await client.setPlaylistSongsChunked(id: id, songIDs: songIDs, name: name)
            try await client.updatePlaylist(id: id, isPublic: isPublic)
        }
    }

    public func deletePlaylist(id: String) async {
        do {
            try await clientProvider().deletePlaylist(id: id)
            playlists.removeAll { $0.id == id }
        } catch {
            reportFailure(error)
        }
    }

    // MARK: - Helpers

    private func mutatePlaylist(_ body: @escaping (NavidromeClient) async throws -> Void) async {
        do {
            try await body(clientProvider())
            await loadPlaylists()
        } catch {
            reportFailure(error)
        }
    }

    private func run(_ body: @escaping (NavidromeClient) async throws -> Void) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try clientProvider()
            try await body(client)
            lastError = nil
        } catch {
            reportFailure(error)
        }
    }

    private func reportFailure(_ error: any Error) {
        let message = (error as? NavidromeError)?.errorDescription ?? error.localizedDescription
        musicStoreLog.error("\(message, privacy: .public)")
        lastError = message
    }
}
