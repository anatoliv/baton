import SwiftUI

/// Heuristics for cleaning up a messy (YouTube-imported) artist library.
enum ArtistHeuristics {
    /// A likely auto-imported / junk "artist" — YT single-track imports store a track
    /// title or a numeric id in the artist field. Flags quoted names, numeric-prefixed
    /// names ("026_Bobina", "10-Faithless"), and "User 959578140".
    static func isAutoImport(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return true }
        if let first = t.first, "\"“'".contains(first) { return true }
        if t.range(of: #"^\d+\s*[-_.,]"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^[Uu]ser\s+\d+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// A likely auto-imported "album": YT single-track imports use a generic album name
    /// ("YT Mix"), a zero-padded positional number ("01", "026"), or hang off an
    /// auto-import artist. Deliberately conservative on numbers — real numeric album titles
    /// ("4", "21", "1989") have no leading zero, so only `0`-prefixed numbers are flagged.
    static func isAutoImportAlbum(name: String, artist: String?) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.caseInsensitiveCompare("YT Mix") == .orderedSame { return true }
        if n.range(of: #"^0\d+$"#, options: .regularExpression) != nil { return true }
        if isAutoImport(n) { return true }
        if let artist, isAutoImport(artist) { return true }
        return false
    }

    /// Shared, persisted key for the "hide auto-imports" toggle (Albums + Artists).
    static let hideAutoImportsKey = "tonebox.music.hideAutoImports"

    /// Normalized key for duplicate grouping: diacritic- and case-insensitive, with a
    /// leading numeric prefix and all punctuation/whitespace stripped. So "Tiësto",
    /// "Tiesto", and "TIESTO" collapse to one key.
    static func normalizedKey(_ name: String) -> String {
        var s = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        s = s.replacingOccurrences(of: #"^\d+\s*[-_.,]?\s*"#, with: "", options: .regularExpression)
        s = s.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return s
    }

    static func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes) min" }
        return seconds > 0 ? "\(seconds)s" : "—"
    }
}

/// Shared per-artist playback/curation actions, so the list row and grid card don't
/// duplicate the logic. Each caller wraps these in its own `working` flag.
@MainActor
enum ArtistActions {
    static func play(_ artist: NavidromeArtist, _ model: MusicModel, shuffle: Bool) async {
        var songs = await model.musicLibrary.artistSongs(id: artist.id)
        guard !songs.isEmpty else { return }
        if shuffle { songs.shuffle() }
        model.music.play(songs, source: .init(label: artist.name, kind: .artist, id: artist.id))
    }

    static func queue(_ artist: NavidromeArtist, _ model: MusicModel) async {
        let songs = await model.musicLibrary.artistSongs(id: artist.id)
        if !songs.isEmpty { model.music.enqueue(songs) }
    }

    static func radio(_ artist: NavidromeArtist, _ model: MusicModel) async {
        let radio = await model.musicLibrary.similarSongs(seedID: artist.id)
        if !radio.isEmpty {
            model.music.play(radio, source: .init(label: "\(artist.name) Radio", kind: .radio, id: nil))
        }
    }

    static func saveAsPlaylist(_ artist: NavidromeArtist, _ model: MusicModel) async {
        let songs = await model.musicLibrary.artistSongs(id: artist.id)
        guard !songs.isEmpty else { return }
        _ = await model.musicLibrary.createPlaylist(name: artist.name, songIDs: songs.map(\.id))
        await model.musicLibrary.loadPlaylists()
        model.music.postToast("Saved playlist “\(artist.name)”", symbol: "square.and.arrow.down")
    }

    static func download(_ artist: NavidromeArtist, _ model: MusicModel) async {
        let songs = await model.musicLibrary.artistSongs(id: artist.id)
        guard !songs.isEmpty else { return }
        model.music.postToast("Downloading \(songs.count) song\(songs.count == 1 ? "" : "s")…", symbol: "arrow.down.circle")
        // Record the artist's full track set so its download badge can report complete/partial.
        MusicDownloadStore.shared.registerCollection(kind: "artist", id: artist.id, trackIDs: songs.map(\.id))
        await MusicDownloadStore.shared.download(songs)
    }

    static func markAllForRemoval(_ artist: NavidromeArtist, _ model: MusicModel) async {
        let songs = await model.musicLibrary.artistSongs(id: artist.id)
        for song in songs { await model.musicLibrary.markForRemoval(song) }
    }
}

