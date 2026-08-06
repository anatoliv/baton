import SwiftUI

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

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { LikedView(model: model) } label: {
                    Label("Liked", systemImage: "heart").badge(likedCount)
                }
                NavigationLink { PlaylistsView(model: model) } label: {
                    Label("Playlists", systemImage: "music.note.list")
                        .badge(model.musicLibrary.playlists.count)
                }
                NavigationLink { ArtistsView(model: model) } label: {
                    Label("Artists", systemImage: "music.mic")
                        .badge(model.musicLibrary.artists.count)
                }
                NavigationLink { GenresView(model: model) } label: {
                    Label("Genres", systemImage: "guitars")
                }
                NavigationLink { HistoryView(model: model) } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .badge(model.history.recentlyPlayed.count)
                }
                NavigationLink { DownloadsView(model: model) } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                        .badge(model.pins.pins.count)
                }
                NavigationLink { PodcastsInlineView(model: model) } label: {
                    Label("Podcasts", systemImage: "mic")
                }
                NavigationLink { RadioView(model: model) } label: {
                    Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                        .badge(model.radio.stations.count)
                }
            }
            .nowPlayingWash(wash)
            .navigationTitle("Library")
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album, model: model)
            }
        }
    }
}

/// Liked — songs, albums and artists you've starred, with sort and a filter.
///
/// The Mac splits this three ways because "liked" means three different collections on a
/// Subsonic server, and a flat song list buries the other two. Sort matters here more
/// than elsewhere: a liked list is the one that grows without bound.
struct LikedView: View {
    let model: MobileModel

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
            case .albums: albumsSection
            case .artists: artistsSection
            }
        }
        .listStyle(.plain)
        .searchable(text: $filter, prompt: "Filter liked")
        .navigationTitle("Liked")
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
                    SongRow(song: song, model: model)
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
                            Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
    private func sorted(_ songs: [NavidromeSong]) -> [NavidromeSong] {
        switch sort {
        case .recent: songs
        case .title: songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: songs.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        }
    }
}

struct PlaylistsView: View {
    let model: MobileModel
    @State private var showsNew = false
    @State private var newName = ""
    @State private var renaming: NavidromePlaylist?
    @State private var renameText = ""
    @State private var deleting: NavidromePlaylist?

    var body: some View {
        List(model.musicLibrary.playlists) { playlist in
            NavigationLink {
                PlaylistDetailView(playlist: playlist, model: model)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(url: model.musicLibrary.coverArtURL(id: playlist.coverArtID ?? playlist.id, size: 120))
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(playlist.name)
                        Text("\(playlist.songCount) tracks").font(.caption).foregroundStyle(.secondary)
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
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newName = ""; showsNew = true } label: { Image(systemName: "plus") }
                    .disabled(model.isDemoMode)
            }
        }
        .overlay {
            if model.musicLibrary.playlists.isEmpty {
                ContentUnavailableView("No playlists", systemImage: "music.note.list",
                                       description: Text("Make one here, or add songs to a new playlist from any track's long-press menu."))
            }
        }
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
}

struct PlaylistDetailView: View {
    let playlist: NavidromePlaylist
    let model: MobileModel
    @State private var songs: [NavidromeSong] = []
    @State private var isEditing = false

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
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, model: model)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.music.play(songs, startAt: index, source: source)
                        }
                        .songContextMenu(song, model: model)
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
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle(playlist.name)
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
    @State private var items: [MusicDownloadStore.DownloadItem] = []
    @State private var offlineMode = StreamingPlaybackController.isOfflineMode

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

            Section("\(items.count) downloaded") {
                ForEach(items, id: \.id) { item in
                    Button {
                        let songs = items.map(\.song)
                        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
                        model.music.play(songs, startAt: index, source: .init(label: "Downloads", kind: .playlist))
                    } label: {
                        SongRow(song: item.song, model: model)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            MusicDownloadStore.shared.delete(item.id)
                            items = MusicDownloadStore.shared.downloadedItems()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Downloads")
        .task { items = MusicDownloadStore.shared.downloadedItems() }
    }
}


/// PodcastsView wrapped for in-stack presentation (it owns its own NavigationStack
/// as a tab; inside Library it must not nest one).
struct PodcastsInlineView: View {
    let model: MobileModel

    var body: some View {
        PodcastsListBody(model: model)
            .navigationTitle("Podcasts")
    }
}
