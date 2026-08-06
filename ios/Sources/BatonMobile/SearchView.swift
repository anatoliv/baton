import SwiftUI

/// Search across songs, albums and artists via the shared store's `search3`
/// (which already folds diacritics the way Navidrome indexes them).
struct SearchView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let results = model.musicLibrary.searchResults
                if !results.songs.isEmpty {
                    Section("Songs") {
                        ForEach(results.songs) { song in
                            SongRow(song: song, model: model)
                                .contentShape(Rectangle())
                                .onTapGesture { play(song, in: results.songs) }
                                .songContextMenu(song, model: model)
                        }
                    }
                }
                if !results.albums.isEmpty {
                    Section("Albums") {
                        ForEach(results.albums) { album in
                            NavigationLink(value: album) {
                                HStack {
                                    ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 120))
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading) {
                                        Text(album.name).lineLimit(1)
                                        Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .albumContextMenu(album, model: model)
                        }
                    }
                }
                if !results.artists.isEmpty {
                    Section("Artists") {
                        ForEach(results.artists) { artist in
                            // Was plain text: a search result you can't open is a dead end.
                            NavigationLink {
                                ArtistDetailView(artist: artist, model: model)
                            } label: {
                                Text(artist.name)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .nowPlayingWash(wash)
            .navigationTitle("Search")
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album, model: model)
            }
            .searchable(text: $query, prompt: "Songs, albums, artists")
            .task(id: query) {
                // Small debounce so we search a settled query, not every keystroke.
                guard !query.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.musicLibrary.search(query)
            }
        }
    }

    private func play(_ song: NavidromeSong, in songs: [NavidromeSong]) {
        let index = songs.firstIndex(of: song) ?? 0
        model.music.play(songs, startAt: index, source: .init(label: "Search", kind: .search))
    }
}

/// The one shared song row: title/artist + artwork + the playing indicator.
struct SongRow: View {
    let song: NavidromeSong
    let model: MobileModel

    var body: some View {
        HStack {
            ArtworkView(url: model.musicLibrary.coverArtURL(id: song.coverArtID ?? song.id, size: 120))
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(song.title).lineLimit(1)
                Text(song.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            // Downloaded / liked / playing are the three states worth seeing at a
            // glance in a list; ratings live in the context menu where they're set.
            if MusicDownloadStore.shared.isDownloaded(song.id) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.musicLibrary.isLiked(song) {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if song.id == model.music.nowPlaying?.id {
                Image(systemName: "waveform").foregroundStyle(.tint)
            }
        }
    }
}
