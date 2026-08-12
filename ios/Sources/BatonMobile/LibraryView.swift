import SwiftUI
import BatonPlaybackKit

/// The Library tab: Liked, Playlists, and Downloads over the shared stores.
struct LibraryView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash

    /// Same total the Mac's Liked row counts: songs + albums + artists.
    /// `.badge(0)` renders nothing, so an empty section stays clean without
    /// a special case.
    private var likedCount: Int {
        let starred = model.musicLibrary.starred
        return starred.songs.count + starred.albums.count + starred.artists.count
    }

    @State private var layout = LibraryLayout()
    @State private var isEditing = false

    var body: some View {
        NavigationStack {
            List {
                if isEditing {
                    // Every section, visible or not, each with a toggle and a drag
                    // handle — the fixed eight-row list was the average of everyone's
                    // needs and nobody's actual ones.
                    ForEach(layout.order) { section in
                        HStack(spacing: 12) {
                            Button {
                                layout.setVisible(section, !layout.isVisible(section))
                            } label: {
                                Image(systemName: layout.isVisible(section)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(layout.isVisible(section) ? Color.accentColor : .secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(layout.isVisible(section)
                                                ? "Hide \(section.title)" : "Show \(section.title)")
                            Label(section.title, systemImage: section.symbol)
                        }
                    }
                    .onMove { source, destination in
                        layout.move(fromOffsets: source, toOffset: destination)
                    }
                } else {
                    ForEach(layout.visible) { section in
                        row(for: section)
                    }
                }
            }
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .nowPlayingWash(wash)
            .rootScreenHeader("Library", subtitle: summaryLine) {
                Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                    .font(.body.weight(isEditing ? .semibold : .regular))
            }
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album, model: model)
            }
            .readableWidth()
        }
    }

    @ViewBuilder
    private func row(for section: LibrarySection) -> some View {
        switch section {
        case .liked:
            NavigationLink { LikedView(model: model) } label: {
                Label("Liked", systemImage: section.symbol).badge(likedCount)
            }
        case .playlists:
            NavigationLink { PlaylistsView(model: model) } label: {
                Label("Playlists", systemImage: section.symbol)
                    .badge(model.musicLibrary.playlists.count)
            }
        case .artists:
            NavigationLink { ArtistsView(model: model) } label: {
                Label("Artists", systemImage: section.symbol)
                    .badge(model.musicLibrary.artists.count)
            }
        case .genres:
            NavigationLink { GenresView(model: model) } label: {
                Label("Genres", systemImage: section.symbol)
            }
        case .history:
            NavigationLink { HistoryView(model: model) } label: {
                Label("History", systemImage: section.symbol)
                    .badge(model.history.recentlyPlayed.count)
            }
        case .downloads:
            NavigationLink { DownloadsView(model: model) } label: {
                Label("Downloads", systemImage: section.symbol)
                    // The *download* store, not `model.pins`. This badge read the
                    // save-for-later pin count, so a library with twelve things saved for
                    // later and nothing downloaded advertised twelve downloads.
                    .badge(MusicDownloadStore.shared.downloadedIDs.count)
            }
        case .podcasts:
            NavigationLink { PodcastsInlineView(model: model) } label: {
                Label("Podcasts", systemImage: section.symbol)
            }
        case .radio:
            NavigationLink { RadioView(model: model) } label: {
                Label("Radio", systemImage: section.symbol)
                    .badge(model.radio.stations.count)
            }
        case .folders:
            NavigationLink { FoldersView(model: model) } label: {
                Label("Folders", systemImage: section.symbol)
            }
        }
    }

    /// The two counts the rows below don't already make obvious at a glance. Each row
    /// carries its own badge, so repeating all of them here would be noise; playlists
    /// and downloads are the ones people came to check.
    private var summaryLine: String? {
        // Built from the same rows below, most-personal first, and capped at two so the
        // line stays scannable. Every row carries its own badge, so this is a summary
        // rather than a second copy of the list.
        let candidates: [String?] = [
            likedCount > 0 ? Counted.phrase(likedCount, "liked", plural: "liked") : nil,
            model.musicLibrary.playlists.count > 0
                ? Counted.phrase(model.musicLibrary.playlists.count, "playlist") : nil,
            MusicDownloadStore.shared.downloadedIDs.count > 0
                ? "\(MusicDownloadStore.shared.downloadedIDs.count) downloaded" : nil,
            model.musicLibrary.artists.count > 0
                ? Counted.phrase(model.musicLibrary.artists.count, "artist") : nil,
        ]
        return Counted.line(Array(candidates.compactMap { $0 }.prefix(2)))
    }
}

