import BatonSubsonicKit
import SwiftUI
import UserNotifications

/// Composition root for the services that used to start inside the main "Baton" window's
/// `.task`: the MCP server, the fast-path control socket, the chat-bridge remote control,
/// read-aloud, and preference sync. None of them need a window; they need the app. Gating
/// them on that window's `.task` meant they simply never existed whenever it was closed at
/// quit and restored closed (Baton keeps running from the menu bar), so Settings → Remote and
/// → Friend Log, which both read `RemoteControlService`, rendered empty with nothing on
/// screen to say why.
///
/// **Why an `NSApplicationDelegate` and not `BatonApp.init()`.** The obvious first attempt —
/// building everything in `init()`, gated the same way `SparkleUpdater` already is — compiles
/// but crashes on first launch: `NSApp.servicesProvider = …` (used by read-aloud) force-unwraps
/// `NSApp`, and `NSApp` is `nil` until AppKit's own launch sequence assigns it, which happens
/// *after* SwiftUI finishes constructing the `App` value. `applicationDidFinishLaunching` is
/// the documented point after that assignment and before any window is guaranteed on screen,
/// and it fires exactly once per launch regardless of whether the saved window state reopens
/// the main window or leaves it closed — which is exactly the property this needed.
///
/// `RemoteControlService` reaches the `Window("Settings")` / `Window("Music Friend")` scenes
/// through `remoteHost`, not by being read straight off this delegate in the scene builder.
/// `RemoteControlHost` says why that distinction is the whole fix.
@MainActor
final class BatonAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Where the chat remote control lives, so a view can watch it appear. See
    /// `RemoteControlHost` for why the scenes read it through this box rather than through
    /// the `remote` property below.
    let remoteHost = RemoteControlHost()

    /// Chat remote control (Telegram / Discord). Shares the MCP server's audio-focus
    /// registry and drives the same `BatonMCPToolCatalog`, so a chat message and an agent
    /// call take one code path. Dormant (no bridges run) until configured in Settings →
    /// Remote, but the object itself exists for the app's whole lifetime: Settings → Remote
    /// and → Friend Log both read it.
    var remote: RemoteControlService? { remoteHost.service }

    /// The MCP control server (Streamable HTTP on loopback). Lets agents — and Tonebox —
    /// drive playback, read now-playing/queue, and duck audio via owner-token focus.
    private var mcp: BatonMCPServer?
    /// The native fast-path listener (Unix socket) for latency-critical audio ducking.
    /// Shares the MCP server's audio-focus registry so socket + MCP focus interoperate (§7).
    private var controlSocket: BatonControlSocket?
    /// Notification-center delegate for the `speak_summary` tool's "Play" action. Retained
    /// for the app's lifetime so tapping a spoken-summary notification plays the audio.
    private var speechNotifier: SpeechNotificationDelegate?
    /// Owns the floating speaking-HUD panel (Pause/Resume/Stop over any Space while a summary
    /// plays). Retained for the app's lifetime; observes `music.speech` to show/hide the panel.
    private var speakingHUD: SpeakingHUDPresenter?
    /// Speaks text captured off the screen (Services entry, and later the hotkey). Retained for
    /// the app's lifetime because it owns the in-flight synthesis task for a reading.
    private var readAloud: ReadAloudCoordinator?
    /// Pulls shared settings in on its own. Before this the Mac only ever synced when
    /// someone pressed a button in Settings, so the phone's searches, podcasts and EQ
    /// simply never arrived.
    private var syncScheduler: PreferenceSyncScheduler?

    /// Set by `BatonApp.init()` immediately after this delegate is created. SwiftUI
    /// constructs the `@NSApplicationDelegateAdaptor`-backed delegate before `init()`'s own
    /// body runs — the same "defaults are applied before the body starts" rule that makes
    /// `@State private var music = MusicModel()` already readable there — so this is always
    /// assigned well before AppKit can call `applicationDidFinishLaunching`.
    var music: MusicModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never under XCTest, same guard as `SparkleUpdater` elsewhere in this file: the unit
        // tests are app-hosted, so this fires inside the test host too, and a live MCP
        // listener, chat bridges, and a network sync scheduler in the test host are exactly
        // the real-world side effects `BatonEnvironment` exists to keep out.
        guard !BatonEnvironment.current.isTesting else { return }
        let music = self.music!

        // Expose the composition root to Shortcuts/Siri, same shape as the
        // phone's AppServicesHolder.
        MacIntentServices.model = music
        BatonMCPSpeakTools.sweepStaleTempFiles() // clear orphaned speech clips

        // A cover-art request that comes back 401 or 403 raises the browse store's own
        // error, which is what the library grid already shows through `ContentStatePlaceholder`.
        // Artwork used to discard the response, so a refused credential looked exactly like a
        // grid that had not finished loading. The store's existing rule applies unchanged:
        // only an auth failure is worth telling someone about, because it is the one that
        // never fixes itself. Debounced inside `ArtworkCache`, or sixty covers would say it
        // sixty times.
        ArtworkCache.shared.onCredentialRefused = { [weak music] in
            music?.musicLibrary.lastError = NavidromeError.unauthorized.errorDescription
        }

        // Read aloud (specs/read-aloud.md). The Services provider is the
        // zero-permission acquisition path — the system hands over another app's
        // selection, so this works on first launch with nothing granted and no
        // hotkey bound. Registering it is free; nothing runs until someone
        // chooses Speak with Baton.
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

        let scheduler = PreferenceSyncScheduler(model: music)
        scheduler.start()
        syncScheduler = scheduler

        let s = BatonMCPServer(music: music); s.start(); mcp = s
        // Start the fast-path listener sharing the server's focus registry.
        let sock = BatonControlSocket(focus: s.focus, music: music); sock.start()
        controlSocket = sock
        // Chat bridges, sharing the server's focus registry. `apply()`
        // is a no-op unless the user has configured a platform.
        let chat = RemoteControlService(player: music.music, tools: MCPToolSurface(music: music, focus: s.focus))
        chat.apply()
        remoteHost.service = chat
        // Route spoken-summary notifications ("Play" action) to the engine.
        let notifier = SpeechNotificationDelegate(speech: music.speech)
        UNUserNotificationCenter.current().delegate = notifier
        SpeechNotifier.registerCategory()
        speechNotifier = notifier
        // Bring up the floating speaking HUD (independent, all-Spaces panel).
        speakingHUD = SpeakingHUDPresenter(model: music)
    }

    /// Tears everything down on quit so the accept threads stop, the control.sock file /
    /// advertised endpoints don't linger, and preference sync's observer + heartbeat task have
    /// somewhere to end. Harmless at quit since the process dies anyway; the point is that a
    /// later "sign out" or "disconnect gateway" path needs one place that stops everything, and
    /// a teardown list missing a member is how that path ships half-done.
    func applicationWillTerminate(_ notification: Notification) {
        guard !BatonEnvironment.current.isTesting else { return }
        music?.music.persistNow() // save queue + playhead on quit
        remote?.stopAll()
        controlSocket?.stop()
        mcp?.stop()
        syncScheduler?.stop()
    }
}

