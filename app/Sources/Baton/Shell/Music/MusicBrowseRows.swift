import SwiftUI

/// Column geometry shared by the album/playlist table rows and their headers.
enum BrowseColumns {
    static let thumb: CGFloat = 40
    static let genre: CGFloat = 120
    static let year: CGFloat = 48
    static let tracks: CGFloat = 58
    static let time: CGFloat = 84
    static let like: CGFloat = 26
    static let rating: CGFloat = 96

    static func header(
        _ primary: String, showTime: Bool, showRating: Bool = false, selectable: Bool = false,
        showGenre: Bool = false, showYear: Bool = false, showLike: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                if selectable { Color.clear.frame(width: 18, height: 1) }  // checkbox slot
                Color.clear.frame(width: thumb, height: 1)
                Text(primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showGenre { Text("Genre").frame(width: genre, alignment: .leading) }
            if showYear { Text("Year").frame(width: year, alignment: .trailing) }
            Text("Tracks").frame(width: tracks, alignment: .trailing)
            if showTime { Text("Time").frame(width: time, alignment: .trailing) }
            if showLike { Image(systemName: "heart").frame(width: like, alignment: .center) }
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

/// The "this collection is *actively playing*" cue for the dense album/playlist **list**
/// rows — a small accent speaker wave. Callers show it only while playback is active (a
/// paused source shows nothing), so it always renders the animated wave. It's the
/// list-layout counterpart to the accent border + glow the grid cards get from
/// `MusicMediaCard.isPlaying`, and it matches the speaker cue on song thumbs.
struct NowPlayingSourceGlyph: View {
    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Now playing")
            .help("Now playing")
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

// MARK: - Download status badge

/// The standard offline-download indicator, shared across every song / album / artist surface:
/// a **filled** badge when fully downloaded, an **outline** when partially downloaded, a spinner
/// while fetching, and an empty fixed slot otherwise (so rows stay column-aligned and the glyph
/// is always vertically centered). Reads `MusicDownloadStore.shared`, so it updates live.
struct DownloadStatusBadge: View {
    enum Status { case hidden, downloading, partial, complete }
    let status: Status

    init(status: Status) { self.status = status }
    init(songID: String) { status = Self.status(songID: songID) }
    init(albumID: String, totalTracks: Int?) { status = Self.status(albumID: albumID, totalTracks: totalTracks) }
    init(artistID: String) { status = Self.status(artistID: artistID) }
    init(playlistID: String) { status = Self.status(playlistID: playlistID) }

    /// A single track: downloading → spinner, downloaded → filled, else hidden.
    static func status(songID: String) -> Status {
        let store = MusicDownloadStore.shared
        return store.isDownloading(songID) ? .downloading : (store.isDownloaded(songID) ? .complete : .hidden)
    }

    /// An album: filled when all `totalTracks` are cached, outline when some are, else hidden.
    static func status(albumID: String, totalTracks: Int?) -> Status {
        collectionStatus(cached: MusicDownloadStore.shared.downloadedCount(albumID: albumID), total: totalTracks)
    }

    /// The full/partial/hidden decision for a collection with `cached` downloaded tracks out of
    /// `total` (nil when the total isn't known — then any downloads read as partial). Pure, so
    /// it's unit-tested.
    static func collectionStatus(cached: Int, total: Int?) -> Status {
        if let total, total > 0, cached >= total { return .complete }
        if cached > 0 { return .partial }
        return .hidden
    }

    /// An artist / playlist: computed from the membership recorded when it was downloaded as a
    /// unit — `.complete` when every member is still cached, `.partial` when some are, `.hidden`
    /// when it was never downloaded as a collection.
    static func status(artistID: String) -> Status { collectionStatus(kind: "artist", id: artistID) }
    static func status(playlistID: String) -> Status { collectionStatus(kind: "playlist", id: playlistID) }

    private static func collectionStatus(kind: String, id: String) -> Status {
        guard let members = MusicDownloadStore.shared.collectionMemberCount(kind: kind, id: id) else { return .hidden }
        return collectionStatus(cached: members.downloaded, total: members.total)
    }

    var body: some View {
        Group {
            switch status {
            case .hidden: Color.clear
            case .downloading: ProgressView().controlSize(.small)
            case .partial: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).help("Partly downloaded")
            case .complete: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).help("Downloaded")
            }
        }
        .font(.callout)
        .frame(width: 20, height: 20)
    }
}

// MARK: - Shared per-song menu

/// The playback head of every song context menu — Play · Play Next · Add to Queue ·
/// Start Radio — so the top group is identical on every song row (Liked, Search, Artist,
/// Album, Playlist, Related). `onPlay` matches the row's own tap/double-tap behavior.
@MainActor @ViewBuilder
func songPlaybackMenuItems(_ song: NavidromeSong, _ model: MusicModel, onPlay: @escaping () -> Void) -> some View {
    Button("Get Info", systemImage: "info.circle") { model.inspectorSong = song }
    Divider()
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

/// The **Actions** submenu on a song row — the custom webhook actions the user configured,
/// filled with this song's tokens (metadata always; stream/download URLs only if the action
/// opted into credentialed URLs, enforced in the store). Nil-render when there are no actions.
@MainActor @ViewBuilder
func songActionsMenu(_ song: NavidromeSong, _ model: MusicModel) -> some View {
    WebhookRunner.menu(for: { MusicWebhookTokens.song(song) }, model)
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
            Text("Unlikes it and sets a 1-star rating, so a library-cleanup tool can remove it later.")
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
    PinMenuButton(item: .album(album), model: model)
    Divider()
    Button("Download", systemImage: "arrow.down.circle") { run { await AlbumActions.download(album, model) } }
    Button("Save as Playlist", systemImage: "square.and.arrow.down") {
        run { await AlbumActions.saveAsPlaylist(album, model) }
    }
    WebhookRunner.menu(for: { MusicWebhookTokens.album(album) }, model)
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
            Text("Unlikes every track and rates it 1 star, so a library-cleanup tool can remove them later.")
        }
    }
}

/// A dense album table row — thumbnail (play), title/artist, Tracks / Time columns,
/// and a ⋯ menu. Tapping the name opens the album.
struct MusicAlbumRow: View {
    @Environment(MusicModel.self) private var model
    let album: NavidromeAlbum
    var isSelected = false
    /// Keyboard-focus highlight (↑/↓ navigation in the Albums list layout).
    var highlighted = false
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
    private var genreText: String { album.genres.first ?? album.genre ?? "" }
    private var yearText: String { album.year.map(String.init) ?? "" }

