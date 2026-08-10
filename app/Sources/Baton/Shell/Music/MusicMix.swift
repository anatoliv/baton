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
    /// Optional asset-catalog image used instead of the generated mesh backdrop.
    ///
    /// The mesh is the default precisely because it always exists and never needs curating.
    /// This is the escape hatch for a mix worth art-directing: supply an image and it wins,
    /// omit it and nothing about the card changes. A missing asset falls back to the mesh
    /// rather than drawing a hole, so a typo degrades quietly.
    var artwork: String? = nil
    let songs: @MainActor () async -> [NavidromeSong]

    // Identity is the stable `id` (the `songs` closure isn't Hashable) — enough for a
    // NavigationLink to open the mix's detail page.
    static func == (lhs: MusicMix, rhs: MusicMix) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Build from the shared card, so the copy the user reads has one home.
    init(card: MixCardSpec, songs: @escaping @MainActor () async -> [NavidromeSong]) {
        self.id = card.id
        self.title = card.title
        self.subtitle = card.subtitle
        self.icon = card.icon
        self.color = card.tint
        self.artwork = card.artwork
        self.songs = songs
    }

    /// The literal form, still used by the genre and server-playlist mixes, which are built
    /// from library data rather than from a fixed table.
    init(id: String, title: String, subtitle: String, icon: String, color: Color,
         artwork: String? = nil, songs: @escaping @MainActor () async -> [NavidromeSong]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.artwork = artwork
        self.songs = songs
    }
}

/// The catalog of standard mixes, built from the current library + play-history signals.
/// One source of truth for the Mixes tab and the Home shelf.
enum MusicMixCatalog {
    /// The six server + local-signal auto-mixes.
    @MainActor static func auto(_ model: MusicModel) -> [MusicMix] {
        [
            MusicMix(card: MixCards.card("mostPlayed")) {
                model.musicHistory.topTracks(since: .distantPast).map(\.song)
            },
            MusicMix(card: MixCards.card("recentlyAdded")) {
                await model.musicLibrary.mixSongs(type: "newest")
            },
            MusicMix(card: MixCards.card("topRated")) {
                await model.musicLibrary.mixSongs(type: "highest")
            },
            MusicMix(card: MixCards.card("onRepeat")) {
                await model.musicLibrary.mixSongs(type: "frequent")
            },
            MusicMix(card: MixCards.card("forgotten")) {
                forgottenFavorites(model)
            },
            MusicMix(card: MixCards.card("discover")) {
                // Stay a shuffle (fresh each open), but spread artists so it never stacks the
                // same artist back-to-back (F2 — sonic-aware discovery, docs/09 finding #6).
                MixBuilder.curate(await model.musicLibrary.mixSongs(type: "random").shuffled(), mood: .neutral)
            },
        ]
    }

    /// Playlists **generated on the server** rather than computed here — a nightly job, a
    /// Navidrome smart playlist, anything that writes a real playlist on a schedule.
    ///
    /// These belong on the Mixes tab because they answer the same question the auto mixes
    /// do ("give me something to put on"), and because a handful of generated lists are
    /// invisible among hundreds of hand-sorted ones in the Playlists sidebar.
    ///
    /// They are kept as a separate group, not folded into `auto`, because the mechanism
    /// genuinely differs: an auto mix is computed here on tap from local signals, while
    /// these are *fetched* — the server used data Baton never sees (completion ratios,
    /// skip events, its own tagging) to build them. Presenting a fetch as a computation
    /// would misrepresent what the card does.
    @MainActor static func server(_ model: MusicModel) -> [MusicMix] {
        let palette: [Color] = [.indigo, .teal, .purple, .mint, .cyan, .brown]
        return model.musicLibrary.playlists
            .filter { isServerGenerated($0.name) }
            .sorted { $0.name < $1.name }
            .enumerated()
            .map { index, playlist in
                MusicMix(
                    id: "server-\(playlist.id)",
                    title: playlist.name,
                    subtitle: "Generated on your server",
                    icon: "sparkles.rectangle.stack",
                    color: palette[index % palette.count],
                    artwork: serverArtwork[playlist.name]
                ) {
                    await model.musicLibrary.playlist(id: playlist.id)?.songs ?? []
                }
            }
    }

    /// Art-directed backdrops for specific generated playlists, by name. Anything absent
    /// keeps the generated mesh — this is opt-in per playlist, not a required asset.
    static let serverArtwork: [String: String] = [
        "Focus · Deep": "MixArtFocusDeep",
        "Focus · Momentum": "MixArtFocusMomentum",
        "Focus · Lift": "MixArtFocusLift",
        "Fresh": "MixArtFresh",
        "Daily Jams": "MixArtDailyJams",
        "Daily Discovery": "MixArtDailyDiscovery",
        "Deep Cuts": "MixArtDeepCuts",
        "Favorites Radio": "MixArtFavoritesRadio",
        "Favorites Inbox": "MixArtFavoritesInbox",
    ]

    /// Names that indicate a playlist is produced by a generator rather than curated by
    /// hand. Deliberately a small, explicit list: guessing wrong pulls someone's carefully
    /// built playlist out of the sidebar they expect to find it in.
    static var serverGeneratedNames: Set<String> { MixCatalogRules.serverGeneratedNames }

    /// True when `name` looks generated. Matches the explicit set, plus anything under a
    /// "Focus · " prefix so new focus contexts appear without a code change.
    nonisolated static func isServerGenerated(_ name: String) -> Bool {
        MixCatalogRules.isServerGenerated(name)
    }

