import SwiftUI

/// The full in-app music player: search + browse (albums / artists / playlists /
/// liked), inline ratings, playlist management, and a persistent now-playing bar.
/// Hosted both in the pop-out `MusicWindowView` and reachable from the left rail.
/// Gated on a configured connection.
struct MusicView: View {
    @Environment(MusicModel.self) private var model
    @State private var tab: MusicTab = .home
    @State private var path = NavigationPath()
    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false
    @State private var showFullScreen = false
    @State private var paletteLoader = ArtworkPaletteLoader()
    // Playlists tab filter/sort.
    @State private var playlistSearch = ""
    @State private var playlistSort: PlaylistSort = .name
    @State private var playlistSortAscending = true
    @State private var hideEmptyPlaylists = false
    @State private var albumSearch = ""
    @State private var albumSortAscending = true
    // List ⇄ Grid layout per browse screen (Albums / Playlists default to grid).
    @AppStorage("tonebox.music.albumLayout") private var albumLayout: MusicBrowseLayout = .grid
    @AppStorage(ArtistHeuristics.hideAutoImportsKey) private var hideAutoImports = false
    @AppStorage("tonebox.music.playlistLayout") private var playlistLayout: MusicBrowseLayout = .grid
    /// Collapse the left rail to an icons-only strip. Persisted.
    @AppStorage("tonebox.music.railCollapsed") private var railCollapsed = false
    /// Close action for the pop-out window (nil inline). Drives the rail's close button.
    @Environment(\.musicWindowClose) private var windowClose
    @State private var closeHovering = false

    // Multi-select for the Albums / Playlists browse tabs (shared model + bar).
    @State private var albumSel = MusicMultiSelect()
    @State private var playlistSel = MusicMultiSelect()
    @State private var showAlbumRemoveConfirm = false
    @State private var showPlaylistDeleteConfirm = false
    @FocusState private var albumFilterFocused: Bool
    @FocusState private var playlistFilterFocused: Bool

    private var orderedAlbumIDs: [String] { filteredAlbums.map(\.id) }
    private var selectedAlbums: [NavidromeAlbum] { filteredAlbums.filter { albumSel.contains($0.id) } }
    private var orderedPlaylistIDs: [String] { filteredPlaylists.map(\.id) }
    private var selectedPlaylists: [NavidromePlaylist] { filteredPlaylists.filter { playlistSel.contains($0.id) } }

    /// Albums after the tab's filter (name / artist) + direction. Field order comes
    /// from the server fetch (AlbumSort); the direction toggle reverses the result.
    private var filteredAlbums: [NavidromeAlbum] {
        let q = albumSearch.trimmingCharacters(in: .whitespaces).lowercased()
        var list = library.albums
        if hideAutoImports {
            list = list.filter { !ArtistHeuristics.isAutoImportAlbum(name: $0.name, artist: $0.artist) }
        }
        if !q.isEmpty {
            list = list.filter { $0.name.lowercased().contains(q) || ($0.artist ?? "").lowercased().contains(q) }
        }
        if !albumSortAscending { list.reverse() }
        return list
    }
    /// Shared namespace so the mini-bar artwork morphs into the full-screen hero.
    @Namespace private var artNamespace

