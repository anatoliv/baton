import SwiftUI

/// Column geometry shared by the album/playlist table rows and their headers.
enum BrowseColumns {
    static let thumb: CGFloat = 40
    static let tracks: CGFloat = 58
    static let time: CGFloat = 84
    static let rating: CGFloat = 96

    static func header(_ primary: String, showTime: Bool, showRating: Bool = false, selectable: Bool = false) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                if selectable { Color.clear.frame(width: 18, height: 1) }  // checkbox slot
                Color.clear.frame(width: thumb, height: 1)
                Text(primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Tracks").frame(width: tracks, alignment: .trailing)
            if showTime { Text("Time").frame(width: time, alignment: .trailing) }
            if showRating { Text("Rating").frame(width: rating, alignment: .center) }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

/// A small rounded-square cover thumbnail that doubles as a Play button (hover reveals
/// a play overlay; a spinner shows while `isWorking`). Used by the album/playlist rows.
struct MusicRowThumb: View {
    let url: URL?
    var placeholder: String = "opticaldisc"
    var isHovering: Bool
    var isWorking: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.12))
            if let url {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                    Image(systemName: placeholder).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: placeholder).foregroundStyle(.secondary)
            }
            if isHovering || isWorking {
                Color.black.opacity(0.4)
                if isWorking { ProgressView().controlSize(.small).tint(.white) } else {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                }
            }
        }
        .frame(width: BrowseColumns.thumb, height: BrowseColumns.thumb)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// One inline row action — an icon button revealed on row hover.
struct MusicRowAction {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    let run: () -> Void
}

/// A hover-revealed strip of inline row actions, sitting in the free space between a
/// table row's title and its trailing columns. The row renders it only while hovering
/// so idle rows stay clean; the ⋯ menu remains the full/overflow list. Shared by the
/// artist, album, playlist, and song rows so the pattern is identical everywhere.
struct MusicRowActions: View {
    let actions: [MusicRowAction]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button { action.run() } label: {
                    Image(systemName: action.systemImage)
                        .font(.callout)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(action.tint)
                .help(action.title)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Shared per-song menu

/// The playback head of every song context menu — Play · Play Next · Add to Queue ·
/// Start Radio — so the top group is identical on every song row (Liked, Search, Artist,
/// Album, Playlist, Related). `onPlay` matches the row's own tap/double-tap behavior.
@MainActor @ViewBuilder
func songPlaybackMenuItems(_ song: NavidromeSong, _ model: MusicModel, onPlay: @escaping () -> Void) -> some View {
    Button("Play", systemImage: "play.fill", action: onPlay)
    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.music.playNext([song]) }
    Button("Add to Queue", systemImage: "text.append") { model.music.enqueue([song]) }
    Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
        Task {
            let radio = await model.musicLibrary.similarSongs(seedID: song.id)
            model.music.play([song] + radio, source: .init(label: "\(song.title) Radio", kind: .radio, id: nil))
        }
    }
    songAddToPlaylistMenu([song], model)
}

/// "Add to Playlist ▸" submenu — a **New Playlist…** (created from the tracks, named after
/// the first one) plus every existing playlist. Shared so the reverse flow (add a track to
/// a playlist) is available from every song menu, not just "Save as Playlist" (which only
/// creates new). Takes an array so the multi-select bar can reuse it.
@MainActor @ViewBuilder
func songAddToPlaylistMenu(_ songs: [NavidromeSong], _ model: MusicModel) -> some View {
    Menu {
        Button("New Playlist…", systemImage: "plus") {
            let name = songs.count == 1 ? songs[0].title : "New Playlist"
            Task {
                if let playlist = await model.musicLibrary.createPlaylist(name: name, songIDs: songs.map(\.id)) {
                    model.music.postToast("Created “\(playlist.name)”", symbol: "music.note.list")
                }
            }
        }
        if !model.musicLibrary.playlists.isEmpty {
            Divider()
            ForEach(model.musicLibrary.playlists) { playlist in
                Button(playlist.name) {
                    Task {
                        let added = await model.musicLibrary.addToPlaylist(id: playlist.id, songIDs: songs.map(\.id))
                        if added == 0 {
                            model.music.postToast("Already in “\(playlist.name)”", symbol: "checkmark.circle")
                        } else {
                            let what = added == 1 ? "track" : "\(added) tracks"
                            model.music.postToast("Added \(what) to “\(playlist.name)”", symbol: "music.note.list")
                        }
                    }
                }
            }
        }
    } label: {
        Label("Add to Playlist", systemImage: "music.note.list")
    }
    // Populate the playlist list on first open (surfaces that didn't prefetch it, e.g. the
    // status-bar mini player). Fires when the menu opens, so a moment later the submenu fills.
    .task {
        if model.musicLibrary.playlists.isEmpty { await model.musicLibrary.loadPlaylists() }
    }
}

