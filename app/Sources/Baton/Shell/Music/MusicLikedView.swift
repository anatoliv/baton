import AppKit
import SwiftUI

/// The **Liked** screen — a `MusicCollectionView` over the user's starred items.
struct MusicLikedView: View {
    @Environment(MusicModel.self) private var model
    var body: some View {
        MusicCollectionView(
            title: "Liked",
            filterPrompt: "Filter liked",
            results: .starred,
            layoutKey: "tonebox.music.likedLayout",
            defaultSort: .rating,
            sourceLabel: "Liked Songs",
            sourceKind: .liked,
            songsEmpty: ("heart", "No liked songs", "Tap the heart on any track to collect it here."),
            onAppear: { await model.musicLibrary.loadStarred() }
        )
    }
}

/// The **Search** screen — the same `MusicCollectionView`, but the filter field is a
/// server search (submits on return) and the results come from `search3`.
struct MusicSearchView: View {
    @Environment(MusicModel.self) private var model
    var body: some View {
        MusicCollectionView(
            title: "Search",
            filterPrompt: "Search songs, albums, artists…",
            searchMode: true,
            results: .search,
            layoutKey: "tonebox.music.searchLayout",
            defaultSort: .title,
            defaultAscending: true,
            sourceLabel: "Search",
            sourceKind: .search,
            songsEmpty: ("magnifyingglass", "Search your library", "Type a query and press return."),
            onSubmit: { query in await model.musicLibrary.search(query) }
        )
    }
}

/// A generalized songs/albums/artists collection browser shared by **Liked** and
/// **Search**: a two-row header (title + Songs/Albums/Artists segments + filter, then
/// transport / selection-save / sort / layout) over segmented content (song table or
/// grid, album/artist grid or table) with multi-select and save-as-playlist. Liked
/// filters its starred set locally; Search runs a server query on submit.
struct MusicCollectionView: View {
    @Environment(MusicModel.self) private var model

    /// Where the songs/albums/artists come from. Read via a direct property access
    /// (not a keypath subscript) so `@Observable` change tracking actually fires.
    enum ResultsSource { case starred, search }

    // Configuration.
    let title: String
    let filterPrompt: String
    let searchMode: Bool
    let resultsSource: ResultsSource
    let sourceLabel: String
    let sourceKind: StreamingPlaybackController.QueueSource.Kind
    let songsEmpty: (icon: String, title: String, subtitle: String)
    let onAppear: () async -> Void
    let onSubmit: ((String) async -> Void)?

    // State.
    @State private var segment: Segment = .songs
    @State private var filterText = ""
    @State private var sort: SongSort
    @State private var sortAscending: Bool
    /// Multi-select state (ids + Shift-range anchor) — the shared model used by every
    /// browse screen. Song ids here; the same model type drives albums/artists/playlists.
    @State private var sel = MusicMultiSelect()
    @State private var showSaveDialog = false
    @State private var saveName = ""
    @State private var showBatchRemoveConfirm = false
    /// Collection-level "mark every displayed song for removal" confirmation (Liked only).
    @State private var showRemoveAllConfirm = false
    /// Batch mark-for-removal confirmations for the Albums / Artists segments (Liked only).
    @State private var showAlbumRemoveConfirm = false
    @State private var showArtistRemoveConfirm = false
    /// Collection ⋯ "mark every displayed album's/artist's tracks for removal" confirms.
    @State private var showAllAlbumsRemoveConfirm = false
    @State private var showAllArtistsRemoveConfirm = false
    /// Whether the filter/search field is focused — used to suppress the ⌘A "select all
    /// songs" shortcut while the user is typing (so ⌘A selects the query text instead).
    @FocusState private var filterFocused: Bool
    /// Card grid vs table for the Albums / Artists (and Songs) segments. Persisted.
    @AppStorage private var layout: MusicBrowseLayout

