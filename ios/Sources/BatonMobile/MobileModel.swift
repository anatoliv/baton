import Foundation
import Observation
import UIKit

/// The iPhone app's composition root — a deliberately small sibling of the Mac app's
/// `MusicModel`. It wires the shared-core engine (playback, library, scrobbling) plus
/// the one iOS-only piece, the audio session. Everything substantive lives in
/// `BatonPlaybackKit`; this file only connects it.
@MainActor
@Observable
final class MobileModel {
    let music: StreamingPlaybackController
    let musicLibrary: MusicLibraryStore
    let pins: PinStore
    let scrobbles: ScrobbleService
    /// The two external scrobble destinations, exposed so Settings can set them up on
    /// the phone rather than only inheriting tokens from a Mac settings import.
    let listenBrainz: MusicScrobbler
    let lastfm: MusicLastFM
    let history: MusicPlayHistory
    let handoff: QueueHandoff
    let podcastSubscriptions: PodcastSubscriptionStore
    let podcastProgress: PodcastProgressStore
    let equalizer: MusicEqualizer
    /// What the music friend was asked, what it did, and what you thought of it.
    let friendLog = FriendFeedbackLog()
    /// What it has learned from being told it was wrong — visible and deletable in the
    /// Friend log, and appended to its prompt as evidence rather than as rules.
    let friendLearning = FriendLearningStore()
    /// The same store the chat bridges use for "remember that…", now also the home for a
    /// rating that came with words — see `FriendLearningStore.memory`.
    let friendMemory = RemoteMemoryStore()

    /// Rate an exchange, and learn from it in the same breath.
    ///
    /// One entry point so the two can never disagree: a rating recorded without the
    /// learning step would be a thumbs-down that changes nothing, which is the version of
    /// this feature that quietly wastes someone's time.
    func rateFriendExchange(_ id: UUID, _ rating: FriendExchange.Rating,
                            fault: FriendExchange.Fault? = nil, note: String? = nil) {
        friendLog.rate(id, rating, fault: fault, note: note)
        guard let exchange = friendLog.exchanges.first(where: { $0.id == id }) else { return }
        friendLearning.memory = friendMemory
        friendLearning.learn(from: exchange)
        // An approval of the same words retires an older complaint about them. Otherwise a
        // correction outlives the problem it described, and keeps shaping answers after the
        // thing it complained about has been fixed.
        friendLearning.retireIfApproved(exchange)
    }
    /// Internet radio (station list + raw-stream engine) and the local "keep this out of
    /// radio" list — both shared with the Mac.
    let radio = InternetRadioStore()
    let radioBans = MusicRadioBans()
    /// Albums and artists opened from search, so search has a memory.
    let searchRecents = SearchRecents()
    /// Carries the settings that are yours rather than this device's between your devices,
    /// through the gateway. Does nothing when no gateway is configured.
    let preferenceSync = PreferenceSync(deviceName: UIDevice.current.name)
    /// Retained so the audio-mix closure keeps a strong reference to the tap processor.
    @ObservationIgnored private let eqProcessor: AudioEQProcessor
    /// Where the music friend's brain lives, and whether it has been proven to work.
    /// Observable because the Friend tab appears and disappears with it.
    let agentConfig = AgentConfig()
    @ObservationIgnored private(set) lazy var agent: AgentClient = {
        let client = AgentClient(tools: AgentTools(model: self), player: music, config: agentConfig)
        // The loop was open here: corrections were being written and never sent, so the
        // Friend log's promise that they were "added to what the friend is told about you"
        // was false on the phone. Read fresh on every question, not captured once, or a
        // rating would not take effect until the next launch.
        client.learnedCorrections = { [weak self] in
            guard let self else { return nil }
            // Two sources, one block: what they have told the friend they mean (memory),
            // and what it demonstrably got wrong (corrections). Memory first — guidance
            // before evidence.
            return [friendMemory.rendered(), friendLearning.promptBlock]
                .compactMap { $0 }
                .joined(separator: "\n\n")
                .nilIfEmpty
        }
        return client
    }()
    @ObservationIgnored private(set) lazy var voice: VoiceInput = VoiceInput(controller: music)
    /// Makes this phone the gateway's player while Baton is foregrounded.
    @ObservationIgnored private(set) lazy var deviceLink: GatewayDeviceLink =
        GatewayDeviceLink(tools: AgentTools(model: self), config: agentConfig)

