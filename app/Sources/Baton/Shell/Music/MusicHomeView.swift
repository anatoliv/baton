import SwiftUI

/// Home shelf cards match the browse grids' card width so a card looks the same size here as
/// on Albums/Artists/etc. (those grids use `adaptive(minimum: 220)`).
private let homeShelfCardWidth: CGFloat = 210

/// The **Home** tab — a "For You" landing surface that composes what we already know about
/// the library and the user's listening into tap-to-play shelves: recently played, a
/// "because you liked X" radio seed, freshly added + random-rediscovery albums, and the
/// auto-mixes. Read-only over the existing stores; every card routes through `music.play`.
struct MusicHomeView: View {
    @Environment(MusicModel.self) private var model
    // Optional so Home still renders in contexts without the router (e.g. snapshot tests).
    @Environment(BatonCommandRouter.self) private var router: BatonCommandRouter?

    @State private var recentlyAdded: [NavidromeAlbum] = []
    @State private var rediscover: [NavidromeAlbum] = []
    @State private var likedSeed: NavidromeSong?
    @State private var becauseYouLiked: [NavidromeSong] = []
    @State private var loaded = false
    /// When the "Because you liked" seed was last chosen (reference-date seconds), so it rotates on
    /// a long-running session instead of being frozen until relaunch.
    @AppStorage("baton.home.seedAt") private var seedAtRef: Double = 0

    private var recentlyPlayed: [NavidromeSong] { Array(model.musicHistory.recentlyPlayed.prefix(18)) }
    private var mixes: [MusicMix] { MusicMixCatalog.auto(model) }

    private var isEmpty: Bool {
        recentlyPlayed.isEmpty && recentlyAdded.isEmpty && rediscover.isEmpty
            && becauseYouLiked.isEmpty && continueListening.isEmpty
    }

    /// A podcast episode you started but didn't finish. Reduced to what the shelf actually needs —
    /// a playable song plus its show, for the queue source — so that episodes from *both* podcast
    /// backends (client RSS subscriptions and server-side channels) render through one path.
    private struct ContinueEpisode: Identifiable {
        let id: String
        let song: NavidromeSong
        let showTitle: String
        let showID: String
    }

