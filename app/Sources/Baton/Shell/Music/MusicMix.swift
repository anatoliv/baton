import SwiftUI

/// One auto-generated "mix" — a gradient card with a title/subtitle/icon and a closure that
/// fetches its tracks on tap. Shared by the **Mixes** tab and the **Home** "Your Mixes"
/// shelf so both draw from a single definition.
struct MusicMix: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let songs: @MainActor () async -> [NavidromeSong]

    // Identity is the stable `id` (the `songs` closure isn't Hashable) — enough for a
    // NavigationLink to open the mix's detail page.
    static func == (lhs: MusicMix, rhs: MusicMix) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The catalog of standard mixes, built from the current library + play-history signals.
/// One source of truth for the Mixes tab and the Home shelf.
enum MusicMixCatalog {
    /// The six server + local-signal auto-mixes.
    @MainActor static func auto(_ model: MusicModel) -> [MusicMix] {
        [
            MusicMix(id: "mostPlayed", title: "Most Played", subtitle: "Your top tracks", icon: "flame.fill", color: .orange) {
                model.musicHistory.topTracks(since: .distantPast).map(\.song)
            },
            MusicMix(id: "recentlyAdded", title: "Fresh Additions", subtitle: "Newest in your library", icon: "sparkles", color: .green) {
                await model.musicLibrary.mixSongs(type: "newest")
            },
            MusicMix(id: "topRated", title: "Top Rated", subtitle: "Your highest-rated", icon: "star.fill", color: .yellow) {
                await model.musicLibrary.mixSongs(type: "highest")
            },
            MusicMix(id: "onRepeat", title: "On Repeat", subtitle: "Frequently played", icon: "repeat", color: .pink) {
                await model.musicLibrary.mixSongs(type: "frequent")
            },
            MusicMix(id: "forgotten", title: "Forgotten Favorites", subtitle: "Liked, not heard lately", icon: "heart.circle.fill", color: .red) {
                forgottenFavorites(model)
            },
            MusicMix(id: "discover", title: "Discover", subtitle: "A random shuffle", icon: "shuffle", color: .blue) {
                (await model.musicLibrary.mixSongs(type: "random")).shuffled()
            },
        ]
    }

    /// Per-genre "Daily Mix" cards — the user's top genres by song count.
    @MainActor static func genres(_ model: MusicModel) -> [MusicMix] {
        let palette: [Color] = [.purple, .teal, .indigo, .mint, .brown, .cyan, .orange, .pink]
        return model.musicLibrary.genres
            .filter { ($0.songCount ?? 0) > 0 }
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
            .prefix(12)
            .enumerated()
            .map { index, genre in
                MusicMix(id: "genre-\(genre.name)", title: genre.name, subtitle: "\(genre.songCount ?? 0) songs",
                         icon: "guitars.fill", color: palette[index % palette.count]) {
                    (await model.musicLibrary.songsByGenre(genre.name)).shuffled()
                }
            }
    }

    /// Liked songs the play history hasn't seen in the last 30 days, shuffled.
    @MainActor private static func forgottenFavorites(_ model: MusicModel) -> [NavidromeSong] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        let recentIDs = Set(model.musicHistory.entries.filter { $0.playedAt >= cutoff }.map(\.song.id))
        return model.musicLibrary.starred.songs.filter { !recentIDs.contains($0.id) }.shuffled()
    }
}

