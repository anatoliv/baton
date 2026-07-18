import SwiftUI

/// Always-available status-bar controller for Baton. Lives in the menu bar so the
/// transport is reachable even when every window is closed. Binds to live
/// `@Observable` player state (`model.music`), so the title + play/pause glyph
/// track the current transport without manual refresh.
///
/// The scene itself (`MenuBarExtra`) is declared in `BatonApp`; this file is the
/// content view + the label shown in the status bar.
struct BatonMenuBarLabel: View {
    let model: MusicModel

    private var player: StreamingPlaybackController { model.music }

    var body: some View {
        // A baton/waveform glyph — a compact, monochrome template image so macOS
        // tints it for light/dark menu bars automatically.
        Image(systemName: player.isPlaying ? "music.note" : "music.note.list")
            .accessibilityLabel("Baton")
    }
}

struct BatonMenuBarContent: View {
    let model: MusicModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var player: StreamingPlaybackController { model.music }

    var body: some View {
        // Now-playing header.
        if let song = player.nowPlaying {
            Text(song.title)
            if let artist = song.artist, !artist.isEmpty {
                Text(artist)
            }
            Divider()
        } else {
            Text("Nothing Playing")
            Divider()
        }

        // Compact transport.
        Button(player.isPlaying ? "Pause" : "Play") {
            player.isPlaying ? player.pause() : player.resume()
        }
        .disabled(player.nowPlaying == nil)

        Button("Next") { player.next() }
            .disabled(player.queue.isEmpty)
        Button("Previous") { player.previous() }
            .disabled(player.queue.isEmpty)

        Divider()

        Button("Open Baton") {
            openWindow(id: MusicWindowView.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Mini Player") {
            openWindow(id: MiniPlayerWindowView.windowID)
            dismissWindow(id: MusicWindowView.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit Baton") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
