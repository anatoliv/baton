import SwiftUI

/// Always-available status-bar controller for Baton. Lives in the menu bar so the
/// transport — and, when every window is closed, the app-level actions (Settings,
/// Updates, About, Quit) — stay reachable. Binds to live `@Observable` player state
/// (`model.music`), so the title + play/pause glyph track the transport without refresh.
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

/// Pure text helpers for the status-menu now-playing header. NSMenu ignores SwiftUI layout on
/// menu items (`.lineLimit` / `.frame` / `.truncationMode` do nothing), so a long title would
/// stretch the *whole* menu to full-screen width — the strings have to be clipped here instead.
enum BatonMenuBarText {
    static let titleMax = 44
    static let artistMax = 32

    /// Middle-truncate to `max` grapheme clusters with an ellipsis, keeping the start **and** end
    /// (descriptive mix titles read better than a tail cut). Trims surrounding whitespace.
    static func clip(_ s: String, max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        let keep = max - 1 // room for the ellipsis
        let head = (keep + 1) / 2
        let tail = keep - head
        return "\(t.prefix(head))…\(t.suffix(tail))"
    }

    static func title(_ s: String) -> String { clip(s, max: titleMax) }

    /// The artist line to show, or nil when it's empty or a placeholder ("Unknown" from imports)
    /// — so the header doesn't carry a meaningless "Unknown" line.
    static func artist(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.caseInsensitiveCompare("Unknown") != .orderedSame else { return nil }
        return clip(t, max: artistMax)
    }
}

struct BatonMenuBarContent: View {
    let model: MusicModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var player: StreamingPlaybackController { model.music }

    var body: some View {
        // Now-playing header — clipped so a long title can't balloon the menu width.
        if let song = player.nowPlaying {
            Text(BatonMenuBarText.title(song.title))
            if let artist = BatonMenuBarText.artist(song.artist) {
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
        Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }

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

        // App-level actions — reachable here even with every window closed.
        Button("Settings…") {
            openWindow(id: BatonSettingsView.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Check for Updates…") {
            SparkleUpdater.shared.checkForUpdates()
        }
        .disabled(!UpdateChannel.isConfiguredFromBundle)
        Button("About Baton") {
            openWindow(id: BatonApp.aboutWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit Baton") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