/// Liked — songs, albums and artists you've starred, with sort and a filter.
///
/// The Mac splits this three ways because "liked" means three different collections on a
/// Subsonic server, and a flat song list buries the other two. Sort matters here more
/// than elsewhere: a liked list is the one that grows without bound.
struct LikedView: View {
    let model: MobileModel

    // Only the Albums and Artists segments offer a grid. Liked *songs* stay a list: a song
    // is a title, an artist and a duration, and a wall of identical album covers is a
    // worse way to find one.
    @AppStorage(BrowseScreen.liked.layoutKey) private var layoutRaw = BrowseLayout.list.rawValue
    private var layout: BrowseLayout { BrowseLayout(rawValue: layoutRaw) ?? .list }
    private var layoutBinding: Binding<BrowseLayout> {
        Binding(get: { layout }, set: { layoutRaw = $0.rawValue })
    }

    enum Segment: String, CaseIterable, Identifiable {
        case songs, albums, artists
        var id: String { rawValue }
        var label: String {
            switch self {
            case .songs: "Songs"
            case .albums: "Albums"
            case .artists: "Artists"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case recent, title, artist
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: "Recently added"
            case .title: "Title"
            case .artist: "Artist"
            }
        }
    }

    @State private var segment: Segment = .songs
    @State private var sort: Sort = .recent
    @State private var filter = ""
    /// Phone-native batch editing. The Mac uses Finder-style shift-click, which is a
    /// pointer idiom; selection + a toolbar is what a thumb can drive.
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var showsBatchPlaylist = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Picker("View", selection: $segment) {
                        ForEach(Segment.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }

                switch segment {
                case .songs: songsSection
                case .albums: layout == .grid ? AnyView(albumsGrid) : AnyView(albumsSection)
                case .artists: layout == .grid ? AnyView(artistsGrid) : AnyView(artistsSection)
                }
            }
            // The A–Z rail, indexing whichever segment is showing.
            //
            // Liked is the list this app's own code calls "the one that grows without
            // bound", and it was the only long alphabetical list on the phone with no way
            // to jump — Albums, Artists and Folders all had one.
            .alphabetIndexRail(indexEntries, proxy: proxy)
        }
        .listStyle(.plain)
        .searchable(text: $filter, prompt: "Filter liked")
        .searchKeyboardDismissal()
        .navigationTitle("Liked")
        .toolbar {
            // Only where a grid is on offer — a picker over the Songs segment would be a
            // control that does nothing.
            if segment != .songs {
                ToolbarItem(placement: .topBarTrailing) { LayoutPicker(layout: layoutBinding) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !selection.isEmpty { selectionBar }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            if segment == .songs {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Done" : "Select") {
                        if isSelecting { endSelecting() } else { isSelecting = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showsBatchPlaylist) {
            PlaylistPickerSheet(songIDs: Array(selection), model: model)
        }
        .task { await model.musicLibrary.loadStarred() }
        .refreshable { await model.musicLibrary.loadStarred() }
        .overlay {
            if isEmpty {
                ContentUnavailableView("Nothing liked yet", systemImage: "heart",
                                       description: Text("Tap the heart on a track, album or artist and it turns up here."))
            }
        }
    }

    @ViewBuilder
    private var songsSection: some View {
        let songs = sorted(filtered(model.musicLibrary.starred.songs))
        Section {
            ForEach(songs) { song in
                HStack(spacing: 10) {
                    if isSelecting {
                        Image(systemName: selection.contains(song.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(song.id) ? Color.accentColor : .secondary)
                    }
                    // The Liked screen is liked-by-construction: a heart on every row is
                    // decoration that costs a glance, and crowds the downloaded/playing
                    // marks that actually vary.
                    SongRow(song: song, model: model)
                        .likedByConstruction()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelecting {
                        if selection.contains(song.id) { selection.remove(song.id) } else { selection.insert(song.id) }
                    } else {
                        model.music.play(songs, startAt: songs.firstIndex(of: song) ?? 0,
                                         source: .init(label: "Liked", kind: .liked))
                    }
                }
                .songContextMenu(song, model: model)
            }
        }
    }

    /// The batch bar — only the actions that make sense on a multi-selection.
    private var selectionBar: some View {
        HStack(spacing: 18) {
            Button {
                let songs = selectedSongs
                model.music.enqueue(songs)
                endSelecting()
            } label: { Label("Queue", systemImage: "text.append") }

            Button {
                showsBatchPlaylist = true
            } label: { Label("Playlist", systemImage: "music.note.list") }

            Button {
                Task { _ = await MusicDownloadStore.shared.download(selectedSongs) }
                endSelecting()
            } label: { Label("Download", systemImage: "arrow.down.circle") }

            Button(role: .destructive) {
                let songs = selectedSongs
                endSelecting()
                Task { for song in songs { await model.musicLibrary.toggleLike(song) } }
            } label: { Label("Unlike", systemImage: "heart.slash") }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var selectedSongs: [NavidromeSong] {
        model.musicLibrary.starred.songs.filter { selection.contains($0.id) }
    }

    private func endSelecting() {
        selection = []
        isSelecting = false
    }

    /// Liked albums as tiles.
    private var albumsGrid: some View {
        let albums = model.musicLibrary.starred.albums.filter { matches($0.name, $0.artist) }
        return LazyVGrid(columns: BrowseGrid.columns, spacing: BrowseGrid.spacing) {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album, model: model)
                } label: {
                    BrowseTile(
                        artwork: model.musicLibrary.coverArtURL(
                            id: album.coverArtID ?? album.id, size: 400),
                        title: album.name,
                        subtitle: Counted.line([album.artist, PlayTime.total(album.duration)])
                    )
                }
                .buttonStyle(.plain)
                .albumContextMenu(album, model: model)
            }
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// Liked artists as portraits.
    private var artistsGrid: some View {
        let artists = model.musicLibrary.starred.artists.filter { matches($0.name, nil) }
        return LazyVGrid(columns: BrowseGrid.columns, spacing: BrowseGrid.spacing) {
            ForEach(artists) { artist in
                NavigationLink {
                    ArtistDetailView(artist: artist, model: model)
                } label: {
                    BrowseTile(artwork: model.musicLibrary.coverArtURL(
                                   id: artist.coverArtID ?? artist.id, size: 400),
                               title: artist.name)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var albumsSection: some View {
        let albums = model.musicLibrary.starred.albums.filter { matches($0.name, $0.artist) }
        Section {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album, model: model)
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 120))
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading) {
                            Text(album.name).lineLimit(1)
                            Text(Counted.line([album.artist, PlayTime.total(album.duration)]) ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .albumContextMenu(album, model: model)
            }
        }
    }

    @ViewBuilder
    private var artistsSection: some View {
        let artists = model.musicLibrary.starred.artists.filter { matches($0.name, nil) }
        Section {
            ForEach(artists) { artist in
                NavigationLink {
                    ArtistDetailView(artist: artist, model: model)
                } label: {
                    Label(artist.name, systemImage: "music.mic")
                }
            }
        }
    }

    private var isEmpty: Bool {
        switch segment {
        case .songs: model.musicLibrary.starred.songs.isEmpty
        case .albums: model.musicLibrary.starred.albums.isEmpty
        case .artists: model.musicLibrary.starred.artists.isEmpty
        }
    }

    private func matches(_ name: String, _ artist: String?) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(needle)
            || (artist ?? "").localizedCaseInsensitiveContains(needle)
    }

    private func filtered(_ songs: [NavidromeSong]) -> [NavidromeSong] {
        songs.filter { matches($0.title, $0.artist) }
    }

    /// "Recently added" keeps the server's own order — Subsonic returns starred items
    /// newest-first, and re-deriving that locally would only be able to guess.
    /// Rail entries for the visible segment.
    ///
    /// Same rules as Albums, Artists and Folders: nothing while filtering (a rail over five
    /// hits is noise), and nothing under thirty items (below that, flicking beats jumping).
    /// Songs additionally need an alphabetical sort — jumping to "S" in a recently-added
    /// order is a question with no answer.
    /// The claim about ordering is now an argument rather than a `guard` this screen
    /// happens to remember to write — see `AlphabetIndex.Ordered`.
    private var indexEntries: AlphabetIndex.Ordered {
        guard filter.isEmpty else { return .none }
        switch segment {
        case .songs:
            let songs = sorted(filtered(model.musicLibrary.starred.songs))
            return .clientSorted(songs.map {
                ($0.id, sort == .artist ? ($0.artist ?? "") : $0.title)
            }, isAlphabetical: sort == .title || sort == .artist)
        case .albums, .artists:
            // No rail. `sorted(_:)` only ever ordered the songs segment — these two rows
            // come straight out of `getStarred2` in whatever order the server starred
            // them, and an index over that is the Genres bug in a second place: letters
            // that look like an alphabet over a list that isn't one. Sort these segments
            // and the rail can come back with them.
            return .none
        }
    }

    private func sorted(_ songs: [NavidromeSong]) -> [NavidromeSong] {
        switch sort {
        case .recent: songs
        case .title: songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: songs.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        }
    }
}

/// How the playlists list is ordered. Persisted, because a preference you re-choose on
/// every visit is not a preference.
enum PlaylistSort: String, CaseIterable, Identifiable {
    case name, tracks, duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .tracks: "Songs"
        case .duration: "Play time"
        }
    }

    /// Pure, so it's testable without a view in sight.
    func sorted(_ playlists: [NavidromePlaylist]) -> [NavidromePlaylist] {
        switch self {
        case .name: playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .tracks: playlists.sorted { $0.songCount > $1.songCount }
        case .duration: playlists.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        }
    }
}

/// "80 songs · 6h 57m". Public-ish shape so the tests can pin it.
func playlistSubtitle(_ playlist: NavidromePlaylist) -> String {
    let songs = Counted.phrase(playlist.songCount, "song")
    guard let time = PlayTime.total(playlist.duration) else { return songs }
    return "\(songs) · \(time)"
}

struct PlaylistsView: View {
    let model: MobileModel
    @AppStorage("baton.playlists.sort") private var sortRaw = PlaylistSort.name.rawValue
    @State private var showsNew = false
    @State private var newName = ""
    @State private var renaming: NavidromePlaylist?
    @State private var renameText = ""
    @State private var deleting: NavidromePlaylist?
    /// Every other long list in the app can be narrowed; this one could only be sorted.
    @State private var filter = ""

    private var sort: PlaylistSort { PlaylistSort(rawValue: sortRaw) ?? .name }

    /// Sorted, then narrowed — the rail indexes this same list, so both have to see it.
    private var shown: [NavidromePlaylist] {
        let sorted = sort.sorted(model.musicLibrary.playlists)
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    // List by default: playlists are chosen by name and length, and this library has 324
    // of them — the grid is for the ones you made covers for.
    @AppStorage(BrowseScreen.playlist.layoutKey) private var layoutRaw = BrowseLayout.list.rawValue
    private var layout: BrowseLayout { BrowseLayout(rawValue: layoutRaw) ?? .list }
    private var layoutBinding: Binding<BrowseLayout> {
        Binding(get: { layout }, set: { layoutRaw = $0.rawValue })
    }

    /// Split out from `body` purely so the type-checker can finish: adding one more
    /// modifier to that chain tipped it past its budget ("unable to type-check this
    /// expression in reasonable time").
    private var indexedLayouts: some View {
        ScrollViewReader { proxy in
            Group {
                if layout == .grid { playlistGrid } else { playlistList }
            }
            // A–Z over whichever layout is showing. Sorted alphabetically or not, the rail
            // only appears for the name sort — the same rule Albums uses, for the same
            // reason: jumping to "S" in a track-count ordering answers nothing.
            .alphabetIndexRail(indexEntries, proxy: proxy)
        }
    }

    var body: some View {
        indexedLayouts
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LayoutPicker(layout: layoutBinding) } }
        // On the Group, not the list. Everything below — the load, refresh, the + button,
        // the sort menu, the content state and the new-playlist alert — was attached to
        // `playlistList` alone, so the grid branch had none of it. Harmless only because
        // this screen defaults to `.list`, which is exactly how the Artists bug hid: the
        // plan named three screens with this shape and there were four.
        .searchable(text: $filter, prompt: "Filter playlists")
        .searchKeyboardDismissal()
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Sort", selection: $sortRaw) {
                        ForEach(PlaylistSort.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort playlists")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { newName = ""; showsNew = true } label: { Image(systemName: "plus") }
                    .disabled(model.isDemoMode)
            }
        }
        .contentState(
            ContentDisplayState.resolve(isLoading: model.musicLibrary.isLoading,
                                        error: model.musicLibrary.lastError,
                                        isEmpty: model.musicLibrary.playlists.isEmpty),
            emptyTitle: "No playlists",
            emptyMessage: "Make one here, or add songs to a new playlist from any track's long-press menu.",
            emptySymbol: "music.note.list",
            onRetry: { Task { await model.musicLibrary.loadPlaylists() } }
        )
        .task { await model.musicLibrary.loadPlaylists() }
        .refreshable { await model.musicLibrary.loadPlaylists() }
        .alert("New playlist", isPresented: $showsNew) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task {
                    _ = await model.musicLibrary.createPlaylist(name: name)
                    await model.musicLibrary.loadPlaylists()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                guard let playlist = renaming else { return }
                let name = renameText.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task {
                    await model.musicLibrary.renamePlaylist(id: playlist.id, to: name)
                    await model.musicLibrary.loadPlaylists()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let playlist = deleting else { return }
                Task {
                    await model.musicLibrary.deletePlaylist(id: playlist.id)
                    await model.musicLibrary.loadPlaylists()
                }
            }
        } message: {
            Text("This removes the playlist from your server. The songs stay in your library.")
        }
    }

    /// Client-sorted, so the client buckets — and says so in the same call rather than in
    /// a separate `guard` that a later screen can forget. See `AlphabetIndex.Ordered`.
    /// Not while filtering: an index over five hits is noise, and the rail's letters are
    /// only meaningful against the unfiltered list they were built from.
    private var indexEntries: AlphabetIndex.Ordered {
        guard filter.isEmpty else { return .none }
        return .clientSorted(shown.map { ($0.id, $0.name) },
                             isAlphabetical: sort == .name)
    }

    private var playlistGrid: some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: BrowseGrid.spacing) {
                ForEach(shown) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist, model: model)
                    } label: {
                        BrowseTile(
                            artwork: model.musicLibrary.coverArtURL(
                                id: playlist.coverArtID ?? playlist.id, size: 400),
                            title: playlist.name,
                            subtitle: playlistSubtitle(playlist)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(BrowseGrid.padding)
        }
    }

    private var playlistList: some View {
        List(shown) { playlist in
            NavigationLink {
                PlaylistDetailView(playlist: playlist, model: model)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(url: model.musicLibrary.coverArtURL(id: playlist.coverArtID ?? playlist.id, size: 120))
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(playlist.name)
                        // "80 songs · 6h 57m" — at playlist sizes, the hours are the
                        // information; a bare track count undersells an evening.
                        Text(playlistSubtitle(playlist)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu {
                Button {
                    Task {
                        let songs = await model.musicLibrary.playlist(id: playlist.id)?.songs ?? []
                        model.music.play(songs, source: .init(label: playlist.name, kind: .playlist, id: playlist.id))
                    }
                } label: { Label("Play", systemImage: "play.fill") }
                Button {
                    Task {
                        let songs = await model.musicLibrary.playlist(id: playlist.id)?.songs ?? []
                        model.music.play(songs.shuffled(), source: .init(label: playlist.name, kind: .playlist, id: playlist.id))
                    }
                } label: { Label("Shuffle", systemImage: "shuffle") }
                Button {
                    Task {
                        let songs = await model.musicLibrary.playlist(id: playlist.id)?.songs ?? []
                        model.music.enqueue(songs)
                    }
                } label: { Label("Add to Queue", systemImage: "text.append") }
                Divider()
                Button { renaming = playlist; renameText = playlist.name } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button(role: .destructive) { deleting = playlist } label: {
                    Label("Delete…", systemImage: "trash")
                }
            }
            .swipeActions {
                Button(role: .destructive) { deleting = playlist } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { renaming = playlist; renameText = playlist.name } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.accentColor)
            }
        }
        .listStyle(.plain)
    }
}