/// The one place the app's `RemoteControlService` lives, so that a *view* can watch it appear.
///
/// TBX-5324, second round. Building the service at the composition root was necessary and not
/// sufficient: the scenes wrote `.environment(appDelegate.remote)`, and a `Window` scene's
/// content is a value built while `BatonApp.body` is evaluated, which happens once, before
/// AppKit calls `applicationDidFinishLaunching`. So the `nil` that was there at launch was
/// baked into the Settings window's content and nothing ever read the property again: Settings
/// → Remote and → Friend Log showed their "not available" fallback for the whole run, on a
/// build whose control socket and MCP port were provably live. Measured on a clean single
/// probe by reading the window's accessibility tree, not guessed from a screenshot.
///
/// A box that is `@Observable` and never replaced fixes both halves. Its identity is fixed
/// before the scene graph is built, so the scene can bake *it* in safely, and the nil → service
/// transition is read inside a view body, where SwiftUI's observation actually applies.
@MainActor
@Observable
final class RemoteControlHost {
    var service: RemoteControlService?
}

/// Puts the app's `RemoteControlService` into the environment from inside a view body.
///
/// The one line that matters is in `body`: every window that shows a remote-control surface
/// wraps its content in this instead of writing `.environment(appDelegate.remote)` in the
/// scene builder. See `RemoteControlHost`.
struct RemoteControlScope<Content: View>: View {
    let host: RemoteControlHost
    @ViewBuilder var content: Content

    var body: some View {
        content.environment(host.service)
    }
}

/// Baton — a standalone, free macOS music player extracted from Tonebox.
///
/// The whole player is rooted on a single `MusicModel` (`@Observable`), the same
/// self-contained root Tonebox embeds. Baton owns it directly: no `AppModel`, no
/// recording/sync/AI surface — just playback, a full browser window, and a mini
/// player. (An MCP control server + menu-bar controller arrive in later waves.)
@main
struct BatonApp: App {
    @State private var music = MusicModel()

    /// Owns the MCP server, the chat-bridge remote control, read-aloud, and preference sync —
    /// see the type's own doc for why this composition root is a delegate rather than
    /// `BatonApp.init()`.
    @NSApplicationDelegateAdaptor(BatonAppDelegate.self) private var appDelegate

    /// Bridges menu-bar commands (Go / Find / Now Playing) into the main window's state.
    @State private var commandRouter = BatonCommandRouter()

