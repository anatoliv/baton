import SwiftUI

/// Artists browse — the list, and a hero page per artist with the biography, portrait,
/// stats and discography the Mac shows. All of it comes from endpoints the shared client
/// already speaks (`getArtists`, `getArtistInfo`, `getArtistAlbums`); the phone simply
/// had no screen pointed at them.
struct ArtistsView: View {
    let model: MobileModel
    @State private var query = ""
    // List by default: this library has thousands of artists and you find them by name,
    // not by face. The grid is there for when you're browsing rather than looking.
    @AppStorage(BrowseLayout.key("artist")) private var layoutRaw = BrowseLayout.list.rawValue
    private var layout: BrowseLayout { BrowseLayout(rawValue: layoutRaw) ?? .list }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if layout == .grid { artistGrid } else { artistList }
            }
                // Same A–Z rail as Albums: the artists list is alphabetical by nature and
                // long by nature, which is exactly the combination the rail exists for.
                .overlay(alignment: .trailing) {
                    let entries = indexEntries
                    if !entries.isEmpty {
                        AlphabetIndexRail(entries: entries) { entry in
                            proxy.scrollTo(entry.firstID, anchor: .top)
                        }
                        .padding(.vertical, 8)
                    }
                }
        }
    }

    /// Only while browsing, not while filtering — a rail over five search hits is noise.
    private var indexEntries: [AlphabetIndex.Entry] {
        guard query.isEmpty, filtered.count > 30 else { return [] }
        return AlphabetIndex.entries(from: filtered.map { ($0.id, $0.name) })
    }

    /// Tiles, for recognising someone by their picture.
    private var artistGrid: some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: BrowseGrid.spacing) {
                ForEach(filtered) { artist in
                    NavigationLink {
                        ArtistDetailView(artist: artist, model: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(url: portraitURL(for: artist),
                                        wholeCover: true)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(Circle())
                            Text(artist.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if let count = artist.albumCount {
                                Text("\(count) \(count == 1 ? "album" : "albums")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .id(artist.id)
                }
            }
            .padding(BrowseGrid.padding)
        }
        .searchable(text: $query, prompt: "Artists")
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LayoutPicker(layout: layoutBinding) } }
    }

    private var layoutBinding: Binding<BrowseLayout> {
        Binding(get: { layout }, set: { layoutRaw = $0.rawValue })
    }

    private var artistList: some View {
        List(filtered) { artist in
            NavigationLink {
                ArtistDetailView(artist: artist, model: model)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(url: portraitURL(for: artist))
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(artist.name).lineLimit(1)
                        if let count = artist.albumCount {
                            Text("\(count) \(count == 1 ? "album" : "albums")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .id(artist.id)
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Artists")
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LayoutPicker(layout: layoutBinding) } }
        .overlay {
            if model.musicLibrary.artists.isEmpty {
                ContentUnavailableView("No artists", systemImage: "music.mic")
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task { await model.musicLibrary.loadArtists() }
        .refreshable { await model.musicLibrary.loadArtists() }
    }

    private var filtered: [NavidromeArtist] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return model.musicLibrary.artists }
        return model.musicLibrary.artists.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
        }
    }

    private func portraitURL(for artist: NavidromeArtist) -> URL? {
        if let raw = artist.imageURLString, let url = URL(string: raw) { return url }
        return model.musicLibrary.coverArtURL(id: artist.coverArtID ?? artist.id, size: 120)
    }
}

/// One artist: portrait, biography, play/shuffle/radio, stats, and the discography.
struct ArtistDetailView: View {
    let artist: NavidromeArtist
    let model: MobileModel

    @State private var albums: [NavidromeAlbum] = []
    @State private var info: NavidromeArtistInfo?
    @State private var stats: MusicLibraryStore.ArtistStats?
    @State private var isFollowed = false
    @State private var bioExpanded = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                actions
                if let stats { statsRow(stats) }
                if let bio = info?.biography, !bio.isEmpty { biography(bio) }
                discography
            }
            .padding(.bottom, 16)
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isFollowed = model.musicLibrary.isArtistFollowed(id: artist.id)
            async let albumsTask = model.musicLibrary.artistAlbums(id: artist.id)
            async let infoTask = model.musicLibrary.artistInfo(id: artist.id)
            async let statsTask = model.musicLibrary.artistStats(id: artist.id)
            albums = await albumsTask
            info = await infoTask
            stats = await statsTask
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            ArtworkView(url: info?.imageURL ?? model.musicLibrary.coverArtURL(id: artist.coverArtID ?? artist.id, size: 600))
                .frame(width: 168, height: 168)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            Text(artist.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { model.music.play(await songs(), source: source) }
            } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)

            Button {
                Task { model.music.playShuffleToggling(await songs(), source: source) }
            } label: {
                Label("Shuffle", systemImage: model.music.isShuffled ? "shuffle.circle.fill" : "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(model.music.isShuffled ? Color.accentColor : Color.secondary)
            .accessibilityLabel(model.music.isShuffled ? "Shuffle on" : "Shuffle")

            // Follow is a local marker (the Mac's too) — it doesn't exist server-side.
            Button {
                isFollowed.toggle()
                Task { await model.musicLibrary.setArtistFollowed(id: artist.id, followed: isFollowed) }
            } label: {
                Image(systemName: isFollowed ? "heart.fill" : "heart")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isFollowed ? "Unfollow artist" : "Follow artist")
        }
        .padding(.horizontal)
    }

    private func statsRow(_ stats: MusicLibraryStore.ArtistStats) -> some View {
        HStack(spacing: 0) {
            statTile("\(stats.albums)", "albums")
            statTile("\(stats.tracks)", "tracks")
            statTile(durationText(stats.seconds), "total")
        }
        .padding(.horizontal)
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func biography(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About").font(.headline)
            Text(bio)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(bioExpanded ? nil : 4)
            Button(bioExpanded ? "Less" : "More") {
                withAnimation(.easeInOut(duration: 0.18)) { bioExpanded.toggle() }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal)
    }

    private var discography: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Albums").font(.headline).padding(.horizontal)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 400), wholeCover: true)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                            Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            if let year = album.year {
                                Text(String(year)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .albumContextMenu(album, model: model)
                }
            }
            .padding(.horizontal)
        }
        .navigationDestination(for: NavidromeAlbum.self) { album in
            AlbumDetailView(album: album, model: model)
        }
    }

    private var source: QueueSource { .init(label: artist.name, kind: .artist, id: artist.id) }
    private func songs() async -> [NavidromeSong] { await model.musicLibrary.artistSongs(id: artist.id) }

    private func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// Genres browse — chips into a genre's songs, using the same "is this genre actually a
