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

    @State private var recentlyAdded: [NavidromeAlbum] = []
    @State private var rediscover: [NavidromeAlbum] = []
    @State private var likedSeed: NavidromeSong?
    @State private var becauseYouLiked: [NavidromeSong] = []
    @State private var loaded = false

    private var recentlyPlayed: [NavidromeSong] { Array(model.musicHistory.recentlyPlayed.prefix(18)) }
    private var mixes: [MusicMix] { MusicMixCatalog.auto(model) }

    private var isEmpty: Bool {
        recentlyPlayed.isEmpty && recentlyAdded.isEmpty && rediscover.isEmpty && becauseYouLiked.isEmpty
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
                    if !recentlyPlayed.isEmpty {
                        songShelf("Jump back in", recentlyPlayed) { song in
                            playFrom(recentlyPlayed, seed: song, label: "Jump back in")
                        }
                    }
                    if let seed = likedSeed, !becauseYouLiked.isEmpty {
                        let label = "Because you liked \(seed.artist ?? seed.title)"
                        songShelf(label, becauseYouLiked) { song in
                            playFrom(becauseYouLiked, seed: song, label: label, kind: .radio)
                        }
                    }
                    if !recentlyAdded.isEmpty { albumShelf("Recently added", recentlyAdded) }
                    if !rediscover.isEmpty { albumShelf("Rediscover", rediscover) }
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

    @ViewBuilder
    private func songShelf(_ title: String, _ songs: [NavidromeSong], onPlay: @escaping (NavidromeSong) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, 16)
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
    private func albumShelf(_ title: String, _ albums: [NavidromeAlbum]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, 16)
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

    @ViewBuilder
    private var mixShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Mixes").font(.title3.weight(.semibold)).padding(.horizontal, 16)
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
        // Seed for "Because you liked" — a most-played / recent / liked track.
        if likedSeed == nil {
            let seed = model.musicHistory.topTracks(since: .distantPast).first?.song
                ?? model.musicHistory.recentlyPlayed.first
                ?? model.musicLibrary.starred.songs.first
            if let seed {
                likedSeed = seed
                becauseYouLiked = await model.musicLibrary.similarSongs(seedID: seed.id)
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

    var body: some View {
        MusicMediaCard(
            coverURL: song.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 400) },
            placeholder: "music.note",
            title: song.title,
            subtitle: [song.displayArtistName, song.genres.first ?? song.genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            trailingTop: song.qualityLabel,
            trailingBottom: playTime,
            isHovering: hover,
            isPlayingSource: model.music.nowPlaying?.id == song.id,
            onPlay: onPlay
        )
        .frame(width: homeShelfCardWidth)
        .onHover { hover = $0 }
    }
}
