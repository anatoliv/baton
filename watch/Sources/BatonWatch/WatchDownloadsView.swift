import SwiftUI

/// Music that lives on the watch. The point of a watch player is the run you
/// leave the phone at home for, so downloads are the feature — the same
/// download store, background session and integrity checks the phone uses,
/// just with a wrist-sized list on top.
struct WatchDownloadsView: View {
    let model: WatchModel
    @State private var items: [MusicDownloadStore.DownloadItem] = []

    var body: some View {
        List {
            if items.isEmpty {
                Text("Download from Liked to listen without your phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(items, id: \.id) { item in
                Button {
                    play(from: item)
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        Text(item.artist ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        MusicDownloadStore.shared.delete(item.id)
                        refresh()
                    }
                }
            }
        }
        .navigationTitle("On Watch")
        .task { refresh() }
        // The store publishes as tracks land, so the list fills in while the
        // user watches rather than needing a pull.
        .onChange(of: MusicDownloadStore.shared.downloadedIDs) { _, _ in refresh() }
    }

    private func refresh() {
        items = MusicDownloadStore.shared.downloadedItems()
    }

    private func play(from item: MusicDownloadStore.DownloadItem) {
        let songs = items.map(\.song)
        let index = items.firstIndex { $0.id == item.id } ?? 0
        model.play(songs, from: index, label: "On Watch")
    }
}