/// distinction" rule the mixes use, so a library that tags everything "Music" doesn't get
/// a chip offering itself.
struct GenresView: View {
    let model: MobileModel

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(useful, id: \.id) { genre in
                    NavigationLink {
                        GenreSongsView(genre: genre, model: model)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: MixCatalogRules.symbol(forGenre: genre.name))
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(genre.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text("\(genre.songCount ?? 0) songs")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .background(Color.hoverTint, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if useful.isEmpty {
                ContentUnavailableView("No genres", systemImage: "guitars",
                                       description: Text("Your server hasn't reported any genres worth browsing by."))
            }
        }
        .task { await model.musicLibrary.loadGenres() }
        .refreshable { await model.musicLibrary.loadGenres() }
    }

    private var useful: [NavidromeGenre] {
        let all = model.musicLibrary.genres
        let total = all.reduce(0) { $0 + ($1.songCount ?? 0) }
        return all
            .filter { MixCatalogRules.isUsefulGenre(name: $0.name, songCount: $0.songCount ?? 0, librarySongCount: total) }
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
    }
}

/// The songs in one genre.
struct GenreSongsView: View {
    let genre: NavidromeGenre
    let model: MobileModel
    @State private var songs: [NavidromeSong] = []
    @State private var loading = true

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Button {
                        model.music.play(songs, source: source)
                    } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(songs.isEmpty)
                    Button {
                        model.music.playShuffleToggling(songs, source: source)
                    } label: {
                        Label("Shuffle", systemImage: model.music.isShuffled ? "shuffle.circle.fill" : "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.music.isShuffled ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(model.music.isShuffled ? "Shuffle on" : "Shuffle")
                    .disabled(songs.isEmpty)
                }
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, model: model)
                        .contentShape(Rectangle())
                        .onTapGesture { model.music.play(songs, startAt: index, source: source) }
                        .songContextMenu(song, model: model)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView() } }
        .task {
            songs = await model.musicLibrary.songsByGenre(genre.name)
            loading = false
        }
    }

    private var source: QueueSource { .init(label: genre.name, kind: .search, id: genre.name) }
}