    /// In-progress podcast episodes, newest-listened first — the "Continue listening" source.
    /// Client episodes are joined against the subscribed feeds; server episodes come from the
    /// registry `PodcastProgressStore` keeps (their ids look like library tracks, so they can't be
    /// recognised from the id alone). Both are ranked by the same last-played order.
    private var continueListening: [ContinueEpisode] {
        let ids = model.podcastProgress.inProgressIDs()
        guard !ids.isEmpty else { return [] }
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ContinueEpisode] = []
        for channel in model.podcastSubscriptions.channels {
            for episode in channel.episodes where rank[episode.enclosureURL.absoluteString] != nil {
                out.append(ContinueEpisode(
                    id: episode.enclosureURL.absoluteString,
                    song: episode.asSong(
                        channelTitle: channel.title, artwork: episode.imageURL ?? channel.imageURL),
                    showTitle: channel.title,
                    showID: channel.id
                ))
            }
        }
        for episode in model.podcastProgress.inProgressServerEpisodes() {
            out.append(ContinueEpisode(
                id: episode.id,
                song: NavidromeSong(
                    id: episode.id,
                    title: episode.title,
                    artist: episode.channel,
                    album: episode.channel,
                    albumID: nil,
                    duration: episode.duration.map { Int($0) },
                    coverArtID: episode.coverArtID
                ),
                showTitle: episode.channel,
                showID: episode.channel
            ))
        }
        return Array(out.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }.prefix(12))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(greeting).font(.title3.weight(.semibold))
                Spacer()
            }
            // Match the shared browse header (Search/Mixes): .title3 semibold at 12 / 8 / 4,
            // and the same row height (its filter field) so the title centers at the same Y.
            .frame(height: 28)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !continueListening.isEmpty { continueShelf }
                    if !recentlyPlayed.isEmpty {
                        songShelf("Jump back in", recentlyPlayed, seeAll: .history) { song in
                            playFrom(recentlyPlayed, seed: song, label: "Jump back in")
                        }
                    }
                    if let seed = likedSeed, !becauseYouLiked.isEmpty {
                        let label = "Because you liked \(seed.artist ?? seed.title)"
                        songShelf(label, becauseYouLiked) { song in
                            playFrom(becauseYouLiked, seed: song, label: label, kind: .radio)
                        }
                    }
                    if !recentlyAdded.isEmpty { albumShelf("Recently added", recentlyAdded, seeAll: .albums) }
                    if !rediscover.isEmpty { albumShelf("Rediscover", rediscover, seeAll: .albums) }
                    mixShelf
                    if isEmpty, loaded { emptyState }
                }
                .padding(.vertical, 18)
            }
        }
        .task { await loadIfNeeded() }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5 ..< 12: "Good morning"
        case 12 ..< 17: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: - Shelves

    /// A shelf header title, with an optional "See All" that jumps to the matching sidebar tab.
    @ViewBuilder
    private func shelfHeader(_ title: String, seeAll: MusicView.MusicTab?) -> some View {
        HStack {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            if let seeAll {
                Button("See All") { router?.pendingTab = seeAll }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func songShelf(_ title: String, _ songs: [NavidromeSong], seeAll: MusicView.MusicTab? = nil, onPlay: @escaping (NavidromeSong) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader(title, seeAll: seeAll)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(songs) { song in
                        SongShelfCard(song: song) { onPlay(song) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [NavidromeAlbum], seeAll: MusicView.MusicTab? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader(title, seeAll: seeAll)
            ScrollView(.horizontal, showsIndicators: false) {
                // Reuse the exact Albums-page cell — same card, track count + total time,
                // hover-play, tap-to-open, context menu.
                HStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        AlbumGridCell(album: album).frame(width: homeShelfCardWidth)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
    }

    /// "Continue listening" — resume a partially-heard podcast episode (the play path restores the
    /// saved position by episode id). Placed first on Home since it's the most actionable shelf.
    @ViewBuilder
    private var continueShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader("Continue listening", seeAll: .podcasts)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(continueListening) { item in
                        SongShelfCard(song: item.song) {
                            model.music.play(
                                [item.song],
                                source: .init(label: item.showTitle, kind: .playlist, id: item.showID)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var mixShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader("Your Mixes", seeAll: .mixes)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(mixes) { mix in
                        MusicMixCard(mix: mix).frame(width: homeShelfCardWidth)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.house").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Your Home fills in as you listen").font(.headline)
            Text("Play a few tracks and browse your library — recently played, mixes, and picks show up here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 40).padding(.horizontal, 40)
    }

    // MARK: - Data

    private func loadIfNeeded() async {
        // Seed for "Because you liked" — a most-played / recent / liked track. Recomputed when
        // unset or when the last pick is over 6 hours old, so a long session's Home doesn't freeze.
        let now = Date().timeIntervalSinceReferenceDate
        let seedStale = seedAtRef == 0 || now - seedAtRef > 6 * 3600
        if likedSeed == nil || seedStale {
            let seed = model.musicHistory.topTracks(since: .distantPast).first?.song
                ?? model.musicHistory.recentlyPlayed.first
                ?? model.musicLibrary.starred.songs.first
            if let seed {
                likedSeed = seed
                becauseYouLiked = await model.musicLibrary.similarSongs(seedID: seed.id)
                seedAtRef = now
            }
        }
        if recentlyAdded.isEmpty { recentlyAdded = await model.musicLibrary.albums(type: "newest", size: 16) }
        if rediscover.isEmpty { rediscover = await model.musicLibrary.albums(type: "random", size: 16) }
        // The mix shelf's "Forgotten favorites" needs the starred set loaded.
        if model.musicLibrary.starred.songs.isEmpty { await model.musicLibrary.loadStarred() }
        loaded = true
    }

    // MARK: - Playback

    private func playFrom(
        _ songs: [NavidromeSong], seed: NavidromeSong, label: String,
        kind: StreamingPlaybackController.QueueSource.Kind = .search
    ) {
        let index = songs.firstIndex(of: seed) ?? 0
        model.music.play(songs, startAt: index, source: .init(label: label, kind: kind, id: nil))
    }
}

// MARK: - Cards

/// A track card for the Home song shelves — same `MusicMediaCard` and width as the album
/// cards, showing the track's play time. (Track count doesn't apply to a single song.)
private struct SongShelfCard: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    let onPlay: () -> Void
    @State private var hover = false

    private var playTime: String? {
        guard let seconds = song.duration, seconds > 0 else { return nil }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var isCurrent: Bool { model.music.nowPlaying?.id == song.id }

    var body: some View {
        MusicMediaCard(
            coverURL: song.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 400) },
            placeholder: "music.note",
            title: song.title,
            subtitle: [song.displayArtistName, song.genres.first ?? song.genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            trailingTop: song.qualityLabel,
            trailingBottom: playTime,
            isHovering: hover,
            isSelected: isCurrent,
            isPlaying: isCurrent && model.music.isPlaying,
            onPlay: onPlay
        )
        .frame(width: homeShelfCardWidth)
        .onHover { hover = $0 }
    }
}