    /// This album is the source of the current queue (matches the grid card's cue).
    private var isPlayingSource: Bool {
        let source = model.music.queueSource
        return source?.kind == .album && source?.id == album.id
    }
    private var isPlayingNow: Bool { isPlayingSource && model.music.isPlaying }

    private func run(_ body: @escaping () async -> Void) { Task { working = true; await body(); working = false } }

    var body: some View {
        HStack(spacing: 12) {
            MusicSelectCheckbox(isSelected: isSelected, visible: hovering, onToggle: onToggleSelect)

            Button { run { await play() } } label: {
                MusicRowThumb(url: coverURL, isHovering: hovering, isWorking: working)
            }
            .buttonStyle(.plain).help("Play \(title)")
            .accessibilityLabel("Play \(title)")

            NavigationLink(value: album) {
                HStack(spacing: 6) {
                    if isPlayingNow { NowPlayingSourceGlyph() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.medium))
                            .foregroundStyle(isPlayingNow ? Color.accentColor : .primary).lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
            .accessibilityHint("Opens album")

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

            DownloadStatusBadge(albumID: album.id, totalTracks: album.songCount)

            Text(genreText)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: BrowseColumns.genre, alignment: .leading)
            Text(yearText)
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: BrowseColumns.year, alignment: .trailing)
            Group {
                Text(tracksText).frame(width: BrowseColumns.tracks, alignment: .trailing)
                Text(timeText).frame(width: BrowseColumns.time, alignment: .trailing)
            }
            .monospacedDigit()
            .font(.callout)
            .foregroundStyle(.secondary)

            MusicLikeHeart(
                isLiked: model.musicLibrary.isLiked(id: album.id, isLiked: album.isLiked),
                help: model.musicLibrary.isLiked(id: album.id, isLiked: album.isLiked) ? "Unlike album" : "Like album"
            ) {
                Task {
                    await model.musicLibrary.toggleLike(
                        id: album.id, currentLiked: album.isLiked, userRating: album.userRating
                    )
                }
            }
            .frame(width: BrowseColumns.like, alignment: .center)

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
            isSelected ? Color.selectionTint()
                : (highlighted ? Color.accentColor.opacity(0.14)
                : (isPlayingSource ? Color.nowPlayingRowTint()
                : (hovering ? Color.hoverTint : .clear)))
        ))
        .overlay(alignment: .leading) {
            if highlighted { Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4) }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
        .animation(.easeInOut(duration: 0.18), value: isPlayingSource)
        .animation(.easeInOut(duration: 0.18), value: isPlayingNow)
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
        // Record the playlist's member set so its download badge can report complete/partial.
        MusicDownloadStore.shared.registerCollection(kind: "playlist", id: playlist.id, trackIDs: songs.map(\.id))
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
    private var isPlayingNow: Bool { isPlayingSource && model.music.isPlaying }

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
                isSelected: isPlayingSource,
                isPlaying: isPlayingNow,
                downloadStatus: DownloadStatusBadge.status(playlistID: playlist.id),
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
        .hoverLift(hovering)
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
    PinMenuButton(item: .playlist(playlist), model: model)
    Divider()
    Button("Download", systemImage: "arrow.down.circle") { run { await PlaylistActions.download(playlist, model) } }
    WebhookRunner.menu(for: { MusicWebhookTokens.playlist(playlist) }, model)
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

