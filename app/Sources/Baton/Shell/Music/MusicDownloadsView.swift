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
                        row(item)
                        Divider()
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
    }

    private func row(_ item: MusicDownloadStore.DownloadItem) -> some View {
        let isCurrent = model.music.nowPlaying?.id == item.id
        return HStack(spacing: 10) {
            Button(action: { play(item) }) {
                Image(systemName: isCurrent && model.music.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
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

            Button(action: { pendingDelete = item }) {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete download")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play(item) }
        .contextMenu {
            Button("Play") { play(item) }
            Button("Delete Download", role: .destructive) { pendingDelete = item }
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
        model.music.play([item.song], source: .init(label: "Downloads", kind: .liked, id: nil))
    }

    private func delete(_ item: MusicDownloadStore.DownloadItem) {
        if model.music.nowPlaying?.id == item.id { model.music.pause() }
        store.remove(id: item.id)
        pendingDelete = nil
        revision += 1
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
            coverURL: item.song.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 300) },
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
