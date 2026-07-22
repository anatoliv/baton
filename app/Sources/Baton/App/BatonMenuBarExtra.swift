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

    /// Opt-in: also show the current track/station title beside the glyph. Off by default.
    @AppStorage(BatonMenuBarText.showTitleKey) private var showTitle = false

    private var player: StreamingPlaybackController { model.music }
    /// True while the library player OR an on-air radio station is actively playing.
    private var isPlaying: Bool {
        model.internetRadio.onAirStation != nil ? model.internetRadio.engine.isPlaying : player.isPlaying
    }

    /// What to show as the optional title — the on-air station, else the current track.
    private var title: String? {
        model.internetRadio.onAirStation?.name ?? player.nowPlaying?.title
    }

    var body: some View {
        // A baton/waveform glyph — a compact, monochrome template image so macOS
        // tints it for light/dark menu bars automatically — plus an optional clipped title.
        HStack(spacing: 4) {
            Image(systemName: isPlaying ? "music.note" : "music.note.list")
            if showTitle, let title {
                Text(BatonMenuBarText.clip(title, max: BatonMenuBarText.labelMax))
            }
        }
        .accessibilityLabel("Baton")
    }
}

/// Pure text helpers for the status-menu now-playing header. NSMenu ignores SwiftUI layout on
/// menu items (`.lineLimit` / `.frame` / `.truncationMode` do nothing), so a long title would
/// stretch the *whole* menu to full-screen width — the strings have to be clipped here instead.
enum BatonMenuBarText {
    static let titleMax = 44
    static let artistMax = 32
    /// UserDefaults key for the optional "show the track title in the menu bar" preference.
    static let showTitleKey = "baton.menubar.showTitle"
    /// Max length of the menu-bar label title so it never sprawls across the status bar.
    static let labelMax = 30

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
    /// Lets the now-playing header open the full-screen player (raises the intent `MusicView` consumes).
    let router: BatonCommandRouter

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var player: StreamingPlaybackController { model.music }
    private var radio: InternetRadioStore { model.internetRadio }
    /// While a station is on air it ducks the library player, so the menu bar reflects the radio
    /// transport instead — matching the now-playing bar's takeover (see `NowPlayingBar`).
    private var radioStation: NavidromeRadioStation? { radio.onAirStation }
    private var isRadio: Bool { radioStation != nil }
    private var isPlaying: Bool { isRadio ? radio.engine.isPlaying : player.isPlaying }

    var body: some View {
        // Now-playing header — clipped so a long title can't balloon the menu width. Radio takes
        // over the header (station + live track) exactly as the now-playing bar does.
        if let station = radioStation {
            Text(BatonMenuBarText.title(station.name))
            if let track = BatonMenuBarText.artist(radio.engine.nowPlayingTitle) {
                Text(track)
            }
            Divider()
        } else if let song = player.nowPlaying {
            // The title is actionable — open the full-screen player (was inert text).
            Button(BatonMenuBarText.title(song.title)) {
                openWindow(id: MusicWindowView.windowID)
                router.showNowPlayingToken += 1
                NSApp.activate(ignoringOtherApps: true)
            }
            if let artist = BatonMenuBarText.artist(song.artist) {
                Text(artist)
            }
            Divider()
        } else {
            Text("Nothing Playing")
            Divider()
        }

        // Compact transport — drives the radio engine while on air, else the library player.
        Button(isPlaying ? "Pause" : "Play") {
            if isRadio {
                radio.engine.isPlaying ? radio.engine.pause() : radio.engine.resume()
            } else {
                player.isPlaying ? player.pause() : player.resume()
            }
        }
        .disabled(!isRadio && player.nowPlaying == nil)

        Button(isRadio ? "Next Station" : "Next") { isRadio ? radio.playAdjacent(1) : player.next() }
            .disabled(!isRadio && player.queue.isEmpty)
        Button(isRadio ? "Previous Station" : "Previous") { isRadio ? radio.playAdjacent(-1) : player.previous() }
            .disabled(!isRadio && player.queue.isEmpty)
        Button(player.isMuted ? "Unmute" : "Mute") {
            player.toggleMute()
            if isRadio { radio.engine.setMuted(player.isMuted) }
        }
        // Like the current track (library only — a station can't be liked).
        if !isRadio, let song = player.nowPlaying {
            let liked = model.musicLibrary.isLiked(song)
            Button(liked ? "Unlike" : "Like") { Task { await model.musicLibrary.toggleLike(song) } }
        }

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
        // Spoken-summary history — reachable here even when Baton is closed and an
        // agent spoke a summary while you were working in another app.
        Button("Recent Summaries…") {
            openWindow(id: SpeechHistoryView.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        .disabled(model.speechHistory.entries.isEmpty)

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