/// The Download / Remove Download menu item for a song — a toggle on the offline copy.
/// Shared by every song row so the wording, icon (`trash.slash` for un-download), and
/// toasts are identical everywhere. Kept separate from the destructive removal item.
@MainActor @ViewBuilder
func songDownloadMenuItems(_ song: NavidromeSong, _ model: MusicModel) -> some View {
    let downloads = MusicDownloadStore.shared
    if downloads.isDownloaded(song.id) {
        Button("Remove Download", systemImage: "trash.slash") {
            downloads.delete(song.id)
            model.music.postToast("Removed download", symbol: "trash.slash")
        }
    } else {
        Button("Download", systemImage: "arrow.down.circle") {
            model.music.postToast("Downloading \(song.title)…", symbol: "arrow.down.circle")
            Task { await downloads.download(song) }
        }
        .disabled(downloads.isDownloading(song.id))
    }
}

/// The destructive "Mark for Removal" menu item — flips the caller's confirm flag so a
/// tap always asks first. Pair with `.songRemovalConfirm` for the dialog + action.
@MainActor @ViewBuilder
func songRemovalMenuItem(showConfirm: Binding<Bool>) -> some View {
    Button("Mark for Removal", systemImage: "xmark.bin", role: .destructive) {
        showConfirm.wrappedValue = true
    }
}

/// "Don't play in radio" / "Allow in radio" — excludes (or re-includes) a track from
/// radio/autoplay suggestions without removing it from the library.
@MainActor @ViewBuilder
func songRadioMenuItem(_ song: NavidromeSong, _ model: MusicModel) -> some View {
    if model.musicRadioBans.isBanned(song.id) {
        Button("Allow in Radio", systemImage: "hand.thumbsup") { model.musicRadioBans.unban(song.id) }
    } else {
        Button("Don't Play in Radio", systemImage: "hand.thumbsdown") { model.musicRadioBans.ban(song.id) }
    }
}

extension View {
    /// The shared "Mark … for removal?" confirmation + pipeline action (unlike + 1-star),
    /// so every song row asks and acts identically.
    @MainActor
    func songRemovalConfirm(_ song: NavidromeSong, _ model: MusicModel, isPresented: Binding<Bool>) -> some View {
        confirmationDialog(
            "Mark “\(song.title)” for removal?",
            isPresented: isPresented, titleVisibility: .visible
        ) {
            Button("Mark for Removal", role: .destructive) {
                model.music.postToast("Marked for removal", symbol: "xmark.bin")
                Task { await model.musicLibrary.markForRemoval(song) }
            }
        } message: {
            Text("Unlikes it and sets a 1-star rating — the signal the cleanup pipeline uses to prune it.")
        }
    }
}

// MARK: - Album actions (parity with ArtistActions)

/// Shared per-album playback/curation actions, so the list row and grid card share one
/// implementation. Each caller wraps these in its own `working` flag.
@MainActor
enum AlbumActions {
    static func play(_ album: NavidromeAlbum, _ model: MusicModel, shuffle: Bool) async {
        var songs = await model.musicLibrary.albumSongs(id: album.id)
        guard !songs.isEmpty else { return }
        if shuffle { songs.shuffle() }
        model.music.play(songs, source: .init(label: album.name, kind: .album, id: album.id))
    }

    static func queue(_ album: NavidromeAlbum, _ model: MusicModel) async {
        let songs = await model.musicLibrary.albumSongs(id: album.id)
        if !songs.isEmpty { model.music.enqueue(songs) }
    }

    static func radio(_ album: NavidromeAlbum, _ model: MusicModel) async {
        let songs = await model.musicLibrary.albumSongs(id: album.id)
        guard let seed = songs.first else { return }
        let radio = await model.musicLibrary.similarSongs(seedID: seed.id)
        model.music.play(radio.isEmpty ? songs : radio,
                         source: .init(label: "\(album.name) Radio", kind: .radio, id: nil))
    }