    /// Window id for the custom About panel (opened from the app menu).
    static let aboutWindowID = "baton-about"

    init() {
        // Start opt-in crash reporting if (and only if) the user turned it on
        // and release packaging supplied a complete Crashbox configuration.
        // No-op otherwise. See CrashReporting.
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

        // Hand the composition-root delegate the model it needs, before AppKit can possibly
        // call `applicationDidFinishLaunching` on it. See `BatonAppDelegate`.
        appDelegate.music = music
    }

    /// A failed link says so, in the same place a failed drag already does.
    ///
    /// Every way this can go wrong — offline, a locked Keychain, no server yet, an id from a
    /// different server — used to be swallowed by `try?` with no `else`, so the whole feature
    /// had one failure mode and it was "absolutely nothing happens". The app already made
    /// this argument for drag and drop, where `MusicView` posts a toast because "a drop with
    /// no feedback is indistinguishable from a drop that missed". A link is the same shape.
    ///
    /// Static and pure so the wording is testable without a running app: a toast that appears
    /// and says nothing useful is the original defect wearing a hat.
    static func deepLinkFailureText(_ what: String, error: Error? = nil) -> String {
        guard let error else { return what }
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? what : "\(what): \(trimmed)"
    }

    /// Acts on a `baton://` link. Deliberately small, and deliberately reusing what is
    /// already wired: `pendingSourceNavigation` is how the full-screen player's "Playing
    /// from" link already navigates, and `music.music.play` is the same call every row in
    /// the app makes.
    @MainActor
    private func handle(_ link: BatonDeepLink) async {
        // Bring Baton forward whichever way the link goes. Acting on it behind the window the
        // user was actually looking at is its own version of nothing happening.
        NSApp.activate(ignoringOtherApps: true)
        switch link {
        case .presentPlayer:
            commandRouter.showNowPlayingToken += 1
        case let .playSong(id):
            do {
                let song = try await NavidromeConfig.makeClient().getSong(id: id)
                music.music.play([song], source: .init(label: song.title, kind: .song, id: id))
            } catch {
                music.music.postToast(
                    Self.deepLinkFailureText("Couldn't open that track", error: error),
                    symbol: "exclamationmark.triangle.fill", seconds: 4
                )
            }
        case let .playAlbum(id):
            let songs = await music.musicLibrary.albumSongs(id: id)
            if songs.isEmpty {
                // `albumSongs` swallows its own error and hands back an empty list, so there is
                // nothing more specific to say here than that the album did not come back.
                music.music.postToast(
                    Self.deepLinkFailureText("Couldn't open that album"),
                    symbol: "exclamationmark.triangle.fill", seconds: 4
                )
            } else {
                music.music.play(songs, source: .init(label: "Album", kind: .album, id: id))
            }
        }
    }

    /// Whether the menu-bar icon is shown. False only under tests — see the scene below.
    ///
    /// A binding rather than a conditional scene because `SceneBuilder` would not type-check the
    /// `if`, and `MenuBarExtra(isInserted:)` is the API built for this.
    @State private var menuBarExtraInserted = !BatonApp.isRunningUnderTests

