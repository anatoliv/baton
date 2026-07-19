import SwiftUI
import UserNotifications

/// Baton — a standalone, free macOS music player extracted from Tonebox.
///
/// The whole player is rooted on a single `MusicModel` (`@Observable`), the same
/// self-contained root Tonebox embeds. Baton owns it directly: no `AppModel`, no
/// recording/sync/AI surface — just playback, a full browser window, and a mini
/// player. (An MCP control server + menu-bar controller arrive in later waves.)
@main
struct BatonApp: App {
    @State private var music = MusicModel()

    /// The MCP control server (Streamable HTTP on loopback). Lets agents — and Tonebox —
    /// drive playback, read now-playing/queue, and duck audio via owner-token focus.
    /// Started once when the main window first appears.
    @State private var mcp: BatonMCPServer?

    /// The native fast-path listener (Unix socket) for latency-critical audio ducking.
    /// Shares the MCP server's audio-focus registry so socket + MCP focus interoperate (§7).
    @State private var controlSocket: BatonControlSocket?

    /// Notification-center delegate for the `speak_summary` tool's "Play" action. Retained
    /// for the app's lifetime so tapping a spoken-summary notification plays the audio.
    @State private var speechNotifier: SpeechNotificationDelegate?

    /// Window id for the custom About panel (opened from the app menu).
    static let aboutWindowID = "baton-about"

    var body: some Scene {
        // Main player window. Reuses the chromeless pop-out view Tonebox ships, so the
        // mini player's "expand" deep-link (`openWindow(id: MusicWindowView.windowID)`)
        // resolves to this window.
        Window("Baton", id: MusicWindowView.windowID) {
            MusicWindowView()
                .environment(music)
                // Anchor the whole app to Baton brand orange (also installed as the
                // `AccentColor` asset). Brand ⇄ Dynamic rule: chrome + actions are
                // brand; the player wires the dynamic artwork accent explicitly on top.
                .tint(.batonOrange)
                .task {
                    if mcp == nil {
                        let s = BatonMCPServer(music: music); s.start(); mcp = s
                        // Start the fast-path listener sharing the server's focus registry.
                        let sock = BatonControlSocket(focus: s.focus, music: music); sock.start()
                        controlSocket = sock
                        // Route spoken-summary notifications ("Play" action) to the engine.
                        let notifier = SpeechNotificationDelegate(speech: music.speech)
                        UNUserNotificationCenter.current().delegate = notifier
                        SpeechNotifier.registerCategory()
                        speechNotifier = notifier
                        // Tear both down on app quit so the accept threads stop and the
                        // control.sock file / advertised endpoints don't linger.
                        NotificationCenter.default.addObserver(
                            forName: NSApplication.willTerminateNotification,
                            object: nil, queue: .main
                        ) { _ in
                            MainActor.assumeIsolated { sock.stop(); s.stop() }
                        }
                    }
                }
        }
        // Match Tonebox's music window: SwiftUI-managed title-bar hiding, persistent
        // across window reconfiguration (unlike poking NSWindow, which SwiftUI keeps
        // re-drawing as a grey collar). The `MusicWindowConfigurator` inside
        // `MusicWindowView` only hides the traffic-light buttons on top of this.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 760)
        .commands {
            BatonAppCommands()
            PlaybackMenuCommands(model: music)
            // Help menu: "Baton Help" (⌘?) + "What's New", opening the
            // in-app two-pane Help window (BatonHelpView).
            HelpMenuCommands()
        }

        // Detached mini player (⌘⌥M elsewhere; opened via the transport's mini button).
        Window("Mini Player", id: MiniPlayerWindowView.windowID) {
            MiniPlayerWindowView()
                .environment(music)
                .tint(.batonOrange)
        }
        .defaultSize(width: 340, height: 132)
        .windowResizability(.contentSize)

        // Custom About panel — a small, non-resizable utility window opened from
        // the app menu's "About Baton" item (see `BatonAppCommands`).
        Window("About Baton", id: Self.aboutWindowID) {
            BatonAboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Unified Settings window (⌘,). Consolidates the former standalone
        // Servers and Equalizer windows into sidebar panes, alongside Playback
        // and About. ⌥⌘E deep-links to the Equalizer pane (see BatonAppCommands).
        Window("Settings", id: BatonSettingsView.windowID) {
            BatonSettingsView()
                .environment(music)
                .tint(.batonOrange)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 560)
        .defaultPosition(.center)

        // In-app Help window (⌘?). Two-pane help center that renders the
        // bundled HELP.md / FAQ.md guides, with search, callouts, working
        // cross-links, What's New, and guided tours. See BatonHelpView.
        Window("Baton Help", id: BatonHelpView.windowID) {
            BatonHelpView()
                .tint(.batonOrange)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 660)
        .defaultPosition(.center)

        // Always-available menu-bar controller — current track + compact transport,
        // reachable even when every window is closed. Binds to live player state.
        MenuBarExtra {
            BatonMenuBarContent(model: music)
        } label: {
            BatonMenuBarLabel(model: music)
        }
    }
}