    enum PlaylistSort: String, CaseIterable, Identifiable, MusicSortField {
        case name, tracks
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: "Name"
            case .tracks: "Track count"
            }
        }
    }

    /// Playlists after the tab's search / hide-empty / sort controls are applied.
    private var filteredPlaylists: [NavidromePlaylist] {
        var list = model.musicLibrary.playlists
        let query = playlistSearch.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { list = list.filter { $0.name.lowercased().contains(query) } }
        if hideEmptyPlaylists { list = list.filter { $0.songCount > 0 } }
        switch playlistSort {
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .tracks: list.sort { $0.songCount < $1.songCount }
        }
        if !playlistSortAscending { list.reverse() }
        return list
    }

    enum MusicTab: String, CaseIterable, Identifiable {
        case home, search, mixes, albums, artists, playlists, starred, history, podcasts, radio, downloads
        var id: String {
            rawValue
        }

        var label: String {
            switch self {
            case .home: "Home"
            case .search: "Search"
            case .mixes: "Mixes"
            case .albums: "Albums"
            case .artists: "Artists"
            case .playlists: "Playlists"
            case .starred: "Liked"
            case .history: "History"
            case .podcasts: "Podcasts"
            case .radio: "Radio"
            case .downloads: "Downloads"
            }
        }

        var icon: String {
            switch self {
            case .home: "house.fill"
            case .search: "magnifyingglass"
            case .mixes: "square.grid.2x2.fill"
            case .albums: "square.stack"
            case .artists: "music.mic"
            case .playlists: "music.note.list"
            case .starred: "heart"
            case .history: "clock.arrow.circlepath"
            case .podcasts: "mic.fill"
            case .radio: "dot.radiowaves.left.and.right"
            case .downloads: "arrow.down.circle"
            }
        }
    }

    private var library: MusicLibraryStore {
        model.musicLibrary
    }

    private var nowPlayingCoverURL: URL? {
        guard let id = model.music.nowPlaying?.coverArtID else { return nil }
        return library.coverArtURL(id: id, size: ArtworkColorExtractor.coverSize)
    }

    var body: some View {
        Group {
            if library.isConfigured {
                ZStack {
                    // Whole-window color-from-artwork wash (Plexamp UltraBlur), tinted
                    // from the now-playing track; frosted so lists stay readable.
                    AdaptiveBackdrop(palette: paletteLoader.palette)
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            sidebar
                            Divider()
                            NavigationStack(path: $path) {
                                content
                                    .navigationDestination(for: NavidromeAlbum.self) { MusicAlbumDetail(album: $0) }
                                    .navigationDestination(for: NavidromeArtist.self) { MusicArtistDetail(artist: $0) }
                                    .navigationDestination(for: NavidromePlaylist.self) {
                                        MusicPlaylistDetail(playlist: $0)
                                    }
                                    .navigationDestination(for: MusicMix.self) { MusicMixDetail(mix: $0) }
                            }
                            .scrollContentBackground(.hidden)
                        }
                        .musicActionToast()
                        NowPlayingBar(
                            artNamespace: artNamespace, expanded: showFullScreen,
                            accent: paletteLoader.palette.uiAccent
                        ) {
                            // Pop any drill-down to root so the window-titlebar back
                            // button (which would sit next to the traffic lights and
                            // pop navigation behind the full-screen overlay — a dead
                            // button) isn't shown while the player is up. Keeps the
                            // window controls intact (unlike hiding the whole toolbar).
                            path = NavigationPath()
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { showFullScreen = true }
                        }
                    }
                    .background(.ultraThinMaterial)
                }
                .overlay {
                    if showFullScreen {
                        FullScreenNowPlaying(isPresented: $showFullScreen, artNamespace: artNamespace)
                            .transition(.opacity)
                            .zIndex(10)
                    }
                }
                // Dark scheme so text/icons stay readable over the color-from-artwork
                // backdrop (the library was near-black text on a warm wash in Light
                // mode) — and consistent with the full-screen player.
                .preferredColorScheme(.dark)
                .onAppear { paletteLoader.update(url: nowPlayingCoverURL) }
                .onChange(of: model.music.nowPlaying?.coverArtID) { _, _ in
                    paletteLoader.update(url: nowPlayingCoverURL)
                }
            } else {
                MusicNotConnectedView()
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    /// Left navigation rail — sections + selection highlight. Collapses to an
    /// icons-only strip to save space; collapse toggle pinned top-right.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            railHeader
            ForEach(MusicTab.allCases) { item in
                sidebarRow(item)
            }
            Spacer()
        }
        // Top row aligns with the content header's title (matching top inset).
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 12)
        .frame(width: railCollapsed ? 56 : 176)
        .animation(.easeInOut(duration: 0.2), value: railCollapsed)
        // Prefetch the collections so their nav badges populate without visiting each
        // tab. Guarded so it doesn't refetch what's already loaded.
        .task {
            if library.albums.isEmpty { await library.loadAlbums() }
            if library.artists.isEmpty { await library.loadArtists() }
            if library.playlists.isEmpty { await library.loadPlaylists() }
            if library.starred.songs.isEmpty, library.starred.albums.isEmpty, library.starred.artists.isEmpty {
                await library.loadStarred()
            }
            // Prefetch radio stations so the Radio nav badge populates like the others.
            await model.internetRadio.loadIfNeeded()
        }
    }

    @ViewBuilder
    private func sidebarRow(_ item: MusicTab) -> some View {
        let selected = tab == item
        Button {
            tab = item
            path = NavigationPath() // leave any drill-down when switching sections
        } label: {
            Group {
                if railCollapsed {
                    // Icon only, centered; no count badge when collapsed. Tooltip names
                    // the section.
                    Image(systemName: item.icon)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                        .frame(maxWidth: .infinity)
                        .help(item.label)
                } else {
                    HStack(spacing: 6) {
                        Label(item.label, systemImage: item.icon)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                        Spacer(minLength: 4)
                        if let count = tabCount(item) {
                            Text("\(count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(
                                    Capsule().fill(selected ? Color.badgeTint() : Color.badgeIdleTint)
                                )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, railCollapsed ? 4 : 10).padding(.vertical, 7)
            .background(
                selected ? AnyShapeStyle(Color.sidebarSelectionTint()) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.18), value: selected)
        }
        .buttonStyle(.plain)
    }

    /// The rail's top line: a single round **close** button (pop-out window only) and the
    /// collapse/expand chevron — both aligned with the content header's title. Expanded:
    /// close leading, chevron trailing on one line. Collapsed: stacked and centered so they
    /// line up with the icon column below.
    @ViewBuilder
    private var railHeader: some View {
        if railCollapsed {
            // Collapsed: no room for traffic lights → a single red close button (pop-out
            // only) stacked above the expand chevron, centered with the icon column.
            VStack(spacing: 8) {
                if let windowClose { closeButton(windowClose) }
                collapseChevron
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
        } else {
            // Expanded: the native traffic lights show at the top-left; the rail just needs
            // the collapse chevron on the right.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                collapseChevron
            }
            .padding(.bottom, 2)
        }
    }

    /// A red, traffic-light-style round button that closes the pop-out window (⌘W also
    /// works). Shows an ✕ on hover, like the real close control.
    private func closeButton(_ action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.black.opacity(0.55))
                    .opacity(closeHovering ? 1 : 0)
            }
            .frame(width: 14, height: 14)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { closeHovering = $0 }
        .help("Close window (⌘W)")
    }

    /// Collapse / expand the rail (icons-only ⇄ full).
    private var collapseChevron: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { railCollapsed.toggle() }
        } label: {
            Image(systemName: railCollapsed ? "sidebar.left" : "chevron.left.2")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: railCollapsed ? nil : 30, height: 28)
                .frame(maxWidth: railCollapsed ? .infinity : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(railCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    /// Item count for a nav badge (nil = no badge — Search has no fixed total, and a
    /// not-yet-loaded collection shows nothing rather than a misleading 0).
    private func tabCount(_ item: MusicTab) -> Int? {
        switch item {
        case .home: nil
        case .search: nil
        case .mixes: nil
        case .albums: library.albums.isEmpty ? nil : library.albums.count
        case .artists: library.artists.isEmpty ? nil : library.artists.count
        case .playlists: library.playlists.isEmpty ? nil : library.playlists.count
        case .starred:
            {
                let total = library.starred.songs.count + library.starred.albums.count + library.starred.artists.count
                return total == 0 ? nil : total
            }()
        case .history:
            model.musicHistory.recentlyPlayed.isEmpty ? nil : model.musicHistory.recentlyPlayed.count
        case .radio: model.internetRadio.stations.isEmpty ? nil : model.internetRadio.stations.count
        case .downloads:
            MusicDownloadStore.shared.downloadedIDs.isEmpty ? nil : MusicDownloadStore.shared.downloadedIDs.count
        case .podcasts: nil
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Every browse tab (incl. Search) renders its own two-row header.
            if let error = library.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .home: MusicHomeView()
        case .search: MusicSearchView()
        case .mixes: MusicMixesView()
        case .albums: albumsTab
        case .artists: artistsTab
        case .playlists: playlistsTab
        case .starred: starredTab
        case .history: MusicHistoryView()
        case .podcasts: MusicPodcastsView()
        case .radio: MusicRadioView()
        case .downloads: MusicDownloadsView()
        }
    }

    // MARK: - Tabs

    private var albumsTab: some View {
        VStack(spacing: 0) {
            MusicBrowseHeader(
                title: "Albums",
                count: filteredAlbums.count,
                filter: $albumSearch,
                filterPrompt: "Filter albums",
                filterFocused: $albumFilterFocused,
                filterHistoryKey: "albums",
                layout: $albumLayout,
                accessory: { EmptyView() },
                leading: {
                    if albumSel.isEmpty {
                        MusicMiniTransport()
                        Toggle(isOn: $hideAutoImports) { Text("Hide auto-imports") }
                            .toggleStyle(.button).controlSize(.small)
                            .help("Hide auto-imported YT/junk albums")
                        if !filteredAlbums.isEmpty {
                            selectAllButton("Select all albums (⌘A)", albumFilterFocused) { albumSel.selectAll(orderedAlbumIDs) }
                        }
                    } else {
                        albumSelectionBar
                    }
                },
                sortMenu: {
                    MusicSortControls(
                        ascending: $albumSortAscending,
                        selection: Binding(
                            get: { library.albumSort },
                            set: { newValue in
                                guard library.albumSort != newValue else { return }
                                library.albumSort = newValue
                                Task { await library.loadAlbums() }
                            }
                        )
                    )
                }
            )
            if albumLayout == .list {
                VStack(spacing: 0) {
                    BrowseColumns.header("Album", showTime: true, showRating: true, selectable: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredAlbums) { album in
                                MusicAlbumRow(
                                    album: album,
                                    isSelected: albumSel.contains(album.id),
                                    onToggleSelect: { albumSel.clicked(album.id, ordered: orderedAlbumIDs) }
                                )
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity).padding(.horizontal, 16)
            } else {
                ScrollView { albumGrid(filteredAlbums).padding(12) }
            }
        }
        .task { if library.albums.isEmpty { await library.loadAlbums() } }
        .onChange(of: orderedAlbumIDs) { albumSel.reconcile(orderedAlbumIDs) }
        .confirmationDialog(
            "Mark all tracks in \(selectedAlbums.count) album\(selectedAlbums.count == 1 ? "" : "s") for removal?",
            isPresented: $showAlbumRemoveConfirm, titleVisibility: .visible
        ) {
            Button("Mark All for Removal", role: .destructive) { batchAlbumRemove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every track in the selected albums is unliked and rated 1 star — the signal the cleanup pipeline uses to prune them.")
        }
    }

    private var artistsTab: some View {
        MusicArtistsBrowser()
    }

    private var playlistsTab: some View {
        VStack(spacing: 0) {
            MusicBrowseHeader(
                title: "Playlists",
                count: filteredPlaylists.count,
                filter: $playlistSearch,
                filterPrompt: "Filter playlists",
                filterFocused: $playlistFilterFocused,
                filterHistoryKey: "playlists",
                layout: $playlistLayout,
                accessory: { EmptyView() },
                leading: {
                    if playlistSel.isEmpty {
                        MusicMiniTransport()
                        Button { showingNewPlaylist = true } label: { Label("New Playlist", systemImage: "plus") }
                            .controlSize(.small)
                        if !filteredPlaylists.isEmpty {
                            selectAllButton("Select all playlists (⌘A)", playlistFilterFocused) { playlistSel.selectAll(orderedPlaylistIDs) }
                        }
                    } else {
                        playlistSelectionBar
                    }
                },
                sortMenu: {
                    MusicSortControls(ascending: $playlistSortAscending, selection: $playlistSort) {
                        Divider()
                        Toggle("Hide empty playlists", isOn: $hideEmptyPlaylists)
                    }
                }
            )
            if library.playlists.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No playlists yet").foregroundStyle(.secondary)
                    Text("Create one with “New Playlist”, or save a queue as a playlist.")
                        .font(.callout).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredPlaylists.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No playlists match “\(playlistSearch)”").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playlistLayout == .list {
                VStack(spacing: 0) {
                    BrowseColumns.header("Playlist", showTime: true, selectable: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredPlaylists) { playlist in
                                MusicPlaylistRow(
                                    playlist: playlist,
                                    isSelected: playlistSel.contains(playlist.id),
                                    onToggleSelect: { playlistSel.clicked(playlist.id, ordered: orderedPlaylistIDs) }
                                ) {
                                    Task { await library.deletePlaylist(id: playlist.id) }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity).padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(filteredPlaylists) { playlist in
                            PlaylistGridCell(
                                playlist: playlist,
                                isSelected: playlistSel.contains(playlist.id),
                                onToggleSelect: { playlistSel.clicked(playlist.id, ordered: orderedPlaylistIDs) }
                            ) {
                                Task { await library.deletePlaylist(id: playlist.id) }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task { if library.playlists.isEmpty { await library.loadPlaylists() } }
        .onChange(of: orderedPlaylistIDs) { playlistSel.reconcile(orderedPlaylistIDs) }
        .confirmationDialog(
            "Delete \(selectedPlaylists.count) playlist\(selectedPlaylists.count == 1 ? "" : "s")?",
            isPresented: $showPlaylistDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { batchPlaylistDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently removes the selected playlists. The songs themselves aren't deleted.")
        }
        .alert("New playlist", isPresented: $showingNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                newPlaylistName = ""
                if !name.isEmpty { Task { await library.createPlaylist(name: name) } }
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        }
    }

    private var starredTab: some View {
        MusicLikedView()
    }

    // MARK: - Reusable

    func albumGrid(_ albums: [NavidromeAlbum]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(albums) { album in
                AlbumGridCell(
                    album: album,
                    selectable: true,
                    isSelected: albumSel.contains(album.id),
                    onToggleSelect: { albumSel.clicked(album.id, ordered: orderedAlbumIDs) }
                )
            }
        }
    }

    /// A compact "Select all" affordance for a browse header (⌘A when the filter field
    /// isn't focused), shown when nothing is selected yet.
    private func selectAllButton(_ help: String, _ filterFocused: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Select", systemImage: "checklist").font(.caption).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .keyboardShortcut(filterFocused ? nil : KeyboardShortcut("a", modifiers: .command))
        .help(help)
    }

    // MARK: - Album batch actions (via shared MusicBatchActions)

    private func albumTracks() async -> [NavidromeSong] { await MusicBatchActions.songs(ofAlbums: selectedAlbums, model) }

    private var albumSelectionBar: some View {
        let label = "\(selectedAlbums.count) albums"
        let name = selectedAlbums.count == 1 ? (selectedAlbums.first?.name ?? label) : "\(selectedAlbums.count) Albums"
        return MusicSelectionBar(
            count: selectedAlbums.count,
            allSelected: albumSel.allSelected(orderedAlbumIDs),
            selectAllShortcut: !albumFilterFocused,
            onToggleSelectAll: { albumSel.toggleSelectAll(orderedAlbumIDs) },
            onClear: { albumSel.clear() }
        ) {
            MusicBatchButton(system: "play.fill", help: "Play selected") { MusicBatchActions.play(model, shuffle: false, label: label, kind: .album, gather: albumTracks) }
            MusicBatchButton(system: "shuffle", help: "Shuffle selected") { MusicBatchActions.play(model, shuffle: true, label: label, kind: .album, gather: albumTracks) }
            MusicBatchButton(system: "text.append", help: "Add to queue") { MusicBatchActions.queue(model, gather: albumTracks) }
            MusicBatchButton(system: "square.and.arrow.down", help: "Save as playlist") { MusicBatchActions.save(model, name: name, gather: albumTracks) }
            MusicBatchAddToPlaylistMenu(gather: albumTracks)
            MusicBatchButton(system: "arrow.down.circle", help: "Download") { MusicBatchActions.download(model, gather: albumTracks) }
            MusicBatchButton(system: "xmark.bin", help: "Mark all for removal") { showAlbumRemoveConfirm = true }
        }
    }

    private func batchAlbumRemove() { MusicBatchActions.markForRemoval(model, gather: albumTracks) { albumSel.clear() } }

    // MARK: - Playlist batch actions (via shared MusicBatchActions)

    private func playlistTracks() async -> [NavidromeSong] { await MusicBatchActions.songs(ofPlaylists: selectedPlaylists, model) }

    private var playlistSelectionBar: some View {
        let label = "\(selectedPlaylists.count) playlists"
        return MusicSelectionBar(
            count: selectedPlaylists.count,
            allSelected: playlistSel.allSelected(orderedPlaylistIDs),
            selectAllShortcut: !playlistFilterFocused,
            onToggleSelectAll: { playlistSel.toggleSelectAll(orderedPlaylistIDs) },
            onClear: { playlistSel.clear() }
        ) {
            MusicBatchButton(system: "play.fill", help: "Play selected") { MusicBatchActions.play(model, shuffle: false, label: label, kind: .playlist, gather: playlistTracks) }
            MusicBatchButton(system: "shuffle", help: "Shuffle selected") { MusicBatchActions.play(model, shuffle: true, label: label, kind: .playlist, gather: playlistTracks) }
            MusicBatchButton(system: "text.append", help: "Add to queue") { MusicBatchActions.queue(model, gather: playlistTracks) }
            MusicBatchButton(system: "arrow.down.circle", help: "Download") { MusicBatchActions.download(model, gather: playlistTracks) }
            MusicBatchButton(system: "trash", help: "Delete selected", tint: .red) { showPlaylistDeleteConfirm = true }
        }
    }

    /// Playlist deletion is not song-based — it removes the containers themselves.
    private func batchPlaylistDelete() {
        let playlists = selectedPlaylists
        guard !playlists.isEmpty else { return }
        Task {
            for playlist in playlists { await library.deletePlaylist(id: playlist.id) }
            model.music.postToast("Deleted \(playlists.count) playlist\(playlists.count == 1 ? "" : "s")", symbol: "trash")
            playlistSel.clear()
        }
    }
}

/// A hover-lifting album cell. A *single* `.onHover` here drives the card's play
/// button, the scale, and the `zIndex` lift — nesting a second `.onHover` inside
/// the card makes this outer one miss events, so the card takes hover as input.
/// `LazyVGrid` honors the `zIndex`, so the hovered card rises above its neighbors.
struct AlbumGridCell: View {
    @Environment(MusicModel.self) private var model
    let album: NavidromeAlbum
    /// Whether the multi-select checkbox is offered (off in contexts without a selection,
    /// e.g. the artist-detail albums section).
    var selectable = false
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    @State private var hovering = false
    @State private var showRemoveConfirm = false

    private func run(_ body: @escaping () async -> Void) { Task { await body() } }

    var body: some View {
        NavigationLink(value: album) { MusicAlbumCard(album: album, previewHovering: hovering) }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) {
                if selectable, hovering || isSelected {
                    MusicSelectCheckbox(isSelected: isSelected, onToggle: onToggleSelect)
                        .padding(6).shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                }
            }
            .scaleEffect(hovering ? 1.06 : 1)
            .zIndex(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: hovering)
            .onHover { hovering = $0 }
            // Full parity with the album list row + artist card: identical right-click menu.
            .contextMenu {
                albumActionMenuItems(album, model, run: run, onRemove: { showRemoveConfirm = true })
            }
            .albumRemovalConfirm(album, isPresented: $showRemoveConfirm) {
                run { await AlbumActions.markAllForRemoval(album, model) }
            }
    }
}

/// A compact album cover card. Hover state is supplied by the enclosing
/// `AlbumGridCell` (`previewHovering`) — the card itself no longer tracks hover,
/// to avoid nested `.onHover` swallowing the cell's events.
struct MusicAlbumCard: View {
    @Environment(MusicModel.self) private var model
    let album: NavidromeAlbum
    /// Hover state, driven by the enclosing cell (or forced in snapshots).
    var previewHovering = false

    private var isHovering: Bool {
        previewHovering
    }

    private var coverURL: URL? {
        guard let coverID = album.coverArtID else { return nil }
        return model.musicLibrary.coverArtURL(id: coverID, size: 400)
    }

    /// The descriptive line to lead with. These YT imports store the video title
    /// in `artist` and a constant source ("YT Mix") in `name`, so prefer `artist`.
    private var cardTitle: String {
        let artist = (album.artist ?? "").trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? album.name : artist
    }

    private var cardSubtitle: String {
        let artist = (album.artist ?? "").trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? "" : album.name
    }

    private var trackCountText: String? {
        guard let count = album.songCount, count > 0 else { return nil }
        return "\(count) track\(count == 1 ? "" : "s")"
    }

    private var durationText: String? {
        guard let duration = album.duration, duration > 0 else { return nil }
        return Self.albumDuration(duration)
    }

    private var isPlayingSource: Bool {
        let source = model.music.queueSource
        return source?.kind == .album && source?.id == album.id
    }

    var body: some View {
        MusicMediaCard(
            coverURL: coverURL,
            title: cardTitle,
            subtitle: cardSubtitle,
            trailingTop: trackCountText,
            trailingBottom: durationText,
            isHovering: isHovering,
            isPlayingSource: isPlayingSource,
            onPlay: playAlbum
        )
    }

    /// Compact total-length label for an album: "1h 12m" / "47 min".
    static func albumDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds)s"
    }

    private func playAlbum() {
        Task {
            let songs = await model.musicLibrary.albumSongs(id: album.id)
            if !songs.isEmpty {
                model.music.play(songs, source: .init(label: album.name, kind: .album, id: album.id))
            }
        }
    }
}

/// Shown when no music server is configured — gates the whole player.
struct MusicNotConnectedView: View {
    @State private var showConnect = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.house").font(.largeTitle).foregroundStyle(.secondary)
            Text("No music server connected").font(.headline)
            Text("Connect a Navidrome or Subsonic server to browse and play your library.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Connect a Server…") { showConnect = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showConnect) { BatonConnectSheet() }
    }
}
