import AVFoundation
import Foundation
import Observation
import OSLog
import BatonSubsonicKit
import BatonSubsonicModels

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
public final class StreamingPlaybackController {
    public enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case error(String)
    }

    public private(set) var state: State = .idle

    /// A brief, user-facing confirmation for a music action (Add to Queue, Play Next,
    /// Download…), shown as a toast by the Music UI. A fresh `id` on every post makes the
    /// toast re-trigger even when the text repeats. Set via `postToast`.
    public struct Toast: Equatable, Identifiable {
        public let id = UUID()
        public let text: String
        public let symbol: String
        /// How long the UI holds it. Confirmations ("Added to queue") are glanceable, but a
        /// failure now carries a diagnosis ("HTTP 401 · missing bearer token") that can't be read
        /// in the default beat — so callers reporting an error ask for longer.
        public var seconds: Double = 1.9
    }

    public private(set) var toast: Toast?

    /// Post a transient confirmation toast (auto-dismissed by the UI). Call from the main
    /// actor; several actions across the browse rows funnel their feedback through here so
    /// there's always a visible response even when the queue popover isn't open.
    public func postToast(
        _ text: String,
        symbol: String = "checkmark.circle.fill",
        seconds: Double = 1.9
    ) {
        toast = Toast(text: text, symbol: symbol, seconds: seconds)
    }

    /// Ordered play queue. Persisted across launches.
    public private(set) var queue: [NavidromeSong] = []
    /// Index of the current track within `queue` (valid only when non-empty).
    public private(set) var currentIndex: Int = 0
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    /// True while an async `seek(to:)` is in flight — makes the periodic clock observer
    /// skip its update so it can't snap the scrubber back before the seek lands.
    @ObservationIgnored private var isSeeking = false
    /// Stamps each seek so only the newest one's completion clears `isSeeking`.
    @ObservationIgnored private var seekGeneration = 0

    /// How many seconds into the track the current stream *begins*, when it was fetched with
    /// Subsonic `timeOffset` to reach a position a still-encoding transcode couldn't seek to
    /// (see `StreamSeek`). The player's clock restarts at zero for such a stream, so every
    /// track-logical reading is `streamStartOffset + player clock`. Zero for a normal load.
    @ObservationIgnored private var streamStartOffset: TimeInterval = 0

    /// Seconds of audio that have actually **played** for the current track.
    ///
    /// Not the playhead: seeking forward doesn't listen to what it skipped, and seeking back
    /// re-listens. Accumulated from the clock observer, counting only small forward steps, so a
    /// seek contributes nothing. This is the one number that says whether a track was really
    /// listened to — everything derivable from the server's log measures bytes delivered, and a
    /// long track buffers completely within minutes however briefly you stay.
    @ObservationIgnored private var listenedSeconds: TimeInterval = 0
    /// The clock reading at the previous observer tick, to difference against.
    @ObservationIgnored private var lastClockSample: TimeInterval?
    /// A gap larger than this between ticks is a seek or a stall, not listening. The observer
    /// fires every 0.25 s, so this is generous while still excluding any real jump.
    public static let maxListenStep: TimeInterval = 2.0

    /// The track `listenedSeconds` is being accumulated for, with its length — held separately
    /// because the report is emitted *after* `nowPlaying` has already moved on.
    @ObservationIgnored private var listeningTrack: (song: NavidromeSong, duration: TimeInterval)?

    /// Emitted when a track is left, with how much of it actually played. The honest answer to
    /// "did you listen to this", which nothing derived from the server's access log can give.
    public var onListenFinished: ((NavidromeSong, TimeInterval, TimeInterval) -> Void)?

    /// Close out the current track's listening record and start a fresh one for `song`.
    private func rotateListenRecord(to song: NavidromeSong?) {
        if let previous = listeningTrack, listenedSeconds >= 1 {
            onListenFinished?(previous.song, listenedSeconds, previous.duration)
        }
        listenedSeconds = 0
        lastClockSample = nil
        listeningTrack = song.map { ($0, Double($0.duration ?? 0)) }
    }

    /// How many times an early end-of-stream has been refused and re-requested for this track.
    /// Bounded, because the refusal is a *diagnosis* — a genuinely truncated or unreadable file
    /// also ends early, and retrying that forever would wedge the queue on it rather than moving
    /// on. Past the cap the end is taken at face value. Reset by any genuine new track.
    @ObservationIgnored private var spuriousEndRecoveries = 0
    public static let maxSpuriousEndRecoveries = 3

    /// True while the transport intends to play but audio isn't flowing yet — a
    /// buffering/stall signal derived from `AVPlayer.timeControlStatus`. Drives the
    /// spinner in the now-playing surfaces so a cold stream doesn't look frozen.
    public private(set) var isBuffering = false

    /// Muted independently of `volumePercent` (the slider still shows the level).
    /// Raising the volume unmutes.
    public private(set) var isMuted = false

    /// When set, playback pauses at this instant (sleep timer). Exposed so the UI can
    /// show a live countdown; the actual pause is driven by `sleepTimerTask`.
    public var sleepTimerEndsAt: Date?
    /// Sleep-timer variant that pauses when the current track finishes rather than at
    /// a fixed time. Checked in `handleEnded`.
    public var sleepAfterCurrentTrack = false
    public var sleepTimerTask: Task<Void, Never>?

    /// Repeat mode: off (stop at end), all (loop the queue), one (replay track).
    public private(set) var repeatMode: RepeatMode = .off
    /// Whether shuffle is on. Toggling saves/restores the pre-shuffle order.
    public private(set) var isShuffled = false
    private var orderBeforeShuffle: [NavidromeSong]?

    /// Continuous radio: when the queue is about to run dry, auto-append tracks similar to
    /// the current one so playback keeps going instead of stopping. Persisted. Has no
    /// effect unless `relatedProvider` is wired (AppModel does that).
    public var autoplayEnabled: Bool = false {
        didSet {
            guard autoplayEnabled != oldValue else { return }
            defaults.set(autoplayEnabled, forKey: Self.autoplayKey)
            if autoplayEnabled { extendQueueIfNeeded() } // top up immediately if near the end
        }
    }
    /// Injected "more like this" fetcher, wired to the library by AppModel. Nil ⇒ autoplay
    /// can't extend (the toggle still persists, it just does nothing until wired).
    @ObservationIgnored public var relatedProvider: (@MainActor (NavidromeSong) async -> [NavidromeSong])?
    /// Called when a track actually starts playing — wired to the play-history log.
    @ObservationIgnored public var onTrackStarted: (@MainActor (NavidromeSong) -> Void)?
    /// Called after playback pauses (user, remote command, or interruption) — wired to
    /// the cross-device handoff saver so a paused queue is immediately continuable elsewhere.
    @ObservationIgnored public var onPause: (@MainActor () -> Void)?
    /// Injected resume-offset lookup (podcasts). When it returns a value for the starting
    /// track, playback seeks there once the item is ready. Nil ⇒ always start at 0.
    @ObservationIgnored public var resumeOffsetProvider: (@MainActor (NavidromeSong) -> TimeInterval?)?
    /// Called periodically (~every 5 s) and at track end with the current position/duration —
    /// wired to `PodcastProgressStore` so episodes are resumable and get marked played.
    @ObservationIgnored public var onProgressUpdate: (@MainActor (_ song: NavidromeSong, _ time: TimeInterval, _ duration: TimeInterval) -> Void)?
    /// Called once per track when it crosses the scrobble threshold (half its length, or 4 min),
    /// with the wall-clock time the track *started* — wired to `ScrobbleService`. The start time
    /// (not "now") is the canonical scrobble timestamp Last.fm/ListenBrainz expect.
    @ObservationIgnored public var onScrobbleEligible: (@MainActor (NavidromeSong, Date) -> Void)?
    @ObservationIgnored private var scrobbledCurrent = false
    /// Wall-clock time the current track began — captured at every start path so a threshold
    /// scrobble (or a later offline retry) reports when playback actually started.
    @ObservationIgnored private var currentTrackStartedAt = Date()
    /// Fired when a fixed-time sleep timer elapses (after the fade-out). AppModel wires this to
    /// also stop internet radio, which plays on a separate engine the library pause can't reach.
    @ObservationIgnored public var onSleepFire: (@MainActor () -> Void)?
    /// Attaches/detaches the equalizer audio-mix on a freshly-loaded item (AppModel wires
    /// this to the EQ). Nil ⇒ no EQ.
    @ObservationIgnored public var configureAudioMix: (@MainActor (AVPlayerItem) -> Void)?

    /// Re-apply the EQ mix to the current item (call when the EQ is toggled on/off).
    public func refreshAudioMix() {
        // Engine deck: the EQ is a node in the graph, toggled live with no reload —
        // MusicModel pushes band/enable changes straight to the deck.
        if engineOwnsPlayback { return }
        guard nowPlaying != nil, player.currentItem != nil else { return }
        // AVFoundation binds an item's audioMix (the EQ tap) when the item starts playing, NOT when
        // it's reassigned on a live item — so toggling the EQ on/off had no audible effect on the
        // current track. Reload the current track at its position so the tap attaches (EQ on) or
        // drops (EQ off) immediately. A no-op reassign suffices only when nothing is loaded.
        // (EQ live-toggle fix)
        let wasPlaying = state == .playing
        // Fetch from the current position rather than loading at 0 and seeking back: on a
        // transcode the server is still encoding, a seek to the playhead is exactly the seek that
        // can't land (see `StreamSeek`), so an EQ toggle mid-set would restart the track.
        // A continuation, not a new play — the listener never left the track.
        loadCurrent(autoplay: wasPlaying, startingAt: currentTime, isContinuation: true)
    }
    /// Guards against overlapping autoplay fetches.
    @ObservationIgnored private var autoplayFetching = false

    /// A 0…1 fade envelope multiplied into the output volume — used for the sleep-timer
    /// fade-out (and available for other gentle fades). 1 = no fade.
    @ObservationIgnored public var fadeMultiplier: Float = 1
    @ObservationIgnored private var fadeTask: Task<Void, Never>?

    /// Track-to-track loudness normalization using the server's ReplayGain/R128 data —
    /// applied as a per-track volume multiplier (no DSP, no latency). Persisted.
    public var loudnessMode: LoudnessMode = .off {
        didSet {
            guard loudnessMode != oldValue else { return }
            defaults.set(loudnessMode.rawValue, forKey: Self.loudnessKey)
            applyVolume()
        }
    }
    /// Extra pre-amp on top of the ReplayGain adjustment, in dB. Persisted.
    public var loudnessPreampDB: Double = 0 {
        didSet {
            guard loudnessPreampDB != oldValue else { return }
            defaults.set(loudnessPreampDB, forKey: Self.loudnessPreampKey)
            applyVolume()
        }
    }
    /// Crossfade duration between tracks, in seconds. 0 = a classic hard cut (unchanged
    /// behavior); >0 overlaps the outgoing and incoming track. Persisted.
    public var crossfadeSeconds: Double = 0 {
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
    public var gaplessEnabled: Bool = false {
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
    public var gaplessPrefetchWifiOnly: Bool = false {
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
    public var duckPercent: Int = 20 {
        didSet {
            let clamped = max(0, min(duckPercent, 100))
            if clamped != duckPercent { duckPercent = clamped; return }
            guard duckPercent != oldValue else { return }
            defaults.set(duckPercent, forKey: Self.duckKey)
        }
    }

    public enum RepeatMode: String, CaseIterable { case off, all, one }

    public enum LoudnessMode: String, CaseIterable, Identifiable {
        case off, track, album
        public var id: String { rawValue }
        public var label: String {
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
    public struct QueueSource: Equatable, Codable, Sendable {
        public var label: String
        public var kind: Kind
        /// Source entity id when applicable (e.g. a playlist id) — lets the grid
        /// highlight the playing playlist.
        public var id: String?

        public init(label: String, kind: Kind, id: String? = nil) {
            self.label = label
            self.kind = kind
            self.id = id
        }

        public enum Kind: String, Codable, Sendable { case playlist, album, artist, radio, search, liked, song, folder }

        public var icon: String {
            switch kind {
            case .playlist: "music.note.list"
            case .album: "square.stack"
            case .artist: "music.mic"
            case .radio: "dot.radiowaves.left.and.right"
            case .search: "magnifyingglass"
            case .liked: "heart.fill"
            case .song: "music.note"
            case .folder: "folder"
            }
        }
    }

    /// The current queue's origin, if known. Set by `play(_:source:)`.
    public private(set) var queueSource: QueueSource?

    // Queue-advance decision logic (the pure `Advance` enum + `onTrackEnd`/`onManualNext`) lives
    // in StreamingPlaybackController+Advance.swift — first extraction of the  decomposition.

    /// Player volume as a percentage 0–100. Mapped to `AVPlayer.volume` (0…1).
    /// Persisted; does NOT move the macOS system output volume.
    /// Playback speed (0.5×–2×), primarily for podcasts. Applied through
    /// `AVPlayer.defaultRate` so pause/resume and gapless item advances keep the
    /// chosen speed instead of snapping back to 1×.
    public var playbackRate: Float = 1.0 {
        didSet {
            let clamped = min(2.0, max(0.5, playbackRate))
            if playbackRate != clamped { playbackRate = clamped; return }
            player.defaultRate = clamped
            if isPlaying { player.rate = clamped }
            if engineOwnsPlayback { engineDeck?.setPlaybackRate(clamped) }
        }
    }

    public var volumePercent: Int = 70 {
        didSet {
            let clamped = max(0, min(volumePercent, 100))
            if clamped != volumePercent { volumePercent = clamped; return }
            applyVolume()
            defaults.set(clamped, forKey: Self.volumeKey)
        }
    }

    /// The track playing (or paused/loaded) right now, if any.
    public var nowPlaying: NavidromeSong? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    public var isPlaying: Bool {
        state == .playing
    }

    // MARK: - Internals

    /// `AVQueuePlayer` (an `AVPlayer` subclass, so seek/volume/observers all work) so that
    /// true **gapless** playback can preload the next item and let the OS auto-advance
    /// with no gap. Non-gapless paths keep exactly one item queued at a time.
    private var player = AVQueuePlayer()

    // MARK: - Experimental engine deck (feat/audio-engine)

    /// The pluggable AVAudioEngine deck (docs/audio-engine-rearchitecture.md §6, stage 1).
    /// When attached, **library stream tracks** play through it — EQ and live metering on
    /// streams, in-spool + `timeOffset` seeks — while podcasts, local files, and radio
    /// stay on AVPlayer. All queue/focus/scrobble policy in this type is unchanged; the
    /// deck is only ever the thing that renders audio. Nil in production by default.
    @ObservationIgnored private var engineDeck: EngineDeckBridge?
    /// True while the *current* track is playing on the engine deck — the routing flag
    /// every transport verb consults. False the moment a non-routable track loads.
    @ObservationIgnored private var engineOwnsPlayback = false {
        didSet {
            guard engineOwnsPlayback != oldValue else { return }
            // Metering follows ownership, and it does so here rather than at the five
            // places that assign this flag — the lesson of every engine bug found by ear
            // so far is that a rule spread across call sites is a rule that will be missed
            // at one of them.
            //
            // The render tap was installed once by each host and never removed
            // (`stopMetering` had a single caller, `shutdown()`, which production never
            // runs), so it analysed whatever the graph rendered — silence included — forty
            // times a second for the life of the process, whether or not the engine was
            // playing anything.
            if engineOwnsPlayback {
                engineDeck?.resumeMetering()
            } else {
                engineDeck?.suspendMetering()
            }
        }
    }
    #if DEBUG
    public var engineOwnsPlaybackForTesting: Bool { engineOwnsPlayback }
    #endif

    /// Builds the deck the first time a track genuinely wants it, for hosts that cannot
    /// build one at launch.
    ///
    /// The Mac attaches its deck in the composition root and never needs this. The phone
    /// does: an `AVAudioEngine` cannot start until the `AVAudioSession` is active, and
    /// activating the session at launch interrupts whatever the user is already listening
    /// to — Spotify, a podcast — before they have asked Baton for anything. Those two
    /// rules are in direct conflict, and a provider is what resolves them: the phone hands
    /// over a closure, and it runs at the first moment a routable track is about to play,
    /// which is precisely when activating the session is warranted.
    ///
    /// Called at most once. A provider that returns nil (no output, engine refused to
    /// start) is not retried — the host silently keeps AVPlayer, which is the correct
    /// degradation and matches what the Mac does with a failed `deviceBridge()`.
    @ObservationIgnored public var engineDeckProvider: (@MainActor () -> EngineDeckBridge?)?
    @ObservationIgnored private var engineDeckResolved = false

    /// The deck, building it on first demand. Call *after* establishing that the track is
    /// engine-routable, never before: resolving eagerly would spin up an audio engine to
    /// play a podcast, and on the phone would activate the audio session to do it.
    private func resolveEngineDeck() -> EngineDeckBridge? {
        if let engineDeck { return engineDeck }
        guard !engineDeckResolved, let provider = engineDeckProvider else { return nil }
        engineDeckResolved = true
        guard let deck = provider() else { return nil }
        attachEngineDeck(deck)
        return engineDeck
    }

    #if DEBUG
    /// The lazy-resolution rules (once only, nil is final, detach re-arms) decide whether
    /// the phone plays with an equalizer or silently without one, and they are not
    /// observable from outside without driving real audio. Exposed for tests only.
    @discardableResult
    public func resolveEngineDeckForTesting() -> EngineDeckBridge? { resolveEngineDeck() }
    #endif

    /// Move the track that is already playing onto whichever deck now applies.
    ///
    /// Without this, attaching or detaching the deck only affects the *next* track, so a
    /// host that flips its experimental setting mid-listen appears to do nothing at all —
    /// which is exactly how the iPhone shipped: the toggle promised it would take effect on
    /// the next track and in fact took effect on the next *launch*, so switching equalizer
    /// presets stayed silent and looked like a broken equalizer rather than an inert switch.
    ///
    /// Reloads at the playhead as a continuation, the same way `refreshAudioMix` does for
    /// the EQ tap — fetching from the current position rather than restarting, because on a
    /// cold transcode a seek back to the playhead is precisely the seek that cannot land.
    public func reloadCurrentTrackForDeckChange() {
        guard nowPlaying != nil else { return }
        loadCurrent(autoplay: state == .playing, startingAt: currentTime, isContinuation: true)
    }

    /// Attach (or detach, with nil) the experimental engine deck. Wired here, in the main
    /// file, because the deck's callbacks need this type's private clock/scrobble state —
    /// they ARE the periodic-observer body for engine-owned tracks.
    public func attachEngineDeck(_ deck: EngineDeckBridge?) {
        if deck == nil, engineOwnsPlayback { engineDeck?.stop(); engineOwnsPlayback = false }
        // Detaching re-arms the provider. iOS media-services reset leaves every audio
        // object dead, and recovery is exactly "throw this deck away and let the next
        // track build a new one" — which a one-shot latch would refuse to do, leaving the
        // phone silently on AVPlayer until relaunch.
        if deck == nil { engineDeckResolved = false }
        engineDeck = deck
        // The user's stall timeout is a setting; it was inert whenever the engine owned
        // playback, because nothing carried it across the bridge.
        deck?.setStallTimeout(stallTimeoutSeconds)
        guard let deck else { return }
        deck.onClock = { [weak self] time, engineDuration, buffering in
            guard let self, engineOwnsPlayback else { return }
            // A host-side seek holds the scrubber at the target until the engine's clock
            // reaches it — the same snap-back guard the AVPlayer path gets from its seek
            // completion, expressed against the engine's authoritative clock.
            if isSeeking {
                guard abs(time - currentTime) < 1.0 else { return }
                isSeeking = false
            }
            currentTime = time
            if engineDuration > 1, abs(engineDuration - duration) > 1 { duration = engineDuration }
            isBuffering = buffering && state == .playing
            // The periodic-observer essentials, so an engine-owned track scrobbles,
            // saves progress, and persists exactly like an AVPlayer one.
            if let previous = lastClockSample {
                let step = time - previous
                if step > 0, step <= Self.maxListenStep { listenedSeconds += step }
            }
            lastClockSample = time
            if let song = nowPlaying, duration > 1, abs(currentTime - lastProgressSaveTime) >= 5 {
                lastProgressSaveTime = currentTime
                onProgressUpdate?(song, currentTime, duration)
            }
            if duration > 1, abs(currentTime - lastQueuePersistTime) >= 15 {
                lastQueuePersistTime = currentTime
                persistQueue()
            }
            if !scrobbledCurrent, let song = nowPlaying, duration > 30,
               currentTime >= MusicScrobbler.scrobbleThreshold(duration: duration) {
                scrobbledCurrent = true
                onScrobbleEligible?(song, currentTrackStartedAt)
            }
        }
        deck.onEnded = { [weak self] in
            guard let self, engineOwnsPlayback else { return }
            // The engine already refused any spurious early EOF itself (its own bounded
            // re-request ladder), so this end is genuine by construction.
            currentTime = duration
            handleEnded()
        }
        deck.onFailure = { [weak self] message in
            guard let self, engineOwnsPlayback else { return }
            handleLoadFailure(message)
        }
    }
    private var endObserver: (any NSObjectProtocol)?
    /// The item we consider "current" — compared against `player.currentItem` to detect a
    /// gapless auto-advance (the OS moved to the preloaded next track on its own).
    private var loadedItem: AVPlayerItem?
    /// The preloaded next item + its queue index (gapless mode only). Nil when nothing is
    /// queued ahead. Inserted into the `AVQueuePlayer` so the OS auto-advances with no gap;
    /// `handleEnded` reconciles our logical state once the outgoing item's end fires.
    private var gaplessPreload: (index: Int, item: AVPlayerItem)?
    /// Owns the second player + volume ramp during a crossfade overlap; its player is promoted to
    /// `player` in `finishCrossfade` when the fade completes.
    /// Shapes the player's own volume around pause/stop/resume so transport actions don't
    /// click. Distinct from `crossfadeRamp`, which overlaps two players at a track boundary.
    private let transportFade = TransportFade()
    private let crossfadeRamp = CrossfadeRamp()
    private var isCrossfading = false

    // Test seams for the crossfade leak. The bug lived precisely in these two disagreeing,
    // so a test has to be able to put them out of step deliberately — that state is
    // otherwise only reachable through a timing race nobody can stage on demand.
    var crossfadeRampForTesting: CrossfadeRamp { crossfadeRamp }
    var isCrossfadingForTesting: Bool { isCrossfading }
    func setCrossfadingForTesting(_ value: Bool) { isCrossfading = value }

    /// True when true-gapless is active: gapless toggle on and no crossfade set (a nonzero
    /// crossfade takes over the transition instead).
    private var isGaplessMode: Bool { gaplessEnabled && crossfadeSeconds < 0.05 }
    /// Periodic observer on the player clock — updates `currentTime` smoothly (~4 Hz)
    /// while audio flows. Replaces the old manual poll loop.
    private var timeObserverToken: Any?
    /// Stalled-stream auto-recovery bookkeeping (see +StallRecovery). Reset per track.
    var stallPolicy = StallRecoveryPolicy()
    /// A position to seek to once the current item reaches `readyToPlay` — used to
    /// restore a persisted playhead without racing a fixed delay.
    private var pendingSeek: TimeInterval?
    /// Consecutive stream-load failures; guards the auto-skip so an all-unplayable
    /// queue can't loop forever.
    private var consecutiveFailures = 0
    /// Retries of the CURRENT track before giving up and skipping — a brief network blip
    /// shouldn't skip the track (let alone cascade through the queue). Reset on a genuine
    /// track change / successful load.
    private var sameTrackRetries = 0
    public static let maxSameTrackRetries = 3
    /// Watchdog for a mid-stream buffering STALL. AVPlayer's `automaticallyWaitsToMinimizeStalling`
    /// waits *indefinitely* on a slow-but-open connection — the classic symptom behind a corporate
    /// proxy / TLS-inspection middlebox or a high-latency, jittery link — so the UI shows an endless
    /// spinner and never recovers. When the player sits in `waitingToPlayAtSpecifiedRate` while we
    /// intend to play, we arm this; if it's still stalled after `stallTimeout` we route into the same
    /// `handleLoadFailure` ladder a hard failure uses (same-track retry preserving the playhead, then
    /// skip). Cancelled the instant audio flows or we pause/stop.
    private var stallWatchdog: Task<Void, Never>?
    /// How long the player may sit buffering before we treat it as a stall and recover (see
    /// `stallWatchdog`). User-configurable in Settings → Playback and clamped to a sane range:
    /// generous by default so a legitimately slow connection still fills its buffer, but low enough
    /// that a blocked one recovers promptly. A retry preserves the playhead, so even a premature fire
    /// just resumes in place. Persisted.
    public var stallTimeoutSeconds: Double = 20 {
        didSet {
            let clamped = min(max(stallTimeoutSeconds, Self.minStallTimeout), Self.maxStallTimeout)
            if clamped != stallTimeoutSeconds { stallTimeoutSeconds = clamped; return }
            guard stallTimeoutSeconds != oldValue else { return }
            engineDeck?.setStallTimeout(stallTimeoutSeconds)
            defaults.set(stallTimeoutSeconds, forKey: Self.stallTimeoutKey)
        }
    }
    public static let defaultStallTimeout: Double = 20
    public static let minStallTimeout: Double = 5
    public static let maxStallTimeout: Double = 120
    /// True once the current track's end has been handled — de-dupes the end notification
    /// and the periodic-observer fallback. Reset on load / seek-off-end.
    private var didHandleEnd = false

    #if DEBUG
    /// Test instrumentation: counts how a track boundary was crossed so an integration
    /// test can prove it was truly gapless. A gapless boundary increments
    /// `gaplessAdvanceCountForTesting` (state reconciled onto the already-playing preloaded
    /// item — no reload); a hard reload increments `loadCurrentCountForTesting`.
    public private(set) var gaplessAdvanceCountForTesting = 0
    public private(set) var loadCurrentCountForTesting = 0
    /// Counts how many times the queued gapless-next stream item was swapped for a local
    /// prefetched file (the zero-gap-on-streams path).
    public private(set) var gaplessLocalSwapCountForTesting = 0
    /// Exposes the private true-gapless-active predicate so a test can assert the
    /// gapless ⊕ crossfade mutual-exclusivity invariant (F3 — the audiophile crown
    /// jewels must never silently regress).
    public var isGaplessModeForTesting: Bool { isGaplessMode }
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
    @ObservationIgnored public var stateGeneration = 0

    /// Bump the intervention counter. Call from genuine user/external transport actions.
    private func bumpStateGeneration() { stateGeneration &+= 1 }

    /// Monotonic seek counter, exposed so observers (e.g. the MCP now-playing
    /// notification) can detect a seek on the *current* track — which changes neither
    /// state, track id, nor queue index and would otherwise be invisible.
    public var seekMarker: Int { seekGeneration }

    /// A one-shot claim on "pause the player for me, resume it when I'm done — but only if
    /// nothing else touched the transport in between". Handed out by
    /// `acquireAudioFocusSuspend(owner:)` and redeemed by `releaseAudioFocus(_:)`.
    /// Prepares the player for cross-process control (a separate app can duck for owner X
    /// and resume only if X ducked and the user didn't intervene).
    public struct AudioFocusToken: Equatable {
        public let owner: String
        /// The `stateGeneration` captured at suspend time — release compares against the
        /// live counter to detect intervening user transport changes.
        public let generation: Int
        /// Whether the acquire actually took effect (paused, or ducked from a higher level).
        /// False ⇒ nothing to undo, so release is a clean no-op.
        public let didSuspend: Bool
        /// How the acquire suspended: paused the transport, or ducked the player volume.
        /// Release undoes the matching action (unpause vs. restore volume).
        public var mode: Mode = .pause
        /// For `mode == .duck`, the `volumePercent` in effect *before* the duck — restored
        /// verbatim on release. Nil for pause.
        public var previousVolumePercent: Int?

        public enum Mode: String, Equatable, Sendable { case pause, duck }
    }

    /// The single current audio-focus holder, if any. Last-writer-wins: a new
    /// `acquireAudioFocusSuspend` replaces any prior holder (the older token then releases
    /// as a no-op, since it's no longer `currentFocus`).
    @ObservationIgnored public var currentFocus: AudioFocusToken?

    /// The audio-focus token held by the `"capture"` owner (recording/dictation), if the
    /// `suspendForCapture()` wrapper is currently ducking. Backs the legacy
    /// `suspendedForCapture` flag.
    @ObservationIgnored public var captureToken: AudioFocusToken?
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

    /// Annotate a stream request with where the track was played *from*.
    ///
    /// Subsonic servers ignore query parameters they don't know, so this rides along
    /// harmlessly — but it lands in the server's access log, which is the only place the
    /// provenance of a play can be recorded. Without it, "this track was played" is all
    /// anyone downstream can know: a track appearing in two playlists is indistinguishable
    /// between them, so any judgement about whether a *playlist* works has to be inferred
    /// from membership rather than observed.
    ///
    /// Deliberately coarse — kind and id, never a title. It is a log line, not telemetry:
    /// nothing here says anything a listening history doesn't already.
    public nonisolated static func annotate(_ url: URL, with source: QueueSource?) -> URL {
        guard let source,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var value = source.kind.rawValue
        if let id = source.id, !id.isEmpty { value += ":" + id }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "playedFrom", value: value)]
        return parts.url ?? url
    }

    /// Marks a stream request as a **prefetch** — audio fetched ahead of time so a track boundary
    /// is gap-free, which nobody has heard and may never hear.
    ///
    /// Without this a preload is indistinguishable from a play in the server's access log: same
    /// URL, same `playedFrom`, and it downloads the whole file, so anything counting plays from
    /// the log counts it as a complete listen. That was measurably corrupting the listening
    /// signal — two different tracks "completed" one second apart, which is a preload, not a
    /// listen. Subsonic servers ignore unknown query parameters, so this rides along harmlessly
    /// and lets the log tell the two apart.
    public nonisolated static func markPrefetch(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "prefetch" }
            + [URLQueryItem(name: "prefetch", value: "1")]
        return parts.url ?? url
    }

    /// The stream URL for `songID`, carrying the current queue's provenance.
    ///
    /// `startingAt` asks the server for the stream from that point (Subsonic `timeOffset`), which
    /// is the only way to reach a position in a transcode the server is still encoding — see
    /// `StreamSeek`. A natively-decodable track skips the transcode entirely, so it arrives
    /// byte-range seekable from the first play and never needs the offset dance at all.
    private func annotatedStreamURL(_ songID: String, startingAt offset: TimeInterval = 0) throws -> URL {
        let base = Self.annotate(try streamURLProvider(songID), with: queueSource)
        let suffix = queue.first { $0.id == songID }?.suffix
        return StreamSeek.streamURL(base, offset: offset,
                                    transcode: StreamSeek.needsTranscode(suffix: suffix))
    }

    public static let queueKey = "tonebox.navidrome.queue"
    public static let volumeKey = "tonebox.navidrome.volume"
    public static let repeatKey = "tonebox.navidrome.repeat"
    public static let shuffleKey = "tonebox.navidrome.shuffle"
    public static let autoplayKey = "tonebox.navidrome.autoplay"
    public static let loudnessKey = "tonebox.navidrome.loudness"
    public static let loudnessPreampKey = "tonebox.navidrome.loudnessPreamp"
    public static let crossfadeKey = "tonebox.navidrome.crossfade"
    public static let gaplessKey = "tonebox.navidrome.gapless"
    public static let gaplessWifiOnlyKey = "tonebox.navidrome.gaplessWifiOnly"
    public static let duckKey = "tonebox.navidrome.duckPercent"
    public static let stallTimeoutKey = "tonebox.navidrome.stallTimeout"
    /// Crash-recovery record for an active audio-focus duck: the player volume we lowered
    /// FROM, persisted the instant a duck is placed so a crash/force-quit while ducked can
    /// restore the user's level on next launch (mirrors `OutputVolumeController`). Only the
    /// duck case needs recovery — a pause is harmless across a relaunch (the queue restores
    /// paused anyway), but a stranded low *volume* would silently mis-play every future track.
    public static let activeSuspendVolumeKey = "tonebox.navidrome.audioFocus.pendingVolume"

    /// Where the queue + volume persist. Production uses `.standard`; under XCTest
    /// it defaults to an isolated suite so tests can NEVER pollute the real app's
    /// stored queue/volume (which once restored a phantom test track on launch).
    public let defaults: UserDefaults

    /// The persistence store to use when none is injected: `.standard` in
    /// production, an isolated suite under XCTest.
    public static func defaultStore(environment: BatonEnvironment = .current) -> UserDefaults {
        guard environment.isTesting else { return .standard }
        // A unique suite per instance under test: persisted queue / now-playing state must never
        // leak between tests that each build their own controller or MusicModel (a shared suite let
        // one test's seeded queue restore into the next, e.g. "seek with nothing playing"). Tests
        // that deliberately verify cross-instance restore inject a shared `defaults:`.
        return UserDefaults(suiteName: "io.tonebox.tests.music.\(UUID().uuidString)") ?? .standard
    }

    /// Resolves a queue item's `id` to a playable URL. Handles three cases: an offline
    /// download, a client-side podcast episode (whose id *is* its absolute enclosure URL — see
    /// `PodcastEpisode.asSong`), and the normal case of a Subsonic media id streamed from the
    /// server. Static + isolated so it's unit-testable without a live server.
    @MainActor
    /// The URL to DOWNLOAD a track for offline use: the original file for a library track
    /// (download.view, no transcode), or the enclosure URL for a podcast episode.
    public static func resolveDownloadURL(songID: String) throws -> URL {
        if MediaKind(id: songID) == .podcastEpisode, let url = URL(string: songID) {
            return url // podcast episode — its id IS the enclosure URL
        }
        return try NavidromeConfig.makeClient().downloadURL(songID: songID)
    }

    /// The "prefer downloads / play only offline" toggle (Settings + Downloads screen).
    public static let offlineModeKey = "baton.music.offlineMode"
    public static var isOfflineMode: Bool { UserDefaults.standard.bool(forKey: offlineModeKey) }

    public static func resolveStreamURL(songID: String) throws -> URL {
        // Prefer an offline download when present.
        if let local = MusicDownloadStore.shared.localURL(for: songID) { return local }
        // Content that already lives on this device (the bundled demo library) carries
        // its own file URL as its id. It plays with no server and is exempt from the
        // offline-mode check below, since it is by definition available offline.
        if MediaKind(id: songID) == .localFile, let url = URL(string: songID) { return url }
        // Offline mode: never fall back to streaming — only downloaded content plays. Without
        // this the shipped toggle did nothing and Baton streamed anyway.
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

    public init(
        streamURLProvider: @escaping @MainActor (String) throws -> URL = { songID in
            try StreamingPlaybackController.resolveStreamURL(songID: songID)
        },
        coverArtURLProvider: @escaping @MainActor (String) -> URL? = { songID in
            // A podcast enclosure URL has no derivable cover art — skip the (bogus) server
            // lookup so now-playing falls back to a placeholder rather than a broken request.
            // Neither a podcast enclosure URL nor a local file URL has derivable server
            // cover art — skip the (bogus) lookup so now-playing falls back cleanly.
            if MediaKind(id: songID) != .libraryTrack { return nil }
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
        // caller injects them explicitly (tests do, to share/verify a specific store).
        self.defaults = defaults ?? Self.defaultStore(environment: environment)
        self.systemNowPlaying = systemNowPlaying ?? !environment.isTesting
        let defaults = self.defaults // the resolved, non-optional store for the settings reads below
        let cache = gaplessCache ?? MusicGaplessCache()
        let downloader: @MainActor (URL, String) async -> URL? = gaplessPrefetchDownloader ?? { streamURL, songID in
            // Stream the (transcoded) next track to the ephemeral prefetch cache so the
            // boundary can hand off from a local file — zero-gap even for streams.
            // /PER-03: treat a non-HTTP or error response as failure (was `?? true`),
            // so an error page never gets cached and handed to the gapless boundary.
            var prefetchRequest = URLRequest(url: streamURL)
            for (name, value) in NavidromeConfig.customHeaders() {
                prefetchRequest.setValue(value, forHTTPHeaderField: name)
            }
            guard let (temp, response) = try? await URLSession.shared.download(for: prefetchRequest),
                  (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? false
            else { return nil }
            // MPL integrity check (docs/plan-ios-app.md): a Subsonic error-as-200 envelope or a
            // truncated transcode must never reach the gapless boundary — a poisoned prefetch
            // hot-swaps into the queue and plays as silence at full duration.
            guard (try? AudioResponseValidator.validate(
                fileAt: temp, response: response, songId: songID,
                logger: Logger(subsystem: "io.tonebox.baton", category: "GaplessPrefetch")
            )) != nil else {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
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
        stallTimeoutSeconds = defaults.object(forKey: Self.stallTimeoutKey) as? Double ?? Self.defaultStallTimeout
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
                    self.cancelStallWatchdog()
                    streamingLog.info("player: audio flowing (rate \(rate, privacy: .public))")
                case .waitingToPlayAtSpecifiedRate:
                    // Only "buffering" while we actually intend to play (not paused).
                    self.isBuffering = (self.state == .playing)
                    streamingLog.error("player: waiting to play — reason \(waitReason, privacy: .public)")
                    // A slow-but-open connection can wait here forever (corporate proxy / VPN /
                    // TLS inspection). Arm the watchdog so playback recovers instead of spinning.
                    if self.isBuffering { self.armStallWatchdog() } else { self.cancelStallWatchdog() }
                case .paused:
                    self.isBuffering = false
                    self.cancelStallWatchdog()
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
                // While the engine deck owns playback, AVPlayer is not the clock — and this
                // observer must not act as though it were.
                //
                // It publishes `streamStartOffset + time.seconds`. On a track change the
                // player is emptied but this observer stays installed, so it can still fire
                // with a zeroed player clock while `streamStartOffset` still holds the
                // *previous* track's offset — publishing the old position, which the engine's
                // own tick then corrects to zero a moment later. That is the playhead
                // jumping somewhere and snapping back on every Next.
                //
                // It is a second writer of the same value, which is why fixing the engine's
                // stale tick (the `clockGeneration` guard in `EngineDeckBridge`) did not end
                // the symptom: two publishers, one fixed. Everything below this line is
                // AVPlayer's business — the stall watchdog, the resume offset, listening
                // accumulation — and none of it applies to a track this player is not playing.
                guard !self.engineOwnsPlayback else { return }
                // Nor during a skip blend, for the same reason: two things would be
                // writing one value.
                //
                // `beginSkipBlend` advances the transport immediately and zeroes the
                // playhead, but this observer stays attached to the *outgoing* player until
                // the incoming one is promoted — so it went on publishing the old track's
                // position over that zero. The bar jumped to wherever the previous track had
                // reached, then snapped back when the new player took over. Reported on the
                // desktop after the engine-side fix, because the engine was never the only
                // path this happened on.
                guard !self.isCrossfading else { return }
                // Stalled-stream watchdog: runs on the same clock so a parked player
                // with a recovered buffer gets nudged (see +StallRecovery).
                self.stallRecoveryTick(player: self.player)
                // Don't let a stale clock tick override a just-issued seek target.
                if self.isSeeking { return }
                // An offset stream's clock restarts at zero, so the track-logical playhead is
                // the offset plus the player's clock (`streamStartOffset` is 0 for a normal load).
                let playhead = max(0, self.streamStartOffset + time.seconds)
                // Accumulate real listening: only small forward steps, so a seek (or a stall's
                // catch-up) adds nothing. See `listenedSeconds`.
                if let previous = self.lastClockSample {
                    let step = playhead - previous
                    if step > 0, step <= Self.maxListenStep { self.listenedSeconds += step }
                }
                self.lastClockSample = playhead
                self.currentTime = playhead
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
                // the real position (persistQueue otherwise only runs on transport events).
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
                   !self.isSeeking,
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
    //
    @ObservationIgnored public var radioIsOnAir: (@MainActor () -> Bool)?
    @ObservationIgnored public var radioRemote: RadioRemote?

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
    /// The `currentTime` at the last queue persist, so the playhead is saved ~every 15 s.
    private var lastQueuePersistTime: TimeInterval = 0
    /// Whether the loaded item's track-start side effects have fired. A restored queue
    /// loads paused (no start), so the first `resume()` must fire them.
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
    /// Start these songs shuffled, and leave the player *in* shuffle.
    ///
    /// Every "Shuffle" button in both apps used to call `play(songs.shuffled())` and stop
    /// there. That plays a shuffled queue, but shuffle mode stays off — so the transport's
    /// own shuffle control sits reading "Shuffle off" over music that is plainly not in
    /// order, and the fixed shuffled list, not shuffle, decides what comes next. Reported
    /// as "the shuffle button does not change the visual state when you click it".
    ///
    /// It lives here rather than as two lines at each call site because there were nine of
    /// them across the two apps, and the tenth would have been written the old way.
    public func playShuffled(_ songs: [NavidromeSong], source: QueueSource? = nil) {
        play(songs.shuffled(), source: source)
        // Never a bare toggle: for someone who already had shuffle on, pressing Shuffle
        // would turn it off.
        if !isShuffled { toggleShuffle() }
    }

    /// What the **Shuffle button next to Play** does: press to shuffle, press again to
    /// stop shuffling.
    ///
    /// Distinct from `playShuffled`, which only ever turns shuffle on and is right for a
    /// context-menu "Shuffle" — a menu item that silently un-shuffles would be a surprise.
    /// This one is for a button that *shows* whether shuffle is on: once it lights up, the
    /// only thing pressing it can reasonably mean is "stop".
    /// - off → on: shuffle mode on, and this collection starts shuffled.
    /// - on, and *this* collection is what's playing: shuffle off **in place**. The queue
    ///   un-shuffles around the current track and the music keeps going.
    /// - on, but something else is playing: shuffle off, and this collection starts in
    ///   order — there is nothing in place to preserve.
    ///
    /// The middle case is the whole point of the asymmetry. Restarting on the way *off*
    /// means that three tracks into a shuffled album, pressing Shuffle to stop shuffling
    /// throws you back to track one — which is not what anyone means by that press.
    /// `toggleShuffle` already restores the original order while keeping the current
    /// track, so un-shuffling in place is behaviour that exists and is tested; this only
    /// has to decline to restart.
    public func playShuffleToggling(_ songs: [NavidromeSong], source: QueueSource? = nil) {
        guard isShuffled else { return playShuffled(songs, source: source) }
        let alreadyPlayingThis = nowPlaying != nil && source != nil && queueSource == source
        toggleShuffle()                                  // off, restoring the prior order
        guard !alreadyPlayingThis else { return }        // ...and don't disturb the music
        play(songs, source: source)
    }

    public func play(_ songs: [NavidromeSong], startAt index: Int = 0, source: QueueSource? = nil) {
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
    public func enqueue(_ songs: [NavidromeSong]) {
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
    public func playNext(_ songs: [NavidromeSong]) {
        guard !songs.isEmpty else { return }
        guard !queue.isEmpty else { enqueue(songs); return }
        queue.insert(contentsOf: songs, at: min(currentIndex + 1, queue.count))
        preloadGaplessNextIfNeeded() // these become the immediate gapless "next"
        persistQueue()
        postToast("\(songs.count) playing next", symbol: "text.line.first.and.arrowtriangle.forward")
    }

    public func resume() {
        guard nowPlaying != nil else { return }
        bumpStateGeneration()
        resetFade() // in case we were paused mid sleep-timer fade
        // Engine deck: resume in place (or reload from the top when parked at the end).
        // Must precede the currentItem-nil check below — the AVPlayer is deliberately
        // empty while the deck owns playback, and that nil means nothing here.
        if engineOwnsPlayback, let deck = engineDeck {
            if TrackBoundary.isAtEnd(currentTime: currentTime, duration: duration) {
                loadCurrent(autoplay: true)
                return
            }
            deck.resume()
            state = .playing
            if !startNotifiedForCurrentItem, let song = nowPlaying {
                notifyTrackStarted(song)
            }
            pushNowPlaying()
            return
        }
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
        // Ramped up rather than switched on: resuming mid-waveform is the same
        // discontinuity as pausing mid-waveform, just in the other direction.
        transportFade.in(apply: { [weak self] in self?.applyVolume() })
        state = .playing
        // First play of a restored (loaded-paused) item: fire the track-start side effects
        // (history / "now playing") and stamp the scrobble timestamp now, so a restored
        // track doesn't scrobble against app-launch time.
        if !startNotifiedForCurrentItem, let song = nowPlaying {
            notifyTrackStarted(song)
        }
        // Gapless: a resume from paused (notably a restored-on-launch queue, which loads
        // paused and so skipped the preload) must buffer the next track now, or the first
        // boundary after pressing play would fall back to a reload (gap).
        preloadGaplessNextIfNeeded()
        pushNowPlaying()
    }


    /// Builds the AVURLAsset for a stream/local URL, attaching the active server's
    /// custom headers for remote URLs (Cloudflare Access etc.). Local files skip the
    /// options — AVFoundation ignores headers for file URLs anyway.
    ///
    /// **The MIME hint is what makes the audio tap possible on streams.** A Subsonic
    /// stream URL has no file extension, so `loadTracks` — the *inspection* path — fails
    /// with "Cannot Open" even while the *playback* path happily sniffs and plays the
    /// bytes. And no inspection means no track, no `audioMix`, no tap: the equalizer and
    /// the level meter silently applied only to downloaded files, never to streams.
    /// Because that failure was `try?`-swallowed, nothing ever said so.
    ///
    /// The hint is exact by construction, not a guess: `streamURL(songID:)` always
    /// requests `format=mp3`, so any URL carrying that marker delivers MPEG audio —
    /// Navidrome transcodes everything else to match. Podcast enclosures and local files
    /// don't carry the marker and are left for AVFoundation to identify on its own.
    static func streamAsset(_ url: URL) -> AVURLAsset {
        guard !url.isFileURL else { return AVURLAsset(url: url) }
        var options: [String: Any] = [:]
        let headers = NavidromeConfig.customHeaders()
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        if let mime = Self.mimeHint(for: url) { options[AVURLAssetOverrideMIMETypeKey] = mime }
        return options.isEmpty ? AVURLAsset(url: url) : AVURLAsset(url: url, options: options)
    }

    /// The out-of-band MIME type for a URL whose payload format we *know*, or nil to let
    /// AVFoundation work it out. Only our own `format=mp3` stream request qualifies —
    /// a wrong hint here wouldn't break an indicator, it would break playback.
    static func mimeHint(for url: URL) -> String? {
        guard let query = url.query, query.contains("format=mp3") else { return nil }
        return "audio/mpeg"
    }

    public func pause() {
        bumpStateGeneration()
        pauseInternal()
        onPause?()
    }

    /// Pauses without bumping the intervention counter — used by the audio-focus
    /// suspend path, which pauses playback *for* an owner and must not have its own
    /// pause read back as user intervention. `pause()` is the user-facing wrapper.
    public func pauseInternal() {
        cancelCrossfade()
        // Engine deck: it shapes its own pause fade; running this type's transport fade
        // on top would double-ramp the same audio.
        if engineOwnsPlayback, let deck = engineDeck {
            deck.pause()
            if state == .playing { state = .paused }
            pushNowPlaying()
            persistQueue()
            return
        }
        // Ramped rather than cut. State and Now Playing update immediately below, so the
        // UI still responds instantly; only the audio is shaped.
        transportFade.out(apply: { [weak self] in self?.applyVolume() },
                          then: { [weak self] in self?.player.pause() })
        if state == .playing { state = .paused }
        pushNowPlaying()
        persistQueue() // capture the playhead where the user paused
    }

    /// Persist the queue + playhead immediately (called on app termination).
    public func persistNow() { persistQueue() }

    /// Stops playback cleanly (keeps the queue so it can be restarted / persisted).
    public func stop() {
        bumpStateGeneration()
        cancelCrossfade()
        if engineOwnsPlayback {
            engineDeck?.stop()
            engineOwnsPlayback = false // a later resume() re-routes via loadCurrent
            cancelStallWatchdog()
            state = .idle
            currentTime = 0
            isBuffering = false
            persistQueue()
            pushNowPlaying()
            return
        }
        // Fade, then pause and rewind — seeking a still-audible player is the other way to
        // produce a click.
        transportFade.out(apply: { [weak self] in self?.applyVolume() }) { [weak self] in
            guard let self else { return }
            self.player.pause()
            // Seek the player to the start too, so a later play() resumes from 0:00 — matching
            // the scrubber we reset below — instead of continuing from where Stop was
            // pressed.
            self.player.seek(to: .zero)
        }
        cancelGaplessPrefetch() // don't keep downloading a "next" track after Stop
        cancelStallWatchdog()
        state = .idle
        currentTime = 0
        isBuffering = false
        persistQueue()
        pushNowPlaying()
    }

    /// Empties the queue and stops. Clears the persisted queue and Now Playing.
    public func clearQueue() {
        cancelCrossfade()
        cancelGaplessPrefetch()
        queue = []
        currentIndex = 0
        orderBeforeShuffle = nil
        queueSource = nil
        if engineOwnsPlayback {
            engineDeck?.stop()
            engineOwnsPlayback = false
        }
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
    public func next() {
        cancelCrossfade()
        guard !queue.isEmpty else { return }
        bumpStateGeneration()
        let wasPlaying = state == .playing
        switch Self.onManualNext(current: currentIndex, count: queue.count, repeatMode: repeatMode) {
        case let .play(idx):
            // Blend the audio, but only when already playing — a skip while paused has
            // nothing to fade from. The transport still advances synchronously inside
            // `beginSkipBlend`, so observers never see a stale track.
            if wasPlaying, beginSkipBlend(to: idx) { return }
            currentIndex = idx
            loadCurrent(autoplay: wasPlaying)
            persistQueue()
        case .replay:
            loadCurrent(autoplay: wasPlaying)
        case .stop:
            stop()
        }
    }

    /// Advance to `index` immediately, then blend the audio across
    /// `Crossfade.manualSkipSeconds` instead of cutting.
    ///
    /// Order matters: every observable property moves *first*, so `nowPlaying`, the UI and
    /// `music_next` are correct the moment the call returns. Only the audio lags, by a third
    /// of a second, under the cover of the fade. The ramp holds the outgoing track at full
    /// volume until the incoming stream is audible, so this never fades into silence.
    ///
    /// Returns false when no blend can be set up (no stream URL, a podcast, or a fade already
    /// running), leaving the caller to do the ordinary hard-cut load.
    @discardableResult
    private func beginSkipBlend(to index: Int) -> Bool {
        // Not on the engine deck. This blend is AVPlayer machinery end to end — it advances
        // the transport synchronously and then crossfades between two AVPlayer instances.
        // With the engine owning playback those players are silent, so pressing Next moved
        // every observable property to the next track while the engine carried on rendering
        // the old one, and the playhead oscillated between the two clocks. Returning false
        // sends the caller down `loadCurrent`, which is the only path that reaches the deck.
        guard engineDeck == nil else { return false }
        guard queue.indices.contains(index), !isCrossfading,
              nowPlaying?.isPodcastEpisode != true,
              let url = try? annotatedStreamURL(queue[index].id) else { return false }

        let outgoing = player
        let startOut = outgoing.volume
        let item = AVPlayerItem(asset: Self.streamAsset(url))
        configureAudioMix?(item)
        let targetIn = Float(volumePercent) / 100
            * Self.normalizationGain(for: queue[index], mode: loudnessMode, preampDB: loudnessPreampDB)

        isCrossfading = true
        didHandleEnd = true // the outgoing track is being abandoned, not completed

        // The synchronous advance — before the ramp starts, so nothing can observe a stale index.
        currentIndex = index
        // The listening record closes with the logical advance, not with the audio ramp: this is
        // the moment the outgoing track was left. `finishCrossfade` also rotates, which is then a
        // no-op — the accumulator is already zero. A manual skip takes this path, so most track
        // changes land here rather than in `loadCurrent`.
        rotateListenRecord(to: queue[index])
        currentTime = 0
        // The observer publishes `streamStartOffset + player.currentTime`. Left stale from
        // an offset load, it would re-add the old track's offset to the new track's clock.
        streamStartOffset = 0
        lastClockSample = nil
        duration = Double(queue[index].duration ?? 0)
        scrobbledCurrent = false
        notifyTrackStarted(queue[index])
        pushNowPlaying()
        persistQueue()

        crossfadeRamp.begin(
            item: item, targetIn: targetIn, isMuted: isMuted,
            outgoing: outgoing, startOut: startOut,
            duration: Crossfade.manualSkipSeconds, steps: 12
        ) { [weak self] promoted in
            self?.finishCrossfade(
                to: index, promoted: promoted, retiring: outgoing, alreadyAdvanced: true
            )
        }
        return true
    }


    /// Cycle repeat off → all → one → off. Persisted.
    public func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        defaults.set(repeatMode.rawValue, forKey: Self.repeatKey)
    }

    /// Toggle shuffle. Turning on keeps the current track first and shuffles the
    /// rest (saving the prior order); turning off restores that order.
    public func toggleShuffle() {
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
    public func jump(to index: Int) {
        cancelCrossfade()
        guard queue.indices.contains(index) else { return }
        bumpStateGeneration()
        currentIndex = index
        loadCurrent(autoplay: true)
        persistQueue()
    }

    /// Reorders the queue (drag-and-drop), keeping the current track selected.
    public func moveQueueItem(from source: IndexSet, to destination: Int) {
        let current = nowPlaying
        // Foundation-only reorder with SwiftUI's move(fromOffsets:toOffset:) semantics
        // (destination is an index into the PRE-removal array).
        let moving = source.sorted().compactMap { queue.indices.contains($0) ? queue[$0] : nil }
        let before = queue.prefix(destination).enumerated()
            .filter { !source.contains($0.offset) }.map(\.element)
        let after = queue.enumerated().dropFirst(destination)
            .filter { !source.contains($0.offset) }.map(\.element)
        queue = before + moving + after
        if let current, let idx = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
        }
        preloadGaplessNextIfNeeded() // reorder may have changed which track is next
        persistQueue()
    }

    /// Removes tracks from the queue, keeping the current track selected (or
    /// stopping cleanly if the current track was removed).
    public func removeFromQueue(at offsets: IndexSet) {
        cancelCrossfade()
        let current = nowPlaying
        let removingCurrent = offsets.contains(currentIndex)
        // Foundation-only removal (SwiftUI's remove(atOffsets:) linked by accident
        // through the app targets; this package must stand without UI frameworks).
        for index in offsets.sorted(by: >) where queue.indices.contains(index) {
            queue.remove(at: index)
        }
        if let current, !removingCurrent, let idx = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
            preloadGaplessNextIfNeeded() // removed a queued track — the next may have changed
        } else if removingCurrent {
            // Land on the current track's successor: subtract the items removed BEFORE the
            // current index, else a multi-select spanning items before AND at the current
            // track skips past the intended next track.
            let removedBeforeCurrent = offsets.filter { $0 < currentIndex }.count
            currentIndex = min(max(0, currentIndex - removedBeforeCurrent), max(0, queue.count - 1))
            if queue.isEmpty { stop() } else { loadCurrent(autoplay: state == .playing) }
        }
        persistQueue()
    }

    /// Goes to the previous track (or restarts the current one at the start).
    ///
    /// - Parameter force: skip the restart-first rule and always step back a track.
    ///
    /// The 3-second rule is right for a human at a button, where the gap between hearing
    /// something and pressing is well under a second. It is wrong for a caller reaching
    /// through the control socket, where a round-trip takes seconds by construction — so
    /// `music_previous` would restart the current track almost every time and stepping back
    /// was effectively unreachable. Rather than tune a threshold that is correct for hands,
    /// the remote caller says which behaviour it means.
    public func previous(force: Bool = false) {
        cancelCrossfade()
        guard !queue.isEmpty else { return }
        bumpStateGeneration()
        let wasPlaying = state == .playing
        if Self.previousRestartsCurrent(currentTime: currentTime, currentIndex: currentIndex, force: force) {
            seek(to: 0)
        } else {
            currentIndex -= 1
            loadCurrent(autoplay: wasPlaying)
            persistQueue()
        }
    }

    /// Whether `previous()` should restart the current track rather than step back.
    /// Pure, so the rule is testable without a player. Index 0 always restarts — there is
    /// nothing before it — and `force` cannot invent a track that doesn't exist.
    public nonisolated static func previousRestartsCurrent(
        currentTime: TimeInterval, currentIndex: Int, force: Bool
    ) -> Bool {
        if currentIndex == 0 { return true }
        return force ? false : currentTime > 3
    }

    public func seek(to seconds: TimeInterval) {
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
        // Each seek is a fresh intent, not a retry of the last one, so it gets a fresh recovery
        // budget. Measured live: three consecutive seeks into a long set each correctly refused a
        // spurious end, which exhausted a per-track budget of 3 — and the fourth seek skipped the
        // track. The bound exists to stop a genuinely broken stream looping forever, and that
        // still holds: nothing but a new user seek resets it.
        spuriousEndRecoveries = 0
        // Moving the playhead off the end re-arms end handling.
        if !TrackBoundary.isAtEnd(currentTime: target, duration: duration) { didHandleEnd = false }
        pushNowPlaying()

        // Engine deck: the engine runs the whole seek decision itself (in-spool
        // reposition vs `timeOffset` re-request — the same reused `StreamSeek` rules).
        // `isSeeking` stays up; the deck's clock callback clears it when its playhead
        // reaches the target, which is this path's version of the completion guard.
        if engineOwnsPlayback, let deck = engineDeck {
            deck.seek(to: target)
            return
        }

        // Can this stream actually reach the target? A transcode the server is still encoding
        // reports `Accept-Ranges: none`, so AVPlayer's seek silently runs off the end and the item
        // reports EOF — which used to advance the queue. Ask the item what it can reach, and
        // re-request the stream from the target when it can't. (See `StreamSeek`.)
        switch StreamSeek.strategy(target: target,
                                   seekableRanges: currentSeekableRanges(),
                                   streamStartOffset: streamStartOffset) {
        case .reload(let offset):
            reloadStream(startingAt: offset)
        case .direct:
            player.seek(to: CMTime(seconds: target - streamStartOffset, preferredTimescale: 600)) { [weak self] finished in
                Task { @MainActor in
                    guard let self, generation == self.seekGeneration else { return }
                    self.isSeeking = false
                    // `finished == false` past the generation guard is a genuine failure, not a
                    // superseding seek — the item couldn't reach the target after all. Recover by
                    // re-requesting rather than leaving the scrubber claiming a position the
                    // audio never went to.
                    guard !finished else { return }
                    streamingLog.info("direct seek did not complete; re-requesting stream at \(Int(target))s")
                    self.reloadStream(startingAt: target)
                }
            }
        }
    }

    /// What the current item can actually seek to, in stream-local seconds.
    private func currentSeekableRanges() -> [ClosedRange<TimeInterval>] {
        (player.currentItem?.seekableTimeRanges ?? []).compactMap {
            let r = $0.timeRangeValue
            let start = r.start.seconds
            let end = (r.start + r.duration).seconds
            guard start.isFinite, end.isFinite, end >= start else { return nil }
            return start...end
        }
    }

    /// Re-request the current track's stream starting at `offset`, preserving playback state.
    /// The way to reach a position in a stream that can't be byte-range seeked.
    private func reloadStream(startingAt offset: TimeInterval) {
        let wasPlaying = state == .playing
        isSeeking = false
        state = .loading
        isBuffering = true
        loadCurrent(autoplay: wasPlaying, startingAt: offset, isContinuation: true)
    }

    /// Sets the player volume from a 0–100 percentage. A positive volume unmutes.
    /// A user volume change counts as transport intervention (§4.2): it bumps the generation
    /// so an in-flight audio-focus duck/pause won't auto-restore over the user's new level.
    public func setVolume(percent: Int) {
        bumpStateGeneration()
        volumePercent = max(0, min(percent, 100))
        if volumePercent > 0, isMuted {
            isMuted = false
            player.isMuted = false
        }
    }

    /// Toggles mute independently of the volume level (the slider keeps its value).
    public func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// Push the effective volume to AVPlayer: the user's level times the current track's
    /// loudness-normalization multiplier. (Mute is separate — `player.isMuted`.)
    public func applyVolume() {
        let mult = Self.loudnessMultiplier(for: nowPlaying, mode: loudnessMode, preampDB: loudnessPreampDB)
        player.volume = PlaybackVolume.effective(percent: volumePercent, loudness: mult,
                                                 fade: fadeMultiplier,
                                                 transport: transportFade.multiplier)
        // Engine deck: mirror the same composition onto the engine's own level model —
        // user volume + mute as-is, loudness by song via the engine's identical math,
        // and the sleep/transport envelopes folded into its external envelope.
        if engineOwnsPlayback, let deck = engineDeck {
            deck.applyLevel(volumePercent: volumePercent, isMuted: isMuted,
                            envelope: fadeMultiplier * transportFade.multiplier)
            deck.applyLoudness(mode: loudnessMode, preampDB: loudnessPreampDB)
        }
    }

    // Loudness-normalization math (loudnessHeadroom + loudnessMultiplier + normalizationGain) lives
    // in StreamingPlaybackController+Loudness.swift — pure ReplayGain functions,  extraction.

    /// Ramp the fade envelope to `target` over `duration`, then run `then` (e.g. pause).
    /// Cancels any in-flight fade. Used for the sleep-timer fade-out.
    public func fade(to target: Float, duration: Double, then: (@MainActor () -> Void)? = nil) {
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
    public func resetFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadeMultiplier = 1
        applyVolume()
    }


    // Sleep-timer (fixed-time + end-of-track, with a fade-out) lives in
    // StreamingPlaybackController+SleepTimer.swift.

    // MARK: - Loading

    /// - Parameters:
    ///   - startingAt: fetch the stream from this many seconds in (Subsonic `timeOffset`) rather
    ///     than from the top. Used to reach a position AVPlayer can't seek to in a transcode the
    ///     server is still encoding — see `StreamSeek`.
    ///   - isContinuation: this load re-fetches the track the listener is *already* playing (a
    ///     seek that needed a new stream, an EQ toggle) rather than starting one. It must be
    ///     inaudible bookkeeping-wise: no second "track started", no reset of the scrobble state,
    ///     and no re-application of the saved resume offset — which would otherwise yank the
    ///     playhead back to the resume point immediately after the listener chose a position.
    private func loadCurrent(autoplay: Bool, isRetry: Bool = false,
                             startingAt: TimeInterval = 0, isContinuation: Bool = false) {
        cancelStallWatchdog() // a fresh load supersedes any pending stall watchdog
        // Settle any transport ramp still in flight, *before* the item is replaced. A
        // pending stop finishes with pause() + seek(.zero); arriving after the new item is
        // in place, it would pause and rewind the track that just started — press Stop,
        // pick another song inside the fade, and the app looks frozen with no error. This
        // has to precede replaceCurrentItem so the teardown lands on the outgoing item.
        transportFade.cancel(apply: { [weak self] in self?.applyVolume() })
        #if DEBUG
        loadCurrentCountForTesting += 1
        #endif
        if !isRetry { sameTrackRetries = 0 } // a genuine (non-retry) load starts a fresh track
        // A fresh item can end again — clear the end-handled guard.
        didHandleEnd = false
        if !isContinuation {
            scrobbledCurrent = false
            startNotifiedForCurrentItem = false // set true by notifyTrackStarted (autoplay path)
            spuriousEndRecoveries = 0 // a new track starts with a fresh recovery budget
            // Close out the outgoing track's listening record before the new one begins.
            rotateListenRecord(to: nowPlaying)
        } else {
            // The listener just chose where to be; a pending resume must not override it.
            pendingResumeOffset = nil
        }
        guard let song = nowPlaying else {
            state = .idle
            return
        }
        // Clamp: an offset at or past the end would fetch an empty stream that instantly "ends".
        let offset = max(0, min(startingAt, max(0, Double(song.duration ?? 0) - 1)))
        streamStartOffset = offset
        let url: URL
        do {
            url = try annotatedStreamURL(song.id, startingAt: offset)
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
        #if DEBUG
        lastStreamURLForTesting = url
        #endif

        // EXPERIMENT (feat/audio-engine): route library stream tracks to the engine deck.
        // The deck handles offsets itself (its own `timeOffset` / decode-skip logic), so it
        // gets the base annotated URL rather than the offset-rewritten one above.
        // Routability is decided BEFORE the deck is resolved, so a host using a lazy
        // provider never builds an audio engine (or, on the phone, activates the audio
        // session) merely to discover the track was a podcast.
        if let engineURL = try? annotatedStreamURL(song.id),
           EngineDeckBridge.canPlay(songID: song.id, url: engineURL),
           let deck = resolveEngineDeck() {
            engineOwnsPlayback = true
            // Say which deck took the track. With two engines behind one transport, "is it
            // even on the new path?" is the first question of every diagnosis, and inferring
            // it from side effects is how you end up measuring the wrong thing — see the
            // now-playing bars, which looked reactive for a day while reading zeros.
            streamingLog.info("engine deck owns playback (AVAudioEngine) for \(song.id, privacy: .public)")
            // Nothing may be left on the AVPlayer side — a stale item would play in parallel.
            player.removeAllItems()
            loadedItem = nil
            gaplessPreload = nil
            // The retry paths park the playhead in `pendingSeek` (the AVPlayer path
            // applies it at readyToPlay); the engine takes it up front as the offset,
            // so a retried track resumes in place rather than restarting.
            var offset = offset
            if let pending = pendingSeek {
                pendingSeek = nil
                offset = max(offset, pending)
            }
            deck.load(
                song: song, url: engineURL, startingAt: offset, autoplay: autoplay,
                headers: NavidromeConfig.customHeaders(),
                supportsTimeOffset: StreamSeek.needsTranscode(suffix: song.suffix)
            )
            applyVolume() // routes level + loudness to the deck while it owns playback
            currentTime = offset
            duration = Double(song.duration ?? 0)
            if autoplay {
                state = .playing
                if !isContinuation { notifyTrackStarted(song) }
            } else {
                state = .paused
            }
            pushNowPlaying()
            extendQueueIfNeeded()
            return
        } else if engineOwnsPlayback {
            // Leaving the engine path (podcast, local file, deck detached): silence the
            // deck before AVPlayer takes over, or both would play at once.
            engineDeck?.stop()
            engineOwnsPlayback = false
        }

        let item = AVPlayerItem(asset: Self.streamAsset(url))
        setCurrentItem(item)
        configureAudioMix?(item)
        applyVolume()
        currentTime = offset
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
            if !isContinuation { notifyTrackStarted(song) }
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
        //
        // `StreamSeek.logicalDuration` owns the rule — notably that an offset stream's own
        // duration must be ignored, because it reports the whole track rather than the remainder.
        let metadataDuration = duration
        Task { [weak self] in
            let seconds = await (try? item.asset.load(.duration))?.seconds
            guard let self else { return }
            let logical = StreamSeek.logicalDuration(assetSeconds: seconds,
                                                     metadata: metadataDuration,
                                                     streamStartOffset: offset)
            if player.currentItem === item, logical > 1, logical != duration {
                duration = logical
                pushNowPlaying()
            }
        }
    }

    /// User-initiated retry of the current track after an error (the now-playing bar's **Retry**).
    /// Reuses the same-track reload path — preserving the playhead — and clears the automatic backoff
    /// counters so a manual retry always attempts, even after auto-retries were exhausted.
    public func retryCurrent() {
        guard nowPlaying != nil else { return }
        sameTrackRetries = 0
        consecutiveFailures = 0
        let resumeAt = currentTime
        if resumeAt > 1 { pendingSeek = resumeAt }
        state = .loading
        loadCurrent(autoplay: true, isRetry: true)
    }

    /// A stream item failed to load (bad format, auth, network). Surfaces the error
    /// and — so one dud track doesn't stall the whole queue — auto-skips to the next
    /// after a short beat, unless every track has failed (guarded to avoid a loop).
    private func handleLoadFailure(_ message: String) {
        isBuffering = false
        cancelStallWatchdog() // recovery is taking over; don't let a pending watchdog double-fire
        // First, retry the SAME track with a capped backoff, preserving the playhead — a brief
        // outage (Wi-Fi blip, server restart) then recovers in place instead of skipping the
        // track and cascade-skipping the rest of the queue.
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

    /// Arm the stall watchdog if it isn't already running (see `stallWatchdog`). Fires once after
    /// `stallTimeout`; before acting it re-checks that we're *still* stalled — intending to play and
    /// the player still `waitingToPlayAtSpecifiedRate` — so a connection that recovers on its own is
    /// left untouched. On a real stall it enters the same recovery ladder as a hard load failure.
    private func armStallWatchdog() {
        guard stallWatchdog == nil else { return }
        let timeout = stallTimeoutSeconds
        stallWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.stallWatchdog = nil
            guard self.state == .playing, self.isBuffering,
                  self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            streamingLog.error("player: buffering stalled > \(timeout, privacy: .public)s — recovering")
            self.handleLoadFailure(
                "Playback stalled — the connection may be blocked or too slow (check VPN or network filtering)."
            )
        }
    }

    /// Cancel any pending stall watchdog (audio resumed, we paused/stopped, or recovery took over).
    private func cancelStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    #if DEBUG
    /// Test seam: drives the end-of-track handler without a real AVPlayer clock.
    public func simulateTrackEndedForTesting() { handleEnded() }
    /// Test seam: drives the load-failure handler without a real stream failure.
    public func simulateLoadFailureForTesting(_ message: String = "test failure") { handleLoadFailure(message) }
    public var sameTrackRetriesForTesting: Int { sameTrackRetries }
    /// Test seam: the URL actually handed to `AVPlayerItem`, after provenance annotation and the
    /// `StreamSeek` rewrite — the only place the offset/transcode decisions become observable.
    public private(set) var lastStreamURLForTesting: URL?
    public var streamStartOffsetForTesting: TimeInterval { streamStartOffset }
    /// Test seam: stand in for "this stream was fetched with `timeOffset`", which a local file
    /// can't produce (it is fully seekable, so a seek never needs a re-request).
    public func setStreamStartOffsetForTesting(_ seconds: TimeInterval) { streamStartOffset = seconds }
    /// Test seam: force a queue snapshot without waiting for a transport event.
    public func persistQueueForTesting() { persistQueue() }
    /// Test seam: advance the listening accumulator without waiting out real playback.
    public func accumulateListeningForTesting(_ seconds: TimeInterval) { listenedSeconds += seconds }
    #endif

    /// A track finished. Hard-cut to the next queued track, or stop cleanly at the
    /// end of the queue (REQ-10 — stopped, not errored).
    private func handleEnded() {
        // Idempotent per item-end: both the AVPlayerItemDidPlayToEndTime notification and
        // the periodic-observer fallback can fire for the same end — only act once. Cleared
        // when a new item loads or the playhead seeks off the end.
        guard !didHandleEnd else { return }

        // Is this actually the end? A transcode the server is still encoding reports EOF when a
        // seek runs past what it has, and that is indistinguishable here from the track
        // finishing — which is how clicking the playbar 40 minutes into a long set used to skip
        // to the next track. The playhead settles it: a real end happens at the end. Anything
        // else means the stream ran out early, so re-request it from where the listener actually
        // is instead of abandoning the track. (See `StreamSeek`.)
        if !StreamSeek.isGenuineEnd(currentTime: currentTime, duration: duration),
           spuriousEndRecoveries < Self.maxSpuriousEndRecoveries {
            spuriousEndRecoveries += 1
            streamingLog.info(
                "ignoring end-of-stream at \(Int(self.currentTime))s of \(Int(self.duration))s — re-requesting")
            reloadStream(startingAt: currentTime)
            return
        }
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
        // Engine deck: the AVQueuePlayer look-ahead is meaningless while the deck owns
        // playback — deck-mode transitions are hard cuts (documented degradation).
        guard !engineOwnsPlayback else { return }
        let planned = plannedNextIndex()
        // Reap in-flight prefetches for tracks that are no longer the planned next (e.g. after
        // rapid skipping), so stale full-file downloads don't pile up competing with the live
        // stream on the same link.
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
        // Marked as a prefetch: this downloads a whole track that may never be heard, and an
        // unmarked one is counted as a complete play by anything reading the server's access log.
        guard let streamURL = (try? annotatedStreamURL(songID)).map(Self.markPrefetch) else { return }
        // Prefer an already-prefetched local file (or an offline download, which
        // streamURLProvider already resolves to a file URL) so the handoff is gap-free.
        let preloadURL = GaplessPreload.preloadURL(stream: streamURL, cached: gaplessPrefetcher.cachedURL(for: songID))
        let item = AVPlayerItem(asset: Self.streamAsset(preloadURL))
        configureAudioMix?(item) // attach EQ at preload creation, before it plays
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
        let item = AVPlayerItem(asset: Self.streamAsset(localURL))
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
    public var gaplessCacheSizeBytes: Int64 { gaplessPrefetcher.cacheSizeBytes }

    /// Empties the gapless prefetch cache. Safe during playback: cancels in-flight
    /// prefetches and drops any queued preload that may point at a file we're deleting, then
    /// rebuilds it from the stream so the next boundary still has something to advance to.
    public func clearGaplessCache() {
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
        // The incoming track was preloaded from the top, so its clock is the track's. Carrying a
        // previous track's `timeOffset` across the boundary would make the periodic observer read
        // `staleOffset + 0` as the new playhead — minutes into a track that just started, which
        // reads as already-finished and skips it. Set BEFORE `currentTime`, which depends on it.
        streamStartOffset = 0
        currentTime = 0
        duration = Double(song.duration ?? 0)
        didHandleEnd = false
        rotateListenRecord(to: song)
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
            // Freshness: a user action may have happened while we were fetching.
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
        // Open the window EARLIER than the audible blend by roughly the time an incoming
        // stream takes to become audible. The ramp now waits for readiness before fading,
        // and waiting inside the window would eat it — the blend would finish late, or get
        // truncated by the outgoing track actually ending.
        let window = Crossfade.preRollWindow(
            window: crossfadeSeconds,
            expectedLatency: Crossfade.assumedStreamLatency,
            duration: duration
        )
        guard !engineOwnsPlayback, // deck-mode transitions are hard cuts (documented)
              state == .playing, !isCrossfading,
              Crossfade.inWindow(currentTime: currentTime, duration: duration, window: window) else { return }
        // Never crossfade a podcast (spoken word) — and crossfading suppresses the outgoing
        // track's end handler, which is a podcast's only played/auto-remove trigger.
        if nowPlaying?.isPodcastEpisode == true { return }
        guard case let .play(nextIndex) = Self.onTrackEnd(current: currentIndex, count: queue.count, repeatMode: repeatMode),
              nextIndex != currentIndex, queue.indices.contains(nextIndex) else { return }
        startCrossfade(to: nextIndex, duration: window)
    }

    /// Start the second player on `nextIndex` at silence and ramp the two volumes past
    /// each other over `crossfadeSeconds`, then promote it in `finishCrossfade`.
    private func startCrossfade(to nextIndex: Int, duration seconds: Double) {
        // Via `annotatedStreamURL`, not the raw provider: a crossfaded track otherwise streams
        // without the `playedFrom` annotation, so its play lands in the server log with no
        // provenance — and provenance is the only way to tell which playlist a play came from,
        // which is what every judgement about whether a playlist works is made from. It also
        // picks up the native-format passthrough (see `StreamSeek`).
        guard let url = try? annotatedStreamURL(queue[nextIndex].id) else { return }
        isCrossfading = true
        didHandleEnd = true // suppress the outgoing track's normal end handler
        // ...but still report the outgoing track as completed, so its final progress is saved
        // (played-state, download auto-remove) — the suppressed handler was their only trigger.
        // Harmless for music; correctness for any non-podcast that reports progress.
        if let outgoing = nowPlaying, duration > 0 { onProgressUpdate?(outgoing, duration, duration) }
        // Attach the EQ tap to the incoming item BEFORE it plays, or the EQ would silently
        // switch off at the first crossfade boundary and stay off for every crossfaded
        // track thereafter.
        let item = AVPlayerItem(asset: Self.streamAsset(url))
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
    /// - Parameter alreadyAdvanced: true when the caller advanced the queue *before* the fade
    ///   started (a manual skip). The transport must move the instant you press skip — deferring
    ///   it until the ramp completes would make `music_next` and the UI report the previous track
    ///   for the length of the blend. In that case this only swaps the players; the queue
    ///   bookkeeping and `notifyTrackStarted` already happened and must not fire twice.
    private func finishCrossfade(
        to nextIndex: Int,
        promoted: AVQueuePlayer,
        retiring: AVQueuePlayer,
        alreadyAdvanced: Bool = false
    ) {
        // Bailing out must not leave the incoming player running. This returns when the
        // queue changed under the fade (an index that no longer exists), when a transport
        // action already cleared the flag, or when a newer ramp replaced this one — and in
        // the first two cases `promoted` is still playing. Stopping it here is the
        // difference between a dropped transition and a track nobody can turn off.
        guard isCrossfading, crossfadeRamp.player === promoted, queue.indices.contains(nextIndex) else {
            if crossfadeRamp.player === promoted {
                isCrossfading = false
                crossfadeRamp.cancel()
                applyVolume()
            }
            return
        }
        retiring.pause()
        detachPlayerObservers()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObservation?.invalidate()

        player = promoted
        loadedItem = promoted.currentItem
        gaplessPreload = nil
        crossfadeRamp.clearAfterPromotion() // release the ramp's ref without pausing the now-main player
        isCrossfading = false
        didHandleEnd = false
        // Same as the gapless boundary: the incoming stream starts at the track's top, so a
        // previous track's `timeOffset` must not carry across. Unconditional — the promoted
        // player is a new stream either way, and `alreadyAdvanced` only means the logical index
        // was reconciled elsewhere, not that the offset still applies.
        streamStartOffset = 0
        // A crossfade is a track boundary like any other, so the outgoing track's listening
        // record closes here too. Unconditional: `alreadyAdvanced` only means the logical index
        // was reconciled elsewhere, not that the boundary didn't happen. (A manual skip is a
        // short crossfade, so this is the path most track changes actually take.)
        rotateListenRecord(to: queue[nextIndex])
        if !alreadyAdvanced {
            currentIndex = nextIndex
            currentTime = 0
            duration = Double(queue[nextIndex].duration ?? 0)
            scrobbledCurrent = false
        }
        attachPlayerObservers()
        if let item = promoted.currentItem { attachItemObservers(item) }
        fadeMultiplier = 1
        applyVolume()
        state = .playing
        if !alreadyAdvanced {
            notifyTrackStarted(queue[nextIndex])
            pushNowPlaying()
            persistQueue()
        }
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
    ///
    /// Guarded on the ramp's *actual* state as well as the flag. `isCrossfading` and
    /// `crossfadeRamp` can disagree — `finishCrossfade` used to bail out of its guard
    /// leaving a live second player behind — and once they did, this returned early and no
    /// transport action could ever stop that player again. The symptom is a track that
    /// keeps playing under everything you choose afterwards, two at once, with no way to
    /// silence it short of killing the app. The flag is a belief; the ramp is the truth.
    public func cancelCrossfade() {
        guard isCrossfading || crossfadeRamp.isActive else { return }
        isCrossfading = false
        crossfadeRamp.cancel()
        didHandleEnd = false
        applyVolume()
    }

    // MARK: - Persistence

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
    public func restoreQueue() {
        guard let data = defaults.data(forKey: Self.queueKey),
              let snapshot = try? JSONDecoder().decode(QueueSnapshot.self, from: data),
              !snapshot.songs.isEmpty
        else { return }
        queue = snapshot.songs
        currentIndex = max(0, min(snapshot.index, snapshot.songs.count - 1))
        queueSource = snapshot.source
        // Ask the server for the stream *from* the saved position rather than loading at 0 and
        // seeking: a long set resumes instantly and correctly even on a cold transcode, which
        // can't be seeked at all (see `StreamSeek`).
        loadCurrent(autoplay: false, startingAt: max(0, snapshot.position))
    }

    /// A one-line "now playing" summary for the `music_now_playing` tool.
    public var nowPlayingSummary: String {
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