    /// This playlist is the source of the current queue (matches the grid cell's cue).
    private var isPlayingSource: Bool {
        let source = model.music.queueSource
        return source?.kind == .playlist && source?.id == playlist.id
    }
    private var isPlayingNow: Bool { isPlayingSource && model.music.isPlaying }

    private func run(_ body: @escaping () async -> Void) { Task { working = true; await body(); working = false } }

    var body: some View {
        HStack(spacing: 12) {
            MusicSelectCheckbox(isSelected: isSelected, visible: hovering, onToggle: onToggleSelect)

            Button { run { await PlaylistActions.play(playlist, model) } } label: {
                MusicRowThumb(url: coverURL, placeholder: "music.note.list", isHovering: hovering, isWorking: working)
            }
            .buttonStyle(.plain).help("Play \(playlist.name)")
            .accessibilityLabel("Play \(playlist.name)")

            NavigationLink(value: playlist) {
                HStack(spacing: 6) {
                    if isPlayingNow { NowPlayingSourceGlyph() }
                    Text(playlist.name).font(.body.weight(.medium))
                        .foregroundStyle(isPlayingNow ? Color.accentColor : .primary).lineLimit(1)
                    if playlist.isPublic {
                        Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playlist.isPublic ? "\(playlist.name), shared playlist" : "\(playlist.name), playlist")
            .accessibilityHint("Opens playlist")

            if hovering {
                MusicRowActions(actions: [
                    MusicRowAction(title: "Shuffle", systemImage: "shuffle") { run { await PlaylistActions.play(playlist, model, shuffle: true) } },
                    MusicRowAction(title: "Add to Queue", systemImage: "text.append") { run { await PlaylistActions.queue(playlist, model) } },
                    MusicRowAction(title: "Find Similar (Radio)", systemImage: "dot.radiowaves.left.and.right") { run { await PlaylistActions.radio(playlist, model) } },
                    MusicRowAction(title: "Download", systemImage: "arrow.down.circle") { run { await PlaylistActions.download(playlist, model) } },
                    MusicRowAction(title: "Delete", systemImage: "trash", tint: .red) { showDeleteConfirm = true },
                ])
            }

            DownloadStatusBadge(playlistID: playlist.id)

            Group {
                Text("\(playlist.songCount)").frame(width: BrowseColumns.tracks, alignment: .trailing)
                Text(playlist.duration.map { MusicAlbumCard.albumDuration($0) } ?? "—")
                    .frame(width: BrowseColumns.time, alignment: .trailing)
            }
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            isSelected ? Color.selectionTint()
                : (isPlayingSource ? Color.nowPlayingRowTint()
                : (hovering ? Color.hoverTint : .clear))
        ))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
        .animation(.easeInOut(duration: 0.18), value: isPlayingSource)
        .animation(.easeInOut(duration: 0.18), value: isPlayingNow)
        .contextMenu {
            playlistActionMenuItems(playlist, model, run: run, onDelete: { showDeleteConfirm = true })
        }
        .playlistDeleteConfirm(playlist, isPresented: $showDeleteConfirm, confirm: onDelete)
    }
}
