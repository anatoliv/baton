import SwiftUI
import BatonPlaybackKit
import BatonSubsonicModels

/// Browsing the library the way it sits on disk — the folder tree is the *owner's*
/// opinion of the library, and for a collection organized by hand over years the folders
/// carry meaning the tags don't.
///
/// This screen is deliberately the same screen as Artists: the shared browse header
/// (filter + history, sort, list ⇄ grid), the shared multi-select and batch bar, the
/// shared card and row hover language, and value-based pushes onto the window's one
/// `NavigationStack`. Folders earn exactly one behavioral difference — "play" means
/// *everything underneath*, because an artist folder's music lives in its album
/// subfolders, not at its top level.

// MARK: - Actions

/// Shared per-folder playback/curation actions, so the list row, grid card, detail view
/// and batch bar all run identical logic. Each caller wraps these in its own `working`
/// flag. Playback is recursive (`songsUnderFolder`), and a truncated walk says so — a
/// silent cap reads as "the folder only had this much".
@MainActor
enum FolderActions {
    static func songs(_ folder: NavidromeFolder, _ model: MusicModel) async -> [NavidromeSong] {
        let result = await model.musicLibrary.songsUnderFolder(id: folder.id)
        if result.truncated {
            model.music.postToast(
                "“\(folder.name)” is huge — using the first \(result.songs.count) songs",
                symbol: "exclamationmark.triangle"
            )
        }
        return result.songs
    }

    static func play(_ folder: NavidromeFolder, _ model: MusicModel, shuffle: Bool) async {
        var songs = await songs(folder, model)
        guard !songs.isEmpty else {
            model.music.postToast("“\(folder.name)” has no songs", symbol: "folder")
            return
        }
        if shuffle { songs.shuffle() }
        model.music.play(songs, source: .init(label: folder.name, kind: .folder, id: folder.id))
    }

    static func queue(_ folder: NavidromeFolder, _ model: MusicModel) async {
        let songs = await songs(folder, model)
        if !songs.isEmpty { model.music.enqueue(songs) }
    }

    static func download(_ folder: NavidromeFolder, _ model: MusicModel) async {
        let songs = await songs(folder, model)
        guard !songs.isEmpty else { return }
        model.music.postToast("Downloading \(songs.count) song\(songs.count == 1 ? "" : "s")…", symbol: "arrow.down.circle")
        // Record the folder's track set so its download badge can report complete/partial.
        MusicDownloadStore.shared.registerCollection(kind: "folder", id: folder.id, trackIDs: songs.map(\.id))
        await MusicDownloadStore.shared.download(songs)
    }

    static func saveAsPlaylist(_ folder: NavidromeFolder, _ model: MusicModel) async {
        let songs = await songs(folder, model)
        guard !songs.isEmpty else { return }
        _ = await model.musicLibrary.createPlaylist(name: folder.name, songIDs: songs.map(\.id))
        await model.musicLibrary.loadPlaylists()
        model.music.postToast("Saved playlist “\(folder.name)”", symbol: "square.and.arrow.down")
    }
}

/// The full folder menu for right-click — grid cards and detail rows alike. The list row
/// additionally surfaces the same actions as inline hover icons, like Artists does.
@MainActor @ViewBuilder
func folderActionMenuItems(
    _ folder: NavidromeFolder,
    _ model: MusicModel,
    run: @escaping (@escaping () async -> Void) -> Void
) -> some View {
    Button("Play", systemImage: "play.fill") { run { await FolderActions.play(folder, model, shuffle: false) } }
    Button("Shuffle", systemImage: "shuffle") { run { await FolderActions.play(folder, model, shuffle: true) } }
    Button("Add to Queue", systemImage: "text.append") { run { await FolderActions.queue(folder, model) } }
    Divider()
    Button("Download", systemImage: "arrow.down.circle") { run { await FolderActions.download(folder, model) } }
    Button("Save as Playlist", systemImage: "square.and.arrow.down") {
        run { await FolderActions.saveAsPlaylist(folder, model) }
    }
}

// MARK: - Roots browser