/// A mix's detail page — loads the mix's tracks and shows them under the shared hero +
/// browse-header (like albums/artists/playlists), so you can see what's inside before
/// playing. Reuses `MusicAlbumBanner` with the mix's color + icon.
struct MusicMixDetail: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mix: MusicMix
    @State private var songs: [NavidromeSong] = []
    @State private var loading = true
    @State private var heroImage: Image?
    @State private var filter = ""
    @State private var layout: MusicBrowseLayout = .list

    private var source: StreamingPlaybackController.QueueSource {
        .init(label: mix.title, kind: .radio, id: nil)
    }

    private var totalSeconds: Int { songs.reduce(0) { $0 + ($1.duration ?? 0) } }

    private var detailText: String {
        var parts: [String] = []
        if !songs.isEmpty { parts.append("\(songs.count) song\(songs.count == 1 ? "" : "s")") }
        if totalSeconds > 0 { parts.append(MusicAlbumCard.albumDuration(totalSeconds)) }
        return parts.joined(separator: " · ")
    }

    private var visibleSongs: [NavidromeSong] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return songs }
        return songs.filter { $0.title.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MusicAlbumBanner(
                    name: mix.title,
                    kindLabel: "MIX",
                    detail: loading ? mix.subtitle : detailText,
                    heroImage: heroImage,
                    accentColor: mix.color,
                    placeholderIcon: mix.icon,
                    onBack: { dismiss() }
                )

                MusicBrowseHeader(
                    title: "Songs",
                    count: visibleSongs.count,
                    filter: $filter,
                    filterPrompt: "Filter songs",
                    filterHistoryKey: "mixSongs",
                    layout: $layout,
                    accessory: { EmptyView() },
                    leading: {
                        MusicMiniTransport(onPlayWhenIdle: { model.music.play(songs, source: source) }, pageSource: source)
                        MusicRowActions(actions: [
                            MusicRowAction(title: "Add to Queue", systemImage: "text.append") { model.music.enqueue(songs) },
                            MusicRowAction(title: "Download", systemImage: "arrow.down.circle") { Task { await MusicDownloadStore.shared.download(songs) } },
                            MusicRowAction(title: "Shuffle", systemImage: "shuffle") { model.music.play(songs.shuffled(), source: source) },
                        ])
                    },
                    sortMenu: { EmptyView() }
                )

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                } else if visibleSongs.isEmpty {
                    Text(songs.isEmpty ? "This mix is empty right now" : "No songs match “\(filter)”")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(24)
                } else if layout == .grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                            LikedSongGridCell(song: song, isSelected: false, showSelect: false) {
                                model.music.play(visibleSongs, startAt: index, source: source)
                            }
                        }
                    }
                    .padding(16)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                            MusicLikedSongRow(song: song, showSelect: false) {
                                model.music.play(visibleSongs, startAt: index, source: source)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden(true)
        .task(id: mix.id) {
            loading = true
            heroImage = nil
            songs = await mix.songs()
            loading = false
            if let coverID = songs.first?.coverArtID, let url = model.musicLibrary.coverArtURL(id: coverID, size: 600),
               let image = await MusicAlbumDetail.fetchImage(url) {
                withAnimation(.easeOut(duration: 0.25)) { heroImage = image }
            }
        }
    }
}

/// A mix card: gradient + icon. **Tapping opens the mix's detail page** (see its tracks);
/// the **hover play button** plays it immediately (with its own loading spinner, so playing
/// one card doesn't disable the others).
struct MusicMixCard: View {
    @Environment(MusicModel.self) private var model
    let mix: MusicMix
    @State private var loading = false
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: mix) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    LinearGradient(colors: [mix.color, mix.color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: mix.icon)
                        .font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // The play button plays directly without opening the detail page.
                    Button(action: play) {
                        Image(systemName: "play.circle.fill")
                            .font(.title).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    .opacity(loading ? 0 : (hovering ? 1 : 0.85))
                    .overlay { if loading { ProgressView().controlSize(.small).tint(.white).padding(12) } }
                    .help("Play “\(mix.title)”")
                }
                .frame(height: 96)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mix.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(mix.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.14), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func play() {
        guard !loading else { return }
        loading = true
        Task {
            let songs = await mix.songs()
            loading = false
            guard !songs.isEmpty else {
                model.music.postToast("No tracks for “\(mix.title)”", symbol: "exclamationmark.triangle")
                return
            }
            model.music.play(songs, source: .init(label: mix.title, kind: .radio, id: nil))
        }
    }
}
