import SwiftUI

/// The **Downloads** tab: everything downloaded for offline listening. Shares the browse
/// header (title · count · filter, then sort + grid/list) with the other screens, plus the
/// **Offline mode** toggle, a hero mini-transport, and **multi-select batch actions**
/// (play / shuffle / queue / save / add-to-playlist / delete). The dense table rows mirror
/// the Artists table: a select checkbox, a cover thumbnail that doubles as Play, title/artist,
/// hover actions, and right-aligned Size / Time columns.
struct MusicDownloadsView: View {
    @Environment(MusicModel.self) private var model
    @AppStorage("baton.music.offlineMode") private var offlineMode = false

    /// Refresh trigger: bumped after a delete so the derived list re-reads the store.
    @State private var revision = 0
    @State private var pendingDelete: MusicDownloadStore.DownloadItem?
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
    @State private var sel = MusicMultiSelect()
    @State private var showBatchDeleteConfirm = false
    @AppStorage("tonebox.music.downloadLayout") private var layout: MusicBrowseLayout = .list
    @AppStorage("tonebox.music.downloadSort") private var sortField: DownloadSort = .name
    @AppStorage("tonebox.music.downloadSortAscending") private var sortAscending = true

    /// Sort fields for the Downloads screen (mirrors the other browse screens).
    enum DownloadSort: String, CaseIterable, Identifiable, MusicSortField {
        case name, artist, size
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: "Name"
            case .artist: "Artist"
            case .size: "Size"
            }
        }
    }

    private var store: MusicDownloadStore { .shared }

    /// Re-read on every `revision` change (deletes) and whenever the store's set changes.
    private var items: [MusicDownloadStore.DownloadItem] {
        _ = revision
        _ = store.downloadedIDs
        return store.downloadedItems()
    }

    /// Items after the header's filter + sort controls are applied.
    private var filteredItems: [MusicDownloadStore.DownloadItem] {
        var list = items
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query) || ($0.artist?.lowercased().contains(query) ?? false)
            }
        }
        switch sortField {
        case .name:
            list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            list.sort { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .size:
            list.sort { $0.byteSize < $1.byteSize }
        }
        if !sortAscending { list.reverse() }
        return list
    }

    private var orderedIDs: [String] { filteredItems.map(\.id) }
    private var selectedItems: [MusicDownloadStore.DownloadItem] { filteredItems.filter { sel.contains($0.id) } }

    private var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: store.totalBytes(), countStyle: .file)
    }

    /// Where the "play all downloads" transport queues from.
    private var downloadsSource: StreamingPlaybackController.QueueSource {
        .init(label: "Downloads", kind: .liked, id: nil)
    }

    var body: some View {
        Group {
            if items.isEmpty, store.inFlight.isEmpty, store.failedIDs.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    MusicBrowseHeader(
                        title: "Downloads",
                        count: filteredItems.count,
                        filter: $filterText,
                        filterPrompt: "Filter downloads",
                        filterFocused: $filterFocused,
                        filterHistoryKey: "downloads",
                        layout: $layout,
                        accessory: {
                            Text(totalSizeText).font(.caption).foregroundStyle(.secondary)
                        },
                        leading: {
                            if sel.isEmpty {
                                MusicMiniTransport(
                                    onPlayWhenIdle: { model.music.play(filteredItems.map(\.song), source: downloadsSource) },
                                    pageSource: downloadsSource
                                )
                                Toggle(isOn: $offlineMode) { Text("Offline mode") }
                                    .toggleStyle(.switch).controlSize(.small)
                                    .help("Prefer downloaded files over streaming from the server.")
                                if !filteredItems.isEmpty {
                                    Button { sel.selectAll(orderedIDs) } label: {
                                        Label("Select", systemImage: "checklist").font(.caption).labelStyle(.titleAndIcon)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .keyboardShortcut(filterFocused ? nil : KeyboardShortcut("a", modifiers: .command))
                                    .help("Select all downloads (⌘A)")
                                }
                            } else {
                                selectionBar
                            }
                        },
                        sortMenu: { MusicSortControls(ascending: $sortAscending, selection: $sortField) }
                    )
                    downloadActivityBanner
                    content
                }
            }
        }
        .onChange(of: orderedIDs) { sel.reconcile(orderedIDs) }
        .confirmationDialog(
            "Delete download?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete “\(item.title)”", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removes the downloaded file from disk. You can download it again later.")
        }
        .confirmationDialog(
            "Delete \(selectedItems.count) download\(selectedItems.count == 1 ? "" : "s")?",
            isPresented: $showBatchDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete \(selectedItems.count) Download\(selectedItems.count == 1 ? "" : "s")", role: .destructive) { batchDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the selected files from disk. You can download them again later.")
        }
    }

    // MARK: - Download activity

    /// Live progress for in-flight downloads + a Retry for failures, shown above the list.
    @ViewBuilder private var downloadActivityBanner: some View {
        if !store.inFlight.isEmpty || !store.failedIDs.isEmpty {
            HStack(spacing: 12) {
                if !store.inFlight.isEmpty {
                    ProgressView(value: aggregateDownloadProgress).frame(width: 130)
                    Text("Downloading \(store.inFlight.count) track\(store.inFlight.count == 1 ? "" : "s")…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !store.failedIDs.isEmpty {
                    Label("\(store.failedIDs.count) failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                    Button("Retry") { Task { await store.retryFailed() } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
        }
    }

    /// Mean completion fraction across in-flight downloads (0…1) for the aggregate bar.
    private var aggregateDownloadProgress: Double {
        let ids = store.inFlight
        guard !ids.isEmpty else { return 0 }
        return ids.reduce(0.0) { $0 + (store.downloadProgress[$1] ?? 0) } / Double(ids.count)
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        MusicSelectionBar(
            count: sel.selectedCount(in: orderedIDs),
            allSelected: sel.allSelected(orderedIDs),
            selectAllShortcut: !filterFocused,
            onToggleSelectAll: { sel.toggleSelectAll(orderedIDs) },
            onClear: { sel.clear() }
        ) {
            MusicBatchButton(system: "play.fill", help: "Play selected") {
                let songs = selectedItems.map(\.song)
                MusicBatchActions.play(model, shuffle: false, label: "Downloads", kind: .liked) { songs }
            }
            MusicBatchButton(system: "shuffle", help: "Shuffle selected") {
                let songs = selectedItems.map(\.song)
                MusicBatchActions.play(model, shuffle: true, label: "Downloads", kind: .liked) { songs }
            }
            MusicBatchButton(system: "text.append", help: "Add to queue") {
                let songs = selectedItems.map(\.song)
                MusicBatchActions.queue(model) { songs }
            }
            MusicBatchButton(system: "square.and.arrow.down", help: "Save as playlist") {
                let songs = selectedItems.map(\.song)
                MusicBatchActions.save(model, name: "Downloads") { songs }
            }
            MusicBatchAddToPlaylistMenu(gather: { selectedItems.map(\.song) })
            MusicBatchButton(system: "trash", help: "Delete selected downloads", tint: .red) {
                showBatchDeleteConfirm = true
            }
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if layout == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 16) {
                    ForEach(filteredItems) { item in
                        DownloadCard(
                            item: item,
                            isSelected: sel.contains(item.id),
                            onToggleSelect: { sel.clicked(item.id, ordered: orderedIDs) },
                            onPlay: { play(item) },
                            onDelete: { pendingDelete = item }
                        )
                    }
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 0) {
                DownloadColumns.header
                    .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredItems) { item in
                            DownloadRow(
                                item: item,
                                isSelected: sel.contains(item.id),
                                onToggleSelect: { sel.clicked(item.id, ordered: orderedIDs) },
                                onPlay: { play(item) },
                                onDelete: { pendingDelete = item }
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

    // MARK: - Empty state

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No downloads yet").font(.title3.bold())
            Text("Download tracks from an album or playlist to play them offline.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Actions

    private func play(_ item: MusicDownloadStore.DownloadItem) {
        if model.music.nowPlaying?.id == item.id {
            model.music.isPlaying ? model.music.pause() : model.music.resume()
            return
        }
        // Play the whole (filtered/sorted) list starting at this track, so playback continues
        // through the rest — the same behavior as albums/playlists/mixes.
        let songs = filteredItems.map(\.song)
        let index = filteredItems.firstIndex(where: { $0.id == item.id }) ?? 0
        model.music.play(songs, startAt: index, source: downloadsSource)
    }

    private func delete(_ item: MusicDownloadStore.DownloadItem) {
        if model.music.nowPlaying?.id == item.id { model.music.pause() }
        store.remove(id: item.id)
        pendingDelete = nil
        revision += 1
    }

    private func batchDelete() {
        for item in selectedItems {
            if model.music.nowPlaying?.id == item.id { model.music.pause() }
            store.remove(id: item.id)
        }
        model.music.postToast("Deleted \(selectedItems.count) download\(selectedItems.count == 1 ? "" : "s")", symbol: "trash")
        sel.clear()
        revision += 1
    }
}

/// Shared column geometry for the Downloads table so the header and rows line up.
enum DownloadColumns {
    static let thumb: CGFloat = 44
    static let size: CGFloat = 84
    static let time: CGFloat = 60

    static var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 18, height: 1)     // selection checkbox slot
                Color.clear.frame(width: thumb, height: 1)  // thumbnail slot
                Text("Track")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: size, alignment: .trailing)
            Text("Time").frame(width: time, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
    }
}

// MARK: - Table row

/// A dense download table row (Artists style): select checkbox + cover thumbnail (doubles as
/// Play), title/artist, hover actions, then right-aligned Size / Time columns.
private struct DownloadRow: View {
    @Environment(MusicModel.self) private var model
    let item: MusicDownloadStore.DownloadItem
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    let onPlay: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    private var isCurrent: Bool { model.music.nowPlaying?.id == item.id }
    private var isPlaying: Bool { isCurrent && model.music.isPlaying }
    private var isLiked: Bool { model.musicLibrary.isLiked(item.song) }
    private var sizeText: String { ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file) }
    private var durationText: String { item.duration.map { MusicTrackRow.formatDuration($0) } ?? "—" }

    private func startRadio() {
        Task {
            let radio = await model.musicLibrary.similarSongs(seedID: item.id)
            guard !radio.isEmpty else { return }
            model.music.play(radio, source: .init(label: "\(item.title) Radio", kind: .radio, id: nil))
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            MusicSelectCheckbox(isSelected: isSelected, visible: hover, onToggle: onToggleSelect)

            Button(action: onPlay) {
                artwork
                    .frame(width: DownloadColumns.thumb, height: DownloadColumns.thumb)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        if hover || isCurrent {
                            ZStack {
                                Color.black.opacity(0.34)
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.caption).foregroundStyle(.white)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Play")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                if let artist = item.artist, !artist.isEmpty {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)

            if hover {
                MusicRowActions(actions: [
                    MusicRowAction(
                        title: isLiked ? "Unlike" : "Like",
                        systemImage: isLiked ? "heart.fill" : "heart",
                        tint: isLiked ? .pink : .secondary
                    ) {
                        Task { await model.musicLibrary.toggleLike(item.song) }
                    },
                    MusicRowAction(title: "Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        model.music.playNext([item.song])
                    },
                    MusicRowAction(title: "Add to Queue", systemImage: "text.append") {
                        model.music.enqueue([item.song])
                    },
                    MusicRowAction(title: "Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                        startRadio()
                    },
                    MusicRowAction(title: "Delete Download", systemImage: "trash", tint: .red) {
                        onDelete()
                    },
                ])
            }

            Group {
                Text(sizeText).frame(width: DownloadColumns.size, alignment: .trailing)
                Text(durationText).frame(width: DownloadColumns.time, alignment: .trailing)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            isSelected ? Color.selectionTint() : (hover ? Color.hoverTint : .clear)
        ))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: onPlay)
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.music.playNext([item.song]) }
            Button("Add to Queue", systemImage: "text.append") { model.music.enqueue([item.song]) }
            Button(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.fill" : "heart") {
                Task { await model.musicLibrary.toggleLike(item.song) }
            }
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { startRadio() }
            Divider()
            Button("Delete Download", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var artwork: some View {
        // A podcast download carries a direct artwork URL (no Subsonic cover id); otherwise
        // prefer the stored cover-art id, falling back to the song id (Navidrome's getCoverArt
        // accepts it) so downloads saved before the id was persisted still show art.
        if let url = item.artworkURL ?? model.musicLibrary.coverArtURL(id: item.coverArtID ?? item.id, size: 88) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "music.note").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Grid card

/// A download shown as a card in the grid layout — cover art, title, artist, hover play, and
/// a selection checkbox overlay.
private struct DownloadCard: View {
    @Environment(MusicModel.self) private var model
    let item: MusicDownloadStore.DownloadItem
    var isSelected = false
    var onToggleSelect: () -> Void = {}
    let onPlay: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    private var isCurrent: Bool { model.music.nowPlaying?.id == item.id }

    var body: some View {
        MusicMediaCard(
            coverURL: item.artworkURL ?? model.musicLibrary.coverArtURL(id: item.coverArtID ?? item.id, size: 300),
            aspect: 1,
            placeholder: "arrow.down.circle",
            title: item.title,
            subtitle: item.artist ?? "",
            isHovering: hover,
            isPlayingSource: isCurrent,
            onPlay: onPlay
        )
        .overlay(alignment: .topLeading) {
            if hover || isSelected {
                MusicSelectCheckbox(isSelected: isSelected, onToggle: onToggleSelect)
                    .padding(6)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
        }
        .onHover { hover = $0 }
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button("Play", action: onPlay)
            Button("Add to Queue", systemImage: "text.append") { model.music.enqueue([item.song]) }
            Divider()
            Button("Delete Download", role: .destructive, action: onDelete)
        }
    }
}
