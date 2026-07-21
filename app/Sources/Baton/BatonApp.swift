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

    /// Owns the floating speaking-HUD panel (Pause/Resume/Stop over any Space while a summary
    /// plays). Retained for the app's lifetime; observes `music.speech` to show/hide the panel.
    @State private var speakingHUD: SpeakingHUDPresenter?

    /// Bridges menu-bar commands (Go / Find / Now Playing) into the main window's state.
    @State private var commandRouter = BatonCommandRouter()

    /// Window id for the custom About panel (opened from the app menu).
    static let aboutWindowID = "baton-about"

    init() {
        // Start opt-in crash reporting if (and only if) the user turned it on
        // and a DSN is baked into this build. No-op otherwise. See CrashReporting.
        CrashReporting.startIfEnabled()
        // Start Sparkle's background update scheduler at launch — not lazily from the
        // Settings UI — so a user who just plays music still receives automatic checks.
        // Gated on a genuinely-live channel so a placeholder-key dev build stays dormant. (W-09)
        if UpdateChannel.isConfiguredFromBundle {
            MainActor.assumeIsolated { _ = SparkleUpdater.shared }
        }
    }

    var body: some Scene {
        // Main player window. Reuses the chromeless pop-out view Tonebox ships, so the
        // mini player's "expand" deep-link (`openWindow(id: MusicWindowView.windowID)`)
        // resolves to this window.
        Window("Baton", id: MusicWindowView.windowID) {
            MusicWindowView()
                .environment(music)
                .environment(commandRouter)
                // Anchor the whole app to Baton brand orange (also installed as the
                // `AccentColor` asset). Brand ⇄ Dynamic rule: chrome + actions are
                // brand; the player wires the dynamic artwork accent explicitly on top.
                .tint(.batonOrange)
                .task {
                    BatonMCPSpeakTools.sweepStaleTempFiles() // clear orphaned speech clips (W-19)
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
                        // Bring up the floating speaking HUD (independent, all-Spaces panel).
                        speakingHUD = SpeakingHUDPresenter(model: music)
                        // Tear both down on app quit so the accept threads stop and the
                        // control.sock file / advertised endpoints don't linger.
                        NotificationCenter.default.addObserver(
                            forName: NSApplication.willTerminateNotification,
                            object: nil, queue: .main
                        ) { _ in
                            MainActor.assumeIsolated {
                                music.music.persistNow() // save queue + playhead on quit (W-11)
                                sock.stop(); s.stop()
                            }
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
            BatonAppCommands(model: music)
            GoMenuCommands(router: commandRouter)
            PlaybackMenuCommands(model: music)
            // "Check for Updates…" under About (disabled until the appcast
            // channel is live). See SparkleUpdater / UpdateChannel.
            UpdatesMenuCommands()
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