    // The genre/name/ordering rules live in `MixCatalogRules` (BatonPlaybackKit) so the
    // Mac and the phone can't drift — the same library must produce the same mixes on
    // whichever device you pick up. These stay as the Mac's names, forwarding.
    static var uninformativeGenres: Set<String> { MixCatalogRules.uninformativeGenres }
    static var genreDominanceCeiling: Double { MixCatalogRules.genreDominanceCeiling }

    nonisolated static func isUsefulGenre(name: String, songCount: Int, librarySongCount: Int) -> Bool {
        MixCatalogRules.isUsefulGenre(name: name, songCount: songCount, librarySongCount: librarySongCount)
    }

    /// An SF Symbol that suits a genre.
    ///
    /// Every genre card previously showed `guitars.fill`, which put a guitar on Trance,
    /// House, Electronic and Pop — twelve identical guitars did more to make the row look
    /// monotonous than the backdrops did. Matching is on substrings so related genres
    /// ("Hard Trance", "Vocal Trance", "Classic Trance") share a symbol without needing an
    /// entry each, and anything unrecognised keeps a neutral default rather than guessing.
    nonisolated static func symbol(forGenre name: String) -> String {
        MixCatalogRules.symbol(forGenre: name)
    }

    /// Per-genre "Daily Mix" cards — the user's top genres by song count.
    @MainActor static func genres(_ model: MusicModel) -> [MusicMix] {
        let palette: [Color] = [.purple, .teal, .indigo, .mint, .brown, .cyan, .orange, .pink]
        let total = model.musicLibrary.genres.reduce(0) { $0 + ($1.songCount ?? 0) }
        return model.musicLibrary.genres
            .filter { isUsefulGenre(name: $0.name, songCount: $0.songCount ?? 0, librarySongCount: total) }
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
            .prefix(12)
            .enumerated()
            .map { index, genre in
                MusicMix(id: "genre-\(genre.name)", title: genre.name, subtitle: "\(genre.songCount ?? 0) songs",
                         icon: symbol(forGenre: genre.name), color: palette[index % palette.count]) {
                    MixBuilder.curate(await model.musicLibrary.songsByGenre(genre.name).shuffled(), mood: .neutral)
                }
            }
    }

    /// Liked songs the play history hasn't seen in the last 30 days, shuffled.
    @MainActor private static func forgottenFavorites(_ model: MusicModel) -> [NavidromeSong] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        let recentIDs = Set(model.musicHistory.entries.filter { $0.playedAt >= cutoff }.map(\.song.id))
        let pool = model.musicLibrary.starred.songs.filter { !recentIDs.contains($0.id) }.shuffled()
        // Keep the nostalgic shuffle, but spread artists so it doesn't clump (F2 — consistent
        // with Discover / genre mixes).
        return MixBuilder.curate(pool, mood: .neutral)
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
    @State private var sortField: MixSort = .mix
    @State private var sortAscending = true

    /// Sort fields for a mix's tracks — defaults to the mix's own (ranked) order.
    enum MixSort: String, CaseIterable, Identifiable, MusicSortField {
        case mix, name, artist, duration, plays
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mix: "Mix order"
            case .name: "Name"
            case .artist: "Artist"
            case .duration: "Duration"
            case .plays: "Plays"
            }
        }
    }

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
        var list = songs
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter { $0.title.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query) }
        }
        switch sortField {
        case .mix: break // keep the mix's own (ranked) order
        case .name: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: list.sort { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .duration: list.sort { ($0.duration ?? 0) < ($1.duration ?? 0) }
        case .plays: list.sort { ($0.playCount ?? 0) < ($1.playCount ?? 0) }
        }
        if !sortAscending { list.reverse() }
        return list
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
                            // Shows whether shuffle is on, because pressing it turns it
                            // on — an action that changes a mode and then looks exactly
                            // as it did is indistinguishable from one that did nothing.
                            MusicRowAction(
                                title: "Shuffle",
                                systemImage: model.music.isShuffled ? "shuffle.circle.fill" : "shuffle",
                                tint: model.music.isShuffled ? .accentColor : .secondary
                            ) {
                                model.music.playShuffleToggling(songs, source: source)
                            },
                        ])
                    },
                    sortMenu: { MusicSortControls(ascending: $sortAscending, selection: $sortField) }
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
                    // Procedural artwork, seeded from the mix's identity.
                    //
                    // The obvious alternative — a mosaic of the tracks' own cover art — was
                    // tried and dropped. This library is YouTube-sourced, so "cover art" is a
                    // 16:9 video thumbnail carrying text, faces and channel watermarks; tiled
                    // into a 2×2 it reads as clutter rather than as a cover. It also cost a
                    // library query per card just to draw a backdrop.
                    //
                    // A mesh gradient is deterministic per mix (same card every launch, so it
                    // becomes recognisable), needs no network, no asset, and raises no
                    // licensing question in a redistributed app.
                    MixBackdrop(artwork: mix.artwork, seed: mix.id, tint: mix.color)
                    Image(systemName: mix.icon)
                        .font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
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
            .adaptiveMaterial(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
            // The app's standard lift, not a bespoke one. This card carried scale 1.02
            // over 0.14s where everything else uses 1.06 over 0.16s — close enough to look
            // like a mistake rather than a choice, and it sat next to shelves using the
            // standard. zIndex so a lifted card draws over its neighbours instead of being
            // clipped by the next one.
            .hoverLift(hovering)
            .zIndex(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: hovering)
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


// MARK: - Mix artwork