    static func download(_ album: NavidromeAlbum, _ model: MusicModel) async {
        let songs = await model.musicLibrary.albumSongs(id: album.id)
        guard !songs.isEmpty else { return }
        model.music.postToast("Downloading \(songs.count) song\(songs.count == 1 ? "" : "s")…", symbol: "arrow.down.circle")
        await MusicDownloadStore.shared.download(songs)
    }

    static func saveAsPlaylist(_ album: NavidromeAlbum, _ model: MusicModel) async {
        let songs = await model.musicLibrary.albumSongs(id: album.id)
        guard !songs.isEmpty else { return }
        _ = await model.musicLibrary.createPlaylist(name: album.name, songIDs: songs.map(\.id))
        await model.musicLibrary.loadPlaylists()
        model.music.postToast("Saved playlist “\(album.name)”", symbol: "square.and.arrow.down")
    }

    static func markAllForRemoval(_ album: NavidromeAlbum, _ model: MusicModel) async {
        let songs = await model.musicLibrary.albumSongs(id: album.id)
        for song in songs { await model.musicLibrary.markForRemoval(song) }
    }
}

/// The full album action menu — identical to `artistActionMenuItems`, shared by the album
/// list row and grid card so right-click is the same everywhere (and matches artists).
@MainActor @ViewBuilder
func albumActionMenuItems(
    _ album: NavidromeAlbum,
    _ model: MusicModel,
    run: @escaping (@escaping () async -> Void) -> Void,
    onRemove: @escaping () -> Void
) -> some View {
    Button("Play", systemImage: "play.fill") { run { await AlbumActions.play(album, model, shuffle: false) } }
    Button("Shuffle", systemImage: "shuffle") { run { await AlbumActions.play(album, model, shuffle: true) } }
    Button("Add to Queue", systemImage: "text.append") { run { await AlbumActions.queue(album, model) } }
    Button("Find Similar (Radio)", systemImage: "dot.radiowaves.left.and.right") {
        run { await AlbumActions.radio(album, model) }
    }
    Divider()
    Button("Download", systemImage: "arrow.down.circle") { run { await AlbumActions.download(album, model) } }
    Button("Save as Playlist", systemImage: "square.and.arrow.down") {
        run { await AlbumActions.saveAsPlaylist(album, model) }
    }
    Divider()
    Button("Mark All for Removal", systemImage: "xmark.bin", role: .destructive) { onRemove() }
}

extension View {
    /// Shared "Mark all of <album> for removal?" confirmation (unlike + 1-star every track).
    func albumRemovalConfirm(_ album: NavidromeAlbum, isPresented: Binding<Bool>, confirm: @escaping () -> Void) -> some View {
        confirmationDialog(
            "Mark all of “\(album.name)” for removal?",
            isPresented: isPresented, titleVisibility: .visible
        ) {
            Button("Mark for removal", role: .destructive, action: confirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unlikes every track and rates it 1 star — the signal the cleanup pipeline uses to prune them.")
        }
    }
}

/// A dense album table row — thumbnail (play), title/artist, Tracks / Time columns,
/// and a ⋯ menu. Tapping the name opens the album.
struct MusicAlbumRow: View {
    @Environment(MusicModel.self) private var model
    let album: NavidromeAlbum
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    @State private var hovering = false
    @State private var working = false
    @State private var showRemoveConfirm = false

