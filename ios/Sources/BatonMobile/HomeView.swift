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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    header

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
            .navigationTitle("Baton")
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting).font(.title2.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 4)
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
                                ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 400))
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
                                ArtworkView(url: model.musicLibrary.coverArtURL(id: song.coverArtID ?? song.id, size: 400))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                LinearGradient(
                    colors: [mix.tint.opacity(0.95), mix.tint.opacity(0.45)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: mix.icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(width: 142, height: 142)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: mix.tint.opacity(0.3), radius: 8, y: 3)
            Text(mix.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(mix.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 142)
    }
}

/// A mix's detail page — what's inside, before you commit to playing it.
struct MixDetailView: View {
    let mix: MobileMix
    let model: MobileModel
    @State private var songs: [NavidromeSong] = []
    @State private var loading = true

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ZStack {
                        LinearGradient(colors: [mix.tint.opacity(0.95), mix.tint.opacity(0.45)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: mix.icon)
                            .font(.system(size: 56, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .frame(width: 190, height: 190)
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
                            model.music.play(songs.shuffled(), source: .init(label: mix.title, kind: .radio, id: mix.id))
                        } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
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
