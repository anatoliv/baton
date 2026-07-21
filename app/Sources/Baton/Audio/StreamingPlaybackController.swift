import AVFoundation
import Foundation
import Observation
import OSLog

let streamingLog = Logger(subsystem: "io.tonebox.baton", category: "StreamingPlayback")

/// Streams music from a Navidrome (Subsonic) server and plays it locally on the
/// Mac via `AVPlayer`. A deliberate **sibling** to the recording-playback
/// `PlaybackController`: it owns its own `AVPlayer` and never shares state, so
/// music and recording review can't fight over the transport.
///
/// The queue drives play/next/previous; volume is a per-player volume (0–100)
/// that never touches the CoreAudio system master (`OutputVolumeController`).
/// Tracks play as a **hard cut** by default, or **crossfade** into each other when
/// `crossfadeSeconds > 0` (a second player overlaps the transition). The queue is persisted
/// and restored **paused** across launches. Recording/dictation auto-pauses
/// playback via `suspendForCapture()` / `resumeAfterCapture()`.
@MainActor
@Observable
final class StreamingPlaybackController {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case error(String)
    }

    private(set) var state: State = .idle

    /// A brief, user-facing confirmation for a music action (Add to Queue, Play Next,
    /// Download…), shown as a toast by the Music UI. A fresh `id` on every post makes the
    /// toast re-trigger even when the text repeats. Set via `postToast`.
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
    }

    private(set) var toast: Toast?

    /// Post a transient confirmation toast (auto-dismissed by the UI). Call from the main
    /// actor; several actions across the browse rows funnel their feedback through here so
    /// there's always a visible response even when the queue popover isn't open.
    func postToast(_ text: String, symbol: String = "checkmark.circle.fill") {
        toast = Toast(text: text, symbol: symbol)
    }

    /// Ordered play queue. Persisted across launches.
    private(set) var queue: [NavidromeSong] = []
    /// Index of the current track within `queue` (valid only when non-empty).
    private(set) var currentIndex: Int = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    /// True while an async `seek(to:)` is in flight — makes the periodic clock observer
    /// skip its update so it can't snap the scrubber back before the seek lands.
    @ObservationIgnored private var isSeeking = false
    /// Stamps each seek so only the newest one's completion clears `isSeeking`.
    @ObservationIgnored private var seekGeneration = 0

    /// True while the transport intends to play but audio isn't flowing yet — a
    /// buffering/stall signal derived from `AVPlayer.timeControlStatus`. Drives the
    /// spinner in the now-playing surfaces so a cold stream doesn't look frozen.
    private(set) var isBuffering = false

    /// Muted independently of `volumePercent` (the slider still shows the level).
    /// Raising the volume unmutes.
    private(set) var isMuted = false

    /// When set, playback pauses at this instant (sleep timer). Exposed so the UI can
    /// show a live countdown; the actual pause is driven by `sleepTimerTask`.
    var sleepTimerEndsAt: Date?
    /// Sleep-timer variant that pauses when the current track finishes rather than at
    /// a fixed time. Checked in `handleEnded`.
    var sleepAfterCurrentTrack = false
    var sleepTimerTask: Task<Void, Never>?

    /// Repeat mode: off (stop at end), all (loop the queue), one (replay track).
    private(set) var repeatMode: RepeatMode = .off
    /// Whether shuffle is on. Toggling saves/restores the pre-shuffle order.
    private(set) var isShuffled = false
    private var orderBeforeShuffle: [NavidromeSong]?

    /// Continuous radio: when the queue is about to run dry, auto-append tracks similar to
    /// the current one so playback keeps going instead of stopping. Persisted. Has no
    /// effect unless `relatedProvider` is wired (AppModel does that).
    var autoplayEnabled: Bool = false {
        didSet {
            guard autoplayEnabled != oldValue else { return }
            defaults.set(autoplayEnabled, forKey: Self.autoplayKey)
            if autoplayEnabled { extendQueueIfNeeded() } // top up immediately if near the end
        }
    }
    /// Injected "more like this" fetcher, wired to the library by AppModel. Nil ⇒ autoplay
    /// can't extend (the toggle still persists, it just does nothing until wired).
    @ObservationIgnored var relatedProvider: (@MainActor (NavidromeSong) async -> [NavidromeSong])?
    /// Called when a track actually starts playing — wired to the play-history log.
    @ObservationIgnored var onTrackStarted: (@MainActor (NavidromeSong) -> Void)?
    /// Injected resume-offset lookup (podcasts). When it returns a value for the starting
    /// track, playback seeks there once the item is ready. Nil ⇒ always start at 0.
    @ObservationIgnored var resumeOffsetProvider: (@MainActor (NavidromeSong) -> TimeInterval?)?
    /// Called periodically (~every 5 s) and at track end with the current position/duration —
    /// wired to `PodcastProgressStore` so episodes are resumable and get marked played.
    @ObservationIgnored var onProgressUpdate: (@MainActor (_ song: NavidromeSong, _ time: TimeInterval, _ duration: TimeInterval) -> Void)?
    /// Called once per track when it crosses the scrobble threshold (half its length, or 4 min),
    /// with the wall-clock time the track *started* — wired to `ScrobbleService`. The start time
    /// (not "now") is the canonical scrobble timestamp Last.fm/ListenBrainz expect.
    @ObservationIgnored var onScrobbleEligible: (@MainActor (NavidromeSong, Date) -> Void)?
    @ObservationIgnored private var scrobbledCurrent = false
    /// Wall-clock time the current track began — captured at every start path so a threshold
    /// scrobble (or a later offline retry) reports when playback actually started.
    @ObservationIgnored private var currentTrackStartedAt = Date()
    /// Fired when a fixed-time sleep timer elapses (after the fade-out). AppModel wires this to
    /// also stop internet radio, which plays on a separate engine the library pause can't reach.
    @ObservationIgnored var onSleepFire: (@MainActor () -> Void)?
    /// Attaches/detaches the equalizer audio-mix on a freshly-loaded item (AppModel wires
    /// this to the EQ). Nil ⇒ no EQ.
    @ObservationIgnored var configureAudioMix: (@MainActor (AVPlayerItem) -> Void)?

    /// Re-apply the EQ mix to the current item (call when the EQ is toggled on/off).
    func refreshAudioMix() {
        guard nowPlaying != nil, player.currentItem != nil else { return }
        // AVFoundation binds an item's audioMix (the EQ tap) when the item starts playing, NOT when
        // it's reassigned on a live item — so toggling the EQ on/off had no audible effect on the
        // current track. Reload the current track at its position so the tap attaches (EQ on) or
        // drops (EQ off) immediately. A no-op reassign suffices only when nothing is loaded.
        // (EQ live-toggle fix)
        let wasPlaying = state == .playing
        pendingSeek = currentTime
        loadCurrent(autoplay: wasPlaying)
    }
    /// Guards against overlapping autoplay fetches.
    @ObservationIgnored private var autoplayFetching = false

    /// A 0…1 fade envelope multiplied into the output volume — used for the sleep-timer
    /// fade-out (and available for other gentle fades). 1 = no fade.
    @ObservationIgnored var fadeMultiplier: Float = 1
    @ObservationIgnored private var fadeTask: Task<Void, Never>?

    /// Track-to-track loudness normalization using the server's ReplayGain/R128 data —
    /// applied as a per-track volume multiplier (no DSP, no latency). Persisted.
    var loudnessMode: LoudnessMode = .off {
        didSet {
            guard loudnessMode != oldValue else { return }
            defaults.set(loudnessMode.rawValue, forKey: Self.loudnessKey)
            applyVolume()
        }
    }
    /// Extra pre-amp on top of the ReplayGain adjustment, in dB. Persisted.
    var loudnessPreampDB: Double = 0 {
        didSet {
            guard loudnessPreampDB != oldValue else { return }
            defaults.set(loudnessPreampDB, forKey: Self.loudnessPreampKey)
            applyVolume()
        }
    }
    /// Crossfade duration between tracks, in seconds. 0 = a classic hard cut (unchanged
    /// behavior); >0 overlaps the outgoing and incoming track. Persisted.
    var crossfadeSeconds: Double = 0 {
        didSet {
            guard crossfadeSeconds != oldValue else { return }
            defaults.set(crossfadeSeconds, forKey: Self.crossfadeKey)
            // Turning crossfade on disables gapless (they're mutually exclusive); drop any
            // preloaded gapless item so the crossfade path owns the transition.
            preloadGaplessNextIfNeeded()
        }
    }
    /// True (sample-accurate) gapless playback: with no crossfade, preload the next track
    /// into the `AVQueuePlayer` so the OS advances to it with *no* gap at all — albums
    /// recorded without gaps (live, DJ, classical) flow seamlessly, with none of the
    /// stream-buffering pause a reload would cause. Persisted. Ignored when crossfade > 0
    /// (that already overlaps tracks).
    var gaplessEnabled: Bool = false {
        didSet {
            guard gaplessEnabled != oldValue else { return }
            defaults.set(gaplessEnabled, forKey: Self.gaplessKey)
            // Preload (or, when turned off, discard) the next item to match the new mode.
            preloadGaplessNextIfNeeded()
        }
    }
    /// When on, the gapless next-track prefetch is skipped on metered connections
    /// (cellular / personal hotspot / Low Data Mode) — playback still works, the streamed
    /// handoff just isn't pre-cached. Persisted.
    var gaplessPrefetchWifiOnly: Bool = false {
        didSet {
            guard gaplessPrefetchWifiOnly != oldValue else { return }
            defaults.set(gaplessPrefetchWifiOnly, forKey: Self.gaplessWifiOnlyKey)
        }
    }

    /// How far the music dims (target volume %) when something needs to be heard over it — a
    /// spoken summary, or an agent taking cooperative audio focus in `duck` mode (dictation /
    /// recording). This is the level for spoken summaries and the **default** for an agent duck;
    /// an `audio_focus` call may still pass its own `duckToPercent` to override it per request.
    /// Restored on release. Persisted.
    var duckPercent: Int = 20 {
        didSet {
            let clamped = max(0, min(duckPercent, 100))
            if clamped != duckPercent { duckPercent = clamped; return }
            guard duckPercent != oldValue else { return }
            defaults.set(duckPercent, forKey: Self.duckKey)
        }
    }

    enum RepeatMode: String, CaseIterable { case off, all, one }

    enum LoudnessMode: String, CaseIterable, Identifiable {
        case off, track, album
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: "Off"
            case .track: "Track"
            case .album: "Album"
            }
        }
    }

    /// Where the current queue was started from (a playlist, album, radio, …) so the
    /// UI can show "Playing from <playlist>" and highlight the source. Persisted with
    /// the queue.
    struct QueueSource: Equatable, Codable {
        var label: String
        var kind: Kind
        /// Source entity id when applicable (e.g. a playlist id) — lets the grid
        /// highlight the playing playlist.
        var id: String?

        enum Kind: String, Codable { case playlist, album, artist, radio, search, liked, song }

        var icon: String {
            switch kind {
            case .playlist: "music.note.list"
            case .album: "square.stack"
            case .artist: "music.mic"
            case .radio: "dot.radiowaves.left.and.right"
            case .search: "magnifyingglass"
            case .liked: "heart.fill"
            case .song: "music.note"
            }
        }
    }

    /// The current queue's origin, if known. Set by `play(_:source:)`.
    private(set) var queueSource: QueueSource?

    // Queue-advance decision logic (the pure `Advance` enum + `onTrackEnd`/`onManualNext`) lives
    // in StreamingPlaybackController+Advance.swift — first extraction of the W-50 decomposition.

    /// Player volume as a percentage 0–100. Mapped to `AVPlayer.volume` (0…1).
    /// Persisted; does NOT move the macOS system output volume.
    var volumePercent: Int = 70 {
        didSet {
            let clamped = max(0, min(volumePercent, 100))
            if clamped != volumePercent { volumePercent = clamped; return }
            applyVolume()
            defaults.set(clamped, forKey: Self.volumeKey)
        }
    }

    /// The track playing (or paused/loaded) right now, if any.
    var nowPlaying: NavidromeSong? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var isPlaying: Bool {
        state == .playing
    }

    // MARK: - Internals

    /// `AVQueuePlayer` (an `AVPlayer` subclass, so seek/volume/observers all work) so that
    /// true **gapless** playback can preload the next item and let the OS auto-advance
    /// with no gap. Non-gapless paths keep exactly one item queued at a time.
    private var player = AVQueuePlayer()
    private var endObserver: (any NSObjectProtocol)?
    /// The item we consider "current" — compared against `player.currentItem` to detect a
    /// gapless auto-advance (the OS moved to the preloaded next track on its own).
    private var loadedItem: AVPlayerItem?
    /// The preloaded next item + its queue index (gapless mode only). Nil when nothing is
    /// queued ahead. Inserted into the `AVQueuePlayer` so the OS auto-advances with no gap;
    /// `handleEnded` reconciles our logical state once the outgoing item's end fires.
    private var gaplessPreload: (index: Int, item: AVPlayerItem)?
    /// Owns the second player + volume ramp during a crossfade overlap; its player is promoted to
    /// `player` in `finishCrossfade` when the fade completes. (W-50 collaborator.)
    private let crossfadeRamp = CrossfadeRamp()
    private var isCrossfading = false

    /// True when true-gapless is active: gapless toggle on and no crossfade set (a nonzero
    /// crossfade takes over the transition instead).
    private var isGaplessMode: Bool { gaplessEnabled && crossfadeSeconds < 0.05 }
    /// Periodic observer on the player clock — updates `currentTime` smoothly (~4 Hz)
    /// while audio flows. Replaces the old manual poll loop.
    private var timeObserverToken: Any?
    /// A position to seek to once the current item reaches `readyToPlay` — used to
    /// restore a persisted playhead without racing a fixed delay.
    private var pendingSeek: TimeInterval?
    /// Consecutive stream-load failures; guards the auto-skip so an all-unplayable
    /// queue can't loop forever.
    private var consecutiveFailures = 0
    /// Retries of the CURRENT track before giving up and skipping — a brief network blip
    /// shouldn't skip the track (let alone cascade through the queue). Reset on a genuine
    /// track change / successful load. (W-26 / AUDIO-06)
    private var sameTrackRetries = 0
    static let maxSameTrackRetries = 3
    /// True once the current track's end has been handled — de-dupes the end notification
    /// and the periodic-observer fallback. Reset on load / seek-off-end.
    private var didHandleEnd = false

    #if DEBUG
    /// Test instrumentation: counts how a track boundary was crossed so an integration
    /// test can prove it was truly gapless. A gapless boundary increments
    /// `gaplessAdvanceCountForTesting` (state reconciled onto the already-playing preloaded
    /// item — no reload); a hard reload increments `loadCurrentCountForTesting`.
    private(set) var gaplessAdvanceCountForTesting = 0
    private(set) var loadCurrentCountForTesting = 0
    /// Counts how many times the queued gapless-next stream item was swapped for a local
    /// prefetched file (the zero-gap-on-streams path).
    private(set) var gaplessLocalSwapCountForTesting = 0
    /// Exposes the private true-gapless-active predicate so a test can assert the
    /// gapless ⊕ crossfade mutual-exclusivity invariant (F3 — the audiophile crown
    /// jewels must never silently regress).
    var isGaplessModeForTesting: Bool { isGaplessMode }
    #endif

    /// Owns the gapless prefetch machinery (in-flight tasks + the ephemeral disk cache + the
    /// downloader). The preloaded item itself lives in the main player's queue, so the swap +
    /// boundary reconciliation stay here; this owns only the self-contained prefetch subsystem.
    @ObservationIgnored private let gaplessPrefetcher: GaplessPrefetcher
    /// Whether the current network connection is metered (cellular / hotspot / Low Data).
    /// Injectable for tests; the default reads the shared `NetworkReachability`.
    @ObservationIgnored private let networkIsMetered: @MainActor () -> Bool
    /// Bridges to macOS Now Playing (Control Center, media keys). Off under XCTest.
    private let nowPlayingCenter = MusicNowPlayingCenter()
    private let systemNowPlaying: Bool
    /// Resolves a song's cover-art URL for the Now Playing artwork. Injectable; nil
    /// under test (system Now Playing is disabled there anyway).
    private let coverArtURLProvider: @MainActor (String) -> URL?

    // MARK: - Audio focus (owner-token capture coordination)

    /// A monotonically increasing stamp bumped on every **user- or external-initiated**
    /// transport change (play/resume/pause/next/previous/seek/stop). It is the
    /// "did the user intervene?" signal for audio focus: an owner captures its value at
    /// suspend time, and auto-resume is cancelled if the counter has moved since. The
    /// internal gapless-advance / end-of-track paths deliberately do NOT bump it — an
    /// auto-advance between suspend and release must not look like user intervention.
    @ObservationIgnored var stateGeneration = 0

    /// Bump the intervention counter. Call from genuine user/external transport actions.
    private func bumpStateGeneration() { stateGeneration &+= 1 }

    /// Monotonic seek counter, exposed so observers (e.g. the MCP now-playing
    /// notification) can detect a seek on the *current* track — which changes neither
    /// state, track id, nor queue index and would otherwise be invisible.
    var seekMarker: Int { seekGeneration }

    /// A one-shot claim on "pause the player for me, resume it when I'm done — but only if
    /// nothing else touched the transport in between". Handed out by
    /// `acquireAudioFocusSuspend(owner:)` and redeemed by `releaseAudioFocus(_:)`.
    /// Prepares the player for cross-process control (a separate app can duck for owner X
    /// and resume only if X ducked and the user didn't intervene).
    struct AudioFocusToken: Equatable {
        let owner: String
        /// The `stateGeneration` captured at suspend time — release compares against the
        /// live counter to detect intervening user transport changes.
        let generation: Int
        /// Whether the acquire actually took effect (paused, or ducked from a higher level).
        /// False ⇒ nothing to undo, so release is a clean no-op.
        let didSuspend: Bool
        /// How the acquire suspended: paused the transport, or ducked the player volume.
        /// Release undoes the matching action (unpause vs. restore volume).
        var mode: Mode = .pause
        /// For `mode == .duck`, the `volumePercent` in effect *before* the duck — restored
        /// verbatim on release. Nil for pause.
        var previousVolumePercent: Int?

        enum Mode: String, Equatable { case pause, duck }
    }

    /// The single current audio-focus holder, if any. Last-writer-wins: a new
    /// `acquireAudioFocusSuspend` replaces any prior holder (the older token then releases
    /// as a no-op, since it's no longer `currentFocus`).
    @ObservationIgnored var currentFocus: AudioFocusToken?

    /// The audio-focus token held by the `"capture"` owner (recording/dictation), if the
    /// `suspendForCapture()` wrapper is currently ducking. Backs the legacy
    /// `suspendedForCapture` flag.
    @ObservationIgnored var captureToken: AudioFocusToken?
    /// True while a `suspendForCapture()` is actively ducking playback it paused. Kept as a
    /// computed shim over the capture token so existing call sites / tests are unchanged.
    private var suspendedForCapture: Bool { captureToken?.didSuspend == true }
    /// KVO on the current item's `status` — surfaces decode / stream failures that
    /// would otherwise leave the transport stuck at "playing" with no audio.
    private var statusObservation: NSKeyValueObservation?
    /// KVO on the player's `timeControlStatus` — logs (at error level, so it
    /// persists) when the player is stuck waiting to play and why, versus actually
    /// playing. Makes a "playing but silent" report diagnosable from the logs.
    private var timeControlObservation: NSKeyValueObservation?
    /// Builds a signed Subsonic stream URL for a song id. Injectable for tests;
    /// defaults to the configured Navidrome client.
    private let streamURLProvider: @MainActor (String) throws -> URL

    static let queueKey = "tonebox.navidrome.queue"
    static let volumeKey = "tonebox.navidrome.volume"
    static let repeatKey = "tonebox.navidrome.repeat"
    static let shuffleKey = "tonebox.navidrome.shuffle"
    static let autoplayKey = "tonebox.navidrome.autoplay"
    static let loudnessKey = "tonebox.navidrome.loudness"
    static let loudnessPreampKey = "tonebox.navidrome.loudnessPreamp"
    static let crossfadeKey = "tonebox.navidrome.crossfade"
    static let gaplessKey = "tonebox.navidrome.gapless"
    static let gaplessWifiOnlyKey = "tonebox.navidrome.gaplessWifiOnly"
    static let duckKey = "tonebox.navidrome.duckPercent"
    /// Crash-recovery record for an active audio-focus duck: the player volume we lowered
    /// FROM, persisted the instant a duck is placed so a crash/force-quit while ducked can
    /// restore the user's level on next launch (mirrors `OutputVolumeController`). Only the
    /// duck case needs recovery — a pause is harmless across a relaunch (the queue restores
    /// paused anyway), but a stranded low *volume* would silently mis-play every future track.
    static let activeSuspendVolumeKey = "tonebox.navidrome.audioFocus.pendingVolume"

    /// Where the queue + volume persist. Production uses `.standard`; under XCTest
    /// it defaults to an isolated suite so tests can NEVER pollute the real app's
    /// stored queue/volume (which once restored a phantom test track on launch).
    let defaults: UserDefaults

    /// The persistence store to use when none is injected: `.standard` in
    /// production, an isolated suite under XCTest.
    static func defaultStore(environment: BatonEnvironment = .current) -> UserDefaults {
        guard environment.isTesting else { return .standard }
        // A unique suite per instance under test: persisted queue / now-playing state must never
        // leak between tests that each build their own controller or MusicModel (a shared suite let
        // one test's seeded queue restore into the next, e.g. "seek with nothing playing"). Tests
        // that deliberately verify cross-instance restore inject a shared `defaults:`. (W-49)
        return UserDefaults(suiteName: "io.tonebox.tests.music.\(UUID().uuidString)") ?? .standard
    }

    /// Resolves a queue item's `id` to a playable URL. Handles three cases: an offline
    /// download, a client-side podcast episode (whose id *is* its absolute enclosure URL — see
    /// `PodcastEpisode.asSong`), and the normal case of a Subsonic media id streamed from the
    /// server. Static + isolated so it's unit-testable without a live server.
    @MainActor
    /// The URL to DOWNLOAD a track for offline use: the original file for a library track
    /// (download.view, no transcode), or the enclosure URL for a podcast episode. (W-34 / DL-04)
    static func resolveDownloadURL(songID: String) throws -> URL {
        if MediaKind(id: songID) == .podcastEpisode, let url = URL(string: songID) {
            return url // podcast episode — its id IS the enclosure URL
        }
        return try NavidromeConfig.makeClient().downloadURL(songID: songID)
    }

    /// The "prefer downloads / play only offline" toggle (Settings + Downloads screen).
    static let offlineModeKey = "baton.music.offlineMode"
    static var isOfflineMode: Bool { UserDefaults.standard.bool(forKey: offlineModeKey) }

    static func resolveStreamURL(songID: String) throws -> URL {
        // Prefer an offline download when present.
        if let local = MusicDownloadStore.shared.localURL(for: songID) { return local }
        // Offline mode: never fall back to streaming — only downloaded content plays. Without
        // this the shipped toggle did nothing and Baton streamed anyway (PROD-01). (W-53)
        if isOfflineMode {
            throw NavidromeError.transport("Offline mode is on — this track isn't downloaded.")
        }
        // A podcast episode carries its enclosure URL as its id — play it directly.
        if MediaKind(id: songID) == .podcastEpisode, let url = URL(string: songID) {
            return url
        }
        // Otherwise it's a Subsonic media id — stream from the configured server.
        return try NavidromeConfig.makeClient().streamURL(songID: songID)
    }

    init(
        streamURLProvider: @escaping @MainActor (String) throws -> URL = { songID in
            try StreamingPlaybackController.resolveStreamURL(songID: songID)
        },
        coverArtURLProvider: @escaping @MainActor (String) -> URL? = { songID in
            // A podcast enclosure URL has no derivable cover art — skip the (bogus) server
            // lookup so now-playing falls back to a placeholder rather than a broken request.
            if MediaKind(id: songID) == .podcastEpisode { return nil }
            return (try? NavidromeConfig.makeClient())?.coverArtURL(id: songID, size: 600)
        },
        environment: BatonEnvironment = .current,
        defaults: UserDefaults? = nil,
        systemNowPlaying: Bool? = nil,
        gaplessCache: MusicGaplessCache? = nil,
        gaplessPrefetchDownloader: (@MainActor (URL, String) async -> URL?)? = nil,
        networkIsMetered: (@MainActor () -> Bool)? = nil
    ) {
        self.networkIsMetered = networkIsMetered ?? { NetworkReachability.shared.isMetered }
        self.streamURLProvider = streamURLProvider
        self.coverArtURLProvider = coverArtURLProvider
        // Environment decides the persistence store + whether to touch system Now Playing, unless a
        // caller injects them explicitly (tests do, to share/verify a specific store). (W-49)
        self.defaults = defaults ?? Self.defaultStore(environment: environment)
        self.systemNowPlaying = systemNowPlaying ?? !environment.isTesting
        let defaults = self.defaults // the resolved, non-optional store for the settings reads below
        let cache = gaplessCache ?? MusicGaplessCache()
        let downloader: @MainActor (URL, String) async -> URL? = gaplessPrefetchDownloader ?? { streamURL, songID in
            // Stream the (transcoded) next track to the ephemeral prefetch cache so the
            // boundary can hand off from a local file — zero-gap even for streams.
            // W-05/PER-03: treat a non-HTTP or error response as failure (was `?? true`),
            // so an error page never gets cached and handed to the gapless boundary.
            guard let (temp, response) = try? await URLSession.shared.download(from: streamURL),
                  (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? false
            else { return nil }
            return cache.store(tempFile: temp, songID: songID)
        }
        self.gaplessPrefetcher = GaplessPrefetcher(cache: cache, downloader: downloader)
        if let stored = defaults.object(forKey: Self.volumeKey) as? Int {
            volumePercent = stored
        }
        if let raw = defaults.string(forKey: Self.repeatKey), let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        isShuffled = defaults.bool(forKey: Self.shuffleKey)
        autoplayEnabled = defaults.bool(forKey: Self.autoplayKey)
        if let raw = defaults.string(forKey: Self.loudnessKey), let mode = LoudnessMode(rawValue: raw) {
            loudnessMode = mode
        }
        loudnessPreampDB = defaults.object(forKey: Self.loudnessPreampKey) as? Double ?? 0
        crossfadeSeconds = defaults.object(forKey: Self.crossfadeKey) as? Double ?? 0
        gaplessEnabled = defaults.bool(forKey: Self.gaplessKey)
        gaplessPrefetchWifiOnly = defaults.bool(forKey: Self.gaplessWifiOnlyKey)
        duckPercent = defaults.object(forKey: Self.duckKey) as? Int ?? 20
        applyVolume()
        player.isMuted = false
        attachPlayerObservers()
        configureNowPlaying()
        // If a prior run crashed while ducked for audio focus, restore the stranded volume.
        recoverStuckDuckFromPreviousSession()
    }

    /// Wire the transport-status + periodic-clock observers to the current `player`.
    /// Factored out so a crossfade can promote its second player and re-observe it.
    private func attachPlayerObservers() {
        // Diagnose "playing but silent": log why the player is stalled, or confirm
        // audio is actually flowing. `.error` level so it persists to the log store.
        // Doubles as the UI buffering signal (`isBuffering`).
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            // KVO can fire on AVFoundation's internal queues; read Sendable values
            // here, then hop to the main actor (assumeIsolated would trap off-main).
            let status = player.timeControlStatus
            let rate = player.rate
            let waitReason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .playing:
                    self.isBuffering = false
                    streamingLog.info("player: audio flowing (rate \(rate, privacy: .public))")
                case .waitingToPlayAtSpecifiedRate:
                    // Only "buffering" while we actually intend to play (not paused).
                    self.isBuffering = (self.state == .playing)
                    streamingLog.error("player: waiting to play — reason \(waitReason, privacy: .public)")
                case .paused:
                    self.isBuffering = false
                @unknown default:
                    break
                }
            }
        }
        // Smooth playhead updates while audio flows — an AVPlayer clock observer,
        // auto-suspended when paused, replacing the old 500 ms poll `Task`.
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                // Don't let a stale clock tick override a just-issued seek target.
                if self.isSeeking { return }
                self.currentTime = max(0, time.seconds)
                // Resume: once the item is ready (duration known), jump to the saved offset
                // exactly once. Done here (not at track start) because the item may not be
                // seekable and its duration may be unknown until audio actually flows.
                if let offset = self.pendingResumeOffset, self.duration > 1 {
                    self.pendingResumeOffset = nil
                    if PlaybackResume.shouldResume(offset: offset, duration: self.duration) {
                        self.lastProgressSaveTime = offset
                        self.seek(to: offset)
                        return
                    }
                }
                // Persist listening progress (podcasts) roughly every 5 s of playback.
                if let song = self.nowPlaying, self.duration > 1,
                   abs(self.currentTime - self.lastProgressSaveTime) >= 5 {
                    self.lastProgressSaveTime = self.currentTime
                    self.onProgressUpdate?(song, self.currentTime, self.duration)
                }
                // Persist queue + playhead ~every 15 s so a quit mid-track restores near
                // the real position (persistQueue otherwise only runs on transport events). (W-11)
                if self.duration > 1, abs(self.currentTime - self.lastQueuePersistTime) >= 15 {
                    self.lastQueuePersistTime = self.currentTime
                    self.persistQueue()
                }
                // Fire an external scrobble once the track's been played long enough.
                if !self.scrobbledCurrent, let song = self.nowPlaying, self.duration > 30,
                   self.currentTime >= MusicScrobbler.scrobbleThreshold(duration: self.duration) {
                    self.scrobbledCurrent = true
                    self.onScrobbleEligible?(song, self.currentTrackStartedAt)
                }
                // Start a crossfade into the next track when we're within the crossfade
                // window of the end (opt-in; 0 keeps the classic hard cut).
                self.maybeStartCrossfade()
                // Fallback end-of-track detection: some streams never post
                // AVPlayerItemDidPlayToEndTime. If we intend to be playing but the item has
                // reached its end and the player has stopped advancing (rate 0), drive the
                // end handler so the transport doesn't get stuck showing "playing" with a
                // parked player. handleEnded() flips the state, so this won't re-fire.
                if self.state == .playing,
                   TrackBoundary.isAtEnd(currentTime: self.currentTime, duration: self.duration),
                   self.player.timeControlStatus == .paused
                {
                    self.handleEnded()
                }
            }
        }
    }

    /// Remove the current player observers (before swapping players in a crossfade).
    private func detachPlayerObservers() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let timeObserverToken { player.removeTimeObserver(timeObserverToken) }
        timeObserverToken = nil
    }

    // Radio-awareness hooks for media-key / Now Playing remote commands. Wired by MusicModel; nil
    // (no-op) in tests / when radio isn't used. Stored here because extensions can't hold stored
    // properties — the routing logic lives in StreamingPlaybackController+RemoteCommands.swift.
    // (W-50 extraction / W-29 / AUDIO-05)
    @ObservationIgnored var radioIsOnAir: (@MainActor () -> Bool)?
    @ObservationIgnored var radioRemote: RadioRemote?

    /// Wires the macOS Now Playing remote commands to the transport (once).
    private func configureNowPlaying() {
        guard systemNowPlaying else { return }
        nowPlayingCenter.configure(.init(
            play: { [weak self] in self?.handleRemotePlay() },
            pause: { [weak self] in self?.handleRemotePause() },
            toggle: { [weak self] in self?.handleRemoteToggle() },
            next: { [weak self] in self?.handleRemoteNext() },
            previous: { [weak self] in self?.handleRemotePrevious() },
            seek: { [weak self] in self?.handleRemoteSeek(to: $0) }
        ))
    }

    /// Cached Now Playing artwork URL, resolved once per cover id — the signed cover
    /// URL embeds a fresh salt each build, so recomputing it every push would make the
    /// OS refetch the same image on every pause/seek.
    private var nowPlayingCoverID: String?
    private var nowPlayingDirectArt: URL?
    private var nowPlayingCoverURL: URL?
    /// A resume offset to apply once the current item is ready (duration known). Set at track
    /// start from `resumeOffsetProvider`, consumed by the first meaningful clock tick.
    private var pendingResumeOffset: TimeInterval?
    /// The `currentTime` at the last progress save, so `onProgressUpdate` fires ~every 5 s.
    private var lastProgressSaveTime: TimeInterval = 0
    /// The `currentTime` at the last queue persist, so the playhead is saved ~every 15 s. (W-11)
    private var lastQueuePersistTime: TimeInterval = 0
    /// Whether the loaded item's track-start side effects have fired. A restored queue
    /// loads paused (no start), so the first `resume()` must fire them. (W-11)
    private var startNotifiedForCurrentItem = false

    /// Notifies listeners a track began and arms its resume offset (podcasts). Call in place of
    /// `onTrackStarted?(song)` so every start path resumes + logs identically.
    private func notifyTrackStarted(_ song: NavidromeSong) {
        currentTrackStartedAt = Date()
        startNotifiedForCurrentItem = true
        onTrackStarted?(song)
        pendingResumeOffset = resumeOffsetProvider?(song)
        lastProgressSaveTime = 0
    }

    /// Publishes the current track + transport state to macOS Now Playing.
    private func pushNowPlaying() {
        guard systemNowPlaying else { return }
        let coverID = nowPlaying?.coverArtID
        let directArt = nowPlaying?.artworkURL
        // Recompute the artwork URL when either the Subsonic cover id or the direct art URL
        // (podcasts) changes. Podcast episodes all carry a nil coverID, so keying only on that
        // would leave the lock-screen art stuck on the first episode.
        if coverID != nowPlayingCoverID || directArt != nowPlayingDirectArt {
            nowPlayingCoverID = coverID
            nowPlayingDirectArt = directArt
            nowPlayingCoverURL = directArt ?? coverID.flatMap { coverArtURLProvider($0) }
        }
        nowPlayingCenter.update(
            song: nowPlaying,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            artworkURL: nowPlayingCoverURL
        )
    }

    // MARK: - Transport

    /// Replaces the queue with `songs` and starts playing from `index`. `source`
    /// records where the queue came from (playlist/album/radio) for the UI.
    func play(_ songs: [NavidromeSong], startAt index: Int = 0, source: QueueSource? = nil) {
        cancelCrossfade()
        guard !songs.isEmpty else { return }
        bumpStateGeneration()
        queue = songs
        currentIndex = max(0, min(index, songs.count - 1))
        queueSource = source
        loadCurrent(autoplay: true)
        persistQueue()
    }

    /// Appends `songs` to the queue. If nothing is playing, starts playback at the
    /// first newly-added track.
    func enqueue(_ songs: [NavidromeSong]) {
        guard !songs.isEmpty else { return }
        let wasEmpty = queue.isEmpty
        let firstNew = queue.count
        queue.append(contentsOf: songs)
        if wasEmpty {
            currentIndex = firstNew
            loadCurrent(autoplay: true)
        } else {
            preloadGaplessNextIfNeeded() // appended tracks may become the gapless "next"
        }
        persistQueue()
        postToast("Added \(songs.count) to queue", symbol: "text.append")
    }

    /// Inserts `songs` immediately after the current track so they play next (true
    /// "Play Next"), rather than at the end of the queue like `enqueue`. Starts
    /// playback if the queue was empty.
    func playNext(_ songs: [NavidromeSong]) {
        guard !songs.isEmpty else { return }
        guard !queue.isEmpty else { enqueue(songs); return }
        queue.insert(contentsOf: songs, at: min(currentIndex + 1, queue.count))
        preloadGaplessNextIfNeeded() // these become the immediate gapless "next"
        persistQueue()
        postToast("\(songs.count) playing next", symbol: "text.line.first.and.arrowtriangle.forward")
    }

    func resume() {
        guard nowPlaying != nil else { return }
        bumpStateGeneration()
        resetFade() // in case we were paused mid sleep-timer fade
        // AVQueuePlayer *drains* its current item when a track (or the whole queue) plays to
        // its end, so `player.currentItem` becomes nil and `play()` would do nothing (the
        // "waiting to play — no item" state). It's also nil right after a restore that failed
        // to buffer. In either case — or when parked at the end — reload the current track
        // from the top instead of calling play() on an empty player.
        if player.currentItem == nil || TrackBoundary.isAtEnd(currentTime: currentTime, duration: duration) {
            loadCurrent(autoplay: true)
            return
        }
        player.play()
        state = .playing
        // First play of a restored (loaded-paused) item: fire the track-start side effects
        // (history / "now playing") and stamp the scrobble timestamp now, so a restored
        // track doesn't scrobble against app-launch time. (W-11)
        if !startNotifiedForCurrentItem, let song = nowPlaying {
            notifyTrackStarted(song)
        }
        // Gapless: a resume from paused (notably a restored-on-launch queue, which loads
        // paused and so skipped the preload) must buffer the next track now, or the first
        // boundary after pressing play would fall back to a reload (gap).
        preloadGaplessNextIfNeeded()
        pushNowPlaying()
    }

    func pause() {
        bumpStateGeneration()
        pauseInternal()
    }

    /// Pauses without bumping the intervention counter — used by the audio-focus
    /// suspend path, which pauses playback *for* an owner and must not have its own
    /// pause read back as user intervention. `pause()` is the user-facing wrapper.
    func pauseInternal() {
        cancelCrossfade()
        player.pause()
        if state == .playing { state = .paused }
        pushNowPlaying()
        persistQueue() // capture the playhead where the user paused (W-11)
    }

    /// Persist the queue + playhead immediately (called on app termination). (W-11)
    func persistNow() { persistQueue() }

    /// Stops playback cleanly (keeps the queue so it can be restarted / persisted).
    func stop() {
        bumpStateGeneration()
        cancelCrossfade()
        player.pause()
        // Seek the player to the start too, so a later play() resumes from 0:00 — matching the
        // scrubber we reset below — instead of continuing from where Stop was pressed. (W-24 / AUDIO-10)
        player.seek(to: .zero)
        cancelGaplessPrefetch() // don't keep downloading a "next" track after Stop (W-28 / AUDIO-17)
        state = .idle
        currentTime = 0
        isBuffering = false
        persistQueue()
        pushNowPlaying()
    }

    /// Empties the queue and stops. Clears the persisted queue and Now Playing.
    func clearQueue() {
        cancelCrossfade()
        cancelGaplessPrefetch()
        queue = []
        currentIndex = 0
        orderBeforeShuffle = nil
        queueSource = nil
        player.removeAllItems()
        loadedItem = nil
        gaplessPreload = nil
        state = .idle
        currentTime = 0
        duration = 0
        isBuffering = false
        persistQueue()
        pushNowPlaying()
    }

    /// Advances to the next track. Wraps when repeat is on, stops otherwise.
    func next() {
        cancelCrossfade()
        guard !queue.isEmpty else { return }
        bumpStateGeneration()
        let wasPlaying = state == .playing
        switch Self.onManualNext(current: currentIndex, count: queue.count, repeatMode: repeatMode) {
        case let .play(idx):
            currentIndex = idx
            loadCurrent(autoplay: wasPlaying)
            persistQueue()
        case .replay:
            loadCurrent(autoplay: wasPlaying)
        case .stop:
            stop()
        }
    }

    /// Cycle repeat off → all → one → off. Persisted.
    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        defaults.set(repeatMode.rawValue, forKey: Self.repeatKey)
    }

    /// Toggle shuffle. Turning on keeps the current track first and shuffles the
    /// rest (saving the prior order); turning off restores that order.
    func toggleShuffle() {
        let current = nowPlaying
        if isShuffled {
            if let original = orderBeforeShuffle { queue = original }
            orderBeforeShuffle = nil
            isShuffled = false
        } else {
            orderBeforeShuffle = queue
            var rest = queue
            if let current, let idx = rest.firstIndex(where: { $0.id == current.id }) { rest.remove(at: idx) }
            rest.shuffle()
            queue = (current.map { [$0] } ?? []) + rest
            isShuffled = true
        }
        if let current, let idx = queue.firstIndex(where: { $0.id == current.id }) { currentIndex = idx }
        defaults.set(isShuffled, forKey: Self.shuffleKey)
        preloadGaplessNextIfNeeded() // (un)shuffle changed the track order
        persistQueue()
    }

    /// Jumps to a specific queue index and plays it.
    func jump(to index: Int) {
        cancelCrossfade()
        guard queue.indices.contains(index) else { return }
        bumpStateGeneration()
        currentIndex = index
        loadCurrent(autoplay: true)
        persistQueue()
    }

    /// Reorders the queue (drag-and-drop), keeping the current track selected.
    func moveQueueItem(from source: IndexSet, to destination: Int) {
        let current = nowPlaying
        queue.move(fromOffsets: source, toOffset: destination)
        if let current, let idx = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
        }
        preloadGaplessNextIfNeeded() // reorder may have changed which track is next
        persistQueue()
    }

    /// Removes tracks from the queue, keeping the current track selected (or
    /// stopping cleanly if the current track was removed).
    func removeFromQueue(at offsets: IndexSet) {
        cancelCrossfade()
        let current = nowPlaying
        let removingCurrent = offsets.contains(currentIndex)
        queue.remove(atOffsets: offsets)
        if let current, !removingCurrent, let idx = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
            preloadGaplessNextIfNeeded() // removed a queued track — the next may have changed
        } else if removingCurrent {
            // Land on the current track's successor: subtract the items removed BEFORE the
            // current index, else a multi-select spanning items before AND at the current
            // track skips past the intended next track. (W-24 / AUDIO-11)
            let removedBeforeCurrent = offsets.filter { $0 < currentIndex }.count
            currentIndex = min(max(0, currentIndex - removedBeforeCurrent), max(0, queue.count - 1))
            if queue.isEmpty { stop() } else { loadCurrent(autoplay: state == .playing) }
        }
        persistQueue()
    }

    /// Goes to the previous track (or restarts the current one at the start).
    func previous() {
        cancelCrossfade()
        guard !queue.isEmpty else { return }
        bumpStateGeneration()
        let wasPlaying = state == .playing
        if currentTime > 3 || currentIndex == 0 {
            seek(to: 0)
        } else {
            currentIndex -= 1
            loadCurrent(autoplay: wasPlaying)
            persistQueue()
        }
    }

    func seek(to seconds: TimeInterval) {
        cancelCrossfade()
        bumpStateGeneration()
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        // Guard the periodic time observer while AVPlayer's async seek is in flight — it
        // ticks every 0.25 s and would otherwise clobber `currentTime` back to the *old*
        // playhead before the seek lands, snapping the scrubber back to where it was. The
        // generation stamp means only the latest seek's completion lifts the guard, so a
        // fast drag (many seeks) doesn't clear it early.
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeeking = true
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.seekGeneration else { return }
                self.isSeeking = false
            }
        }
        // Moving the playhead off the end re-arms end handling.
        if !TrackBoundary.isAtEnd(currentTime: target, duration: duration) { didHandleEnd = false }
        pushNowPlaying()
    }

    /// Sets the player volume from a 0–100 percentage. A positive volume unmutes.
    /// A user volume change counts as transport intervention (§4.2): it bumps the generation
    /// so an in-flight audio-focus duck/pause won't auto-restore over the user's new level.
    func setVolume(percent: Int) {
        bumpStateGeneration()
        volumePercent = max(0, min(percent, 100))
        if volumePercent > 0, isMuted {
            isMuted = false
            player.isMuted = false
        }
    }

    /// Toggles mute independently of the volume level (the slider keeps its value).
    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// Push the effective volume to AVPlayer: the user's level times the current track's
    /// loudness-normalization multiplier. (Mute is separate — `player.isMuted`.)
    func applyVolume() {
        let mult = Self.loudnessMultiplier(for: nowPlaying, mode: loudnessMode, preampDB: loudnessPreampDB)
        player.volume = PlaybackVolume.effective(percent: volumePercent, loudness: mult, fade: fadeMultiplier)
    }

    // Loudness-normalization math (loudnessHeadroom + loudnessMultiplier + normalizationGain) lives
    // in StreamingPlaybackController+Loudness.swift — pure ReplayGain functions, W-50 extraction.

    /// Ramp the fade envelope to `target` over `duration`, then run `then` (e.g. pause).
    /// Cancels any in-flight fade. Used for the sleep-timer fade-out.
    func fade(to target: Float, duration: Double, then: (@MainActor () -> Void)? = nil) {
        fadeTask?.cancel()
        let start = fadeMultiplier
        fadeTask = Task { @MainActor [weak self] in
            let steps = 20
            for i in 1 ... steps {
                if Task.isCancelled { return }
                self?.fadeMultiplier = Fade.multiplier(step: i, of: steps, start: start, target: target)
                self?.applyVolume()
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
            }
            if Task.isCancelled { return }
            self?.fadeMultiplier = target
            self?.applyVolume()
            then?()
        }
    }

    /// Reset the fade envelope to full (called when playback (re)starts a track).
    func resetFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadeMultiplier = 1
        applyVolume()
    }


    // Sleep-timer (fixed-time + end-of-track, with a fade-out) lives in
    // StreamingPlaybackController+SleepTimer.swift (W-50 extraction).

    // MARK: - Loading

    private func loadCurrent(autoplay: Bool, isRetry: Bool = false) {
        #if DEBUG
        loadCurrentCountForTesting += 1
        #endif
        if !isRetry { sameTrackRetries = 0 } // a genuine (non-retry) load starts a fresh track
        // A fresh item can end again — clear the end-handled guard.
        didHandleEnd = false
        scrobbledCurrent = false
        startNotifiedForCurrentItem = false // set true by notifyTrackStarted (autoplay path)
        guard let song = nowPlaying else {
            state = .idle
            return
        }
        let url: URL
        do {
            url = try streamURLProvider(song.id)
        } catch {
            streamingLog.error("stream URL failed: \(error.localizedDescription, privacy: .public)")
            state = .error((error as? NavidromeError)?.errorDescription ?? error.localizedDescription)
            return
        }

        // Tear down the previous item's observers before swapping.
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()

        streamingLog.info("streaming song id \(song.id, privacy: .public)")
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        setCurrentItem(item)
        configureAudioMix?(item)
        applyVolume()
        currentTime = 0
        // Seed duration from the track's metadata immediately — Navidrome transcodes
        // on the fly, so AVPlayer often can't determine the stream's duration, which
        // left the scrubber stuck at 0:00. The async load below refines it if possible.
        duration = Double(song.duration ?? 0)

        // Surface decode/stream failures + end-of-track — factored so a promoted crossfade
        // player can re-observe its item the same way.
        attachItemObservers(item)

        if autoplay {
            player.isMuted = isMuted
            resetFade()
            player.play()
            state = .playing
            notifyTrackStarted(song)
        } else {
            state = .paused
        }
        pushNowPlaying()

        // Continuous radio: top up the queue ahead of time so the last track never ends
        // on a hard stop (see autoplayEnabled / extendQueueIfNeeded).
        extendQueueIfNeeded()

        // True-gapless: buffer the next track so the OS advances with no gap.
        preloadGaplessNextIfNeeded()

        // Refine duration from the asset when it's actually determinable (a real
        // finite value) — otherwise keep the metadata seed above.
        Task { [weak self] in
            let seconds = await (try? item.asset.load(.duration))?.seconds
            guard let self, let seconds, seconds.isFinite, seconds > 1 else { return }
            if player.currentItem === item {
                duration = seconds
                pushNowPlaying()
            }
        }
    }

    /// A stream item failed to load (bad format, auth, network). Surfaces the error
    /// and — so one dud track doesn't stall the whole queue — auto-skips to the next
    /// after a short beat, unless every track has failed (guarded to avoid a loop).
    private func handleLoadFailure(_ message: String) {
        isBuffering = false
        // First, retry the SAME track with a capped backoff, preserving the playhead — a brief
        // outage (Wi-Fi blip, server restart) then recovers in place instead of skipping the
        // track and cascade-skipping the rest of the queue. (W-26 / AUDIO-06)
        if sameTrackRetries < Self.maxSameTrackRetries {
            sameTrackRetries += 1
            let resumeAt = currentTime
            let attempt = sameTrackRetries
            state = .loading
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(attempt) * 1.0)) // 1s, 2s, 3s
                guard let self, case .loading = self.state else { return }
                if resumeAt > 1 { self.pendingSeek = resumeAt }
                self.loadCurrent(autoplay: true, isRetry: true)
            }
            return
        }
        // Exhausted same-track retries — treat it as a genuinely bad track and move on, with
        // the existing guard so an all-unplayable queue can't loop forever.
        sameTrackRetries = 0
        state = .error(message)
        consecutiveFailures += 1
        guard queue.count > 1, consecutiveFailures < queue.count else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, case .error = state else { return }
            switch Self.onManualNext(current: currentIndex, count: queue.count, repeatMode: repeatMode) {
            case let .play(idx):
                currentIndex = idx
                loadCurrent(autoplay: true)
                persistQueue()
            case .replay, .stop:
                break
            }
        }
    }

    #if DEBUG
    /// Test seam: drives the end-of-track handler without a real AVPlayer clock.
    func simulateTrackEndedForTesting() { handleEnded() }
    /// Test seam: drives the load-failure handler without a real stream failure.
    func simulateLoadFailureForTesting(_ message: String = "test failure") { handleLoadFailure(message) }
    var sameTrackRetriesForTesting: Int { sameTrackRetries }
    #endif

    /// A track finished. Hard-cut to the next queued track, or stop cleanly at the
    /// end of the queue (REQ-10 — stopped, not errored).
    private func handleEnded() {
        // Idempotent per item-end: both the AVPlayerItemDidPlayToEndTime notification and
        // the periodic-observer fallback can fire for the same end — only act once. Cleared
        // when a new item loads or the playhead seeks off the end.
        guard !didHandleEnd else { return }
        didHandleEnd = true

        // Final progress update so a finished episode is marked played (and its download can be
        // reaped). Reports the full duration as the position — that's what "reached the end" is.
        if let song = nowPlaying, duration > 1 {
            onProgressUpdate?(song, duration, duration)
        }

        // True-gapless: the `AVQueuePlayer` auto-advances the *audio* to the preloaded next
        // item with no gap. Rather than reload (which would re-buffer and insert a pause),
        // reconcile our logical state onto that already-queued item. We trust the preload's
        // presence rather than comparing against `player.currentItem`: the end notification
        // can fire before `currentItem` flips, and the queue player is guaranteed to advance
        // to the item we inserted next.
        if isGaplessMode, let preload = gaplessPreload {
            gaplessAdvanced(to: preload.index, item: preload.item)
            return
        }
        advanceAfterEnd()
    }

    /// Decide what happens after the current track ends: honor an end-of-track sleep timer,
    /// else replay / advance / continue-radio / stop per the repeat + autoplay settings.
    /// Shared by the hard-cut end and the gapless end-of-queue (no preload) paths.
    private func advanceAfterEnd() {
        // Sleep timer armed to stop at the end of this track.
        if sleepAfterCurrentTrack {
            sleepAfterCurrentTrack = false
            state = .paused
            player.pause()
            currentTime = 0
            persistQueue()
            pushNowPlaying()
            return
        }
        switch Self.onTrackEnd(current: currentIndex, count: queue.count, repeatMode: repeatMode) {
        case .replay:
            loadCurrent(autoplay: true)
        case let .play(idx):
            currentIndex = idx
            loadCurrent(autoplay: true)
            persistQueue()
        case .stop:
            // Continuous radio: instead of stopping at the end, pull in similar tracks and
            // keep playing. Falls through to a real stop if autoplay is off or finds nothing.
            if autoplayEnabled, relatedProvider != nil, !queue.isEmpty {
                state = .loading
                pushNowPlaying()
                fetchRelated(playFirstNew: true)
            } else {
                endOfQueue()
            }
        }
    }

    // MARK: - Gapless queue

    /// Make `item` the sole queued item on the `AVQueuePlayer` and adopt it as current.
    /// Replaces the old `replaceCurrentItem(with:)` — on a queue player we clear the queue
    /// (dropping any stale gapless preload) and insert exactly one item.
    private func setCurrentItem(_ item: AVPlayerItem) {
        player.removeAllItems()
        if player.canInsert(item, after: nil) { player.insert(item, after: nil) }
        loadedItem = item
        gaplessPreload = nil
    }

    /// The queue index the current track will advance to at its natural end, or nil when the
    /// track will replay or the queue will stop (nothing meaningful to preload).
    private func plannedNextIndex() -> Int? {
        guard case let .play(next) = Self.onTrackEnd(current: currentIndex, count: queue.count, repeatMode: repeatMode),
              next != currentIndex, queue.indices.contains(next) else { return nil }
        return next
    }

    /// Keep the `AVQueuePlayer`'s look-ahead item in sync with the current mode + queue: in
    /// gapless mode, buffer the next track so the OS advances to it with no gap; otherwise
    /// (or when the planned next changed) discard any stale preload. Idempotent — safe to
    /// call after any queue mutation or setting change.
    private func preloadGaplessNextIfNeeded() {
        let planned = plannedNextIndex()
        // Reap in-flight prefetches for tracks that are no longer the planned next (e.g. after
        // rapid skipping), so stale full-file downloads don't pile up competing with the live
        // stream on the same link. (W-28 / AUDIO-17)
        let plannedID = planned.map { queue[$0].id }
        gaplessPrefetcher.reap(keeping: plannedID)
        // Drop a preload that no longer matches (mode off, queue reordered, crossfade on…).
        if let existing = gaplessPreload, !isGaplessMode || existing.index != planned {
            player.remove(existing.item)
            gaplessPreload = nil
        }
        // Insert after `loadedItem` (the track we last made current). Note we do NOT gate on
        // `loadedItem === player.currentItem`: AVQueuePlayer doesn't update `currentItem`
        // synchronously after an `insert`, so requiring identity here would skip the preload
        // and the boundary would fall back to a reload (gap).
        guard isGaplessMode, state == .playing, !isCrossfading, !sleepAfterCurrentTrack,
              gaplessPreload == nil, let planned, let current = loadedItem else { return }
        let songID = queue[planned].id
        guard let streamURL = try? streamURLProvider(songID) else { return }
        // Prefer an already-prefetched local file (or an offline download, which
        // streamURLProvider already resolves to a file URL) so the handoff is gap-free.
        let preloadURL = GaplessPreload.preloadURL(stream: streamURL, cached: gaplessPrefetcher.cachedURL(for: songID))
        let item = AVPlayerItem(asset: AVURLAsset(url: preloadURL))
        configureAudioMix?(item) // attach EQ at preload creation, before it plays (W-22 / AUDIO-28)
        guard player.canInsert(item, after: current) else { return }
        player.insert(item, after: current)
        gaplessPreload = (planned, item)
        streamingLog.info("gapless preloaded next → queue index \(planned, privacy: .public)\(preloadURL.isFileURL ? " (local)" : " (stream)")")
        // If the next track is a network stream, prefetch it to disk so we can swap the
        // queued item to a local file before the boundary — zero-gap even on transcoded
        // streams that AVFoundation won't pre-buffer as a queued item.
        if !preloadURL.isFileURL {
            startGaplessPrefetch(songID: songID, streamURL: streamURL, index: planned)
        }
    }

    /// Download the queued next stream to the prefetch cache; when it lands (and it's still
    /// the queued gapless next), swap the streaming item for the local file so the boundary
    /// is a gap-free local handoff.
    private func startGaplessPrefetch(songID: String, streamURL: URL, index: Int) {
        guard !gaplessPrefetcher.isPrefetching(songID) else { return }
        // Respect the user's "Wi-Fi only" preference on metered connections — the streamed
        // handoff still works, it just isn't pre-cached (a small buffer at the seam).
        if !GaplessPreload.shouldPrefetch(wifiOnly: gaplessPrefetchWifiOnly, metered: networkIsMetered()) {
            streamingLog.info("gapless prefetch skipped — metered connection (Wi-Fi only)")
            return
        }
        gaplessPrefetcher.prefetch(songID: songID, from: streamURL, index: index) { [weak self] songID, index, local in
            self?.adoptPrefetchedNext(songID: songID, index: index, localURL: local)
        }
    }

    /// Swap the queued (streaming) gapless-next item for its freshly prefetched local file —
    /// but only if it's still the queued next and we haven't already advanced onto it.
    private func adoptPrefetchedNext(songID: String, index: Int, localURL: URL) {
        guard isGaplessMode, let preload = gaplessPreload, preload.index == index,
              queue.indices.contains(index), queue[index].id == songID,
              player.currentItem !== preload.item, let current = loadedItem else { return }
        let item = AVPlayerItem(asset: AVURLAsset(url: localURL))
        guard player.canInsert(item, after: current) else { return }
        player.remove(preload.item)
        player.insert(item, after: current)
        gaplessPreload = (index, item)
        #if DEBUG
        gaplessLocalSwapCountForTesting += 1
        #endif
        streamingLog.info("gapless preload swapped to local prefetch → zero-gap (index \(index, privacy: .public))")
    }

    /// Cancels any in-flight gapless prefetch downloads (queue cleared / stopped).
    private func cancelGaplessPrefetch() {
        gaplessPrefetcher.cancelAll()
    }

    /// Current size of the gapless prefetch cache on disk, in bytes.
    var gaplessCacheSizeBytes: Int64 { gaplessPrefetcher.cacheSizeBytes }

    /// Empties the gapless prefetch cache. Safe during playback: cancels in-flight
    /// prefetches and drops any queued preload that may point at a file we're deleting, then
    /// rebuilds it from the stream so the next boundary still has something to advance to.
    func clearGaplessCache() {
        cancelGaplessPrefetch()
        if let preload = gaplessPreload {
            player.remove(preload.item)
            gaplessPreload = nil
        }
        gaplessPrefetcher.clearCache()
        preloadGaplessNextIfNeeded()
    }

    /// The OS gaplessly advanced to the preloaded next track — sync our logical state onto
    /// the item already playing (no reload, no re-buffer), then preload the one after it.
    private func gaplessAdvanced(to index: Int, item: AVPlayerItem) {
        guard queue.indices.contains(index) else { return }
        let song = queue[index]
        #if DEBUG
        gaplessAdvanceCountForTesting += 1
        #endif
        streamingLog.info("gapless advance → queue index \(index, privacy: .public) (no reload)")
        // Retire the outgoing item's observers and adopt the new current item's.
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObservation?.invalidate()
        loadedItem = item
        gaplessPreload = nil
        currentIndex = index
        currentTime = 0
        duration = Double(song.duration ?? 0)
        didHandleEnd = false
        scrobbledCurrent = false
        resetFade()
        attachItemObservers(item)
        configureAudioMix?(item)
        applyVolume()
        state = .playing
        notifyTrackStarted(song)
        pushNowPlaying()
        persistQueue()
        extendQueueIfNeeded()
        preloadGaplessNextIfNeeded()
        // Refine duration from the asset when it's actually determinable.
        Task { [weak self] in
            let seconds = await (try? item.asset.load(.duration))?.seconds
            guard let self, let seconds, seconds.isFinite, seconds > 1, self.player.currentItem === item else { return }
            self.duration = seconds
            self.pushNowPlaying()
        }
    }

    /// The genuine end-of-queue stop (autoplay off, or it had nothing more to add).
    private func endOfQueue() {
        currentTime = duration
        state = .idle
        player.pause()
        persistQueue()
        pushNowPlaying()
    }

    /// Prefetch: when the queue is nearly exhausted, append tracks similar to the current
    /// one so playback never hits a hard stop. No-op unless autoplay is on, a provider is
    /// wired, we're within two tracks of the end, not repeating the list, and not already
    /// fetching. Called as tracks load so the top-up lands before the last one ends.
    private func extendQueueIfNeeded() {
        guard autoplayEnabled, relatedProvider != nil, repeatMode == .off,
              !queue.isEmpty, currentIndex >= queue.count - 2, !autoplayFetching else { return }
        fetchRelated(playFirstNew: false)
    }

    /// Fetch "more like the current track" and append (deduped against the queue). With
    /// `playFirstNew`, jump to the first appended track and play it — the end-of-queue
    /// continuation. If nothing comes back on that path, stop for real.
    private func fetchRelated(playFirstNew: Bool) {
        guard let seed = nowPlaying, let relatedProvider, !autoplayFetching else {
            if playFirstNew { endOfQueue() }
            return
        }
        autoplayFetching = true
        let generation = stateGeneration
        Task { [weak self] in
            let more = await relatedProvider(seed)
            guard let self else { return }
            self.autoplayFetching = false
            // Freshness (W-23 / AUDIO-16): a user action may have happened while we were fetching.
            if playFirstNew {
                // The end-of-queue continuation must not yank playback if the user stopped or
                // started something else in the meantime.
                guard self.stateGeneration == generation, self.nowPlaying?.id == seed.id else { return }
            } else {
                // A background top-up is harmless to append, but not onto a queue the user
                // cleared or replaced — so require the seed to still be present.
                guard self.queue.contains(where: { $0.id == seed.id }) else { return }
            }
            let existing = Set(self.queue.map(\.id))
            let fresh = more.filter { !existing.contains($0.id) }
            guard !fresh.isEmpty else {
                if playFirstNew { self.endOfQueue() }
                return
            }
            let firstNew = self.queue.count
            self.queue.append(contentsOf: fresh)
            self.persistQueue()
            if playFirstNew {
                self.currentIndex = firstNew
                self.loadCurrent(autoplay: true)
            } else {
                // Radio top-up landed — the last track now has a gapless "next" to flow into.
                self.preloadGaplessNextIfNeeded()
            }
        }
    }

    /// Wire an item's status (decode/stream failures) + end-of-track notification. Shared
    /// by `loadCurrent` and the crossfade promotion so both paths behave identically.
    private func attachItemObservers(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            // KVO can fire off-main; read Sendable values, then hop to the main actor.
            let status = item.status
            let failureMessage = item.error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    streamingLog.info("stream item ready to play")
                    self.consecutiveFailures = 0
                    self.isBuffering = false
                    if let target = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seek(to: target)
                    }
                case .failed:
                    let message = failureMessage
                        ?? "Playback failed — the track may be an unsupported format (e.g. Ogg/Opus)."
                    streamingLog.error("stream item failed: \(message, privacy: .public)")
                    self.handleLoadFailure(message)
                default:
                    break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnded() }
        }
    }

    // MARK: - Crossfade

    /// From the periodic clock tick: begin a crossfade into the next track when we're
    /// within the crossfade window of the end. No-op when crossfade is off (0s) — the
    /// classic hard-cut end handler runs instead.
    private func maybeStartCrossfade() {
        // A real crossfade window, or neither (classic hard cut / true-gapless handoff).
        // Gapless no longer blends here — the AVQueuePlayer auto-advances the audio itself.
        let window = crossfadeSeconds
        guard state == .playing, !isCrossfading,
              Crossfade.inWindow(currentTime: currentTime, duration: duration, window: window) else { return }
        // Never crossfade a podcast (spoken word) — and crossfading suppresses the outgoing
        // track's end handler, which is a podcast's only played/auto-remove trigger. (W-27 / AUDIO-12)
        if nowPlaying?.isPodcastEpisode == true { return }
        guard case let .play(nextIndex) = Self.onTrackEnd(current: currentIndex, count: queue.count, repeatMode: repeatMode),
              nextIndex != currentIndex, queue.indices.contains(nextIndex) else { return }
        startCrossfade(to: nextIndex, duration: window)
    }

    /// Start the second player on `nextIndex` at silence and ramp the two volumes past
    /// each other over `crossfadeSeconds`, then promote it in `finishCrossfade`.
    private func startCrossfade(to nextIndex: Int, duration seconds: Double) {
        guard let url = try? streamURLProvider(queue[nextIndex].id) else { return }
        isCrossfading = true
        didHandleEnd = true // suppress the outgoing track's normal end handler
        // ...but still report the outgoing track as completed, so its final progress is saved
        // (played-state, download auto-remove) — the suppressed handler was their only trigger.
        // Harmless for music; correctness for any non-podcast that reports progress. (W-27 / AUDIO-12)
        if let outgoing = nowPlaying, duration > 0 { onProgressUpdate?(outgoing, duration, duration) }
        // Attach the EQ tap to the incoming item BEFORE it plays, or the EQ would silently
        // switch off at the first crossfade boundary and stay off for every crossfaded
        // track thereafter. (W-22 / AUDIO-02)
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        configureAudioMix?(item)
        let outgoing = player
        let targetIn = Float(volumePercent) / 100
            * Self.normalizationGain(for: queue[nextIndex], mode: loudnessMode, preampDB: loudnessPreampDB)
        // The collaborator owns the second player + the ramp loop; we promote the incoming player
        // when it hands it back on completion.
        crossfadeRamp.begin(
            item: item, targetIn: targetIn, isMuted: isMuted,
            outgoing: outgoing, startOut: outgoing.volume, duration: seconds
        ) { [weak self] promoted in
            self?.finishCrossfade(to: nextIndex, promoted: promoted, retiring: outgoing)
        }
    }

    /// Retire the outgoing player, promote the crossfade player to `player`, and advance
    /// the queue — the "hard cut" that happens under the cover of the completed fade.
    private func finishCrossfade(to nextIndex: Int, promoted: AVQueuePlayer, retiring: AVQueuePlayer) {
        guard isCrossfading, crossfadeRamp.player === promoted, queue.indices.contains(nextIndex) else { return }
        retiring.pause()
        detachPlayerObservers()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObservation?.invalidate()

        player = promoted
        loadedItem = promoted.currentItem
        gaplessPreload = nil
        crossfadeRamp.clearAfterPromotion() // release the ramp's ref without pausing the now-main player
        isCrossfading = false
        currentIndex = nextIndex
        currentTime = 0
        duration = Double(queue[nextIndex].duration ?? 0)
        didHandleEnd = false
        scrobbledCurrent = false
        attachPlayerObservers()
        if let item = promoted.currentItem { attachItemObservers(item) }
        fadeMultiplier = 1
        applyVolume()
        state = .playing
        notifyTrackStarted(queue[nextIndex])
        pushNowPlaying()
        persistQueue()
        extendQueueIfNeeded()

        if let item = promoted.currentItem {
            Task { [weak self] in
                let seconds = await (try? item.asset.load(.duration))?.seconds
                guard let self, let seconds, seconds.isFinite, seconds > 1, self.player.currentItem === item else { return }
                self.duration = seconds
                self.pushNowPlaying()
            }
        }
    }

    /// Abort an in-flight crossfade (a transport action interrupted it): stop the second
    /// player, restore the current player's volume, and let the action proceed normally.
    func cancelCrossfade() {
        guard isCrossfading else { return }
        isCrossfading = false
        crossfadeRamp.cancel()
        didHandleEnd = false
        applyVolume()
    }

    // MARK: - Persistence (REQ-14)

    /// Snapshot of the queue for cross-launch restore.
    private struct QueueSnapshot: Codable {
        var songs: [NavidromeSong]
        var index: Int
        var position: Double
        var source: QueueSource?
    }

    private func persistQueue() {
        let snapshot = QueueSnapshot(songs: queue, index: currentIndex, position: currentTime, source: queueSource)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.queueKey)
        }
    }

    /// Restores the persisted queue in a **paused** state at the saved position.
    /// Playback never auto-starts on launch. Safe to call once at startup.
    func restoreQueue() {
        guard let data = defaults.data(forKey: Self.queueKey),
              let snapshot = try? JSONDecoder().decode(QueueSnapshot.self, from: data),
              !snapshot.songs.isEmpty
        else { return }
        queue = snapshot.songs
        currentIndex = max(0, min(snapshot.index, snapshot.songs.count - 1))
        queueSource = snapshot.source
        // Defer the seek to when the item reaches `readyToPlay` (see the status
        // observer in `loadCurrent`) instead of racing a fixed delay.
        if snapshot.position > 0 { pendingSeek = snapshot.position }
        loadCurrent(autoplay: false)
    }

    /// A one-line "now playing" summary for the `music_now_playing` tool.
    var nowPlayingSummary: String {
        guard let song = nowPlaying else { return "Nothing is playing." }
        let verb = switch state {
        case .playing: "Playing"
        case .paused: "Paused"
        case .loading: "Loading"
        case .idle: "Stopped"
        case .error: "Error"
        }
        return "\(verb): \(song.displayLine) [\(currentIndex + 1)/\(queue.count)]"
    }
}