    @ObservationIgnored private let audioSession: MobileAudioSession

    // MARK: - Experimental audio engine (docs/audio-engine-ios.md)

    /// Opt-in AVAudioEngine deck for library streams, mirroring the Mac's setting. It is
    /// what makes the equalizer and the live now-playing bars work on *streamed* audio:
    /// the tap-based path they use today (`MTAudioProcessingTap`) never runs for an
    /// HTTP-streamed AVPlayer item, so on this phone the ten-band equalizer in Settings
    /// has only ever affected downloads. Podcasts, downloads and radio stay on AVPlayer.
    static let experimentalEngineKey = "baton.music.experimentalEngine"
    @ObservationIgnored private(set) var engineBridge: EngineDeckBridge?

    /// True once a server is configured — gates the onboarding flow.
    var isConfigured: Bool { NavidromeConfig.isConfigured }

    /// True while the app is running on the bundled demo library instead of a server.
    /// Screens read it to explain themselves ("this is the demo") and to hide the
    /// handful of actions that need a server to mean anything.
    var isDemoMode = false

    /// What the app is showing. Replaces a `showsSetup` boolean that had grown two
    /// companions (`isDemoMode`, `credentialsRejected`) which could contradict each other —
    /// "in demo mode *and* showing setup" was representable and meaningless.
    ///
    /// It lives here rather than in the `App` struct so that disconnecting brings setup
    /// back; as `@State` evaluated once at launch it left a disconnected app empty and
    /// unrecoverable until the next cold start.
    enum Phase: Equatable {
        case loading
        case needsSetup
        case demo
        case ready
    }

    var phase: Phase = .loading

    /// Kept as the single question the setup gate asks, so call sites read as intent
    /// ("do we need setup?") rather than as enum plumbing.
    var showsSetup: Bool {
        get { phase == .needsSetup }
        set { phase = newValue ? .needsSetup : (isDemoMode ? .demo : .ready) }
    }

    /// True only when the server actively rejected the stored credentials. Distinct from
    /// "offline": the setup screen says something different, and being wrong about which
    /// one it is costs someone either their config or an accurate explanation.
    ///
    /// Read by `OnboardingView` so a re-authentication doesn't look like a first run.
    var credentialsRejected = false

    // MARK: - Reveal (Go to Album / Go to Artist)

    /// Set by any context menu that wants to open an album or artist from wherever it is
    /// — a search result, the queue, the full player. `RootTabView` presents the target
    /// as a sheet, because the asker may be nowhere near a NavigationStack it owns: the
    /// player is itself a sheet, and a context menu inside the Up Next sheet is two
    /// presentations deep. One presenter, at the root, works from everywhere.
    var revealedAlbum: NavidromeAlbum?
    var revealedArtist: NavidromeArtist?

    /// A song's album, built from what the song already carries. `albumID` is on every
    /// Subsonic song; the rest is cosmetic and the detail screen fetches the real thing.
    func revealAlbum(of song: NavidromeSong) {
        guard let albumID = song.albumID else { return }
        revealedAlbum = NavidromeAlbum(
            id: albumID, name: song.album ?? "Album",
            artist: song.artist, coverArtID: song.coverArtID
        )
    }

    /// The artist, when the library knows one by this song's artist name. Songs carry
    /// only the artist's *name*, so this is a lookup rather than a construction — and the
    /// menu entry simply doesn't appear when the lookup fails, which beats a button that
    /// opens an empty screen.
    func artistNamed(_ name: String?) -> NavidromeArtist? {
        guard let name, !name.isEmpty else { return nil }
        return musicLibrary.artists.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A demo session has to outlive a relaunch: nothing is persisted server-side,
    /// so without this the demo user is dropped back at the connect wall.
    private static let demoModeKey = "baton.demoMode"

    /// Wipes the session before anything reads it.
    ///
    /// UI tests share one simulator, and one of them signs in to a real server to prove the
    /// connection badge works. Without this, every test after it inherited that connection:
    /// the demo library was gone, so "Home never opened" and four other screens failed for
    /// a reason that had nothing to do with them. State that leaks between tests turns one
    /// deliberate action into five mystery failures.
    ///
    /// DEBUG-only, and driven by a launch argument no shipping build passes.
    static let resetArgument = "-baton.resetSession"

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.resetArgument) {
            SessionPurge.wipeStores()
        }
        #endif
        let controller = StreamingPlaybackController()
        music = controller
        musicLibrary = MusicLibraryStore()
        pins = PinStore()
        history = MusicPlayHistory()
        // Held as properties, not inline arguments: Settings needs to configure them
        // (ListenBrainz token, Last.fm auth) and the service keeps its destinations
        // private by design.
        let listenBrainz = MusicScrobbler()
        let lastfm = MusicLastFM()
        self.listenBrainz = listenBrainz
        self.lastfm = lastfm
        scrobbles = ScrobbleService(listenBrainz: listenBrainz, lastfm: lastfm)
        podcastSubscriptions = PodcastSubscriptionStore()
        podcastProgress = PodcastProgressStore()
        equalizer = MusicEqualizer()
        eqProcessor = AudioEQProcessor(coefficients: equalizer.coefficients, levels: AudioLevelMonitor.shared.snapshot)
        handoff = QueueHandoff(controller: controller)
        audioSession = MobileAudioSession(controller: controller)
        audioSession.configure()
        installExperimentalEngineIfEnabled()