    init(
        title: String,
        filterPrompt: String,
        searchMode: Bool = false,
        results: ResultsSource,
        layoutKey: String,
        defaultSort: SongSort = .rating,
        defaultAscending: Bool = false,
        sourceLabel: String,
        sourceKind: StreamingPlaybackController.QueueSource.Kind,
        songsEmpty: (icon: String, title: String, subtitle: String),
        onAppear: @escaping () async -> Void = {},
        onSubmit: ((String) async -> Void)? = nil
    ) {
        self.title = title
        self.filterPrompt = filterPrompt
        self.searchMode = searchMode
        self.resultsSource = results
        self.sourceLabel = sourceLabel
        self.sourceKind = sourceKind
        self.songsEmpty = songsEmpty
        self.onAppear = onAppear
        self.onSubmit = onSubmit
        _sort = State(initialValue: defaultSort)
        _sortAscending = State(initialValue: defaultAscending)
        _layout = AppStorage(wrappedValue: .grid, layoutKey)
    }

    private var library: MusicLibraryStore { model.musicLibrary }
    private var results: NavidromeSearchResults {
        switch resultsSource {
        case .starred: model.musicLibrary.starred
        case .search: model.musicLibrary.searchResults
        }
    }

    enum Segment: String, CaseIterable, Identifiable {
        case songs, albums, artists
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum SongSort: String, CaseIterable, Identifiable, MusicSortField {
        case rating, title, artist, duration
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rating: "Rating"
            case .title: "Title"
            case .artist: "Artist"
            case .duration: "Duration"
            }
        }
    }

    private var source: StreamingPlaybackController.QueueSource {
        .init(label: sourceLabel, kind: sourceKind, id: nil)
    }

    /// Local-filter query (Liked). In search mode filtering is server-side, so it's
    /// only used to show the "no matches" copy.
    private var query: String { filterText.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Songs after (local-only, non-search) filter + sort.
    private var songs: [NavidromeSong] {
        var list = results.songs
        if !searchMode, !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query)
            }
        }
        switch sort {
        case .rating: list.sort { ratingFor($0) < ratingFor($1) }
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: list.sort { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .duration: list.sort { ($0.duration ?? 0) < ($1.duration ?? 0) }
        }
        if !sortAscending { list.reverse() }
        return list
    }

    private var albums: [NavidromeAlbum] {
        guard !searchMode, !query.isEmpty else { return results.albums }
        return results.albums.filter { $0.name.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query) }
    }

    private var artists: [NavidromeArtist] {
        guard !searchMode, !query.isEmpty else { return results.artists }
        return results.artists.filter { $0.name.lowercased().contains(query) }
    }

    /// The ids of the currently-shown segment — what selection/⌘A operate on.
    private var segmentOrderedIDs: [String] {
        switch segment {
        case .songs: songs.map(\.id)
        case .albums: albums.map(\.id)
        case .artists: artists.map(\.id)
        }
    }

    private var selectedAlbums: [NavidromeAlbum] { albums.filter { sel.contains($0.id) } }
    private var selectedArtists: [NavidromeArtist] { artists.filter { sel.contains($0.id) } }
    private var segmentIsEmpty: Bool { segmentOrderedIDs.isEmpty }

    private func ratingFor(_ song: NavidromeSong) -> Int { library.rating(song) }

    /// Hide the like-heart badge on the Liked screen — every item there is already
    /// liked, so the badge is redundant. Keep it on Search (a "sign" of liked state).
    private var showLikeBadge: Bool { resultsSource != .starred }

    private func count(_ seg: Segment) -> Int {
        switch seg {
        case .songs: results.songs.count
        case .albums: results.albums.count
        case .artists: results.artists.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MusicBrowseHeader(
                title: title,
                count: segmentOrderedIDs.count,
                filter: $filterText,
                filterPrompt: filterPrompt,
                filterOnSubmit: searchMode ? {
                    let q = filterText.trimmingCharacters(in: .whitespaces)
                    if !q.isEmpty { Task { await onSubmit?(q) } }
                } : nil,
                filterFocused: $filterFocused,
                filterHistoryKey: searchMode ? "search" : "liked",
                layout: $layout,
                accessory: {
                    HStack(spacing: 12) {
                        Divider().frame(height: 20)
                        segmentPills
                    }
                },
                leading: {
                    if sel.isEmpty {
                        MusicMiniTransport(onPlayWhenIdle: { play(shuffle: false) })
                        if !segmentIsEmpty { collectionMenu }
                        if !segmentIsEmpty {
                            Button(action: selectAllDisplayed) {
                                Label("Select All", systemImage: "checklist")
                                    .font(.caption).labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .keyboardShortcut(filterFocused ? nil : KeyboardShortcut("a", modifiers: .command))
                            .help("Select all displayed (⌘A)")
                        }
                    } else {
                        // A batch bar per segment: songs, albums, or artists.
                        switch segment {
                        case .songs: selectionBar
                        case .albums: albumSelectionBar
                        case .artists: artistSelectionBar
                        }
                    }
                },
                sortMenu: {
                    MusicSortControls(ascending: $sortAscending, selection: $sort)
                }
            )
            Group {
                switch segment {
                case .songs: songsView
                case .albums: albumsView
                case .artists: artistsView
                }
            }
        }
        .task { await onAppear() }
        // Selection is song-specific; drop it when leaving the Songs segment so a stale
        // batch bar can't act on songs you're no longer looking at.
        .onChange(of: segment) { clearSelection() }
        // Keep the selection honest as the visible set changes (filter / search / sort).
        .onChange(of: segmentOrderedIDs) { sel.reconcile(segmentOrderedIDs) }
        .alert("Save as playlist", isPresented: $showSaveDialog) {
            TextField("Playlist name", text: $saveName)
            Button("Save") { performSave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a playlist from \(saveSongs.count) track\(saveSongs.count == 1 ? "" : "s").")
        }
        .confirmationDialog(
            "Mark \(selectedSongs.count) song\(selectedSongs.count == 1 ? "" : "s") for removal?",
            isPresented: $showBatchRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark for Removal", role: .destructive) { batchRemove() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Mark all \(songs.count) song\(songs.count == 1 ? "" : "s") for removal?",
            isPresented: $showRemoveAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark All for Removal", role: .destructive) { removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unlikes every displayed song and rates it 1 star — the signal the cleanup pipeline uses to prune them.")
        }
        .confirmationDialog(
            "Mark all tracks in \(selectedAlbums.count) album\(selectedAlbums.count == 1 ? "" : "s") for removal?",
            isPresented: $showAlbumRemoveConfirm, titleVisibility: .visible
        ) {
            Button("Mark All for Removal", role: .destructive) { batchAlbumRemove() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Mark all tracks by \(selectedArtists.count) artist\(selectedArtists.count == 1 ? "" : "s") for removal?",
            isPresented: $showArtistRemoveConfirm, titleVisibility: .visible
        ) {
            Button("Mark All for Removal", role: .destructive) { batchArtistRemove() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Mark all tracks in every displayed album (\(albums.count)) for removal?",
            isPresented: $showAllAlbumsRemoveConfirm, titleVisibility: .visible
        ) {
            Button("Mark All for Removal", role: .destructive) {
                MusicBatchActions.markForRemoval(model, gather: allAlbumSongs)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Mark all tracks by every displayed artist (\(artists.count)) for removal?",
            isPresented: $showAllArtistsRemoveConfirm, titleVisibility: .visible
        ) {
            Button("Mark All for Removal", role: .destructive) {
                MusicBatchActions.markForRemoval(model, gather: allArtistSongs)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Album / Artist segment batch bars + actions

    private func albumSongs() async -> [NavidromeSong] { await MusicBatchActions.songs(ofAlbums: selectedAlbums, model) }
    private func artistSongs() async -> [NavidromeSong] { await MusicBatchActions.songs(ofArtists: selectedArtists, model) }

    private var albumSelectionBar: some View {
        let label = "\(selectedAlbums.count) albums"
        let name = selectedAlbums.count == 1 ? selectedAlbums[0].name : "\(selectedAlbums.count) Albums"
        return MusicSelectionBar(
            count: selectedAlbums.count,
            allSelected: sel.allSelected(segmentOrderedIDs),
            selectAllShortcut: !filterFocused,
            onToggleSelectAll: toggleSelectAll,
            onClear: clearSelection
        ) {
            MusicBatchButton(system: "play.fill", help: "Play selected") { MusicBatchActions.play(model, shuffle: false, label: label, kind: .album, gather: albumSongs) }
            MusicBatchButton(system: "shuffle", help: "Shuffle selected") { MusicBatchActions.play(model, shuffle: true, label: label, kind: .album, gather: albumSongs) }
            MusicBatchButton(system: "text.append", help: "Add to queue") { MusicBatchActions.queue(model, gather: albumSongs) }
            MusicBatchButton(system: "square.and.arrow.down", help: "Save as playlist") { MusicBatchActions.save(model, name: name, gather: albumSongs) }
            MusicBatchAddToPlaylistMenu(gather: albumSongs)
            MusicBatchButton(system: "arrow.down.circle", help: "Download") { MusicBatchActions.download(model, gather: albumSongs) }
            if !searchMode {
                MusicBatchButton(system: "xmark.bin", help: "Mark all for removal") { showAlbumRemoveConfirm = true }
            }
        }
    }

    private var artistSelectionBar: some View {
        let label = "\(selectedArtists.count) artists"
        let name = selectedArtists.count == 1 ? selectedArtists[0].name : "\(selectedArtists.count) Artists"
        return MusicSelectionBar(
            count: selectedArtists.count,
            allSelected: sel.allSelected(segmentOrderedIDs),
            selectAllShortcut: !filterFocused,
            onToggleSelectAll: toggleSelectAll,
            onClear: clearSelection
        ) {
            MusicBatchButton(system: "play.fill", help: "Play selected") { MusicBatchActions.play(model, shuffle: false, label: label, kind: .artist, gather: artistSongs) }
            MusicBatchButton(system: "shuffle", help: "Shuffle selected") { MusicBatchActions.play(model, shuffle: true, label: label, kind: .artist, gather: artistSongs) }
            MusicBatchButton(system: "text.append", help: "Add to queue") { MusicBatchActions.queue(model, gather: artistSongs) }
            MusicBatchButton(system: "square.and.arrow.down", help: "Save as playlist") { MusicBatchActions.save(model, name: name, gather: artistSongs) }
            MusicBatchAddToPlaylistMenu(gather: artistSongs)
            MusicBatchButton(system: "arrow.down.circle", help: "Download") { MusicBatchActions.download(model, gather: artistSongs) }
            if !searchMode {
                MusicBatchButton(system: "xmark.bin", help: "Mark all for removal") { showArtistRemoveConfirm = true }
            }
        }
    }

    private func batchAlbumRemove() { MusicBatchActions.markForRemoval(model, gather: albumSongs) { clearSelection() } }
    private func batchArtistRemove() { MusicBatchActions.markForRemoval(model, gather: artistSongs) { clearSelection() } }

    /// Collection-level actions over *all* displayed songs (respecting filter/sort) —
    /// the same rich set artists/albums get, for the Liked collection as a whole. Shown
    /// on Liked only (not Search, where "mark all results for removal" would be a trap).
    @ViewBuilder private var collectionMenu: some View {
        if !searchMode {
            Menu {
                switch segment {
                case .songs:
                    Button("Play All", systemImage: "play.fill") { play(shuffle: false) }
                    Button("Shuffle All", systemImage: "shuffle") { play(shuffle: true) }
                    Button("Add All to Queue", systemImage: "text.append") { queueAll() }
                    Button("Find Similar (Radio)", systemImage: "dot.radiowaves.left.and.right") { radioFromAll() }
                    Divider()
                    Button("Download All", systemImage: "arrow.down.circle") { downloadAll() }
                    Button("Save as Playlist", systemImage: "square.and.arrow.down") { promptSave() }
                    Divider()
                    Button("Mark All for Removal", systemImage: "xmark.bin", role: .destructive) { showRemoveAllConfirm = true }
                case .albums:
                    collectionActions(count: albums.count, noun: "Albums", kind: .album, gather: allAlbumSongs) { showAllAlbumsRemoveConfirm = true }
                case .artists:
                    collectionActions(count: artists.count, noun: "Artists", kind: .artist, gather: allArtistSongs) { showAllArtistsRemoveConfirm = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.callout)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
            .help("Collection actions")
        }
    }

    /// The album/artist ⋯ menu items — parity with the songs menu, acting on *all*
    /// displayed items via the shared `MusicBatchActions`.
    @ViewBuilder
    private func collectionActions(
        count: Int, noun: String, kind: StreamingPlaybackController.QueueSource.Kind,
        gather: @escaping () async -> [NavidromeSong], onMark: @escaping () -> Void
    ) -> some View {
        let label = "\(count) \(noun.lowercased())"
        Button("Play All", systemImage: "play.fill") { MusicBatchActions.play(model, shuffle: false, label: label, kind: kind, gather: gather) }
        Button("Shuffle All", systemImage: "shuffle") { MusicBatchActions.play(model, shuffle: true, label: label, kind: kind, gather: gather) }
        Button("Add All to Queue", systemImage: "text.append") { MusicBatchActions.queue(model, gather: gather) }
        Divider()
        Button("Download All", systemImage: "arrow.down.circle") { MusicBatchActions.download(model, gather: gather) }
        Button("Save as Playlist", systemImage: "square.and.arrow.down") { MusicBatchActions.save(model, name: "\(title) \(noun)", gather: gather) }
        Divider()
        Button("Mark All for Removal", systemImage: "xmark.bin", role: .destructive, action: onMark)
    }

    private func allAlbumSongs() async -> [NavidromeSong] { await MusicBatchActions.songs(ofAlbums: albums, model) }
    private func allArtistSongs() async -> [NavidromeSong] { await MusicBatchActions.songs(ofArtists: artists, model) }

    private func queueAll() {
        guard !songs.isEmpty else { return }
        model.music.enqueue(songs)
    }

    private func radioFromAll() {
        guard let seed = songs.first else { return }
        Task {
            let radio = await library.similarSongs(seedID: seed.id)
            model.music.play(radio.isEmpty ? songs : radio,
                             source: .init(label: "\(title) Radio", kind: .radio, id: nil))
        }
    }

    private func downloadAll() {
        guard !songs.isEmpty else { return }
        model.music.postToast("Downloading \(songs.count) song\(songs.count == 1 ? "" : "s")…", symbol: "arrow.down.circle")
        Task { await MusicDownloadStore.shared.download(songs) }
    }

    private func removeAll() {
        let all = songs
        guard !all.isEmpty else { return }
        model.music.postToast("Marked \(all.count) for removal", symbol: "xmark.bin")
        Task { for song in all { await library.markForRemoval(song) } }
    }

    /// The batch action bar shown in the header while a selection is active — the shared
    /// `MusicSelectionBar` chrome filled with the song-specific batch operations.
    private var selectionBar: some View {
        MusicSelectionBar(
            count: selectedSongs.count,
            allSelected: allSelected,
            selectAllShortcut: !filterFocused,
            onToggleSelectAll: toggleSelectAll,
            onClear: clearSelection
        ) {
            MusicBatchButton(system: "play.fill", help: "Play selected", action: batchPlay)
            MusicBatchButton(system: "text.line.first.and.arrowtriangle.forward", help: "Play next", action: batchPlayNext)
            MusicBatchButton(system: "text.append", help: "Add to queue", action: batchQueue)
            MusicBatchButton(system: "square.and.arrow.down", help: "Save as playlist", action: promptSave)
            MusicBatchAddToPlaylistMenu(gather: { selectedSongs })
            MusicBatchButton(
                system: selectionAllLiked ? "heart.fill" : "heart",
                help: selectionAllLiked ? "Unlike all" : "Like all",
                tint: selectionAllLiked ? .pink : .secondary,
                action: batchToggleLike
            )
            MusicBatchButton(system: "arrow.down.circle", help: "Download", action: batchDownload)
            MusicBatchButton(system: "xmark.bin", help: "Mark for removal", action: { showBatchRemoveConfirm = true })
        }
    }

    /// Compact Songs / Albums / Artists switcher (sized to content, not stretched).
    private var segmentPills: some View {
        HStack(spacing: 3) {
            ForEach(Segment.allCases) { seg in
                let c = count(seg)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { segment = seg }
                } label: {
                    Text("\(seg.label) \(c)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(segment == seg ? Color.white : .secondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(segment == seg ? Color.accentColor : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(c == 0)
                .opacity(c == 0 ? 0.4 : 1)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    // MARK: - Segments

    private var songsView: some View {
        Group {
            if results.songs.isEmpty {
                emptyState(songsEmpty.icon, songsEmpty.title, songsEmpty.subtitle)
            } else if songs.isEmpty {
                emptyState("magnifyingglass", "No matches", "Nothing matches “\(filterText)”.")
            } else if layout == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            LikedSongGridCell(
                                song: song,
                                isSelected: sel.contains(song.id),
                                showLikeBadge: showLikeBadge,
                                onToggleSelect: { selectClicked(song.id) }
                            ) {
                                model.music.play(songs, startAt: index, source: source)
                            }
                        }
                    }
                    .padding(12)
                }
            } else {
                cappedTable(header: songHeader) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        MusicLikedSongRow(
                            song: song,
                            isSelected: sel.contains(song.id),
                            showLikeBadge: showLikeBadge,
                            onToggleSelect: { selectClicked(song.id) }
                        ) {
                            model.music.play(songs, startAt: index, source: source)
                        }
                    }
                }
            }
        }
    }

    private var songHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Button(action: toggleSelectAll) {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : (sel.isEmpty ? "circle" : "minus.circle.fill"))
                        .foregroundStyle(sel.isEmpty ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain).frame(width: 18).help("Select all")
                Color.clear.frame(width: 40, height: 1)
                Text("Title")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Time").frame(width: 52, alignment: .trailing)
            Text("Rating").frame(width: 110, alignment: .center)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private var albumsView: some View {
        Group {
            if layout == .list {
                cappedTable(header: BrowseColumns.header("Album", showTime: true, showRating: true, selectable: true)) {
                    ForEach(albums) { album in
                        MusicAlbumRow(
                            album: album,
                            isSelected: sel.contains(album.id),
                            onToggleSelect: { selectClicked(album.id) }
                        )
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(albums) { album in
                            AlbumGridCell(
                                album: album,
                                selectable: true,
                                isSelected: sel.contains(album.id),
                                onToggleSelect: { selectClicked(album.id) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var artistsView: some View {
        Group {
            if layout == .list {
                cappedTable(header: ArtistColumns.header) {
                    ForEach(artists) { artist in
                        MusicArtistListRow(
                            artist: artist,
                            isSelected: sel.contains(artist.id),
                            onToggleSelect: { selectClicked(artist.id) }
                        )
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(artists) { artist in
                            ArtistGridCell(
                                artist: artist,
                                isSelected: sel.contains(artist.id),
                                onToggleSelect: { selectClicked(artist.id) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    /// The shared width-capped table shell (header + scrolling rows) used by the
    /// Albums / Artists list layouts.
    private func cappedTable<Header: View, Rows: View>(
        header: Header,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) { rows() }
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 16)
    }

    private func emptyState(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            Text(subtitle).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func play(shuffle: Bool) {
        var list = songs
        guard !list.isEmpty else { return }
        if shuffle { list.shuffle() }
        model.music.play(list, source: source)
    }

    // MARK: - Selection + Save

    /// The songs Save will use: the checked selection (in display order) if any, else
    /// all currently-shown songs.
    private var saveSongs: [NavidromeSong] {
        sel.isEmpty ? songs : songs.filter { sel.contains($0.id) }
    }

    /// The checked songs in display order — what the batch action bar operates on.
    private var selectedSongs: [NavidromeSong] {
        songs.filter { sel.contains($0.id) }
    }

    private var allSelected: Bool { sel.allSelected(segmentOrderedIDs) }

    private func toggleSelectAll() { sel.toggleSelectAll(segmentOrderedIDs) }

    /// Select every currently-displayed item in the active segment (⌘A / the header
    /// toggle). Respects the active filter + segment.
    private func selectAllDisplayed() { sel.selectAll(segmentOrderedIDs) }

    /// A checkbox/row click, made modifier-aware: plain click toggles one item and moves
    /// the anchor; Shift-click selects the contiguous range from the anchor to here.
    private func selectClicked(_ id: String) { sel.clicked(id, ordered: segmentOrderedIDs) }

    private func clearSelection() { sel.clear() }

    // MARK: - Batch actions (operate on the checked selection)

    private func batchPlay() {
        let sel = selectedSongs
        guard !sel.isEmpty else { return }
        model.music.play(sel, source: source)
    }

    private func batchPlayNext() {
        let sel = selectedSongs
        guard !sel.isEmpty else { return }
        model.music.playNext(sel)
    }

    private func batchQueue() {
        let sel = selectedSongs
        guard !sel.isEmpty else { return }
        model.music.enqueue(sel)
    }

    /// True when every selected song is already liked — drives the heart button between
    /// "like all" and "unlike all".
    private var selectionAllLiked: Bool {
        let sel = selectedSongs
        return !sel.isEmpty && sel.allSatisfy { library.isLiked($0) }
    }

    private func batchToggleLike() {
        let (toToggle, unlikeAll) = MusicSelectionMath.likeTargets(
            selected: selectedSongs.map(\.id),
            likedIDs: Set(selectedSongs.filter { library.isLiked($0) }.map(\.id))
        )
        guard !toToggle.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: selectedSongs.map { ($0.id, $0) })
        model.music.postToast(
            "\(unlikeAll ? "Unliked" : "Liked") \(toToggle.count) song\(toToggle.count == 1 ? "" : "s")",
            symbol: unlikeAll ? "heart.slash" : "heart.fill"
        )
        Task { for id in toToggle { if let song = byID[id] { await library.toggleLike(song) } } }
    }

    private func batchDownload() {
        let sel = selectedSongs
        guard !sel.isEmpty else { return }
        model.music.postToast("Downloading \(sel.count) song\(sel.count == 1 ? "" : "s")…", symbol: "arrow.down.circle")
        Task { await MusicDownloadStore.shared.download(sel) }
    }

    private func batchRemove() {
        let sel = selectedSongs
        guard !sel.isEmpty else { return }
        model.music.postToast("Marked \(sel.count) for removal", symbol: "xmark.bin")
        Task {
            for song in sel { await library.markForRemoval(song) }
            clearSelection()
        }
    }

    private func promptSave() {
        guard !saveSongs.isEmpty else { return }
        saveName = sel.isEmpty ? "\(title) Songs" : "\(title) Selection"
        showSaveDialog = true
    }

    private func performSave() {
        let ids = saveSongs.map(\.id)
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !ids.isEmpty, !name.isEmpty else { return }
        Task {
            _ = await library.createPlaylist(name: name, songIDs: ids)
            await library.loadPlaylists()
        }
        model.music.postToast("Saved playlist “\(name)”", symbol: "square.and.arrow.down")
        clearSelection()
    }
}

/// A compact liked-song row matching the Artists-list density: a cover thumbnail
/// (play on hover, now-playing indicator), title/artist, then right-aligned duration,
/// a 5-star rating, and a like heart — inside the width-capped table so nothing is
/// flung to the window edge.
struct MusicLikedSongRow: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    var isSelected: Bool = false
    var showLikeBadge: Bool = true
    /// Whether the multi-select checkbox slot is shown (off on pages without selection,
    /// e.g. the artist detail).
    var showSelect: Bool = true
    /// A leading track number (album detail only) — nil hides the column entirely.
    var trackNumber: Int? = nil
    /// When set (playlist detail), adds a "Remove from Playlist" item to the context menu.
    var onRemoveFromPlaylist: (() -> Void)? = nil
    var onToggleSelect: () -> Void = {}
    var onPlay: () -> Void
    @State private var hovering = false
    @State private var showRemoveConfirm = false

    private var isCurrent: Bool { model.music.nowPlaying?.id == song.id }
    private var downloads: MusicDownloadStore { .shared }
    private var isDownloaded: Bool { downloads.isDownloaded(song.id) }
    private var isDownloading: Bool { downloads.isDownloading(song.id) }

    private func downloadSong() {
        model.music.postToast("Downloading \(song.title)…", symbol: "arrow.down.circle")
        Task { await downloads.download(song) }
    }

    private func removeDownload() {
        downloads.delete(song.id)
        model.music.postToast("Removed download", symbol: "trash.slash")
    }

    var body: some View {
        HStack(spacing: 12) {
            // Selection checkbox — shown on hover or when selected (keeps its slot so
            // the row layout doesn't shift).
            if showSelect {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .opacity(isSelected || hovering ? 1 : 0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).frame(width: 18).help("Select")
            }

            if let trackNumber {
                // `verbatim:` — a plain "\(int)" is a LocalizedStringKey and would add a
                // thousands separator (e.g. 3639 → "3,639") that then wraps in the column.
                Text(verbatim: "\(trackNumber)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 24, alignment: .trailing)
            }

            MusicSongThumb(song: song, showLikeBadge: showLikeBadge, onPlay: onPlay)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                if let artist = song.artist, !artist.isEmpty {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                // Same actions + icons as the context menu (minus Play = the thumb).
                MusicRowActions(actions: [
                    MusicRowAction(title: "Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        model.music.playNext([song])
                    },
                    MusicRowAction(title: "Add to Queue", systemImage: "text.append") {
                        model.music.enqueue([song])
                    },
                    MusicRowAction(title: "Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                        startRadio()
                    },
                    downloadAction,
                    MusicRowAction(title: "Mark for Removal", systemImage: "xmark.bin", tint: .red) {
                        showRemoveConfirm = true
                    },
                ])
            }

            Text(song.duration.map { MusicTrackRow.formatDuration($0) } ?? "—")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            MusicRatingStars(song: song).frame(width: 110, alignment: .center)
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            songPlaybackMenuItems(song, model, onPlay: onPlay)
            Divider()
            songDownloadMenuItems(song, model)
            songRadioMenuItem(song, model)
            if let onRemoveFromPlaylist {
                Divider()
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive, action: onRemoveFromPlaylist)
            }
            Divider()
            songRemovalMenuItem(showConfirm: $showRemoveConfirm)
        }
        .songRemovalConfirm(song, model, isPresented: $showRemoveConfirm)
    }

    /// Download toggle — same icons the context menu uses (`arrow.down.circle` to
    /// download, `trash.slash` to remove the local copy), plus a transient fetching glyph.
    private var downloadAction: MusicRowAction {
        if isDownloading {
            return MusicRowAction(title: "Downloading…", systemImage: "arrow.down.circle.dotted") {}
        } else if isDownloaded {
            return MusicRowAction(title: "Remove Download", systemImage: "trash.slash", run: removeDownload)
        } else {
            return MusicRowAction(title: "Download", systemImage: "arrow.down.circle", run: downloadSong)
        }
    }

    private func startRadio() {
        Task {
            let radio = await model.musicLibrary.similarSongs(seedID: song.id)
            model.music.play([song] + radio, source: .init(label: "\(song.title) Radio", kind: .radio, id: nil))
        }
    }
}

/// The card form of a liked song for the Liked → Songs **grid** layout — the shared
/// `MusicMediaCard` (cover, title, artist, duration) plus a hover/selected checkbox
/// overlay. Clicking the card (or the hover play button) plays from this song.
struct LikedSongGridCell: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    var isSelected: Bool
    var showLikeBadge: Bool = true
    /// Whether the multi-select checkbox overlay is available (off on pages without
    /// selection, e.g. the artist detail).
    var showSelect: Bool = true
    var onToggleSelect: () -> Void = {}
    var onPlay: () -> Void
    @State private var hovering = false
    @State private var showRemoveConfirm = false

    private var coverURL: URL? { song.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 400) } }
    private var isCurrent: Bool { model.music.nowPlaying?.id == song.id }

    var body: some View {
        MusicMediaCard(
            coverURL: coverURL,
            placeholder: "music.note",
            title: song.title,
            subtitle: song.artist ?? "",
            trailingBottom: song.duration.map { MusicTrackRow.formatDuration($0) },
            isHovering: hovering,
            isPlayingSource: isCurrent,
            onPlay: onPlay
        )
        .overlay(alignment: .topLeading) {
            if showSelect, hovering || isSelected {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showLikeBadge {
                SongHeartBadge(song: song, visible: hovering, size: 14).padding(6)
            }
        }
        .scaleEffect(hovering ? 1.06 : 1)
        .zIndex(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            songPlaybackMenuItems(song, model, onPlay: onPlay)
            Divider()
            songDownloadMenuItems(song, model)
            songRadioMenuItem(song, model)
            Divider()
            songRemovalMenuItem(showConfirm: $showRemoveConfirm)
        }
        .songRemovalConfirm(song, model, isPresented: $showRemoveConfirm)
    }
}
