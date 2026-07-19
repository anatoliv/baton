import SwiftUI

/// The **Downloads** tab: everything that's been downloaded for offline listening. Uses the
/// shared browse header (title · count · filter, then sort + grid/list) like the other browse
/// screens, plus the **Offline mode** toggle. Each item shows title / artist / size with a
/// play affordance and a delete-with-confirm.
///
/// The list comes straight from `MusicDownloadStore`; playing a row hands the player a
/// `NavidromeSong` reconstructed from the download's cached metadata, and the controller
/// resolves the local file (so playback never touches the server).
struct MusicDownloadsView: View {
    @Environment(MusicModel.self) private var model
    @AppStorage("baton.music.offlineMode") private var offlineMode = false

    /// Refresh trigger: bumped after a delete so the derived list re-reads the store.
    @State private var revision = 0
    @State private var pendingDelete: MusicDownloadStore.DownloadItem?
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
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

    private var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: store.totalBytes(), countStyle: .file)
    }

    /// Where the "play all downloads" transport queues from.
    private var downloadsSource: StreamingPlaybackController.QueueSource {
        .init(label: "Downloads", kind: .liked, id: nil)
    }

    var body: some View {
        Group {
            if items.isEmpty {
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
                            // Hero mini-player: play-all / shuffle / prev / next / repeat, like the
                            // other browse screens. Plays the currently-shown (filtered/sorted) list.
                            MusicMiniTransport(
                                onPlayWhenIdle: { model.music.play(filteredItems.map(\.song), source: downloadsSource) },
                                pageSource: downloadsSource
                            )
                            Toggle(isOn: $offlineMode) { Text("Offline mode") }
                                .toggleStyle(.switch).controlSize(.small)
                                .help("Prefer downloaded files over streaming from the server.")
                        },
                        sortMenu: { MusicSortControls(ascending: $sortAscending, selection: $sortField) }
                    )
                    content
                }
            }
        }
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
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        ScrollView {
            if layout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 16) {
                    ForEach(filteredItems) { item in
                        DownloadCard(
                            item: item,
                            onPlay: { play(item) },
                            onDelete: { pendingDelete = item }
                        )
                    }
                }
                .padding(16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredItems) { item in
                        DownloadRow(
                            item: item,
                            onPlay: { play(item) },
                            onDelete: { pendingDelete = item }
                        )
                        Divider()
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
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
        model.music.play([item.song], source: downloadsSource)
    }

    private func delete(_ item: MusicDownloadStore.DownloadItem) {
        if model.music.nowPlaying?.id == item.id { model.music.pause() }
        store.remove(id: item.id)
        pendingDelete = nil
        revision += 1
    }
}

// MARK: - List row

/// A download shown as a list row — cover-art thumbnail (with a play/pause overlay on hover
/// or while current), title/artist, on-disk size + duration, and a delete button.
private struct DownloadRow: View {
    @Environment(MusicModel.self) private var model
    let item: MusicDownloadStore.DownloadItem
    let onPlay: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    private var isCurrent: Bool { model.music.nowPlaying?.id == item.id }
    private var isPlaying: Bool { isCurrent && model.music.isPlaying }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                artwork
                    .frame(width: 44, height: 44)
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
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                if let artist = item.artist, !artist.isEmpty {
                    Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
            if let duration = item.duration {
                Text(MusicTrackRow.formatDuration(duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Button(action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete download")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .contextMenu {
            Button("Play", action: onPlay)
            Button("Delete Download", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var artwork: some View {
        // Prefer the stored cover-art id; fall back to the song id (Navidrome's getCoverArt
        // accepts it) so downloads saved before the id was persisted still show art.
        if let url = model.musicLibrary.coverArtURL(id: item.coverArtID ?? item.id, size: 88) {
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

/// A download shown as a card in the grid layout — cover art, title, artist, hover play.
private struct DownloadCard: View {
    @Environment(MusicModel.self) private var model
    let item: MusicDownloadStore.DownloadItem
    let onPlay: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    private var isCurrent: Bool { model.music.nowPlaying?.id == item.id }

    var body: some View {
        MusicMediaCard(
            coverURL: model.musicLibrary.coverArtURL(id: item.coverArtID ?? item.id, size: 300),
            aspect: 1,
            placeholder: "arrow.down.circle",
            title: item.title,
            subtitle: item.artist ?? "",
            isHovering: hover,
            isPlayingSource: isCurrent,
            onPlay: onPlay
        )
        .onHover { hover = $0 }
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button("Play", action: onPlay)
            Button("Delete Download", role: .destructive, action: onDelete)
        }
    }
}