    /// Whether this process is a test host rather than the app someone launched.
    ///
    /// XCTest sets `XCTestConfigurationFilePath` in the environment of the host it injects into,
    /// which is the one signal available *before* any test runs — early enough to decide whether
    /// a scene should exist at all.
    static let isRunningUnderTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        // Main player window. Reuses the chromeless pop-out view Tonebox ships, so the
        // mini player's "expand" deep-link (`openWindow(id: MusicWindowView.windowID)`)
        // resolves to this window.
        Window("Baton", id: MusicWindowView.windowID) {
            MusicWindowView()
                .environment(music)
                .environment(commandRouter)
                // The appearance choice. `MusicView` applies it too, on its outer group, so
                // the view is right wherever it is hosted; here so the rule this app follows
                // is "every window carries it", which is a rule a test can check. Applying an
                // idempotent modifier twice costs nothing; a rule with two exceptions is what
                // let Settings and Help drift in the first place.
                .batonChrome()
                // Every `@AppStorage` below here reads and writes the domain `BatonStorage`
                // resolved — the app's own in a normal launch, a throwaway suite in a probe
                // one. Without this, a probe run's settings would land in the owner's real
                // preferences while its stores wrote elsewhere, which is the half-redirect
                // that makes a sync walk test nothing. Repeated per scene because
                // `defaultAppStorage` is an environment value and each scene has its own.
                .defaultAppStorage(BatonStorage.defaults)
                // Anchor the whole app to Baton brand orange (also installed as the
                // `AccentColor` asset). Brand ⇄ Dynamic rule: chrome + actions are
                // brand; the player wires the dynamic artwork accent explicitly on top.
                .tint(.batonOrange)
                // `baton://` — the front door the Mac never had. Every path behind these
                // links already existed (the router navigates, the engine plays); only the
                // scheme and this handler were missing, so a link that worked on the phone
                // silently did nothing on the desktop. Same `BatonDeepLink` vocabulary as
                // the phone, in Shared/, so the two cannot mean different things by it.
                .onOpenURL { url in
                    guard let link = BatonDeepLink(url: url) else { return }
                    Task { await handle(link) }
                }
                // The Mac end of queue handoff: ask the server once whether the phone left
                // a queue, and offer it. Saving has always happened; asking never did.
                .macQueueHandoffOffer(model: music)
                // DEBUG only, and nothing in a release build: lends `openWindow` to the
                // `-baton.debugOpenWindow` launch flag. See BatonDebugWindows.
                .batonDebugWindowOpener()
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
        // The one window with no `.batonChrome()`, and deliberately: `MiniPlayerWindowView`
        // sets `.preferredColorScheme(.dark)` itself. It is a player surface — artwork wash,
        // white-on-dark transport — and `AppearanceSetting` says those are a design rather
        // than a preference. `BatonChromeCoverageTests` knows about this one by name.
        Window("Mini Player", id: MiniPlayerWindowView.windowID) {
            MiniPlayerWindowView()
                .environment(music)
                .tint(.batonOrange)
                .defaultAppStorage(BatonStorage.defaults)
        }
        .defaultSize(width: 340, height: 132)
        .windowResizability(.contentSize)

        // Custom About panel — a small, non-resizable utility window opened from
        // the app menu's "About Baton" item (see `BatonAppCommands`).
        Window("About Baton", id: Self.aboutWindowID) {
            BatonAboutView()
                .batonChrome()
                .defaultAppStorage(BatonStorage.defaults)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Unified Settings window (⌘,). Consolidates the former standalone
        // Servers and Equalizer windows into sidebar panes, alongside Playback
        // and About. ⌥⌘E deep-links to the Equalizer pane (see BatonAppCommands).
        Window("Settings", id: BatonSettingsView.windowID) {
            RemoteControlScope(host: appDelegate.remoteHost) {
                BatonSettingsView()
                    .environment(music)
                    .tint(.batonOrange)
                    .batonChrome()
                    .defaultAppStorage(BatonStorage.defaults)
            }
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
                .batonChrome()
                .defaultAppStorage(BatonStorage.defaults)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 660)
        .defaultPosition(.center)

        // The music friend, in its own window rather than a Settings pane — a conversation is
        // something you keep open beside the library, not something you configure. The Mac
        // has been running this agent for the chat bridges all along; this is the first way
        // to talk to it without opening Telegram.
        Window("Music Friend", id: MacMusicFriendView.windowID) {
            RemoteControlScope(host: appDelegate.remoteHost) {
                MacMusicFriendView()
                    .tint(.batonOrange)
                    .batonChrome()
                    .defaultAppStorage(BatonStorage.defaults)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 620)

        // Spoken-summary history — a two-pane window: the history list on the left, the same player
        // card as the floating speaking HUD on the right, so a replay plays inline here.
        Window("Spoken Summaries", id: SpeechHistoryView.windowID) {
            SpeechHistoryView()
                .environment(music)
                .tint(.batonOrange)
                .batonChrome()
                .defaultAppStorage(BatonStorage.defaults)
        }
        .windowResizability(.contentMinSize)
        // First-run size only; thereafter `SummariesWindowAccessor` restores the saved frame
        // (size + position) via AppKit autosave, so the window reopens where you left it.
        .defaultSize(width: 720, height: 560)

        // Always-available menu-bar controller — current track + compact transport,
        // reachable even when every window is closed. Binds to live player state.
        //
        // **Absent under tests, and that is not tidiness.** A gate's test host is this app, so it
        // put a second Baton icon in the menu bar next to the real one, with a Quit item that
        // ends the run. That killed four gate runs before it was understood, and the
        // fix there — `.accessory` at bundle load — hides the Dock icon and the app menu but
        // *not* a `MenuBarExtra`, which is a separate scene and is exactly what an accessory app
        // still shows. A fifth run died the same way afterwards, and the diagnostic named this
        // view in the backtrace.
        //
        // Removing the scene is the only thing that removes the icon. Nothing tests the menu bar
        // extra itself; `BatonMenuBarContent` is covered directly where it matters.
        MenuBarExtra(isInserted: $menuBarExtraInserted) {
            BatonMenuBarContent(model: music, router: commandRouter)
                .defaultAppStorage(BatonStorage.defaults)
        } label: {
            // The label renders whether or not any window is open, which is the only place a
            // probe launched with the main window closed can borrow `openWindow` from.
            BatonMenuBarLabel(model: music)
                .batonDebugWindowOpener()
        }
    }
}