/// The full set of artist actions for the **grid's** right-click context menu (the grid
/// cards have no inline hover strip, so they need everything). The list row instead
/// surfaces these as inline hover icons — see `MusicArtistListRow`. `run` wraps an async
/// action (driving a `working` flag); `onRemove` triggers the removal confirmation.
@MainActor @ViewBuilder
func artistActionMenuItems(
    _ artist: NavidromeArtist,
    _ model: MusicModel,
    run: @escaping (@escaping () async -> Void) -> Void,
    onRemove: @escaping () -> Void
) -> some View {
    Button("Play", systemImage: "play.fill") { run { await ArtistActions.play(artist, model, shuffle: false) } }
    Button("Shuffle", systemImage: "shuffle") { run { await ArtistActions.play(artist, model, shuffle: true) } }
    Button("Add to Queue", systemImage: "text.append") { run { await ArtistActions.queue(artist, model) } }
    Button("Find Similar (Radio)", systemImage: "dot.radiowaves.left.and.right") {
        run { await ArtistActions.radio(artist, model) }
    }
    PinMenuButton(item: .artist(artist), model: model)
    Divider()
    Button("Download", systemImage: "arrow.down.circle") { run { await ArtistActions.download(artist, model) } }
    Button("Save as Playlist", systemImage: "square.and.arrow.down") {
        run { await ArtistActions.saveAsPlaylist(artist, model) }
    }
    Divider()
    Button("Mark All for Removal", systemImage: "xmark.bin", role: .destructive) { onRemove() }
}

/// The removal confirmation dialog copy, shared by the row and the card.
extension View {
    func artistRemovalConfirm(_ artist: NavidromeArtist, isPresented: Binding<Bool>, confirm: @escaping () -> Void) -> some View {
        confirmationDialog(
            "Mark all of “\(artist.name)” for removal?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Mark for removal", role: .destructive, action: confirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every track by this artist will be unliked and rated lowest (★) so a library-cleanup tool can remove them later. Subsonic can't delete files directly.")
        }
    }
}

/// The Artists browser: a dense, searchable, sortable list (or card grid) with
/// per-artist stats, junk/duplicate flags, and per-artist actions (play / shuffle /
/// queue / radio / save as playlist / mark for removal).
struct MusicArtistsBrowser: View {
    @Environment(MusicModel.self) private var model
    @State private var search = ""
    @State private var sort: ArtistSort = .name
    @State private var sortAscending = true
    @AppStorage(ArtistHeuristics.hideAutoImportsKey) private var hideAutoImports = false
    @State private var duplicatesOnly = false
    @State private var sel = MusicMultiSelect()
    @State private var showBatchRemoveConfirm = false
    @FocusState private var filterFocused: Bool
    /// List (dense table) vs Grid (cards). Persisted; Artists defaults to list.
    @AppStorage("tonebox.music.artistLayout") private var layout: MusicBrowseLayout = .list

    private var library: MusicLibraryStore { model.musicLibrary }

    private var orderedIDs: [String] { visibleArtists.map(\.id) }
    private var selectedArtists: [NavidromeArtist] { visibleArtists.filter { sel.contains($0.id) } }

    enum ArtistSort: String, CaseIterable, Identifiable, MusicSortField {
        case name, albums
        var id: String { rawValue }
        var label: String { self == .name ? "Name" : "Albums" }
    }

