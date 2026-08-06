import SwiftUI

/// Tabs: Now Playing and Liked. Playback goes through the shared engine; the watch
/// audio session is activated asynchronously before play — watchOS then routes to
/// Bluetooth headphones (it refuses long-form audio to the built-in speaker).
struct WatchRootView: View {
    let model: WatchModel

    var body: some View {
        TabView {
            WatchNowPlayingView(model: model)
            NavigationStack { WatchLikedView(model: model) }
            NavigationStack { WatchDownloadsView(model: model) }
        }
        .tabViewStyle(.verticalPage)
    }
}

struct WatchNowPlayingView: View {
    let model: WatchModel

    var body: some View {
        VStack(spacing: 10) {
            if let song = model.music.nowPlaying {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(song.artist ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 18) {
                    Button { model.music.previous() } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button {
                        model.music.isPlaying ? model.music.pause() : model.music.resume()
                    } label: {
                        Image(systemName: model.music.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                    }
                    Button { model.music.next() } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Pick something from Liked")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

struct WatchLikedView: View {
    let model: WatchModel

    var body: some View {
        List {
            let songs = model.musicLibrary.starred.songs
            ForEach(songs) { song in
                Button {
                    model.play(songs, from: songs.firstIndex(of: song) ?? 0, label: "Liked")
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(song.title).lineLimit(1)
                            Text(song.artist ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if MusicDownloadStore.shared.isDownloaded(song.id) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        } else if MusicDownloadStore.shared.inFlight.contains(song.id) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .swipeActions {
                    if !MusicDownloadStore.shared.isDownloaded(song.id) {
                        Button("Download") {
                            Task { _ = await MusicDownloadStore.shared.download(song) }
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle("Liked")
        .task { await model.musicLibrary.loadStarred() }
        .overlay {
            if model.musicLibrary.starred.songs.isEmpty {
                Text("No liked songs yet").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

}
