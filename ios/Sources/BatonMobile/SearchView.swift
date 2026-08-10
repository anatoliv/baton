import SwiftUI
import BatonPlaybackKit

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
    /// The queries typed on any device. Held in state rather than read inline so a term
    /// added here, or merged in by a sync, redraws the list.
    @State private var recentQueries: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Two kinds of memory, deliberately different, both shown while the field is
                // empty and both shared with the Mac. This one is what you *typed* — the
                // Mac has kept it per screen for a while, so a query typed there is one tap
                // away here.
                if query.trimmingCharacters(in: .whitespaces).isEmpty, !recentQueries.isEmpty {
                    Section {
                        ForEach(recentQueries, id: \.self) { term in
                            Button { runRecent(term) } label: {
                                Label(term, systemImage: "clock")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    FilterHistory.remove(term, from: Self.historyKey)
                                    reloadQueries()
                                } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button("Clear") {
                                FilterHistory.clear(Self.historyKey)
                                reloadQueries()
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                }

                // And this one is what you *opened* — usually the faster route back, since
                // "Dido → 3 albums" is what you wanted and the string you typed to get there
                // is trivia. Scoped per server, because these are Navidrome ids.
                if query.trimmingCharacters(in: .whitespaces).isEmpty,
                   !model.searchRecents.entries.isEmpty {
                    Section {
                        ForEach(model.searchRecents.entries) { entry in
                            Button { open(entry) } label: { recentRow(entry) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("Recently Opened")
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
            // A search that found nothing, and a search that failed, both used to render as
            // an empty list — indistinguishable from not having typed yet. The system's own
            // no-results view names the term back, which is the difference between "nothing
            // matches that" and "something is wrong".
            .overlay {
                let results = model.musicLibrary.searchResults
                let nothingFound = results.songs.isEmpty && results.albums.isEmpty
                    && results.artists.isEmpty
                if !query.trimmingCharacters(in: .whitespaces).isEmpty, nothingFound {
                    if let error = model.musicLibrary.lastError, !error.isEmpty {
                        ContentStatePlaceholder(state: .failed(error))
                    } else if !model.musicLibrary.isLoading {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
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
                                  externalFocus: $searchFocused, onSubmit: commitQuery)
            }
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album, model: model)
            }
            .navigationDestination(for: NavidromeArtist.self) { artist in
                ArtistDetailView(artist: artist, model: model)
            }
            .task { reloadQueries() }
            .task(id: query) {
                // Small debounce so we search a settled query, not every keystroke.
                guard !query.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.musicLibrary.search(query)
            }
        }
    }

    /// The Mac keeps filter history per screen under stable keys; Search's is "search", and
    /// using the same one is what makes the two lists the same list.
    private static let historyKey = "search"

    private func reloadQueries() { recentQueries = FilterHistory.items(Self.historyKey) }

    private func commitQuery() {
        FilterHistory.add(query, to: Self.historyKey)
        reloadQueries()
    }

    /// Re-running a saved query also promotes it, so the list stays ordered by use rather
    /// than by when a term was first typed.
    private func runRecent(_ term: String) {
        query = term
        FilterHistory.add(term, to: Self.historyKey)
        reloadQueries()
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
/// Whether a list is liked-by-construction, so its rows should not each wear a heart.
///
/// A badge that is true of every row carries no information — it is decoration that costs
/// a glance. Set by the container, which is the only thing that knows what the list *is*;
/// `SongRow` cannot see its own siblings.
private struct HidesLikeBadgeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var hidesLikeBadge: Bool {
        get { self[HidesLikeBadgeKey.self] }
        set { self[HidesLikeBadgeKey.self] = newValue }
    }
}

extension View {
    /// Marks a list whose every row is liked, so the per-row heart is suppressed.
    func likedByConstruction(_ isLiked: Bool = true) -> some View {
        environment(\.hidesLikeBadge, isLiked)
    }
}

struct SongRow: View {
    let song: NavidromeSong
    let model: MobileModel
    @Environment(\.hidesLikeBadge) private var hidesLikeBadge

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
            // Not in a list where everything is liked: there the heart is on every row,
            // says nothing, and crowds the three signals that do vary.
            if !hidesLikeBadge, model.musicLibrary.isLiked(song) {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if song.id == model.music.nowPlaying?.id {
                // Animated while it's actually running, still while it isn't. The static
                // symbol said only "this is the current track" — playing and paused looked
                // identical, so the one thing you'd glance down to check was the one thing
                // it couldn't tell you.
                NowPlayingBars(isPlaying: model.music.state == .playing)
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
