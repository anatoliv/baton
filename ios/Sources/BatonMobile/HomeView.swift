import SwiftUI

/// The phone's landing screen — the counterpart to the Mac's Home tab. A greeting, then
/// horizontally scrolling shelves you can tap straight into playback.
///
/// This exists because the app used to open on a grid of album covers, which answers
/// "what do I own" when the question on a phone is almost always "what do I put on".
/// Every shelf here is one tap from sound.
struct HomeView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash

    @State private var recentlyAdded: [NavidromeAlbum] = []
    @State private var rediscover: [NavidromeAlbum] = []
    @State private var loaded = false
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !model.history.recentlyPlayed.isEmpty {
                        SongShelf(title: "Recently Played",
                                  songs: Array(model.history.recentlyPlayed.prefix(18)),
                                  model: model, source: .init(label: "Recently Played", kind: .search))
                    }

                    MixShelf(title: "Your Mixes", mixes: MobileMixCatalog.auto(model), model: model)

                    if !recentlyAdded.isEmpty {
                        AlbumShelf(title: "Recently Added", albums: recentlyAdded, model: model)
                    }

                    let genreMixes = MobileMixCatalog.genres(model)
                    if !genreMixes.isEmpty {
                        MixShelf(title: "Daily Mixes", mixes: genreMixes, model: model)
                    }

                    let serverMixes = MobileMixCatalog.server(model)
                    if !serverMixes.isEmpty {
                        MixShelf(title: "From Your Server", mixes: serverMixes, model: model)
                    }

                    if !rediscover.isEmpty {
                        AlbumShelf(title: "Rediscover", albums: rediscover, model: model)
                    }

                    if loaded, isEmptyLibrary {
                        ContentUnavailableView(
                            "Nothing here yet",
                            systemImage: "music.note.house",
                            description: Text("Once your server has music — and you've played some — this is where it turns up.")
                        )
                        .padding(.top, 40)
                    }
                }
                .padding(.bottom, 12)
            }
            .nowPlayingWash(wash)
            // The greeting is the title — see RootScreenHeader for why no root tab has a
            // navigation bar. Home's title happens to be a greeting rather than the
            // screen's name, which is the only way it differs from the other four.
            .rootScreenHeader(greeting, subtitle: subtitle) {
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            .sheet(isPresented: $showsSettings) {
                MobileSettingsView(model: model)
            }
            .refreshable { await load(force: true) }
            .task { await load(force: false) }
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album, model: model)
            }
            .navigationDestination(for: MobileMix.self) { mix in
                MixDetailView(mix: mix, model: model)
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5 ..< 12: "Good morning"
        case 12 ..< 17: "Good afternoon"
        default: "Good evening"
        }
    }

    private var subtitle: String {
        let count = model.history.lifetimeCount
        if model.isDemoMode { return "You're exploring the demo library." }
        return count > 0 ? "\(count) plays and counting." : "Let's find something to put on."
    }

    private var isEmptyLibrary: Bool {
        recentlyAdded.isEmpty && rediscover.isEmpty
            && model.history.recentlyPlayed.isEmpty
            && model.musicLibrary.albums.isEmpty
    }

    private func load(force: Bool) async {
        guard force || !loaded else { return }
        // Genres and playlists feed the mix shelves; albums feed the album shelves.
        async let genres: Void = model.musicLibrary.loadGenres()
        async let playlists: Void = model.musicLibrary.loadPlaylists()
        async let starred: Void = model.musicLibrary.loadStarred()
        async let newest = model.musicLibrary.albums(type: "newest", size: 16)
        async let random = model.musicLibrary.albums(type: "random", size: 16)
        _ = await (genres, playlists, starred)
        recentlyAdded = await newest
        rediscover = await random
        loaded = true
    }
}

// MARK: - Shelves

/// A horizontal shelf of album covers.
struct AlbumShelf: View {
    let title: String
    let albums: [NavidromeAlbum]
    let model: MobileModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 400), wholeCover: true)
                                    .frame(width: 142, height: 142)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                                Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 142)
                        }
                        .buttonStyle(.plain)
                        .albumContextMenu(album, model: model)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// A horizontal shelf of songs — tap to play the shelf from that track.
