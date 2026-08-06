import SwiftUI

/// The Albums browse tab — a two-column grid over `MusicLibraryStore.albums`, the
/// iPhone rendering of the Mac app's grid branch. Artwork rides `AsyncImage` +
/// `URLCache`, which works because the client's per-instance salt keeps cover-art
/// URLs byte-identical.
struct AlbumsGridView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(model.musicLibrary.albums) { album in
                        NavigationLink(value: album) {
                            AlbumCell(album: album, model: model)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .nowPlayingWash(wash)
            .navigationTitle("Albums")
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album, model: model)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            .refreshable { await model.musicLibrary.loadAlbums() }
            .overlay {
                if model.musicLibrary.albums.isEmpty, model.musicLibrary.isLoading {
                    ProgressView()
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
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
            Text(album.artist ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Shared artwork loader with the placeholder every cell uses.
struct ArtworkView: View {
    let url: URL?

    var body: some View {
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
