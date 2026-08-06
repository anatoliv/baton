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
    /// Internet radio (station list + raw-stream engine) and the local "keep this out of
    /// radio" list — both shared with the Mac.
    let radio = InternetRadioStore()
    let radioBans = MusicRadioBans()
    /// Carries the settings that are yours rather than this device's between your devices,
    /// through the gateway. Does nothing when no gateway is configured.
    let preferenceSync = PreferenceSync(deviceName: UIDevice.current.name)
    /// Retained so the audio-mix closure keeps a strong reference to the tap processor.
    @ObservationIgnored private let eqProcessor: AudioEQProcessor
    /// Where the music friend's brain lives, and whether it has been proven to work.
    /// Observable because the Friend tab appears and disappears with it.
    let agentConfig = AgentConfig()
    @ObservationIgnored private(set) lazy var agent: AgentClient =
        AgentClient(tools: AgentTools(model: self), player: music, config: agentConfig)
    @ObservationIgnored private(set) lazy var voice: VoiceInput = VoiceInput(controller: music)
    /// Makes this phone the gateway's player while Baton is foregrounded.
    @ObservationIgnored private(set) lazy var deviceLink: GatewayDeviceLink =
        GatewayDeviceLink(tools: AgentTools(model: self), config: agentConfig)

    @ObservationIgnored private let audioSession: MobileAudioSession

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

    /// A demo session has to outlive a relaunch: nothing is persisted server-side,
    /// so without this the demo user is dropped back at the connect wall.
    private static let demoModeKey = "baton.demoMode"

    init() {
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
        eqProcessor = AudioEQProcessor(coefficients: equalizer.coefficients)
        handoff = QueueHandoff(controller: controller)
        audioSession = MobileAudioSession(controller: controller)
        audioSession.configure()

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
        music.configureAudioMix = { item in
            guard eq.isEnabled else { item.audioMix = nil; return }
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
}