    private var coverURL: URL? { album.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 80) } }

    // YT imports store the video title in `artist` and a constant source in `name`.
    private var title: String {
        let artist = (album.artist ?? "").trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? album.name : artist
    }

    private var subtitle: String {
        let artist = (album.artist ?? "").trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? "" : album.name
    }

    private var tracksText: String { album.songCount.map { "\($0)" } ?? "—" }
    private var timeText: String { (album.duration).map { MusicAlbumCard.albumDuration($0) } ?? "—" }

    private func run(_ body: @escaping () async -> Void) { Task { working = true; await body(); working = false } }

    var body: some View {
        HStack(spacing: 12) {
            MusicSelectCheckbox(isSelected: isSelected, visible: hovering, onToggle: onToggleSelect)

            Button { run { await play() } } label: {
                MusicRowThumb(url: coverURL, isHovering: hovering, isWorking: working)
            }
            .buttonStyle(.plain).help("Play \(title)")

            NavigationLink(value: album) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering {
                MusicRowActions(actions: [
                    MusicRowAction(title: "Shuffle", systemImage: "shuffle") { run { await AlbumActions.play(album, model, shuffle: true) } },
                    MusicRowAction(title: "Add to Queue", systemImage: "text.append") { run { await AlbumActions.queue(album, model) } },
                    MusicRowAction(title: "Find Similar (Radio)", systemImage: "dot.radiowaves.left.and.right") { run { await AlbumActions.radio(album, model) } },
                    MusicRowAction(title: "Download", systemImage: "arrow.down.circle") { run { await AlbumActions.download(album, model) } },
                    MusicRowAction(title: "Save as Playlist", systemImage: "square.and.arrow.down") { run { await AlbumActions.saveAsPlaylist(album, model) } },
                    MusicRowAction(title: "Mark All for Removal", systemImage: "xmark.bin", tint: .red) { showRemoveConfirm = true },
                ])
            }

            Group {
                Text(tracksText).frame(width: BrowseColumns.tracks, alignment: .trailing)
                Text(timeText).frame(width: BrowseColumns.time, alignment: .trailing)
            }
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)

            MusicStarRating(rating: model.musicLibrary.rating(id: album.id, userRating: album.userRating)) { newRating in
                Task {
                    await model.musicLibrary.setRating(
                        id: album.id, userRating: album.userRating, isLiked: album.isLiked, rating: newRating
                    )
                }
            }
            .frame(width: BrowseColumns.rating, alignment: .center)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            isSelected ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.06) : .clear)
        ))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            albumActionMenuItems(album, model, run: run, onRemove: { showRemoveConfirm = true })
        }
        .albumRemovalConfirm(album, isPresented: $showRemoveConfirm) {
            run { await AlbumActions.markAllForRemoval(album, model) }
        }
    }

    private func play() async { await AlbumActions.play(album, model, shuffle: false) }
}

/// Shared playlist playback actions (fetch songs → play/queue), so the table row and
/// grid cell don't duplicate them.
@MainActor
enum PlaylistActions {
    static func play(_ playlist: NavidromePlaylist, _ model: MusicModel, shuffle: Bool = false) async {
        guard var songs = await model.musicLibrary.playlist(id: playlist.id)?.songs, !songs.isEmpty else { return }
        if shuffle { songs.shuffle() }
        model.music.play(songs, source: .init(label: playlist.name, kind: .playlist, id: playlist.id))
    }

    static func queue(_ playlist: NavidromePlaylist, _ model: MusicModel) async {
        guard let songs = await model.musicLibrary.playlist(id: playlist.id)?.songs, !songs.isEmpty else { return }
        model.music.enqueue(songs)
    }

    static func radio(_ playlist: NavidromePlaylist, _ model: MusicModel) async {
        guard let songs = await model.musicLibrary.playlist(id: playlist.id)?.songs, let seed = songs.first else { return }
        let radio = await model.musicLibrary.similarSongs(seedID: seed.id)
        model.music.play(radio.isEmpty ? songs : radio,
                         source: .init(label: "\(playlist.name) Radio", kind: .radio, id: nil))
    }

    static func download(_ playlist: NavidromePlaylist, _ model: MusicModel) async {
        guard let songs = await model.musicLibrary.playlist(id: playlist.id)?.songs, !songs.isEmpty else { return }
        model.music.postToast("Downloading \(songs.count) song\(songs.count == 1 ? "" : "s")…", symbol: "arrow.down.circle")
        await MusicDownloadStore.shared.download(songs)
    }
}

/// A hover-lifting playlist grid cell — the shared `MusicMediaCard` (same look as
/// albums/artists) fed with the playlist's cover mosaic, name, and track count.
struct PlaylistGridCell: View {
    @Environment(MusicModel.self) private var model
    let playlist: NavidromePlaylist
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var working = false
    @State private var showDeleteConfirm = false