struct SongShelf: View {
    let title: String
    let songs: [NavidromeSong]
    let model: MobileModel
    let source: QueueSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            model.music.play(songs, startAt: index, source: source)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(url: model.musicLibrary.coverArtURL(id: song.coverArtID ?? song.id, size: 400), wholeCover: true)
                                    .frame(width: 142, height: 142)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                                Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(song.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 142)
                        }
                        .buttonStyle(.plain)
                        .songContextMenu(song, model: model)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// A horizontal shelf of mix cards.
struct MixShelf: View {
    let title: String
    let mixes: [MobileMix]
    let model: MobileModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(mixes) { mix in
                        NavigationLink(value: mix) {
                            MixCard(mix: mix)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// A mix's card: a gradient tile with its icon, since a computed mix has no artwork of
/// its own and a grey placeholder would read as "broken" rather than "generated".
struct MixCard: View {
    let mix: MobileMix
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var side: CGFloat { CardMetrics.shelfCard(sizeClass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                // The Mac's art direction, verbatim: an art-directed backdrop where one
                // exists, the deterministic mesh where it doesn't. The flat tint gradient
                // this replaces was the phone's own invention and made the same mixes look
                // like a different product on each device.
                MixBackdrop(artwork: mix.artwork, seed: mix.id, tint: mix.tint)
                Image(systemName: mix.icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .padding(12)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Say what's tappable rather than letting SwiftUI infer it from whatever
            // happens to be opaque. The backdrop is deliberately not hit-testable, which
            // left the symbol as the card's only hittable content — a card you could open
            // only by hitting its small top-left corner, and not at all by tapping the
            // middle of it.
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: mix.tint.opacity(0.3), radius: 8, y: 3)
            Text(mix.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(mix.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: side)
    }
}

/// A mix's detail page — what's inside, before you commit to playing it.
struct MixDetailView: View {
    let mix: MobileMix
    let model: MobileModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var songs: [NavidromeSong] = []
    @State private var loading = true

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    // Same backdrop as the card it was opened from, so the detail page
                    // reads as the same mix rather than a differently-coloured tile.
                    ZStack {
                        MixBackdrop(artwork: mix.artwork, seed: mix.id, tint: mix.tint)
                        Image(systemName: mix.icon)
                            .font(.system(size: 56, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
                    }
                    .frame(width: CardMetrics.detailArt(sizeClass),
                           height: CardMetrics.detailArt(sizeClass))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: mix.tint.opacity(0.35), radius: 16, y: 6)

                    Text(mix.subtitle).font(.subheadline).foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            model.music.play(songs, source: .init(label: mix.title, kind: .radio, id: mix.id))
                        } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(songs.isEmpty)

                        Button {
                            model.music.playShuffleToggling(songs, source: .init(label: mix.title, kind: .radio, id: mix.id))
                        } label: {
                            Label("Shuffle", systemImage: model.music.isShuffled ? "shuffle.circle.fill" : "shuffle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        // Shuffle is a *mode*, and this button now sets it — so it has to
                        // say whether it's on. Without this the only feedback for pressing
                        // it lives in the transport, which is exactly the complaint: "no
                        // indication if it is selected or not".
                        //
                        // A tint rather than `.borderedProminent`: that's Play's weight,
                        // and two prominent buttons side by side stop meaning "the primary
                        // action is Play".
                        .tint(model.music.isShuffled ? Color.accentColor : Color.secondary)
                        .accessibilityLabel(model.music.isShuffled ? "Shuffle on" : "Shuffle")
                        .disabled(songs.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, model: model)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.music.play(songs, startAt: index, source: .init(label: mix.title, kind: .radio, id: mix.id))
                        }
                        .songContextMenu(song, model: model)
                }
            }
            // "Forgotten Favorites" is liked-by-construction, and a heart on every row
            // said nothing while crowding the states that do vary. Decided from the list
            // rather than from the mix's name, so any all-liked list gets the same
            // treatment and a renamed mix cannot quietly lose it.
            .likedByConstruction(!songs.isEmpty && songs.allSatisfy { model.musicLibrary.isLiked($0) })
        }
        .listStyle(.plain)
        .navigationTitle(mix.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading { ProgressView() }
            else if songs.isEmpty {
                ContentUnavailableView("Nothing in this mix yet", systemImage: mix.icon,
                                       description: Text("Play some music and it'll fill up."))
            }
        }
        .task {
            songs = await mix.songs()
            loading = false
        }
    }
}