struct PlaylistDetailView: View {
    let playlist: NavidromePlaylist
    let model: MobileModel
    @State private var songs: [NavidromeSong] = []
    @State private var isEditing = false
    @State private var filter = ""

    /// The rows actually shown. Reorder/delete work on the *unfiltered* list only —
    /// moving row 3 of a filtered view would move the wrong song on the server.
    private var shown: [NavidromeSong] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return songs }
        return songs.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.artist?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }

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
                        model.music.play(songs.shuffled(), source: source)
                    } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .disabled(songs.isEmpty)
                }
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, model: model)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Play the full playlist from this song, filtered or not —
                            // the filter narrows the *view*, not the listening.
                            let start = songs.firstIndex(of: song) ?? index
                            model.music.play(songs, startAt: start, source: source)
                        }
                        .songContextMenu(song, model: model)
                        // Only when not filtering: a filtered view renumbers the rows, so
                        // an index-based move or delete would hit the wrong song on the
                        // server. Per-row, because these modifiers only apply there.
                        .moveDisabled(isFiltering)
                        .deleteDisabled(isFiltering)
                }
                .onMove { source, destination in
                    songs.move(fromOffsets: source, toOffset: destination)
                    Task { await persistOrder() }
                }
                .onDelete { offsets in
                    // Remove server-side by index, then locally, so the list doesn't
                    // flicker back if the request is slow.
                    let indexes = Array(offsets)
                    songs.remove(atOffsets: offsets)
                    Task { await model.musicLibrary.removeFromPlaylist(id: playlist.id, indexes: indexes) }
                }
            }
        }
        .listStyle(.plain)
        // Pushed screen, so the navigation bar is there to host it — unlike the root
        // tabs, `.searchable` works here.
        .searchable(text: $filter, prompt: "Filter this playlist")
        .searchKeyboardDismissal()
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { _ = await MusicDownloadStore.shared.download(songs) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(songs.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                    .disabled(songs.isEmpty || model.isDemoMode)
            }
        }
        .task { songs = await model.musicLibrary.playlist(id: playlist.id)?.songs ?? [] }
    }

    private var source: QueueSource { .init(label: playlist.name, kind: .playlist, id: playlist.id) }

    /// Subsonic has no "move track" call — reordering means rewriting the whole track
    /// list, which is what the shared client's `reorderPlaylist` does.
    private func persistOrder() async {
        await model.musicLibrary.reorderPlaylist(
            id: playlist.id, songIDs: songs.map(\.id),
            name: playlist.name, isPublic: playlist.isPublic
        )
    }
}