/// The Folders tab: a searchable, sortable list (or card grid) of the folder-tree roots,
/// with per-folder actions and the shared multi-select/batch bar.
struct MusicFoldersView: View {
    @Environment(MusicModel.self) private var model

    @State private var roots: [NavidromeFolder] = []
    @State private var loaded = false
    @State private var filter = ""
    @State private var sortAscending = true
    @State private var sort: FolderSort = .name
    @State private var sel = MusicMultiSelect()
    @FocusState private var filterFocused: Bool
    /// List (dense table) vs Grid (cards). Persisted; shared with the folder detail so
    /// the tree reads the same at every level. Folders are name-first → default list.
    @AppStorage("tonebox.music.folderLayout") private var layout: MusicBrowseLayout = .list

    enum FolderSort: String, CaseIterable, Identifiable, MusicSortField {
        case name
        var id: String { rawValue }
        var label: String { "Name" }
    }

    private var shown: [NavidromeFolder] {
        var list = roots
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { list = list.filter { $0.name.lowercased().contains(query) } }
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !sortAscending { list.reverse() }
        return list
    }

    private var orderedIDs: [String] { shown.map(\.id) }
    private var selectedFolders: [NavidromeFolder] { shown.filter { sel.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            MusicBrowseHeader(
                title: "Folders",
                count: shown.count,
                filter: $filter,
                filterPrompt: "Filter folders",
                filterFocused: $filterFocused,
                filterHistoryKey: "folders",
                layout: $layout,
                accessory: { EmptyView() },
                leading: {
                    if sel.isEmpty {
                        MusicMiniTransport()
                        if !shown.isEmpty {
                            Button { sel.selectAll(orderedIDs) } label: {
                                Label("Select", systemImage: "checklist").font(.caption).labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .keyboardShortcut(filterFocused ? nil : KeyboardShortcut("a", modifiers: .command))
                            .help("Select all folders (⌘A)")
                        }
                    } else {
                        folderSelectionBar
                    }
                },
                sortMenu: {
                    MusicSortControls(ascending: $sortAscending, selection: $sort)
                }
            )
            if !loaded {
                Spacer()
                ProgressView()
                Spacer()
            } else if roots.isEmpty {
                emptyState(
                    icon: "folder", title: "No folders",
                    detail: "The server didn't report a folder tree."
                )
            } else if shown.isEmpty {
                emptyState(icon: "magnifyingglass", title: "No folders match", detail: nil)
            } else if layout == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(shown) { folder in
                            FolderGridCell(
                                folder: folder,
                                isSelected: sel.contains(folder.id),
                                onToggleSelect: { sel.clicked(folder.id, ordered: orderedIDs) }
                            )
                        }
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 0) {
                    FolderColumns.header
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(shown) { folder in
                                MusicFolderListRow(
                                    folder: folder,
                                    isSelected: sel.contains(folder.id),
                                    onToggleSelect: { sel.clicked(folder.id, ordered: orderedIDs) }
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
        .task {
            roots = await model.musicLibrary.folderRoots()
            loaded = true
        }
        .onChange(of: orderedIDs) { sel.reconcile(orderedIDs) }
    }

    /// The batch bar for a live folder selection — the shared `MusicSelectionBar` +
    /// `MusicBatchActions`, gathering each folder's recursive songs sequentially.
    private var folderSelectionBar: some View {
        let count = selectedFolders.count
        let label = "\(count) folders"
        let name = count == 1 ? (selectedFolders.first?.name ?? label) : "\(count) Folders"
        return MusicSelectionBar(
            count: count,
            allSelected: sel.allSelected(orderedIDs),
            selectAllShortcut: !filterFocused,
            onToggleSelectAll: { sel.toggleSelectAll(orderedIDs) },
            onClear: { sel.clear() }
        ) {
            MusicBatchButton(system: "play.fill", help: "Play selected") {
                MusicBatchActions.play(model, shuffle: false, label: label, kind: .folder, gather: folderTracks)
            }
            MusicBatchButton(system: "shuffle", help: "Shuffle selected") {
                MusicBatchActions.play(model, shuffle: true, label: label, kind: .folder, gather: folderTracks)
            }
            MusicBatchButton(system: "text.append", help: "Add to queue") {
                MusicBatchActions.queue(model, gather: folderTracks)
            }
            MusicBatchButton(system: "square.and.arrow.down", help: "Save as playlist") {
                MusicBatchActions.save(model, name: name, gather: folderTracks)
            }
            MusicBatchAddToPlaylistMenu(gather: folderTracks)
            MusicBatchButton(system: "arrow.down.circle", help: "Download") {
                MusicBatchActions.download(model, gather: folderTracks)
            }
        }
    }

    private func folderTracks() async -> [NavidromeSong] {
        var all: [NavidromeSong] = []
        for folder in selectedFolders { all += await FolderActions.songs(folder, model) }
        return all
    }

    private func emptyState(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared row/card pieces

/// Immediate-children counts for a folder's row/card subtitle, resolved from the store's
/// session directory cache — the same lazy per-row pattern as artist stats.
private struct FolderStats {
    let folders: Int
    let songs: Int
    let seconds: Int

    var subtitle: String {
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        if songs > 0 { parts.append("\(songs) song\(songs == 1 ? "" : "s")") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    init(_ directory: NavidromeDirectory) {
        folders = directory.folders.count
        songs = directory.songs.count
        seconds = directory.songs.reduce(0) { $0 + ($1.duration ?? 0) }
    }
}

/// Shared column geometry for the Folders table so the header and rows line up.
enum FolderColumns {
    static let folders: CGFloat = 58
    static let songs: CGFloat = 58
    static let time: CGFloat = 84
    static let icon: CGFloat = 40

    static var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 18, height: 1)   // selection checkbox slot
                Color.clear.frame(width: icon, height: 1)
                Text("Folder")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Folders").frame(width: folders, alignment: .trailing)
            Text("Songs").frame(width: songs, alignment: .trailing)
            Text("Time").frame(width: time, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
    }
}

/// One dense folder table row — tinted folder tile (doubling as the Play button, which
/// plays the whole subtree), name, hover action strip, then right-aligned counts loaded
/// lazily from the directory cache. Tapping the name pushes the folder detail.
struct MusicFolderListRow: View {
    @Environment(MusicModel.self) private var model
    let folder: NavidromeFolder
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    @State private var hovering = false
    @State private var working = false
    @State private var stats: FolderStats?

    private var isPlayingSource: Bool {
        let source = model.music.queueSource
        return source?.kind == .folder && source?.id == folder.id
    }
    private var isPlayingNow: Bool { isPlayingSource && model.music.isPlaying }

    private func run(_ body: @escaping () async -> Void) { Task { working = true; await body(); working = false } }

    var body: some View {
        HStack(spacing: 12) {
            MusicSelectCheckbox(isSelected: isSelected, visible: hovering, onToggle: onToggleSelect)

            Button {
                run { await FolderActions.play(folder, model, shuffle: false) }
            } label: { tile }
                .buttonStyle(.plain)
                .help("Play “\(folder.name)” (including subfolders)")
                .accessibilityLabel("Play \(folder.name)")

            NavigationLink(value: folder) {
                HStack(spacing: 8) {
                    if isPlayingNow { NowPlayingSourceGlyph() }
                    Text(folder.name).font(.body.weight(.medium))
                        .foregroundStyle(isPlayingNow ? Color.accentColor : .primary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(folder.name)
            .accessibilityHint("Opens folder")

            if hovering {
                MusicRowActions(actions: [
                    MusicRowAction(title: "Shuffle", systemImage: "shuffle") {
                        run { await FolderActions.play(folder, model, shuffle: true) }
                    },
                    MusicRowAction(title: "Add to Queue", systemImage: "text.append") {
                        run { await FolderActions.queue(folder, model) }
                    },
                    MusicRowAction(title: "Download", systemImage: "arrow.down.circle") {
                        run { await FolderActions.download(folder, model) }
                    },
                    MusicRowAction(title: "Save as Playlist", systemImage: "square.and.arrow.down") {
                        run { await FolderActions.saveAsPlaylist(folder, model) }
                    },
                ])
            }

            DownloadStatusBadge(folderID: folder.id)

            Group {
                Text(stats.map { "\($0.folders)" } ?? "—").frame(width: FolderColumns.folders, alignment: .trailing)
                Text(stats.map { "\($0.songs)" } ?? "—").frame(width: FolderColumns.songs, alignment: .trailing)
                Text(stats.map { ArtistHeuristics.formatDuration($0.seconds) } ?? "—")
                    .frame(width: FolderColumns.time, alignment: .trailing)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
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
        .contextMenu { folderActionMenuItems(folder, model, run: run) }
        .task(id: folder.id) {
            if let directory = await model.musicLibrary.directory(id: folder.id) {
                stats = FolderStats(directory)
            }
        }
    }

    /// Rounded folder tile in the name's monogram color, with a hover play overlay +
    /// working spinner — the folder version of the artist row's avatar.
    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(ArtistMonogram.color(folder.name).gradient)
            Image(systemName: "folder.fill").font(.body).foregroundStyle(.white.opacity(0.9))
            if hovering || working {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.45))
                if working {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "play.fill").font(.body).foregroundStyle(.white)
                }
            }
        }
        .frame(width: FolderColumns.icon, height: FolderColumns.icon)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

/// A hover-lifting folder grid cell — same shell as `ArtistGridCell`: the whole cell
/// navigates, hover drives the shared card's play button, right-click gets the menu.
struct FolderGridCell: View {
    @Environment(MusicModel.self) private var model
    let folder: NavidromeFolder
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    @State private var hovering = false
    @State private var working = false
    @State private var stats: FolderStats?

    private var isPlayingSource: Bool {
        let source = model.music.queueSource
        return source?.kind == .folder && source?.id == folder.id
    }
    private var isPlayingNow: Bool { isPlayingSource && model.music.isPlaying }

    private func run(_ body: @escaping () async -> Void) { Task { working = true; await body(); working = false } }

    var body: some View {
        NavigationLink(value: folder) {
            MusicMediaCard(
                coverURL: nil,
                placeholder: "folder.fill",
                title: folder.name,
                subtitle: stats?.subtitle ?? "",
                trailingBottom: stats.flatMap { $0.seconds > 0 ? ArtistHeuristics.formatDuration($0.seconds) : nil },
                isHovering: hovering,
                isWorking: working,
                isSelected: isPlayingSource,
                isPlaying: isPlayingNow,
                downloadStatus: DownloadStatusBadge.status(folderID: folder.id),
                onPlay: { run { await FolderActions.play(folder, model, shuffle: false) } }
            )
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
        .contextMenu { folderActionMenuItems(folder, model, run: run) }
        .task(id: folder.id) {
            if let directory = await model.musicLibrary.directory(id: folder.id) {
                stats = FolderStats(directory)
            }
        }
    }
}

// MARK: - Folder detail

/// One folder: banner, then subfolders and songs in disk order — a Finder window's
/// reading, in the same dress as every other detail page. Subfolders reuse the exact
/// row/cell components from the roots screen; songs are the shared `MusicTrackRow`.
struct MusicFolderDetailView: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: NavidromeFolder

    @State private var directory: NavidromeDirectory?
    @State private var loaded = false
    @State private var filter = ""
    @State private var kbIndex: Int?
    @AppStorage("tonebox.music.folderLayout") private var layout: MusicBrowseLayout = .list

    private var folderSource: StreamingPlaybackController.QueueSource {
        .init(label: folder.name, kind: .folder, id: folder.id)
    }

    private var subfolders: [NavidromeFolder] { directory?.folders ?? [] }
    private var songs: [NavidromeSong] { directory?.songs ?? [] }

    private var visibleSubfolders: [NavidromeFolder] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return subfolders }
        return subfolders.filter { $0.name.lowercased().contains(query) }
    }

    private var visibleSongs: [NavidromeSong] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return songs }
        return songs.filter { $0.title.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query) }
    }

    /// "3 folders · 12 songs · 42 min" — the banner meta line, from immediate children.
    private var detailText: String {
        guard let directory else { return "" }
        let stats = FolderStats(directory)
        var parts: [String] = []
        if stats.folders > 0 { parts.append("\(stats.folders) folder\(stats.folders == 1 ? "" : "s")") }
        if stats.songs > 0 { parts.append("\(stats.songs) song\(stats.songs == 1 ? "" : "s")") }
        if stats.seconds > 0 { parts.append(ArtistHeuristics.formatDuration(stats.seconds)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MusicAlbumBanner(
                        name: folder.name,
                        kindLabel: "FOLDER",
                        detail: detailText,
                        heroImage: nil,
                        accentColor: ArtistMonogram.color(folder.name),
                        placeholderIcon: "folder.fill",
                        downloadStatus: DownloadStatusBadge.status(folderID: folder.id),
                        onBack: { dismiss() }
                    )

                    MusicBrowseHeader(
                        title: "Contents",
                        count: visibleSubfolders.count + visibleSongs.count,
                        filter: $filter,
                        filterPrompt: "Filter this folder",
                        filterHistoryKey: "folders",
                        layout: $layout,
                        accessory: { EmptyView() },
                        leading: {
                            MusicMiniTransport(
                                onPlayWhenIdle: { Task { await FolderActions.play(folder, model, shuffle: false) } },
                                pageSource: folderSource
                            )
                            MusicRowActions(actions: [
                                MusicRowAction(title: "Shuffle All", systemImage: "shuffle") {
                                    Task { await FolderActions.play(folder, model, shuffle: true) }
                                },
                                MusicRowAction(title: "Add to Queue", systemImage: "text.append") {
                                    Task { await FolderActions.queue(folder, model) }
                                },
                                MusicRowAction(title: "Download", systemImage: "arrow.down.circle") {
                                    Task { await FolderActions.download(folder, model) }
                                },
                                MusicRowAction(title: "Save as Playlist", systemImage: "square.and.arrow.down") {
                                    Task { await FolderActions.saveAsPlaylist(folder, model) }
                                },
                            ])
                        },
                        sortMenu: { EmptyView() }   // folders keep their disk order
                    )

                    if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(24)
                    } else if subfolders.isEmpty && songs.isEmpty {
                        ContentUnavailableView("Empty folder", systemImage: "folder")
                            .frame(maxWidth: .infinity).padding(24)
                    } else {
                        contents
                    }
                }
                .padding(.bottom, 16)
            }
            .keyboardRowNavigation(
                highlighted: $kbIndex, count: visibleSongs.count, proxy: proxy,
                idForIndex: { visibleSongs[$0].id },
                onActivate: { index in
                    model.music.play(visibleSongs, startAt: index, source: folderSource)
                },
                onAltActivate: { model.music.playNext([visibleSongs[$0]]) }
            )
            .revealNowPlaying(proxy: proxy, ids: visibleSongs.map(\.id), currentID: model.music.nowPlaying?.id)
        }
        .navigationBarBackButtonHidden(true)
        .task(id: folder.id) {
            directory = await model.musicLibrary.directory(id: folder.id)
            loaded = true
        }
    }

    @ViewBuilder
    private var contents: some View {
        if !visibleSubfolders.isEmpty {
            if layout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(visibleSubfolders) { sub in
                        FolderGridCell(folder: sub)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(visibleSubfolders) { sub in
                        MusicFolderListRow(folder: sub)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
        }

        if !visibleSongs.isEmpty {
            LazyVStack(spacing: 2) {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                    MusicTrackRow(
                        song: song,
                        isCurrent: model.music.nowPlaying?.id == song.id
                    ) {
                        model.music.play(visibleSongs, startAt: index, source: folderSource)
                    }
                    .id(song.id)
                }
            }
            .padding(.horizontal, 16).padding(.top, visibleSubfolders.isEmpty ? 8 : 16)
        }
    }
}