    private var coverURL: URL? { playlist.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 400) } }

    private var isPlayingSource: Bool {
        let source = model.music.queueSource
        return source?.kind == .playlist && source?.id == playlist.id
    }

    private func run(_ body: @escaping () async -> Void) { Task { working = true; await body(); working = false } }

    var body: some View {
        NavigationLink(value: playlist) {
            MusicMediaCard(
                coverURL: coverURL,
                placeholder: "music.note.list",
                cornerBadge: playlist.isPublic ? ("shared", .accentColor) : nil,
                title: playlist.name,
                subtitle: "",
                trailingTop: "\(playlist.songCount) track\(playlist.songCount == 1 ? "" : "s")",
                trailingBottom: playlist.duration.map { MusicAlbumCard.albumDuration($0) },
                isHovering: hovering,
                isWorking: working,
                isPlayingSource: isPlayingSource,
                onPlay: { run { await PlaylistActions.play(playlist, model) } }
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if hovering || isSelected {
                MusicSelectCheckbox(isSelected: isSelected, onToggle: onToggleSelect)
                    .padding(6).shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
        }
        .scaleEffect(hovering ? 1.06 : 1)
        .zIndex(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            playlistActionMenuItems(playlist, model, run: run, onDelete: { showDeleteConfirm = true })
        }
        .playlistDeleteConfirm(playlist, isPresented: $showDeleteConfirm, confirm: onDelete)
    }
}

/// The full playlist action menu — Play · Shuffle · Add to Queue │ Download │ Delete.
/// Shared by the list row and grid cell so right-click is identical. Delete (not Mark
/// for Removal) is correct here: it removes the playlist, not its tracks' library rows.
@MainActor @ViewBuilder
func playlistActionMenuItems(
    _ playlist: NavidromePlaylist,
    _ model: MusicModel,
    run: @escaping (@escaping () async -> Void) -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button("Play", systemImage: "play.fill") { run { await PlaylistActions.play(playlist, model) } }
    Button("Shuffle", systemImage: "shuffle") { run { await PlaylistActions.play(playlist, model, shuffle: true) } }
    Button("Add to Queue", systemImage: "text.append") { run { await PlaylistActions.queue(playlist, model) } }
    Button("Find Similar (Radio)", systemImage: "dot.radiowaves.left.and.right") { run { await PlaylistActions.radio(playlist, model) } }
    Divider()
    Button("Download", systemImage: "arrow.down.circle") { run { await PlaylistActions.download(playlist, model) } }
    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
}

/// Shared "Delete playlist?" confirmation — used by the list row's inline Delete and the
/// grid cell's context-menu Delete so a destructive tap always asks first (playlist
/// deletion is otherwise immediate and irreversible).
extension View {
    func playlistDeleteConfirm(
        _ playlist: NavidromePlaylist, isPresented: Binding<Bool>, confirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Delete the playlist “\(playlist.name)”?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive, action: confirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the playlist from your library. The songs themselves aren't deleted.")
        }
    }
}

/// A dense playlist table row — thumbnail (play), name (+ shared badge), Tracks
/// column, and a ⋯ menu. Tapping the name opens the playlist.
struct MusicPlaylistRow: View {
    @Environment(MusicModel.self) private var model
    let playlist: NavidromePlaylist
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var working = false
    @State private var showDeleteConfirm = false

    private var coverURL: URL? { playlist.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 80) } }

    private func run(_ body: @escaping () async -> Void) { Task { working = true; await body(); working = false } }

    var body: some View {
        HStack(spacing: 12) {
            MusicSelectCheckbox(isSelected: isSelected, visible: hovering, onToggle: onToggleSelect)

            Button { run { await PlaylistActions.play(playlist, model) } } label: {
                MusicRowThumb(url: coverURL, placeholder: "music.note.list", isHovering: hovering, isWorking: working)
            }
            .buttonStyle(.plain).help("Play \(playlist.name)")

            NavigationLink(value: playlist) {
                HStack(spacing: 6) {
                    Text(playlist.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if playlist.isPublic {
                        Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering {
                MusicRowActions(actions: [
                    MusicRowAction(title: "Shuffle", systemImage: "shuffle") { run { await PlaylistActions.play(playlist, model, shuffle: true) } },
                    MusicRowAction(title: "Add to Queue", systemImage: "text.append") { run { await PlaylistActions.queue(playlist, model) } },
                    MusicRowAction(title: "Find Similar (Radio)", systemImage: "dot.radiowaves.left.and.right") { run { await PlaylistActions.radio(playlist, model) } },
                    MusicRowAction(title: "Download", systemImage: "arrow.down.circle") { run { await PlaylistActions.download(playlist, model) } },
                    MusicRowAction(title: "Delete", systemImage: "trash", tint: .red) { showDeleteConfirm = true },
                ])
            }

            Group {
                Text("\(playlist.songCount)").frame(width: BrowseColumns.tracks, alignment: .trailing)
                Text(playlist.duration.map { MusicAlbumCard.albumDuration($0) } ?? "—")
                    .frame(width: BrowseColumns.time, alignment: .trailing)
            }
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            isSelected ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.06) : .clear)
        ))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            playlistActionMenuItems(playlist, model, run: run, onDelete: { showDeleteConfirm = true })
        }
        .playlistDeleteConfirm(playlist, isPresented: $showDeleteConfirm, confirm: onDelete)
    }
}
