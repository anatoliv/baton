import Foundation
import Observation
import OSLog

private let musicStoreLog = Logger(subsystem: "io.tonebox.baton", category: "MusicLibrary")

/// How to sort/scope the Albums browse tab. Most map directly to a `getAlbumList2`
/// server sort; `tracks` and `duration` have no API equivalent, so they fetch a
/// name-sorted base list and re-order it client-side (see `clientComparator`).
enum AlbumSort: String, CaseIterable, Identifiable, MusicSortField {
    case newest, recent, frequent, name, artist, tracks, duration, starred, highest, random

    var id: String {
        rawValue
    }

    /// The Subsonic `getAlbumList2` `type` value to fetch with.
    var apiType: String {
        switch self {
        case .newest: "newest"
        case .recent: "recent"
        case .frequent: "frequent"
        case .starred: "starred"
        case .highest: "highest"
        case .random: "random"
        case .artist: "alphabeticalByArtist"
        // Name plus the client-sorted ones fetch an A→Z base list.
        case .name, .tracks, .duration: "alphabeticalByName"
        }
    }

    /// A client-side re-order applied after fetching (nil = keep server order).
    var clientComparator: ((NavidromeAlbum, NavidromeAlbum) -> Bool)? {
        switch self {
        case .name: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .tracks: { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        case .duration: { ($0.duration ?? 0) > ($1.duration ?? 0) }
        default: nil
        }
    }

    var label: String {
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
        }
    }
}

/// Optimistic like + rating state for one item, keyed by id.
struct MusicRatingState: Equatable {
    var isLiked: Bool
    var userRating: Int?
}

/// View-model for the full music player: search + browse state, the playlist list,
/// and optimistic like/rating + playlist mutations that write through to the
/// server. Owned by `AppModel` (`musicLibrary`); backed by the configured
/// `NavidromeClient`. Ratings are the shared signal an external pipeline reads, so
/// every like/rating change persists on the server.
@MainActor
@Observable
final class MusicLibraryStore {
    private(set) var searchResults = NavidromeSearchResults.empty
    private(set) var albums: [NavidromeAlbum] = []
    private(set) var artists: [NavidromeArtist] = []
    private(set) var starred = NavidromeSearchResults.empty
    private(set) var playlists: [NavidromePlaylist] = []
    private(set) var genres: [NavidromeGenre] = []

    var albumSort: AlbumSort = .newest
    private(set) var isLoading = false
    /// Last user-facing error (rating write failure, load failure). Cleared on the
    /// next successful action; surfaced by the UI as a transient notice.
    var lastError: String?

    /// Optimistic like/rating overrides keyed by item id — decouples a rating tap
    /// from whichever collection the song currently lives in (search, starred,
    /// album detail, …). Views read `ratingState(for:)`.
    private(set) var ratingOverrides: [String: MusicRatingState] = [:]

    private let clientProvider: () throws -> NavidromeClient

    init(clientProvider: @escaping () throws -> NavidromeClient = { try NavidromeConfig.makeClient() }) {
        self.clientProvider = clientProvider
    }

