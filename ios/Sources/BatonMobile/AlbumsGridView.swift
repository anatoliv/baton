import SwiftUI

/// The Albums browse tab — a two-column grid over `MusicLibraryStore.albums`, the
/// iPhone rendering of the Mac app's grid branch. Artwork rides `AsyncImage` +
/// `URLCache`, which works because the client's per-instance salt keeps cover-art
/// URLs byte-identical.
struct AlbumsGridView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]
    /// Grid shows covers; list shows more of a 2,604-album library per screen. Persisted,
    /// because a view style is a preference, not a mood.
    @AppStorage("baton.albums.style") private var styleRaw = "grid"
    private var isGrid: Bool { styleRaw == "grid" }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if isGrid {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(model.musicLibrary.albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCell(album: album, model: model)
                                }
                                .buttonStyle(.plain)
                                .id(album.id)
                            }
                        }
                        .padding(.horizontal)
                        // Room for the rail, so the last column's titles don't slide under it.
                        .padding(.trailing, indexEntries.isEmpty ? 0 : 18)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(model.musicLibrary.albums) { album in
                                NavigationLink(value: album) {
                                    AlbumListRow(album: album, model: model)
                                }
                                .buttonStyle(.plain)
                                .id(album.id)
                                Divider().padding(.leading, 74)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.trailing, indexEntries.isEmpty ? 0 : 18)
                    }
                }
                // The A–Z rail, for alphabetical sorts on a big library. 2,604 albums
                // without one is a flick marathon.
                .overlay(alignment: .trailing) {
                    if !indexEntries.isEmpty {
                        AlphabetIndexRail(entries: indexEntries) { entry in
                            proxy.scrollTo(entry.firstID, anchor: .top)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .nowPlayingWash(wash)
            .rootScreenHeader("Albums", subtitle: countLine) { sortMenu }
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album, model: model)
            }
            .refreshable { await model.musicLibrary.loadAlbums() }
            .overlay {
                if model.musicLibrary.albums.isEmpty, model.musicLibrary.isLoading {
                    ProgressView()
                }
            }
        }
    }

    /// What the shelf actually holds. Empty while the first load is in flight rather
    /// than "0 albums", which reads as an empty library instead of a pending one.
    private var countLine: String? {
        let albums = model.musicLibrary.albums.count
        let artists = model.musicLibrary.artists.count
        return Counted.line([
            albums > 0 ? Counted.phrase(albums, "album") : nil,
            artists > 0 ? Counted.phrase(artists, "artist") : nil,
        ])
    }

    /// Rail entries for the current sort — empty (rail hidden) unless the order is
    /// alphabetical, because jumping to "S" in a most-played ordering means nothing.
    /// Thirty-plus items is where flicking starts to lose to jumping.
    private var indexEntries: [AlphabetIndex.Entry] {
        let albums = model.musicLibrary.albums
        guard albums.count > 30 else { return [] }
        switch model.musicLibrary.albumSort {
        case .name:
            return AlphabetIndex.entries(from: albums.map { ($0.id, $0.name) })
        case .artist:
            return AlphabetIndex.entries(from: albums.map { ($0.id, $0.artist ?? "") })
        default:
            return []
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Style", selection: $styleRaw) {
                Label("Grid", systemImage: "square.grid.2x2").tag("grid")
                Label("List", systemImage: "list.bullet").tag("list")
            }
            Divider()
            ForEach(AlbumSort.allCases) { sort in
                Button {
                    model.musicLibrary.albumSort = sort
                    Task { await model.musicLibrary.loadAlbums() }
                } label: {
                    if model.musicLibrary.albumSort == sort {
                        Label(sort.label, systemImage: "checkmark")
                    } else {
                        Text(sort.label)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

/// One album as a dense row — the list style for people who scan by name, not cover.
private struct AlbumListRow: View {
    let album: NavidromeAlbum
    let model: MobileModel

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 120))
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).lineLimit(1)
                Text(Counted.line([album.artist, album.year.map(String.init)]) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct AlbumCell: View {
    let album: NavidromeAlbum
    let model: MobileModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 400))
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            Text(album.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(album.artist ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Every cell the same width as its column, so two columns line up and a long
        // title truncates instead of widening its cell.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared artwork loader with the placeholder every cell uses.
struct ArtworkView: View {
    let url: URL?

    var body: some View {
        // `Color.clear` first, image in an overlay.
        //
        // The old version put `AsyncImage` at the root, so once a cover loaded the *image*
        // reported the layout size — and covers are not all square. A 16:9 thumbnail in a
        // grid cell made that cell wider than its column: rows went ragged, titles ran off
        // the edge, and the whole grid looked broken the moment it met a real library
        // instead of four bundled tracks. `Color.clear` has no opinion about its size, so
        // the container decides, and `scaledToFill` + `clipped` fills that box with
        // whatever shape the artwork happens to be.
        Color.clear
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Image(systemName: "music.note")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .clipped()
    }
}

/// Album detail: artwork header + tap-to-play track list, playing through the shared
/// gapless engine exactly as on the Mac.
struct AlbumDetailView: View {
    let album: NavidromeAlbum
    let model: MobileModel
    @State private var songs: [NavidromeSong] = []

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 600))
                            .frame(width: 230, height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                        Text(album.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        Text(album.artist ?? "").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button {
                                play(from: 0)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(songs.isEmpty)

                            Button {
                                model.music.play(songs.shuffled(),
                                                 source: .init(label: album.name, kind: .album, id: album.id))
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(songs.isEmpty)
                        }
                        HStack(spacing: 10) {
                            Button {
                                Task { _ = await MusicDownloadStore.shared.download(songs) }
                            } label: {
                                Label(downloadLabel, systemImage: downloadSymbol)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(songs.isEmpty || isFullyDownloaded)

                            if !model.isDemoMode {
                                Button {
                                    Task {
                                        await model.musicLibrary.toggleLike(
                                            id: album.id, currentLiked: album.isLiked, userRating: album.userRating
                                        )
                                    }
                                } label: {
                                    let liked = model.musicLibrary.isLiked(id: album.id, isLiked: album.isLiked)
                                    Label(liked ? "Liked" : "Like", systemImage: liked ? "heart.fill" : "heart")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    HStack {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading) {
                            Text(song.title).lineLimit(1)
                            if let artist = song.artist, artist != album.artist {
                                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        if model.musicLibrary.isLiked(song) {
                            Image(systemName: "heart.fill").font(.caption).foregroundStyle(.tint)
                        }
                        if song.id == model.music.nowPlaying?.id {
                            Image(systemName: "waveform")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { play(from: index) }
                    .listRowBackground(Color.clear)
                    .songContextMenu(song, model: model)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background {
            // Full-bleed blurred cover behind the whole page (Tidal / Apple Music).
            // The material overlay keeps every row legible over any artwork.
            ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 400))
                .scaledToFill()
                .blur(radius: 60)
                .opacity(0.55)
                .overlay(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { songs = await model.musicLibrary.albumSongs(id: album.id) }
    }

    private func play(from index: Int) {
        model.music.play(songs, startAt: index, source: .init(label: album.name, kind: .album, id: album.id))
    }

    private var isFullyDownloaded: Bool {
        !songs.isEmpty && songs.allSatisfy { MusicDownloadStore.shared.isDownloaded($0.id) }
    }

    private var downloadLabel: String {
        if isFullyDownloaded { return "Downloaded" }
        let inFlight = songs.filter { MusicDownloadStore.shared.inFlight.contains($0.id) }.count
        return inFlight > 0 ? "Downloading…" : "Download"
    }

    private var downloadSymbol: String {
        isFullyDownloaded ? "checkmark.circle" : "arrow.down.circle"
    }
}