        // Podcasts: resume where the episode left off, and record progress so the
        // Mac (via future gateway sync) and this phone agree on played state.
        let progress = podcastProgress
        controller.resumeOffsetProvider = { song in
            progress.resumeOffset(id: song.id)
        }
        controller.onProgressUpdate = { song, time, duration in
            guard song.isPodcastEpisode || progress.isServerEpisode(song.id) else { return }
            _ = progress.record(id: song.id, position: time, duration: duration > 0 ? duration : nil)
        }
        progress.loadIfNeeded()

        // Downloads survive suspension: install the background engine and re-attach
        // to any tasks that outlived the last launch.
        let engine = BackgroundDownloadEngine()
        MusicDownloadStore.shared.backgroundEngine = engine
        engine.restoreOutstandingTasks()

        // Stamp any synced setting the moment it changes, so a foreground sync has
        // something to push. Manual instrumentation had covered 3 of 16 keys.
        preferenceSync.startObservingChanges()

        // Last.fm authorizes in a browser; the shared engine stays platform-neutral and
        // lets the host open the URL.
        MusicLastFM.openExternalURL = { url in
            Task { @MainActor in UIApplication.shared.open(url) }
        }

        // Keep the paired watch configured (encrypted WatchConnectivity context).
        WatchConfigSync.shared.activateAndPush()

        // EQ: attach the audio-mix tap on each loaded item, same wiring as the Mac.
        let eq = equalizer
        let processor = eqProcessor
        // Attaches when the equalizer wants it *or* the now-playing bars do — gating on
        // the EQ alone left the level meter dead for everyone who never opened it.
        music.configureAudioMix = { item in
            guard eq.isEnabled || AudioLevelMonitor.shared.isEnabled else { item.audioMix = nil; return }
            Task { @MainActor in
                if let track = try? await item.asset.loadTracks(withMediaType: .audio).first {
                    item.audioMix = processor.makeAudioMix(for: track)
                }
            }
        }
        eq.onToggle = { [weak self] in self?.music.refreshAudioMix() }

        // The session must be live before the first buffer plays; the engine's
        // track-start hook is the natural activation point.
        let session = audioSession
        let library = musicLibrary
        controller.onTrackStarted = { [weak self] song in
            session.activateForPlayback()
            if self?.isDemoMode != true { self?.scrobbles.nowPlaying(song) }
            self?.history.record(song)
            WidgetBridge.publish(
                song: song, isPlaying: true,
                artworkURL: library.coverArtURL(id: song.coverArtID ?? song.id, size: 300)
            )
        }
        controller.onScrobbleEligible = { [weak self] song, startedAt in
            guard self?.isDemoMode != true else { return }
            self?.scrobbles.completed(song, startedAt: startedAt)
        }
        // Autoplay/radio: extend the queue from server similarity, as on the Mac.
        // In demo mode there is no server to ask, and the whole library is already
        // in the queue, so autoplay stops at the end rather than hanging on a call.
        // Banned tracks are filtered here so both autoplay and Related honour them.
        controller.relatedProvider = { [weak self] song in
            guard let self, !isDemoMode else { return [] }
            return radioBans.filtered(await musicLibrary.similarSongs(seedID: song.id))
        }