    var isConfigured: Bool {
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
    func coverArtURL(id: String, size: Int? = nil) -> URL? {
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
    func refreshConnection() {
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
    func resetForServerChange() {
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
    func ratingState(for song: NavidromeSong) -> MusicRatingState {
        ratingOverrides[song.id] ?? MusicRatingState(isLiked: song.isLiked, userRating: song.userRating)
    }

    func isLiked(_ song: NavidromeSong) -> Bool {
        ratingState(for: song).isLiked
    }

    func rating(_ song: NavidromeSong) -> Int {
        ratingState(for: song).userRating ?? 0
    }

    /// Star rating (0–5) for any rateable entity by id (song / album), honoring an
    /// optimistic override, else the entity's own `userRating`.
    func rating(id: String, userRating: Int?) -> Int {
        ratingOverrides[id]?.userRating ?? userRating ?? 0
    }

    /// Set the star rating for any entity id. Optimistic; reverts on failure.
    /// `userRating`/`isLiked` seed the pre-change baseline for the revert.
    func setRating(id: String, userRating: Int?, isLiked: Bool, rating: Int) async {
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

    func search(_ query: String) async {
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

    func loadAlbums() async {
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

    func loadArtists() async {
        await run { client in self.artists = try await client.getArtists() }
    }

    func loadStarred() async {
        await run { client in self.starred = try await client.getStarred2() }
    }

    func loadPlaylists() async {
        await run { client in self.playlists = try await client.getPlaylists() }
    }

    /// Force-refetch every core collection — the ⌘R "Refresh Library" path, for a server whose
    /// content changed underneath an open Baton. Runs concurrently; each `load*` reconciles its store.
    func reloadAll() async {
        async let albums: Void = loadAlbums()
        async let artists: Void = loadArtists()
        async let playlists: Void = loadPlaylists()
        async let starred: Void = loadStarred()
        _ = await (albums, artists, playlists, starred)
    }

    func loadGenres() async {
        await run { client in self.genres = try await client.getGenres() }
    }

    /// Songs in a genre — powers the per-genre "Daily Mix" cards.
    func songsByGenre(_ genre: String, count: Int = 60) async -> [NavidromeSong] {
        await (try? clientProvider().getSongsByGenre(genre, count: count)) ?? []
    }

    func artistAlbums(id: String) async -> [NavidromeAlbum] {
        await (try? clientProvider().getArtistAlbums(id: id)) ?? []
    }

    func albumSongs(id: String) async -> [NavidromeSong] {
        await (try? clientProvider().getAlbum(id: id)) ?? []
    }

    /// Aggregate stats for an artist (album/track counts + total seconds), summed from
    /// the artist's albums. Cached per id so the dense Artists list can lazy-load stats
    /// for visible rows without refetching.
    struct ArtistStats: Equatable {
        var albums: Int
        var tracks: Int
        var seconds: Int
        /// A representative cover-art id (first album that has one) — the real artwork
        /// to show for the artist when the server's artist portrait is a placeholder.
        var coverArtID: String?
    }

    @ObservationIgnored private var artistStatsCache: [String: ArtistStats] = [:]

    func artistStats(id: String) async -> ArtistStats {
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
    func artistSongs(id: String) async -> [NavidromeSong] {
        let albums = await artistAlbums(id: id)
        var songs: [NavidromeSong] = []
        for album in albums { songs.append(contentsOf: await albumSongs(id: album.id)) }
        return songs
    }

    /// Biography + portrait for an artist (`getArtistInfo2`), nil on failure.
    func artistInfo(id: String) async -> NavidromeArtistInfo? {
        try? await clientProvider().getArtistInfo(id: id)
    }

    /// Whether the artist is in the user's starred ("followed") set. Reads the
    /// already-loaded `starred` list — call `loadStarred()` first if it's empty.
    func isArtistFollowed(id: String) -> Bool {
        starred.artists.contains { $0.id == id }
    }

    /// Follow / unfollow (star / unstar) an artist on the server, then refresh
    /// the starred set so `isArtistFollowed` stays accurate.
    func setArtistFollowed(id: String, followed: Bool) async {
        do {
            let client = try clientProvider()
            if followed { try await client.star(id: id) } else { try await client.unstar(id: id) }
            await loadStarred()
        } catch {
            reportFailure(error)
        }
    }

    func playlist(id: String) async -> NavidromePlaylist? {
        try? await clientProvider().getPlaylist(id: id)
    }

    /// Structured/synced lyrics for a song (nil when the server has none).
    func lyrics(for songID: String) async -> NavidromeLyrics? {
        await (try? clientProvider().getLyrics(songID: songID)) ?? nil
    }

    /// Songs similar to a seed (song or artist id) — powers radio/discovery.
    func similarSongs(seedID: String) async -> [NavidromeSong] {
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
    func albums(type: String, size: Int = 14) async -> [NavidromeAlbum] {
        await (try? clientProvider().getAlbumList2(type: type, size: size)) ?? []
    }

    /// Songs gathered from the first albums of a `getAlbumList2` list (newest / highest /
    /// frequent / random) — the basis for the auto "Made for You" mixes. Deduped; capped
    /// so a mix is a few dozen tracks, not the whole library.
    func mixSongs(type: String, albumLimit: Int = 14, songLimit: Int = 60) async -> [NavidromeSong] {
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

    func toggleLike(_ song: NavidromeSong) async {
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
    func isLiked(id: String, isLiked: Bool) -> Bool {
        ratingOverrides[id]?.isLiked ?? isLiked
    }

    /// Toggle like for any starrable entity by id (album / artist / song). Updates the optimistic
    /// `@Observable` override so the heart flips at once, then stars/unstars on the server
    /// (reverting on failure). `currentLiked`/`userRating` seed the baseline when no override exists.
    func toggleLike(id: String, currentLiked: Bool, userRating: Int?) async {
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

    func setRating(_ song: NavidromeSong, rating: Int) async {
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
    func markForRemoval(_ song: NavidromeSong) async {
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
    func refreshRating(for song: NavidromeSong) async {
        guard let client = try? clientProvider() else { return }
        guard let fresh = try? await client.getSong(id: song.id) else { return }
        ratingOverrides[song.id] = MusicRatingState(isLiked: fresh.isLiked, userRating: fresh.userRating)
    }

    // MARK: - Playlist CRUD

    @discardableResult
    func createPlaylist(name: String, songIDs: [String] = []) async -> NavidromePlaylist? {
        do {
            let playlist = try await clientProvider().createPlaylist(name: name, songIDs: songIDs)
            await loadPlaylists()
            return playlist
        } catch {
            reportFailure(error)
            return nil
        }
    }

    func renamePlaylist(id: String, to name: String) async {
        await mutatePlaylist { try await $0.updatePlaylist(id: id, name: name) }
    }

    func setPlaylistPublic(id: String, isPublic: Bool) async {
        await mutatePlaylist { try await $0.updatePlaylist(id: id, isPublic: isPublic) }
    }

    /// Adds `songIDs` to a playlist, skipping tracks already present (Subsonic's append
    /// otherwise creates duplicates). Returns the number actually added (0 = all were
    /// already there).
    @discardableResult
    func addToPlaylist(id: String, songIDs: [String]) async -> Int {
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

    func removeFromPlaylist(id: String, indexes: [Int]) async {
        await mutatePlaylist { try await $0.updatePlaylist(id: id, songIndexesToRemove: indexes) }
    }

    /// Persist a drag-reorder: overwrite the playlist's tracks with `songIDs` in this order,
    /// preserving the title (passed to the overwrite) and re-asserting the shared flag
    /// afterwards (the `createPlaylist` overwrite doesn't carry it).
    func reorderPlaylist(id: String, songIDs: [String], name: String?, isPublic: Bool) async {
        await mutatePlaylist { client in
            try await client.setPlaylistSongsChunked(id: id, songIDs: songIDs, name: name)
            try await client.updatePlaylist(id: id, isPublic: isPublic)
        }
    }

    func deletePlaylist(id: String) async {
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