    /// Names that appear more than once after normalization (the duplicate groups).
    private var duplicateKeys: Set<String> {
        var counts: [String: Int] = [:]
        for artist in library.artists { counts[ArtistHeuristics.normalizedKey(artist.name), default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private var visibleArtists: [NavidromeArtist] {
        let dupKeys = duplicatesOnly ? duplicateKeys : []
        var list = library.artists
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { list = list.filter { $0.name.lowercased().contains(query) } }
        if hideAutoImports { list = list.filter { !ArtistHeuristics.isAutoImport($0.name) } }
        if duplicatesOnly { list = list.filter { dupKeys.contains(ArtistHeuristics.normalizedKey($0.name)) } }
        switch sort {
        case .name:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .albums:
            list.sort { ($0.albumCount ?? 0) < ($1.albumCount ?? 0) }
        }
        if !sortAscending { list.reverse() }
        if duplicatesOnly {
            // Keep duplicate groups adjacent for easy comparison.
            list.sort { ArtistHeuristics.normalizedKey($0.name) < ArtistHeuristics.normalizedKey($1.name) }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            MusicBrowseHeader(
                title: "Artists",
                count: visibleArtists.count,
                filter: $search,
                filterPrompt: "Filter artists",
                filterFocused: $filterFocused,
                filterHistoryKey: "artists",
                layout: $layout,
                accessory: { EmptyView() },
                leading: {
                    if sel.isEmpty {
                        MusicMiniTransport()
                        Toggle(isOn: $hideAutoImports) { Text("Hide auto-imports") }
                            .toggleStyle(.button).controlSize(.small)
                        Toggle(isOn: $duplicatesOnly) { Label("Duplicates", systemImage: "square.on.square") }
                            .toggleStyle(.button).controlSize(.small)
                        if !visibleArtists.isEmpty {
                            Button { sel.selectAll(orderedIDs) } label: {
                                Label("Select", systemImage: "checklist").font(.caption).labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .keyboardShortcut(filterFocused ? nil : KeyboardShortcut("a", modifiers: .command))
                            .help("Select all artists (⌘A)")
                        }
                    } else {
                        artistSelectionBar
                    }
                },
                sortMenu: {
                    MusicSortControls(ascending: $sortAscending, selection: $sort)
                }
            )
            if library.artists.isEmpty {
                emptyState(icon: "music.mic", title: "No artists")
            } else if visibleArtists.isEmpty {
                emptyState(icon: "magnifyingglass", title: "No artists match")
            } else if layout == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(visibleArtists) { artist in
                            ArtistGridCell(
                                artist: artist,
                                isDuplicate: duplicateKeys.contains(ArtistHeuristics.normalizedKey(artist.name)),
                                isSelected: sel.contains(artist.id),
                                onToggleSelect: { sel.clicked(artist.id, ordered: orderedIDs) }
                            )
                        }
                    }
                    .padding(12)
                }
            } else {
                // Cap the table width and center it so rows don't stretch edge-to-edge
                // on a wide window (which left the name and actions far apart).
                VStack(spacing: 0) {
                    ArtistColumns.header
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(visibleArtists) { artist in
                                MusicArtistListRow(
                                    artist: artist,
                                    isDuplicate: duplicateKeys.contains(ArtistHeuristics.normalizedKey(artist.name)),
                                    isSelected: sel.contains(artist.id),
                                    onToggleSelect: { sel.clicked(artist.id, ordered: orderedIDs) }
                                )
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            }
        }
        .task { if library.artists.isEmpty { await library.loadArtists() } }
        // Keep the selection honest: when a filter/sort hides artists, drop the hidden
        // ones (but keep still-visible picks) so the "N selected" count never lies.
        .onChange(of: orderedIDs) { sel.reconcile(orderedIDs) }
        .confirmationDialog(
            "Mark all tracks by \(selectedArtists.count) artist\(selectedArtists.count == 1 ? "" : "s") for removal?",
            isPresented: $showBatchRemoveConfirm, titleVisibility: .visible
        ) {
            Button("Mark All for Removal", role: .destructive) { batchRemove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every track by the selected artists is unliked and rated 1 star, so a library-cleanup tool can remove them later.")
        }
    }

    /// The batch bar for a live artist selection — mirrors the Liked song bar via the
    /// shared `MusicSelectionBar` + `MusicBatchActions` (each op fans out to tracks).
    private var artistSelectionBar: some View {
        let label = "\(selectedArtists.count) artists"
        let name = selectedArtists.count == 1 ? (selectedArtists.first?.name ?? label) : "\(selectedArtists.count) Artists"
        return MusicSelectionBar(
            count: selectedArtists.count,
            allSelected: sel.allSelected(orderedIDs),
            selectAllShortcut: !filterFocused,
            onToggleSelectAll: { sel.toggleSelectAll(orderedIDs) },
            onClear: { sel.clear() }
        ) {
            MusicBatchButton(system: "play.fill", help: "Play selected") { MusicBatchActions.play(model, shuffle: false, label: label, kind: .artist, gather: artistTracks) }
            MusicBatchButton(system: "shuffle", help: "Shuffle selected") { MusicBatchActions.play(model, shuffle: true, label: label, kind: .artist, gather: artistTracks) }
            MusicBatchButton(system: "text.append", help: "Add to queue") { MusicBatchActions.queue(model, gather: artistTracks) }
            MusicBatchButton(system: "square.and.arrow.down", help: "Save as playlist") { MusicBatchActions.save(model, name: name, gather: artistTracks) }
            MusicBatchAddToPlaylistMenu(gather: artistTracks)
            MusicBatchButton(system: "arrow.down.circle", help: "Download") { MusicBatchActions.download(model, gather: artistTracks) }
            MusicBatchButton(system: "xmark.bin", help: "Mark all for removal") { showBatchRemoveConfirm = true }
        }
    }

    /// The tracks of the currently-selected artists (sequential fetch), for the shared
    /// batch operations.
    private func artistTracks() async -> [NavidromeSong] {
        await MusicBatchActions.songs(ofArtists: selectedArtists, model)
    }

    private func batchRemove() {
        MusicBatchActions.markForRemoval(model, gather: artistTracks) { sel.clear() }
    }

    private func emptyState(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared column geometry for the Artists table so the header and rows line up.
enum ArtistColumns {
    static let albums: CGFloat = 58
    static let tracks: CGFloat = 58
    static let time: CGFloat = 84
    static let avatar: CGFloat = 40

    static var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 18, height: 1)   // selection checkbox slot
                Color.clear.frame(width: avatar, height: 1)
                Text("Artist")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Albums").frame(width: albums, alignment: .trailing)
            Text("Tracks").frame(width: tracks, alignment: .trailing)
            Text("Time").frame(width: time, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
    }
}

/// One dense artist table row — small avatar + name (with junk/duplicate flags), then
/// right-aligned Albums / Tracks / Time columns (lazily loaded), a hover Play, and a ⋯
/// menu. Tapping the name area navigates to the artist detail.
struct MusicArtistListRow: View {
    @Environment(MusicModel.self) private var model
    let artist: NavidromeArtist
    var isDuplicate = false
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    @State private var hovering = false
    @State private var stats: MusicLibraryStore.ArtistStats?
    @State private var working = false
    @State private var showRemoveConfirm = false

    private var albumsText: String { "\(stats?.albums ?? artist.albumCount ?? 0)" }
    private var tracksText: String { stats.map { "\($0.tracks)" } ?? "—" }
    private var timeText: String { stats.map { ArtistHeuristics.formatDuration($0.seconds) } ?? "—" }

    /// Artwork for the avatar. Prefer the artist's real album cover (loaded with the
    /// stats) since the server's artist-level portrait is often a generic placeholder;
    /// then the artist coverArt / direct URL; else the monogram.
    private var imageURL: URL? {
        if let id = stats?.coverArtID { return model.musicLibrary.coverArtURL(id: id, size: 80) }
        if let id = artist.coverArtID { return model.musicLibrary.coverArtURL(id: id, size: 80) }
        if let raw = artist.imageURLString, let url = URL(string: raw) { return url }
        return nil
    }

    private func run(_ body: @escaping () async -> Void) { Task { working = true; await body(); working = false } }

    var body: some View {
        HStack(spacing: 12) {
            MusicSelectCheckbox(isSelected: isSelected, visible: hovering, onToggle: onToggleSelect)

            // Avatar doubles as the Play button: hovering reveals a play overlay right
            // at the start of the row.
            Button {
                Task { working = true; await ArtistActions.play(artist, model, shuffle: false); working = false }
            } label: { avatar }
                .buttonStyle(.plain)
                .help("Play \(artist.name)")
                .accessibilityLabel("Play \(artist.name)")

            NavigationLink(value: artist) {
                HStack(spacing: 8) {
                    Text(artist.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if ArtistHeuristics.isAutoImport(artist.name) { flag("auto-import", .orange) }
                    if isDuplicate { flag("duplicate", .yellow) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(artist.name)
            .accessibilityHint("Opens artist")

            if hovering {
                MusicRowActions(actions: [
                    MusicRowAction(title: "Shuffle", systemImage: "shuffle") {
                        run { await ArtistActions.play(artist, model, shuffle: true) }
                    },
                    MusicRowAction(title: "Add to Queue", systemImage: "text.append") {
                        run { await ArtistActions.queue(artist, model) }
                    },
                    MusicRowAction(title: "Find Similar (Radio)", systemImage: "dot.radiowaves.left.and.right") {
                        run { await ArtistActions.radio(artist, model) }
                    },
                    MusicRowAction(title: "Download", systemImage: "arrow.down.circle") {
                        run { await ArtistActions.download(artist, model) }
                    },
                    MusicRowAction(title: "Save as Playlist", systemImage: "square.and.arrow.down") {
                        run { await ArtistActions.saveAsPlaylist(artist, model) }
                    },
                    MusicRowAction(title: "Mark All for Removal", systemImage: "xmark.bin", tint: .red) {
                        showRemoveConfirm = true
                    },
                ])
            }

            DownloadStatusBadge(artistID: artist.id)

            Group {
                Text(albumsText).frame(width: ArtistColumns.albums, alignment: .trailing)
                Text(tracksText).frame(width: ArtistColumns.tracks, alignment: .trailing)
                Text(timeText).frame(width: ArtistColumns.time, alignment: .trailing)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            isSelected ? Color.selectionTint() : (hovering ? Color.hoverTint : .clear)
        ))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
        // Right-click parity with the grid card + the other list rows (the inline hover
        // icons are the same actions, one hover away).
        .contextMenu {
            artistActionMenuItems(artist, model, run: run, onRemove: { showRemoveConfirm = true })
        }
        .artistRemovalConfirm(artist, isPresented: $showRemoveConfirm) {
            run { await ArtistActions.markAllForRemoval(artist, model) }
        }
        .task(id: artist.id) { stats = await model.musicLibrary.artistStats(id: artist.id) }
    }

    /// Circular artist portrait (server image or monogram fallback) with a hover
    /// play-overlay + a working spinner.
    private var avatar: some View {
        ZStack {
            if let imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    monogram
                }
            } else {
                monogram
            }
            if hovering || working {
                Circle().fill(.black.opacity(0.45))
                if working {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "play.fill").font(.body).foregroundStyle(.white)
                }
            }
        }
        .frame(width: ArtistColumns.avatar, height: ArtistColumns.avatar)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    private var monogram: some View {
        Circle()
            .fill(ArtistMonogram.color(artist.name).gradient)
            .overlay(Text(ArtistMonogram.initial(artist.name)).font(.headline).foregroundStyle(.white))
    }

    private func flag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// A hover-lifting artist grid cell — same pattern as `AlbumGridCell`: one `.onHover`
/// drives the card's play button, scale, and zIndex; the whole cell navigates to the
/// artist and right-clicks for the action menu.
struct ArtistGridCell: View {
    @Environment(MusicModel.self) private var model
    let artist: NavidromeArtist
    var isDuplicate = false
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    @State private var hovering = false
    @State private var working = false
    @State private var showRemoveConfirm = false

    private func run(_ body: @escaping () async -> Void) {
        Task { working = true; await body(); working = false }
    }

    var body: some View {
        NavigationLink(value: artist) {
            MusicArtistGridCard(artist: artist, isDuplicate: isDuplicate, isHovering: hovering, isWorking: working) {
                run { await ArtistActions.play(artist, model, shuffle: false) }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if hovering || isSelected {
                MusicSelectCheckbox(isSelected: isSelected, onToggle: onToggleSelect)
                    .padding(6)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
        }
        .hoverLift(hovering)
        .zIndex(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            artistActionMenuItems(artist, model, run: run, onRemove: { showRemoveConfirm = true })
        }
        .artistRemovalConfirm(artist, isPresented: $showRemoveConfirm) {
            run { await ArtistActions.markAllForRemoval(artist, model) }
        }
    }
}

/// The card variant for the Artists grid — the shared `MusicMediaCard` (same design
/// as albums) fed with artist artwork, name, and lazily-loaded stats. Hover/working
/// state and the play action come from the enclosing `ArtistGridCell`.
struct MusicArtistGridCard: View {
    @Environment(MusicModel.self) private var model
    let artist: NavidromeArtist
    var isDuplicate = false
    var isHovering: Bool
    var isWorking: Bool
    var onPlay: () -> Void
    @State private var stats: MusicLibraryStore.ArtistStats?

    private var imageURL: URL? {
        if let id = stats?.coverArtID { return model.musicLibrary.coverArtURL(id: id, size: 400) }
        if let id = artist.coverArtID { return model.musicLibrary.coverArtURL(id: id, size: 400) }
        if let raw = artist.imageURLString, let url = URL(string: raw) { return url }
        return nil
    }

    private var albumsText: String {
        let n = stats?.albums ?? artist.albumCount ?? 0
        return "\(n) album\(n == 1 ? "" : "s")"
    }

    private var trackCountText: String? { stats.map { "\($0.tracks) track\($0.tracks == 1 ? "" : "s")" } }
    private var durationText: String? { stats.map { ArtistHeuristics.formatDuration($0.seconds) } }

    private var badge: (text: String, color: Color)? {
        if ArtistHeuristics.isAutoImport(artist.name) { return ("auto-import", .orange) }
        if isDuplicate { return ("duplicate", .yellow) }
        return nil
    }

    private var isPlayingSource: Bool {
        let source = model.music.queueSource
        return source?.kind == .artist && source?.id == artist.id
    }

    var body: some View {
        MusicMediaCard(
            coverURL: imageURL,
            placeholder: "music.mic",
            cornerBadge: badge,
            title: artist.name,
            subtitle: albumsText,
            trailingTop: trackCountText,
            trailingBottom: durationText,
            isHovering: isHovering,
            isWorking: isWorking,
            isPlayingSource: isPlayingSource,
            downloadStatus: DownloadStatusBadge.status(artistID: artist.id),
            onPlay: onPlay
        )
        .task(id: artist.id) { stats = await model.musicLibrary.artistStats(id: artist.id) }
    }
}