        // A station ducks the library player rather than fighting it for the output.
        radio.duckController = controller
        pins.loadIfNeeded()
    }

    /// First load after onboarding (or launch when already configured).
    func warmLibrary() async {
        await musicLibrary.loadAlbums()
    }

    /// Exchanges shared preferences with the gateway, if there is one.
    ///
    /// Best-effort by construction: a gateway that is down must never change how the app
    /// behaves, so a failure here is logged and forgotten.
    func syncPreferences(force: Bool = false) async {
        let raw = agentConfig.gatewayURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let url = URL(string: raw), !agentConfig.gatewayToken.isEmpty else { return }
        if force {
            await preferenceSync.sync(gatewayURL: url, token: agentConfig.gatewayToken)
        } else {
            await preferenceSync.syncIfDue(gatewayURL: url, token: agentConfig.gatewayToken)
        }
        // A sync merges the other device's search history straight into UserDefaults, which
        // the in-memory list can't see. Without this the Mac's searches only surface after
        // the next launch, which reads as "it doesn't sync".
        searchRecents.reload()
    }

    /// Point search history at the server now signed in. Entries hold Navidrome ids, so a
    /// different library's rows would open onto errors.
    func refreshSearchScope() {
        searchRecents.setServer(SearchRecents.currentServerFingerprint())
    }

    /// Decides what the app opens into: a configured server, a resumed demo, or setup.
    ///
    /// Configured means **in**, immediately — before any network call. Baton has downloads
    /// and an offline mode, so a phone with no signal must open into the library it already
    /// has rather than bounce its owner to a connect screen they can't complete. The
    /// verification happens behind that, and only an outright rejection sends them to setup;
    /// a timeout is not evidence that a password is wrong.
    func restoreSession() async {
        #if DEBUG
        // Simulator/UI-test affordance. Synthetic taps can drive buttons and rows but not
        // text fields, so there is otherwise no way to reach any screen behind "connect to
        // a server". Mirrors KeepFloat's `-uitestFreshLogin`; never compiled into release.
        //
        //   xcrun simctl launch <sim> io.tonebox.baton \
        //     -uitestServer https://demo.navidrome.org -uitestUser demo -uitestSecret demo
        let args = UserDefaults.standard
        if let url = args.string(forKey: "uitestServer"),
           let user = args.string(forKey: "uitestUser"),
           let secret = args.string(forKey: "uitestSecret") {
            NavidromeConfig.save(urlString: url, username: user, secret: secret, authMode: .tokenSalt)
        }
        #endif

        if NavidromeConfig.isConfigured {
            phase = .ready
            refreshSearchScope()
            await warmLibrary()
            await verifyCredentials()
            await syncPreferences(force: true)
        } else if UserDefaults.standard.bool(forKey: Self.demoModeKey), DemoLibrary.isAvailable {
            startDemo()
        } else {
            showsSetup = true
        }
    }

    /// Confirms the stored credentials still authenticate, in the background.
    ///
    /// The distinction this draws is the whole point: `NavidromeError.unauthorized` means
    /// the credentials are genuinely no good and setup is the only way forward, while a
    /// transport failure means the tube, a rebooting server, or hotel wifi — all of which
    /// resolve themselves, and none of which should cost someone their configuration.
    func verifyCredentials() async {
        do {
            _ = try await NavidromeConfig.makeClient().ping()
            credentialsRejected = false
        } catch let error as NavidromeError {
            if case .unauthorized = error {
                credentialsRejected = true
                showsSetup = true
            }
            // Any other NavidromeError is transport or server-side — stay put.
        } catch {
            // URLError and friends: offline. Explicitly not a reason to log out.
        }
    }

    /// Starts a demo session. Kept here rather than at the call site so every entry
    /// point (onboarding, settings, a relaunch) goes through the same switch.
    func startDemo() {
        DemoLibrary.activate(self)
        UserDefaults.standard.set(true, forKey: Self.demoModeKey)
        phase = .demo
    }

    /// Ends the demo session — called when a real server is connected, so the two
    /// libraries never overlap.
    func endDemo() {
        UserDefaults.standard.set(false, forKey: Self.demoModeKey)
        // Every sign-in path lands here, so it's the one place search history has to be
        // re-pointed at whichever server was just connected.
        refreshSearchScope()
        defer {
            // Recompute rather than trust the caller's ordering: `showsSetup = false`
            // followed by `endDemo()` used to leave `phase == .demo` on a device that was
            // now talking to a real server, because the setter read `isDemoMode` before
            // this method cleared it.
            if phase != .needsSetup { phase = isDemoMode ? .demo : .ready }
        }
        guard isDemoMode else { return }
        music.stop()
        // Demo plays are not listening history. Left in, they surface on Home's "Recently
        // Played" and in History as tracks whose artwork can no longer resolve — bundled
        // cover ids mean nothing to a real server. Observed on device before this line.
        history.clear()
        DemoLibrary.deactivate(self)
    }

    /// Disconnects and removes this account's data from the device.
    ///
    /// `keepDownloads` is the caller's decision, not this method's: switching servers and
    /// erasing your offline music are different intentions, and only one of them is
    /// irreversible. See `SessionPurge`.
    func disconnect(keepDownloads: Bool = false) {
        SessionPurge.purge(self, keepDownloads: keepDownloads)
        isDemoMode = false
        credentialsRejected = false
        showsSetup = true
    }

    // MARK: - Experimental audio engine

    /// Hand the controller a way to build the engine deck, rather than a built one.
    ///
    /// The Mac constructs its deck in the composition root. The phone cannot: an
    /// `AVAudioEngine` will not start without an active `AVAudioSession`, and activating
    /// the session at launch cuts off whatever the user is already listening to. So the
    /// deck is built at the first moment a library stream is genuinely about to play,
    /// which is the same moment activating the session is warranted anyway.
    ///
    /// A failure to build degrades to AVPlayer in silence — the same behaviour as the Mac
    /// with no output device. The experiment must never be able to cost someone playback.
    /// Turn the experiment on or off while the app is running, on the track already
    /// playing.
    ///
    /// This is what the Settings copy promises, and until now it was untrue: the provider
    /// was installed once in `init` and nowhere else, so flipping the switch did nothing
    /// until the next launch. Playing music therefore stayed on AVPlayer, where the tap
    /// never runs for a stream — so switching equalizer presets was silent, and the
    /// equalizer looked broken when the real fault was a switch that wasn't wired.
    func setExperimentalEngine(_ enabled: Bool) {
        if enabled {
            installExperimentalEngineIfEnabled(force: true)
        } else {
            // Order matters: clear the provider first so the reload below cannot simply
            // build a new deck, then detach — which stops the deck and drops the routing
            // flag, leaving the reload to land on AVPlayer.
            music.engineDeckProvider = nil
            music.attachEngineDeck(nil)
            engineBridge = nil
        }
        music.reloadCurrentTrackForDeckChange()
    }

    private func installExperimentalEngineIfEnabled(force: Bool = false) {
        guard force || UserDefaults.standard.bool(forKey: Self.experimentalEngineKey) else { return }
        music.engineDeckProvider = { [weak self] in
            guard let self else { return nil }
            audioSession.activateForPlayback()
            guard let bridge = try? EngineDeckBridge.deviceBridge() else { return nil }
            engineBridge = bridge
            bridge.startMetering(into: AudioLevelMonitor.shared.snapshot)
            pushEQToEngineAndKeepWatching()
            return bridge
        }
        audioSession.onMediaServicesReset = { [weak self] in self?.rebuildEngineAfterReset() }
    }

    /// Keep the engine deck's EQ in lockstep with `MusicEqualizer` — same mechanism as the
    /// Mac. The tap path publishes coefficients the render tap pulls; the engine's EQ is an
    /// `AVAudioUnitEQ` that wants bands pushed, and observation tracking re-pushes on every
    /// edit. This is also what makes the toggle live with no stream reload.
    private func pushEQToEngineAndKeepWatching() {
        guard let bridge = engineBridge else { return }
        let apply = { [equalizer] in
            bridge.applyEQ(bands: equalizer.bands, enabled: equalizer.isEnabled)
        }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.pushEQToEngineAndKeepWatching() }
        }
    }

    /// The audio server died: every CoreAudio object we hold is a dead handle. Detach the
    /// corpse and re-arm the provider so the next track builds a fresh engine.
    ///
    /// Rebuilding eagerly here would be wrong twice over — the session is inactive, and
    /// doing it while the user is not playing anything would activate the session behind
    /// their back. Re-arming defers the rebuild to the next real play, which is the same
    /// rule the cold-launch path follows.
    private func rebuildEngineAfterReset() {
        music.attachEngineDeck(nil)
        engineBridge = nil
        installExperimentalEngineIfEnabled()
    }
}