/// Downloads: what's on this phone, how much space it takes, and the offline switch.
struct DownloadsView: View {
    let model: MobileModel
    /// Read the `@Observable` store directly rather than snapshotting it into `@State` in
    /// `.task`. The snapshot was taken once per appearance, so a download finishing while
    /// you watched changed nothing on screen — and the whole reason to open this screen is
    /// to watch downloads finish. `refresh()` is gone with it; there is nothing to refresh.
    private var store: MusicDownloadStore { MusicDownloadStore.shared }
    @State private var isRetrying = false
    @State private var offlineMode = StreamingPlaybackController.isOfflineMode

    private var items: [MusicDownloadStore.DownloadItem] { store.downloadedItems() }
    private var failed: [NavidromeSong] { Array(store.failedDownloads.values) }
    private var bytes: Int64 { store.totalBytes() }

    /// Mean completion across in-flight downloads, same as the Mac's aggregate bar.
    private var aggregateProgress: Double {
        let ids = store.inFlight
        guard !ids.isEmpty else { return 0 }
        return ids.reduce(0.0) { $0 + (store.downloadProgress[$1] ?? 0) } / Double(ids.count)
    }

    var body: some View {
        List {
            Section {
                Toggle("Offline mode", isOn: $offlineMode)
                    .onChange(of: offlineMode) { _, on in
                        // The engine reads this key on every stream resolution; no restart needed.
                        UserDefaults.standard.set(on, forKey: StreamingPlaybackController.offlineModeKey)
                    }
            } footer: {
                Text("Offline mode plays only downloaded tracks and never streams.")
            }

            // What is happening right now. `inFlight` and `downloadProgress` have been on
            // the store all along and only the Mac ever drew them, so on the phone a
            // five-track download looked identical to nothing happening at all.
            if !store.inFlight.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: aggregateProgress)
                        Text("Downloading \(Counted.phrase(store.inFlight.count, "track"))…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            // A download that failed used to vanish without trace on the phone: the store
            // has tracked `failedDownloads` and offered `retryFailed()` all along, and only
            // the Mac ever showed either. You'd go offline expecting an album and find
            // gaps, with nothing on screen admitting anything had gone wrong.
            if !failed.isEmpty {
                Section {
                    ForEach(failed, id: \.id) { song in
                        SongRow(song: song, model: model)
                    }
                    Button(isRetrying ? "Retrying…" : "Retry all") {
                        isRetrying = true
                        Task {
                            await store.retryFailed()
                            isRetrying = false
                        }
                    }
                    .disabled(isRetrying)
                } header: {
                    Label("\(Counted.phrase(failed.count, "download")) failed", systemImage: "exclamationmark.triangle")
                } footer: {
                    Text("These didn't finish — usually the server went away mid-transfer. Retrying picks up where it stopped.")
                }
            }

            Section {
                ForEach(items, id: \.id) { item in
                    Button {
                        let songs = items.map(\.song)
                        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
                        model.music.play(songs, startAt: index, source: .init(label: "Downloads", kind: .playlist))
                    } label: {
                        SongRow(song: item.song, model: model)
                    }
                    .buttonStyle(.plain)
                    // Everything you can do to a song everywhere else. Downloads was the
                    // one list where a long press did nothing.
                    .songContextMenu(item.song, model: model)
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            store.delete(item.id)
                        }
                    }
                }
            } header: {
                Text(storageLine)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        // A download finishing is the one event here worth feeling: people start one and
        // put the phone down, and the screen changing silently tells them nothing.
        .sensoryFeedback(.success, trigger: items.count)
        .overlay {
            if items.isEmpty, failed.isEmpty, store.inFlight.isEmpty {
                ContentUnavailableView(
                    "Nothing downloaded",
                    systemImage: "arrow.down.circle",
                    description: Text("Download an album or a song and it plays without a connection.")
                )
            }
        }
    }

    /// How many, and how much of the phone they're using. A count alone doesn't answer the
    /// question people actually open this screen with.
    private var storageLine: String {
        let count = Counted.phrase(items.count, "download")
        guard bytes > 0 else { return count }
        return "\(count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

}


/// PodcastsView wrapped for in-stack presentation (it owns its own NavigationStack
/// as a tab; inside Library it must not nest one).
struct PodcastsInlineView: View {
    let model: MobileModel

    var body: some View {
        PodcastsListBody(model: model)
            .navigationTitle("Podcasts")
            .navigationBarTitleDisplayMode(.inline)
    }
}
