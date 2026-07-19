import AVFoundation
import Foundation
import Observation
import OSLog

private let streamingLog = Logger(subsystem: "io.tonebox.macos", category: "StreamingPlayback")

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
    private(set) var sleepTimerEndsAt: Date?
    /// Sleep-timer variant that pauses when the current track finishes rather than at
    /// a fixed time. Checked in `handleEnded`.
    private(set) var sleepAfterCurrentTrack = false
    private var sleepTimerTask: Task<Void, Never>?

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
    /// Called once per track when it crosses the scrobble threshold (half its length, or
    /// 4 min) — wired to external scrobbling (ListenBrainz).
    @ObservationIgnored var onScrobbleEligible: (@MainActor (NavidromeSong) -> Void)?
    @ObservationIgnored private var scrobbledCurrent = false
    /// Fired when a fixed-time sleep timer elapses (after the fade-out). AppModel wires this to
    /// also stop internet radio, which plays on a separate engine the library pause can't reach.
    @ObservationIgnored var onSleepFire: (@MainActor () -> Void)?
    /// Attaches/detaches the equalizer audio-mix on a freshly-loaded item (AppModel wires
    /// this to the EQ). Nil ⇒ no EQ.
    @ObservationIgnored var configureAudioMix: (@MainActor (AVPlayerItem) -> Void)?

    /// Re-apply the EQ mix to the current item (call when the EQ is toggled on/off).
    func refreshAudioMix() {
        if let item = player.currentItem { configureAudioMix?(item) }
    }
    /// Guards against overlapping autoplay fetches.
    @ObservationIgnored private var autoplayFetching = false

    /// A 0…1 fade envelope multiplied into the output volume — used for the sleep-timer
    /// fade-out (and available for other gentle fades). 1 = no fade.
    @ObservationIgnored private var fadeMultiplier: Float = 1
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

    /// What to do when a track ends, given the repeat mode (pure — unit-tested).
    enum Advance: Equatable { case replay, play(Int), stop }

    static func onTrackEnd(current: Int, count: Int, repeatMode: RepeatMode) -> Advance {
        guard count > 0 else { return .stop }
        switch repeatMode {
        case .one: return .replay
        case .all: return current + 1 < count ? .play(current + 1) : .play(0)
        case .off: return current + 1 < count ? .play(current + 1) : .stop
        }
    }

    /// What a manual Next press does — wraps for .all/.one, stops for .off.
    static func onManualNext(current: Int, count: Int, repeatMode: RepeatMode) -> Advance {
        guard count > 0 else { return .stop }
        if current + 1 < count { return .play(current + 1) }
        return repeatMode == .off ? .stop : .play(0)
    }

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
    /// The second player used only during a crossfade overlap; promoted to `player` when
    /// the fade completes. Nil when not crossfading.
    private var crossfadePlayer: AVQueuePlayer?
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
    #endif

    /// Ephemeral disk cache for prefetched next-track audio (zero-gap on streams).
    @ObservationIgnored private let gaplessCache: MusicGaplessCache
    /// Downloads a network stream URL to a local file for the gapless prefetch. Injectable
    /// for tests; the default streams to `gaplessCache` via `URLSession`.
    @ObservationIgnored private let gaplessPrefetchDownloader: @MainActor (URL, String) async -> URL?
    /// In-flight prefetch tasks keyed by song id (de-dupes + cancelable).
    @ObservationIgnored private var prefetchTasks: [String: Task<Void, Never>] = [:]
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
    @ObservationIgnored private var stateGeneration = 0

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
    @ObservationIgnored private var currentFocus: AudioFocusToken?

    /// The audio-focus token held by the `"capture"` owner (recording/dictation), if the
    /// `suspendForCapture()` wrapper is currently ducking. Backs the legacy
    /// `suspendedForCapture` flag.
    @ObservationIgnored private var captureToken: AudioFocusToken?
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
    /// Crash-recovery record for an active audio-focus duck: the player volume we lowered
    /// FROM, persisted the instant a duck is placed so a crash/force-quit while ducked can
    /// restore the user's level on next launch (mirrors `OutputVolumeController`). Only the
    /// duck case needs recovery — a pause is harmless across a relaunch (the queue restores
    /// paused anyway), but a stranded low *volume* would silently mis-play every future track.
    static let activeSuspendVolumeKey = "tonebox.navidrome.audioFocus.pendingVolume"

    /// Where the queue + volume persist. Production uses `.standard`; under XCTest
    /// it defaults to an isolated suite so tests can NEVER pollute the real app's
    /// stored queue/volume (which once restored a phantom test track on launch).
    private let defaults: UserDefaults

    /// The persistence store to use when none is injected: `.standard` in
    /// production, an isolated suite under XCTest.
    static func defaultStore() -> UserDefaults {
        guard BatonRuntime.isTest else { return .standard }
        return UserDefaults(suiteName: "io.tonebox.tests.music") ?? .standard
    }

    init(
        streamURLProvider: @escaping @MainActor (String) throws -> URL = { songID in
            // Prefer an offline download when present; else stream from the server.
            if let local = MusicDownloadStore.shared.localURL(for: songID) { return local }
            return try NavidromeConfig.makeClient().streamURL(songID: songID)
        },
        coverArtURLProvider: @escaping @MainActor (String) -> URL? = { songID in
            (try? NavidromeConfig.makeClient())?.coverArtURL(id: songID, size: 600)
        },
        defaults: UserDefaults = StreamingPlaybackController.defaultStore(),
        systemNowPlaying: Bool = !BatonRuntime.isTest,
        gaplessCache: MusicGaplessCache? = nil,
        gaplessPrefetchDownloader: (@MainActor (URL, String) async -> URL?)? = nil,
        networkIsMetered: (@MainActor () -> Bool)? = nil
    ) {
        self.networkIsMetered = networkIsMetered ?? { NetworkReachability.shared.isMetered }
        self.streamURLProvider = streamURLProvider
        self.coverArtURLProvider = coverArtURLProvider
        self.defaults = defaults
        self.systemNowPlaying = systemNowPlaying
        let cache = gaplessCache ?? MusicGaplessCache()
        self.gaplessCache = cache
        self.gaplessPrefetchDownloader = gaplessPrefetchDownloader ?? { streamURL, songID in
            // Stream the (transcoded) next track to the ephemeral prefetch cache so the
            // boundary can hand off from a local file — zero-gap even for streams.
            guard let (temp, response) = try? await URLSession.shared.download(from: streamURL),
                  (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? true
            else { return nil }
            return cache.store(tempFile: temp, songID: songID)
        }
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
            MainActor.assumeIsolated {
                switch player.timeControlStatus {
                case .playing:
                    self?.isBuffering = false
                    streamingLog.info("player: audio flowing (rate \(player.rate, privacy: .public))")
                case .waitingToPlayAtSpecifiedRate:
                    // Only "buffering" while we actually intend to play (not paused).
                    self?.isBuffering = (self?.state == .playing)
                    let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
                    streamingLog.error("player: waiting to play — reason \(reason, privacy: .public)")
                case .paused:
                    self?.isBuffering = false
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
                // Fire an external scrobble once the track's been played long enough.
                if !self.scrobbledCurrent, let song = self.nowPlaying, self.duration > 30,
                   self.currentTime >= MusicScrobbler.scrobbleThreshold(duration: self.duration) {
                    self.scrobbledCurrent = true
                    self.onScrobbleEligible?(song)
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
                   self.duration > 1,
                   self.currentTime >= self.duration - 0.35,
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

    /// Wires the macOS Now Playing remote commands to the transport (once).
    private func configureNowPlaying() {
        guard systemNowPlaying else { return }
        nowPlayingCenter.configure(.init(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in
                guard let self else { return }
                self.isPlaying ? self.pause() : self.resume()
            },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] in self?.seek(to: $0) }
        ))
    }

    /// Cached Now Playing artwork URL, resolved once per cover id — the signed cover
    /// URL embeds a fresh salt each build, so recomputing it every push would make the
    /// OS refetch the same image on every pause/seek.
    private var nowPlayingCoverID: String?
    private var nowPlayingCoverURL: URL?

    /// Publishes the current track + transport state to macOS Now Playing.
    private func pushNowPlaying() {
        guard systemNowPlaying else { return }
        let coverID = nowPlaying?.coverArtID
        if coverID != nowPlayingCoverID {
            nowPlayingCoverID = coverID
            nowPlayingCoverURL = coverID.flatMap { coverArtURLProvider($0) }
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
        if player.currentItem == nil || (duration > 1 && currentTime >= duration - 0.35) {
            loadCurrent(autoplay: true)
            return
        }
        player.play()
        state = .playing
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
    private func pauseInternal() {
        cancelCrossfade()
        player.pause()
        if state == .playing { state = .paused }
        pushNowPlaying()
    }

    /// Stops playback cleanly (keeps the queue so it can be restarted / persisted).
    func stop() {
        bumpStateGeneration()
        cancelCrossfade()
        player.pause()
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
            currentIndex = min(currentIndex, max(0, queue.count - 1))
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
        if duration <= 1 || target < duration - 0.35 { didHandleEnd = false }
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
    private func applyVolume() {
        let base = Float(volumePercent) / 100
        let norm = nowPlaying.map { Self.normalizationGain(for: $0, mode: loudnessMode, preampDB: loudnessPreampDB) } ?? 1
        player.volume = base * norm * fadeMultiplier
    }

    /// Ramp the fade envelope to `target` over `duration`, then run `then` (e.g. pause).
    /// Cancels any in-flight fade. Used for the sleep-timer fade-out.
    private func fade(to target: Float, duration: Double, then: (@MainActor () -> Void)? = nil) {
        fadeTask?.cancel()
        let start = fadeMultiplier
        fadeTask = Task { @MainActor [weak self] in
            let steps = 20
            for i in 1 ... steps {
                if Task.isCancelled { return }
                self?.fadeMultiplier = start + (target - start) * Float(i) / Float(steps)
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
    private func resetFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadeMultiplier = 1
        applyVolume()
    }

    /// Linear volume multiplier from a track's ReplayGain (pure, unit-testable). Applies the
    /// chosen gain (track or album) + a pre-amp in dB, clamps by the peak so boosting a quiet
    /// track never clips, and caps the boost. Returns 1 when off or the track has no data —
    /// so a library without ReplayGain tags simply plays at normal volume.
    static func normalizationGain(for song: NavidromeSong, mode: LoudnessMode, preampDB: Double) -> Float {
        guard mode != .off, let rg = song.replayGain else { return 1 }
        let gainDB: Double?
        let peak: Double?
        switch mode {
        case .track: gainDB = rg.trackGain ?? rg.albumGain; peak = rg.trackPeak ?? rg.albumPeak
        case .album: gainDB = rg.albumGain ?? rg.trackGain; peak = rg.albumPeak ?? rg.trackPeak
        case .off: return 1
        }
        guard let gainDB else { return 1 }
        var linear = pow(10.0, (gainDB + preampDB) / 20.0)
        if let peak, peak > 0 { linear = min(linear, 1.0 / peak) } // headroom: never clip
        return Float(min(max(linear, 0), 4)) // cap so a huge boost can't blast the speakers
    }

    // MARK: - Sleep timer

    /// Pauses playback after `minutes` (nil/≤0 cancels). Clears any "after current
    /// track" timer. The countdown is exposed via `sleepTimerEndsAt` for the UI.
    func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        sleepAfterCurrentTrack = false
        guard let minutes, minutes > 0 else {
            sleepTimerEndsAt = nil
            return
        }
        sleepTimerEndsAt = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard let self, !Task.isCancelled else { return }
            // Gentle fade-out over ~5s, then pause. resume()/next track resets the envelope.
            self.fade(to: 0, duration: 5) { [weak self] in
                self?.pause()
                self?.fadeMultiplier = 1
                self?.applyVolume()
                self?.onSleepFire?() // also stop internet radio (separate engine)
            }
            self.sleepTimerEndsAt = nil
        }
    }

    /// Arms a sleep timer that pauses when the current track finishes.
    func sleepAtEndOfTrack() {
        sleepTimerTask?.cancel()
        sleepTimerEndsAt = nil
        sleepAfterCurrentTrack = true
    }

    /// Clears any pending sleep timer (fixed-time or end-of-track). Also aborts an
    /// in-progress fade-out and restores full volume if the timer was mid-fade.
    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
        sleepAfterCurrentTrack = false
        if fadeMultiplier < 1 { resetFade() }
    }

    /// Whether any sleep timer is currently armed.
    var sleepTimerArmed: Bool {
        sleepTimerEndsAt != nil || sleepAfterCurrentTrack
    }

    // MARK: - Audio focus API (owner-token capture coordination, REQ-13)

    /// Acquire audio focus by suspending playback for `owner`. If something is currently
    /// `.playing`, pause it (without registering as a user intervention) and record the
    /// owner + the current `stateGeneration`; otherwise return a token flagged
    /// `didSuspend == false` so its release is a clean no-op.
    ///
    /// Only one owner holds the suspend at a time — **last-writer-wins**: a new acquire
    /// replaces any prior holder, and the older token then releases as a no-op (it's no
    /// longer `currentFocus`). Returns the token to hand back to `releaseAudioFocus(_:)`.
    @discardableResult
    func acquireAudioFocusSuspend(owner: String) -> AudioFocusToken {
        cancelCrossfade()
        // Capture the generation BEFORE our own pause so the internal pause doesn't read
        // back as intervention; pauseInternal() deliberately doesn't bump it either.
        let generation = stateGeneration
        let didSuspend = state == .playing
        if didSuspend { pauseInternal() }
        let token = AudioFocusToken(owner: owner, generation: generation, didSuspend: didSuspend, mode: .pause)
        currentFocus = token
        persistActiveSuspend(token)
        return token
    }

    /// Acquire audio focus by **ducking** the player volume for `owner` — lowering it to
    /// `toPercent` (0–100) instead of pausing, so an assistant can talk over quieted music.
    /// Records the pre-duck `volumePercent` on the token and restores it verbatim on release.
    /// Only ducks when currently `.playing` *and* the target is actually lower than the
    /// present level; otherwise returns a `didSuspend == false` no-op token (release is then
    /// a clean no-op). Like the pause path, it doesn't bump the intervention counter, so a
    /// user's subsequent volume/transport change still cancels the auto-restore.
    @discardableResult
    func acquireAudioFocusDuck(owner: String, toPercent: Int) -> AudioFocusToken {
        cancelCrossfade()
        let generation = stateGeneration
        let target = max(0, min(toPercent, 100))
        let previous = volumePercent
        // Only a genuine downward duck counts as "suspended". Nothing playing, or a target
        // at/above the current level, leaves a clean no-op token.
        let didSuspend = state == .playing && target < previous
        if didSuspend {
            // Lower the persisted `volumePercent` to the target WITHOUT bumping the
            // intervention counter — this is a focus duck, not a user volume change, so a
            // later user volume/transport change still cancels the auto-restore. Persisting
            // the ducked level (rather than only touching AVPlayer.volume) is what makes the
            // duck observable and crash-recoverable: a crash while ducked leaves the stored
            // level low, which `recoverStuckDuckFromPreviousSession()` puts back on relaunch.
            setVolumeForFocus(target)
        }
        let token = AudioFocusToken(
            owner: owner, generation: generation, didSuspend: didSuspend,
            mode: .duck, previousVolumePercent: didSuspend ? previous : nil
        )
        currentFocus = token
        persistActiveSuspend(token)
        return token
    }

    /// Set the player volume for an audio-focus duck/restore without bumping the intervention
    /// counter. Assigns `volumePercent` (which persists + drives `applyVolume()`), so the
    /// change is observable and survives across launches — but skips the user-facing
    /// `setVolume(percent:)` so it doesn't register as user intervention.
    private func setVolumeForFocus(_ percent: Int) {
        volumePercent = max(0, min(percent, 100))
    }

    /// Release audio focus held by `token`, resuming playback **only if** all hold: this is
    /// still the current holder, it actually suspended playback, and the user hasn't touched
    /// the transport since (the live `stateGeneration` still equals the token's). Any manual
    /// play/pause/seek/next/previous/stop in between bumps `stateGeneration` and cancels the
    /// auto-resume. Otherwise this is a no-op. Clears the holder either way.
    /// Returns whether it actually resumed/restored (`true`) or declined as a no-op
    /// (`false`) — the cross-process registry uses this to report an accurate `resumed`
    /// outcome for ducks, whose restore isn't otherwise observable from transport state.
    @discardableResult
    func releaseAudioFocus(_ token: AudioFocusToken) -> Bool {
        guard currentFocus == token else { return false } // stale/superseded token → no-op
        currentFocus = nil
        clearActiveSuspend()
        guard token.didSuspend, stateGeneration == token.generation else { return false }
        switch token.mode {
        case .pause:
            // Only unpause if still paused (user hasn't intervened into another state).
            guard state == .paused else { return false }
            resume()
            return true
        case .duck:
            // Restore the exact pre-duck level, but only if the user hasn't changed the
            // volume/transport since (generation is unchanged, checked above). Route through
            // the focus setter so restoring doesn't itself count as user intervention.
            guard let previous = token.previousVolumePercent else { return false }
            setVolumeForFocus(previous)
            return true
        }
    }

    /// Owner string used by the `suspendForCapture()` / `resumeAfterCapture()` shims.
    private static let captureOwner = "capture"

    /// Pauses music because a recording/dictation session is starting. Thin wrapper over
    /// `acquireAudioFocusSuspend(owner:)` — stores the `"capture"` token so
    /// `resumeAfterCapture()` can restore it. Behaviour is identical to before.
    func suspendForCapture() {
        captureToken = acquireAudioFocusSuspend(owner: Self.captureOwner)
    }

    /// Resumes music after recording/dictation ends — but only if this controller paused it
    /// and the user didn't intervene. Thin wrapper over `releaseAudioFocus(_:)`; idempotent
    /// (a nil / already-released capture token is a clean no-op).
    func resumeAfterCapture() {
        guard let token = captureToken else { return }
        captureToken = nil
        releaseAudioFocus(token)
    }

    // MARK: - Audio-focus crash recovery

    /// Persist the pre-duck volume the moment a ducking focus is placed, so a crash while
    /// ducked can be undone on next launch. Pause-mode focus needs no record (a relaunch
    /// restores the queue paused regardless). Clears any stale record for the pause path.
    private func persistActiveSuspend(_ token: AudioFocusToken) {
        if token.mode == .duck, token.didSuspend, let previous = token.previousVolumePercent {
            defaults.set(previous, forKey: Self.activeSuspendVolumeKey)
        } else {
            defaults.removeObject(forKey: Self.activeSuspendVolumeKey)
        }
    }

    /// Clear the active-suspend record — the focus was released cleanly.
    private func clearActiveSuspend() {
        defaults.removeObject(forKey: Self.activeSuspendVolumeKey)
    }

    /// If a previous run persisted a pending duck volume and never cleared it, that run
    /// died while ducked — restore the user's stored level now. Runs once at launch, before
    /// any new focus is placed, so it can't fight a live duck. Idempotent: clears the record
    /// so a subsequent launch doesn't re-restore.
    func recoverStuckDuckFromPreviousSession() {
        guard defaults.object(forKey: Self.activeSuspendVolumeKey) != nil else { return }
        let previous = defaults.integer(forKey: Self.activeSuspendVolumeKey)
        defaults.removeObject(forKey: Self.activeSuspendVolumeKey)
        // Restore the persisted user level (the queue loads paused, so applyVolume() alone
        // suffices — no need to touch the transport).
        volumePercent = max(0, min(previous, 100))
        streamingLog.error("audio-focus: recovered stranded duck volume → \(previous, privacy: .public)%")
    }

    // MARK: - Loading

    private func loadCurrent(autoplay: Bool) {
        #if DEBUG
        loadCurrentCountForTesting += 1
        #endif
        // A fresh item can end again — clear the end-handled guard.
        didHandleEnd = false
        scrobbledCurrent = false
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
            scrobble(songID: song.id)
            onTrackStarted?(song)
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
        state = .error(message)
        isBuffering = false
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
    #endif

    /// A track finished. Hard-cut to the next queued track, or stop cleanly at the
    /// end of the queue (REQ-10 — stopped, not errored).
    private func handleEnded() {
        // Idempotent per item-end: both the AVPlayerItemDidPlayToEndTime notification and
        // the periodic-observer fallback can fire for the same end — only act once. Cleared
        // when a new item loads or the playhead seeks off the end.
        guard !didHandleEnd else { return }
        didHandleEnd = true

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
        let preloadURL = streamURL.isFileURL ? streamURL : (gaplessCache.localURL(for: songID) ?? streamURL)
        let item = AVPlayerItem(asset: AVURLAsset(url: preloadURL))
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
        guard prefetchTasks[songID] == nil else { return }
        // Respect the user's "Wi-Fi only" preference on metered connections — the streamed
        // handoff still works, it just isn't pre-cached (a small buffer at the seam).
        if gaplessPrefetchWifiOnly, networkIsMetered() {
            streamingLog.info("gapless prefetch skipped — metered connection (Wi-Fi only)")
            return
        }
        let downloader = gaplessPrefetchDownloader
        prefetchTasks[songID] = Task { @MainActor [weak self] in
            let local = await downloader(streamURL, songID)
            guard let self else { return }
            self.prefetchTasks[songID] = nil
            guard let local else { return }
            self.adoptPrefetchedNext(songID: songID, index: index, localURL: local)
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
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
    }

    /// Current size of the gapless prefetch cache on disk, in bytes.
    var gaplessCacheSizeBytes: Int64 { gaplessCache.sizeBytes() }

    /// Empties the gapless prefetch cache. Safe during playback: cancels in-flight
    /// prefetches and drops any queued preload that may point at a file we're deleting, then
    /// rebuilds it from the stream so the next boundary still has something to advance to.
    func clearGaplessCache() {
        cancelGaplessPrefetch()
        if let preload = gaplessPreload {
            player.remove(preload.item)
            gaplessPreload = nil
        }
        gaplessCache.clear()
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
        scrobble(songID: song.id)
        onTrackStarted?(song)
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
        Task { [weak self] in
            let more = await relatedProvider(seed)
            guard let self else { return }
            self.autoplayFetching = false
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
            MainActor.assumeIsolated {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    streamingLog.info("stream item ready to play")
                    self.consecutiveFailures = 0
                    self.isBuffering = false
                    if let target = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seek(to: target)
                    }
                case .failed:
                    let message = item.error?.localizedDescription
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
        guard window > 0, state == .playing, !isCrossfading,
              duration > window + 1, currentTime >= duration - window else { return }
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
        let next = AVQueuePlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        next.isMuted = isMuted
        next.volume = 0
        next.play()
        crossfadePlayer = next
        let outgoing = player
        let startOut = outgoing.volume
        let targetIn = Float(volumePercent) / 100
            * Self.normalizationGain(for: queue[nextIndex], mode: loudnessMode, preampDB: loudnessPreampDB)
        Task { @MainActor [weak self] in
            let steps = 24
            for i in 1 ... steps {
                guard let self, self.isCrossfading, self.crossfadePlayer === next else { return }
                let t = Float(i) / Float(steps)
                outgoing.volume = startOut * (1 - t)
                next.volume = targetIn * t
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
            }
            self?.finishCrossfade(to: nextIndex, promoted: next, retiring: outgoing)
        }
    }

    /// Retire the outgoing player, promote the crossfade player to `player`, and advance
    /// the queue — the "hard cut" that happens under the cover of the completed fade.
    private func finishCrossfade(to nextIndex: Int, promoted: AVQueuePlayer, retiring: AVQueuePlayer) {
        guard isCrossfading, crossfadePlayer === promoted, queue.indices.contains(nextIndex) else { return }
        retiring.pause()
        detachPlayerObservers()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObservation?.invalidate()

        player = promoted
        loadedItem = promoted.currentItem
        gaplessPreload = nil
        crossfadePlayer = nil
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
        scrobble(songID: queue[nextIndex].id)
        onTrackStarted?(queue[nextIndex])
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
    private func cancelCrossfade() {
        guard isCrossfading else { return }
        isCrossfading = false
        crossfadePlayer?.pause()
        crossfadePlayer = nil
        didHandleEnd = false
        applyVolume()
    }

    /// Best-effort scrobble on track start — feeds the server's play counts and
    /// "Recently/Most played". Never blocks or affects playback; skipped under test.
    private func scrobble(songID: String) {
        guard !BatonRuntime.isTest else { return }
        Task.detached { try? await NavidromeConfig.makeClient().scrobble(id: songID) }
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
