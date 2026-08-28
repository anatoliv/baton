import BatonSubsonicKit
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

    /// Speaks text captured off the screen (Services entry, and later the hotkey). Retained for
    /// the app's lifetime because it owns the in-flight synthesis task for a reading.
    @State private var readAloud: ReadAloudCoordinator?

    /// Chat remote control (Telegram / Discord). Shares the MCP server's audio-focus
    /// registry and drives the same `BatonMCPToolCatalog`, so a chat message and an
    /// agent call take one code path. Dormant until configured in Settings → Remote.
    @State private var remote: RemoteControlService?
    /// Pulls shared settings in on its own. Before this the Mac only ever synced when
    /// someone pressed a button in Settings, so the phone's searches, podcasts and EQ
    /// simply never arrived.
    @State private var syncScheduler: PreferenceSyncScheduler?

    /// Window id for the custom About panel (opened from the app menu).
    static let aboutWindowID = "baton-about"

    init() {
        // Start opt-in crash reporting if (and only if) the user turned it on
        // and a DSN is baked into this build. No-op otherwise. See CrashReporting.
        CrashReporting.startIfEnabled()
        // Before anything asks the cache to hold something. The default is 512KB in
        // memory — about four covers against a 2,600-album library.
        ArtworkCache.configureURLCache()
        LegacyKeyMigration.run()
        // Start Sparkle's background update scheduler at launch — not lazily from the
        // Settings UI — so a user who just plays music still receives automatic checks.
        // Gated on a genuinely-live channel so a placeholder-key dev build stays dormant.
        //
        // Never under XCTest. The unit tests are app-hosted, so this `init` runs inside the
        // test host — which meant every `scripts/test.sh` run started a live updater pointed
        // at the public appcast, on the same machine that publishes to it. A test host that
        // can download and install a release is a test host that can end its own process
        // mid-run, and `BatonEnvironment` already exists to keep tests off exactly this kind
        // of real-world side effect (system Now Playing, real defaults, the network).
        if UpdateChannel.isConfiguredFromBundle, !BatonEnvironment.current.isTesting {
            MainActor.assumeIsolated { _ = SparkleUpdater.shared }
        }
    }

    /// Acts on a `baton://` link. Deliberately small, and deliberately reusing what is
    /// already wired: `pendingSourceNavigation` is how the full-screen player's "Playing
    /// from" link already navigates, and `music.music.play` is the same call every row in
    /// the app makes.
    @MainActor
    private func handle(_ link: BatonDeepLink) async {
        switch link {
        case .presentPlayer:
            commandRouter.showNowPlayingToken += 1
        case let .playSong(id):
            if let song = try? await NavidromeConfig.makeClient().getSong(id: id) {
                music.music.play([song], source: .init(label: song.title, kind: .song, id: id))
            }
        case let .playAlbum(id):
            let songs = await music.musicLibrary.albumSongs(id: id)
            if !songs.isEmpty {
                music.music.play(songs, source: .init(label: "Album", kind: .album, id: id))
            }
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
                    // Expose the composition root to Shortcuts/Siri, same shape as the
                    // phone's AppServicesHolder.
                    MacIntentServices.model = music
                    BatonMCPSpeakTools.sweepStaleTempFiles() // clear orphaned speech clips
                    // Read aloud (specs/read-aloud.md). The Services provider is the
                    // zero-permission acquisition path — the system hands over another app's
                    // selection, so this works on first launch with nothing granted and no
                    // hotkey bound. Registering it is free; nothing runs until someone
                    // chooses Speak with Baton.
                    if readAloud == nil {
                        let coordinator = ReadAloudCoordinator(music: music)
                        ScreenTextReader.shared.onCapture = { [coordinator] capture in
                            coordinator.read(capture)
                        }
                        NSApp.servicesProvider = ScreenTextReader.shared
                        // The hotkey routes through the same capture path as the Services
                        // entry, so both get identical source classification and cleaning.
                        // `apply()` is a no-op while the key is unbound, which is the default.
                        ReadAloudHotKey.shared.onSelection = { text in
                            ScreenTextReader.shared.capture(text, from: NSWorkspace.shared.frontmostApplication)
                        }
                        ReadAloudHotKey.shared.apply()
                        readAloud = coordinator
                    }
                    if syncScheduler == nil {
                        let scheduler = PreferenceSyncScheduler(model: music)
                        scheduler.start()
                        syncScheduler = scheduler
                    }
                    if mcp == nil {
                        let s = BatonMCPServer(music: music); s.start(); mcp = s
                        // Start the fast-path listener sharing the server's focus registry.
                        let sock = BatonControlSocket(focus: s.focus, music: music); sock.start()
                        controlSocket = sock
                        // Chat bridges, sharing the server's focus registry. `apply()`
                        // is a no-op unless the user has configured a platform.
                        let chat = RemoteControlService(player: music.music, tools: MCPToolSurface(music: music, focus: s.focus), focus: s.focus)
                        chat.apply()
                        remote = chat
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
                                music.music.persistNow() // save queue + playhead on quit
                                chat.stopAll(); sock.stop(); s.stop()
                            }
                        }
                    }
                }
                // `baton://` — the front door the Mac never had. Every path behind these
                // links already existed (the router navigates, the engine plays); only the
                // scheme and this handler were missing, so a link that worked on the phone
                // silently did nothing on the desktop. Same `BatonDeepLink` vocabulary as
                // the phone, in Shared/, so the two cannot mean different things by it.
                .onOpenURL { url in
                    guard let link = BatonDeepLink(url: url) else { return }
                    Task { await handle(link) }
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
            PlaybackMenuCommands(model: music, router: commandRouter)
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
                .environment(remote)
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

        // The music friend, in its own window rather than a Settings pane — a conversation is
        // something you keep open beside the library, not something you configure. The Mac
        // has been running this agent for the chat bridges all along; this is the first way
        // to talk to it without opening Telegram.
        Window("Music Friend", id: MacMusicFriendView.windowID) {
            MacMusicFriendView()
                .environment(remote)
                .tint(.batonOrange)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 620)

        // Spoken-summary history — a two-pane window: the history list on the left, the same player
        // card as the floating speaking HUD on the right, so a replay plays inline here.
        Window("Spoken Summaries", id: SpeechHistoryView.windowID) {
            SpeechHistoryView()
                .environment(music)
                .tint(.batonOrange)
        }
        .windowResizability(.contentMinSize)
        // First-run size only; thereafter `SummariesWindowAccessor` restores the saved frame
        // (size + position) via AppKit autosave, so the window reopens where you left it.
        .defaultSize(width: 720, height: 560)

        // Always-available menu-bar controller — current track + compact transport,
        // reachable even when every window is closed. Binds to live player state.
        MenuBarExtra {
            BatonMenuBarContent(model: music, router: commandRouter)
        } label: {
            BatonMenuBarLabel(model: music)
        }
    }
}
