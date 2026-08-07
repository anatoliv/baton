import SwiftUI

/// Search across songs, albums and artists via the shared store's `search3`
/// (which already folds diacritics the way Navidrome indexes them).
struct SearchView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Path-based so a tap can *record* the entity it opens before pushing it — a plain
    /// NavigationLink navigates without telling anyone, which is why search had no memory.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Search with a memory: the albums and artists you opened before, shown
                // while the field is empty. Entities rather than query strings — what you
                // wanted, not what you typed to find it.
                if query.trimmingCharacters(in: .whitespaces).isEmpty,
                   !model.searchRecents.entries.isEmpty {
                    Section {
                        ForEach(model.searchRecents.entries) { entry in
                            Button { open(entry) } label: { recentRow(entry) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("Recently Searched")
                            Spacer()
                            Button("Clear") { model.searchRecents.clear() }
                                .font(.caption)
                                .textCase(nil)
                        }
                    }
                }

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
                            Button {
                                model.searchRecents.record(album: album)
                                path.append(album)
                            } label: {
                                HStack {
                                    ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 120))
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading) {
                                        Text(album.name).lineLimit(1)
                                        Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album, model: model)
                        }
                    }
                }
                if !results.artists.isEmpty {
                    Section("Artists") {
                        ForEach(results.artists) { artist in
                            Button {
                                model.searchRecents.record(artist: artist)
                                path.append(artist)
                            } label: {
                                HStack {
                                    Text(artist.name)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // Scroll the results to put the keyboard away. Without it the keyboard covers
            // the tab bar and this screen has no exit either.
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { searchFocused = false }
                }
            }
            .nowPlayingWash(wash)
            // `.searchable` renders into the navigation bar, so on a screen that hides
            // its bar the field simply never appears — the Search tab would have had no
            // way to search. It moves into the header instead.
            .rootScreenHeader("Search", subtitle: scopeLine) {} accessory: {
                HeaderSearchField(prompt: "Songs, albums, artists", text: $query,
                                  externalFocus: $searchFocused)
            }
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album, model: model)
            }
            .navigationDestination(for: NavidromeArtist.self) { artist in
                ArtistDetailView(artist: artist, model: model)
            }
            .task(id: query) {
                // Small debounce so we search a settled query, not every keystroke.
                guard !query.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.musicLibrary.search(query)
            }
        }
    }

    /// What is being searched, not what was found — a result count here would resize the
    /// header on every keystroke.
    private var scopeLine: String? {
        let albums = model.musicLibrary.albums.count
        let artists = model.musicLibrary.artists.count
        return Counted.line([
            albums > 0 ? Counted.phrase(albums, "album") : nil,
            artists > 0 ? Counted.phrase(artists, "artist") : nil,
        ])
    }

    private func open(_ entry: SearchRecents.Entry) {
        if let album = model.searchRecents.album(for: entry) {
            model.searchRecents.record(album: album)   // promote to the top
            path.append(album)
        } else if let artist = model.searchRecents.artist(for: entry) {
            model.searchRecents.record(artist: artist)
            path.append(artist)
        }
    }

    private func recentRow(_ entry: SearchRecents.Entry) -> some View {
        HStack {
            if let art = entry.coverArtID {
                ArtworkView(url: model.musicLibrary.coverArtURL(id: art, size: 120))
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: entry.kind == .artist ? 18 : 6))
            } else {
                Image(systemName: entry.kind == .artist ? "music.mic" : "square.stack")
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text(entry.title).lineLimit(1)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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
            // Last, and quiet. This row can already carry three signals (downloaded,
            // liked, playing); the length is reference material, not a state, so it
            // sits at the end in the dimmest weight and takes a fixed width so the
            // icons above it don't shuffle sideways from row to row.
            if let time = PlayTime.track(song.duration) {
                Text(time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 38, alignment: .trailing)
            }
        }
    }
}
