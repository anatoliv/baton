import SwiftUI

/// The **Downloads** tab: everything that's been downloaded for offline listening.
/// Lists each downloaded track (title / artist, on-disk size) with a play affordance and
/// a delete-with-confirm, shows the total size on disk, and hosts the **Offline mode**
/// toggle — when on, the player prefers local files over streaming.
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

    private var store: MusicDownloadStore { .shared }

    /// Re-read on every `revision` change (deletes) and whenever the store's set changes.
    private var items: [MusicDownloadStore.DownloadItem] {
        _ = revision
        _ = store.downloadedIDs
        return store.downloadedItems()
    }

    private var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: store.totalBytes(), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if items.isEmpty {
                empty
            } else {
                list
            }
        }
        .confirmationDialog(
            "Delete download?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete “\(item.title)”", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("Removes the downloaded file from disk. You can download it again later.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Downloads").font(.title2.bold())
                Text(items.isEmpty
                    ? "Nothing downloaded"
                    : "^[\(items.count) track](inflect: true) · \(totalSizeText)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(isOn: $offlineMode) { Text("Offline mode") }
                .toggleStyle(.switch)
                .help("Prefer downloaded files over streaming from the server.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                    Divider()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
