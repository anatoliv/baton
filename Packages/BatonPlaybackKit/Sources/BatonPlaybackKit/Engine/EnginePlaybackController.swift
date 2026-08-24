#if os(macOS) || os(iOS)
// The engine is macOS/iOS only. watchOS has no AudioToolbox — no `AudioFileStream`, so no
// decoder, so no engine — and it plays downloaded files through AVPlayer. See
// `EngineDeckUnavailable.swift` for the stand-in that keeps the policy layer compiling.

import AVFoundation
import Foundation
import Observation
import OSLog
import BatonDSP
import BatonSubsonicModels

/// The **transport core** of the AVAudioEngine playback experiment: **one-track** playback
/// over `EngineAudioPipeline` + `TrackStreamSource`, with EQ and metering that apply to
/// *streamed* audio — the thing `StreamingPlaybackController` structurally cannot do (see
/// docs/audio-engine-rearchitecture.md).
///
/// Deliberately a **sibling, not a replacement**: `StreamingPlaybackController`'s 87
/// public members are queue/focus/persistence *policy*, and this type does not duplicate
/// them. What lives here is exactly the engine-facing transport the old controller
/// implements over AVPlayer — load/play/pause/stop, seek (including into a still-encoding
/// transcode), buffering + stall recovery — implemented over scheduled PCM, and reusing
/// the same pure decision types (`StreamSeek`, `TransportFade`, `PlaybackVolume`) so the
/// two engines cannot drift on policy.
///
/// **It holds one track, not a queue.** It used to carry a queue, `next()`/`previous()`, a
/// gapless roll and a crossfade, and none of it could run: the only production caller
/// (`EngineDeckBridge.load`) always passes a single track, and the host decides what plays
/// next. That half was deleted in Stage 5 rather than fixed, taking both of the
/// optimization plan's Appendix B latent bugs with it. The seam is the design doc's:
/// policy stays in the existing controller; this is the deck it drives for library streams.
@MainActor
@Observable
public final class EnginePlaybackController {
    public enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case error(String)
    }

    /// One playable entry. `song` (when present) supplies loudness tags + transcode
    /// routing; tests play bare URLs.
    public struct Track: Sendable {
        public let id: String
        public let url: URL
        /// Server-metadata duration — authoritative for offset streams, exactly as
        /// `StreamSeek.logicalDuration` established for the AVPlayer engine.
        public let duration: TimeInterval
        public let song: NavidromeSong?
        /// Whether a seek re-request may use Subsonic `timeOffset` (a transcoded
        /// stream). False for plain HTTP sources that only support ranges.
        public let supportsTimeOffset: Bool

        public init(id: String, url: URL, duration: TimeInterval,
                    song: NavidromeSong? = nil, supportsTimeOffset: Bool = true) {
            self.id = id
            self.url = url
            self.duration = duration
            self.song = song
            self.supportsTimeOffset = supportsTimeOffset
        }
    }

    public private(set) var state: State = .idle
    /// The one track this engine is playing.
    ///
    /// This was a `queue: [Track]` plus a `currentIndex`, and the queue never had more than
    /// one element in it. `EngineDeckBridge.load` — the only production entry point — calls
    /// `play(track)` with exactly one track, because the **host** owns the queue: pressing
    /// Next runs `StreamingPlaybackController.loadCurrent`, which is a fresh single-track
    /// load, and `deck.onEnded` hands the end of a track back to the host's own
    /// `advanceAfterEnd`. The engine's `next()`, `previous()`, gapless roll and crossfade
    /// were therefore unreachable in production, and both of the plan's Appendix B latent
    /// bugs lived in them. Deleted rather than fixed — see Stage 5 of
    /// `docs/audio-engine-optimization-plan.md`.
    public private(set) var nowPlaying: Track?
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    /// True while the transport intends to play but the deck has run dry — the engine's
    /// buffering signal, computed from facts (scheduled-ahead, spool growth) rather than
    /// inferred from `timeControlStatus`.
    public private(set) var isBuffering = false

    public var isPlaying: Bool { state == .playing }

    // MARK: - Settings (same semantics as the AVPlayer engine)

    public var volumePercent: Int = 70 {
        didSet {
            let clamped = max(0, min(volumePercent, 100))
            if clamped != volumePercent { volumePercent = clamped; return }
            applyVolume()
        }
    }
    /// Mute as a factor of the master level (the slider keeps its value) — same
    /// semantics as the old engine's `player.isMuted`.
    public var isMuted: Bool = false { didSet { applyVolume() } }
    /// An external 0…1 envelope folded into the master level — the host's sleep-timer
    /// fade / transport shaping when this engine runs as a deck behind
    /// `StreamingPlaybackController` (see `EngineDeckBridge`). 1 = no effect.
    public var externalEnvelope: Float = 1 { didSet { applyVolume() } }
    /// Fired when the track genuinely ends — the deck-mode hook the host uses to run its
    /// own advance policy (repeat, next, autoplay-radio, stop). That policy has always
    /// lived on the host; this engine never had a say in it, which is why its own
    /// `repeatMode` and `crossfadeSeconds` could be deleted without changing behaviour.
    @ObservationIgnored public var onPlaybackEnded: (@MainActor () -> Void)?
    public var loudnessMode: StreamingPlaybackController.LoudnessMode = .off { didSet { applyDeckGain() } }
    public var loudnessPreampDB: Double = 0 { didSet { applyDeckGain() } }
    public var stallTimeoutSeconds: Double = StreamingPlaybackController.defaultStallTimeout
    public var playbackRate: Float {
        get { pipeline.playbackRate }
        set { pipeline.playbackRate = newValue }
    }

    /// Extra HTTP headers for stream requests (Cloudflare Access etc.) — the engine-side
    /// equivalent of `AVURLAssetHTTPHeaderFieldsKey`.
    @ObservationIgnored public var streamHeaders: [String: String] = [:]

    // MARK: - Internals

    @ObservationIgnored private let pipeline: EngineAudioPipeline
    @ObservationIgnored private var activeDeck: EngineAudioPipeline.DeckID = .a
    private var otherDeck: EngineAudioPipeline.DeckID { activeDeck == .a ? .b : .a }

    /// The live source + feeder per deck. A source outlives seeks (the spool is the seek
    /// index); it dies on track change or stop.
    @ObservationIgnored private var sources: [EngineAudioPipeline.DeckID: TrackStreamSource] = [:]
    @ObservationIgnored private var feeders: [EngineAudioPipeline.DeckID: Task<Void, Never>] = [:]

    /// Track-clock anchors: `currentTime = clockBase + (playedFrames - anchorFrames)/rate`.
    /// Reset on load/seek (deck timeline restarts); advanced at a gapless boundary.
    @ObservationIgnored private var anchorFrames: Int64 = 0
    @ObservationIgnored private var clockBase: TimeInterval = 0
    @ObservationIgnored private var trackSampleRate: Double = 0
    /// Seconds into the track the current *stream* begins (`timeOffset` fetch) — same
    /// role as the old engine's `streamStartOffset`.
    @ObservationIgnored private var streamStartOffset: TimeInterval = 0

    /// Invalidates stale feeder/boundary/ramp callbacks after any load/seek/stop: a
    /// flushed `AVAudioPlayerNode` fires the completion handlers of buffers it never
    /// played, so every callback checks its generation first.
    @ObservationIgnored private var loadGeneration = 0

    /// True once the current track's final buffer has been scheduled (spool + decode
    /// exhausted) — from then on an empty deck means "ending", not "buffering".
    @ObservationIgnored private var finishedScheduling = false

    /// Seconds of decoded audio the next feeder must discard before scheduling — the
    /// resume path for sources that can't `timeOffset` (a plain HTTP file): fetch from
    /// zero, decode-and-drop to the target. Network-cheap (the spool fills at wire
    /// speed) and exact; the alternative would be a playhead that lies.
    @ObservationIgnored private var pendingLoadSkipSeconds: TimeInterval = 0

    @ObservationIgnored private let transportFade = TransportFade()
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var stallWatchdog: Task<Void, Never>?

    /// The other half of stall detection: `isBuffering` covers a deck with no data, this
    /// covers a deck with data that nothing is rendering. See `PlayheadStallDetector` for
    /// why the two cannot be one check.
    @ObservationIgnored private var playheadStall = PlayheadStallDetector()
    /// Consecutive playhead recoveries with no healthy stretch of playback between them.
    /// Bounded for the same reason the retry ladder is: a recovery that does not recover
    /// has to escalate rather than loop.
    @ObservationIgnored private var playheadRecoveries = 0
    /// Restarting the I/O is cheap and re-anchors from the spool, so a couple of attempts
    /// are worth making before falling through to the ladder that re-requests the stream.
    static let maxPlayheadRecoveries = 3
    /// The clock's own period, named because the stall detector accumulates in it.
    static let clockInterval: TimeInterval = 0.25

    /// Consecutive same-track retries. Cleared by *playing*, not by reaching `.playing` —
    /// see `clockTick`.
    @ObservationIgnored private var sameTrackRetries = 0
    /// Retries for this track since it last played a long, healthy stretch. The floor the
    /// consecutive counter can't provide: a stream that dies a little way into every
    /// attempt resets `sameTrackRetries` legitimately each time (it did play), so without
    /// this the ladder would still never reach `.error`.
    @ObservationIgnored private var episodeRetries = 0

    /// Rendered audio that counts as "this load worked", clearing the consecutive ladder.
    /// Deliberately longer than the backoff sleeps (1–3 s), so a stream that fails as fast
    /// as it recovers cannot ride the reset.
    static let retryResetDwellSeconds: TimeInterval = 8
    /// Rendered audio that ends a *failure episode* and clears the floor. Two minutes of
    /// uninterrupted playback is a working stream; the occasional hiccup an evening apart
    /// must not accumulate towards giving up, which is the §2.4 lesson that put the reset
    /// there in the first place.
    static let episodeResetDwellSeconds: TimeInterval = 120
    /// Attempts per failure episode, whatever the consecutive counter says.
    static let maxEpisodeRetries = 6

    #if DEBUG
    var sameTrackRetriesForTesting: Int { sameTrackRetries }
    var episodeRetriesForTesting: Int { episodeRetries }
    /// Test instrumentation, mirroring the old engine's boundary counters.
    public private(set) var loadCountForTesting = 0
    /// Re-anchors served from the spool. The distinction Stage 4 is about: a route change
    /// should bump this and leave `loadCountForTesting` alone, because the alternative is a
    /// fresh HTTP request for bytes already on disk.
    public private(set) var refeedCountForTesting = 0
    public var activeDeckForTesting: EngineAudioPipeline.DeckID { activeDeck }
    /// Feeder wake-ups that decoded nothing, and chunks actually pulled. Their ratio is the
    /// duty cycle, and it is the only externally visible sign of it: the decode *work* is
    /// unchanged by design, so a regression to polling would look identical everywhere else.
    public private(set) var feederIdleWakeupsForTesting = 0
    public private(set) var feederPullsForTesting = 0
    public var finishedSchedulingForTesting: Bool { finishedScheduling }
    var sourceForTesting: TrackStreamSource? { sources[activeDeck] }
    /// The URL the last `load` actually fetched — after any `timeOffset` rewrite. The only
    /// place the seek-reload decision is observable, mirroring the old engine's seam.
    /// Tests assert on its *query shape* only; the URL carries auth and is never printed.
    public private(set) var lastStreamURLForTesting: URL?
    #endif

    public init(pipeline: EngineAudioPipeline) {
        self.pipeline = pipeline
        pipeline.onConfigurationChange = { [weak self] in
            // Output device changed under us: the graph restarted; re-anchor playback at
            // the current playhead. AVPlayer did this invisibly — here it costs a reload.
            //
            // Paused counts. This guarded on `isPlaying`, so a device change while paused
            // re-anchored nothing: the engine had been stopped to re-point its output unit,
            // dropping the scheduled buffers, and resume then had nothing to render. The
            // playhead simply froze — and invisibly, because the deck's `aheadSeconds` was
            // still stale-positive, so the dry-detection that would have raised `isBuffering`
            // never fired.
            //
            // And it re-feeds from the spool rather than re-downloading: see
            // `reanchorAfterGraphRestart`, which falls back to the network only when the
            // bytes for this position genuinely are not held.
            guard let self else { return }
            reanchorAfterGraphRestart()
        }
        applyVolume()
    }

    // MARK: - Transport

    /// `atTime` starts the track part-way in — one load, via `timeOffset` when the track
    /// supports it (deck-mode restore/seek lands in a single fetch). `autoplay: false`
    /// loads paused — a restored track must never start sounding on its own, and a
    /// play-then-pause would (the pause lands while still `.loading` and no-ops).
    ///
    /// Takes one track, not an array. It only ever received one.
    public func play(_ track: Track, atTime: TimeInterval = 0, autoplay: Bool = true) {
        // Fresh intent from the host — a different track, or its own retry of this one
        // (`retryCurrent` comes through here). Either way the previous failure episode is
        // over, so both ladders start from zero. This is the only place the floor clears
        // other than two minutes of healthy playback: `load` must not clear it, or the
        // engine's own retries would keep resetting the counter that bounds them.
        sameTrackRetries = 0
        episodeRetries = 0
        nowPlaying = track
        load(track: track, startingAt: max(0, atTime), autoplay: autoplay)
    }

    public func pause() {
        // A pause that lands while a track is still loading used to be dropped on the
        // floor: this guard refused it, the load completed with `autoplay: true`, and audio
        // started — while the host had already moved its own state, the lock screen and the
        // transport button to "paused". The app then showed paused and played, which is
        // worse than either outcome on its own.
        //
        // Latch it instead. The load honours it the moment it would otherwise start.
        if state == .loading {
            pauseRequestedDuringLoad = true
            return
        }
        guard state == .playing else { return }
        state = .paused
        // Same shape as the old engine: the envelope fades, *then* the deck pauses —
        // pause() mid-waveform is a click (see `TransportFade`).
        transportFade.out(apply: { [weak self] in self?.applyVolume() },
                          then: { [weak self] in
                              guard let self else { return }
                              pipeline.pause(activeDeck)
                              deckIsSilenced = true
                              // Nothing is playing; the graph does not need to keep
                              // rendering silence, and the clock does not need to keep
                              // ticking four times a second to report a position that is
                              // not moving.
                              pipeline.suspendIO()
                              stopClock()
                          })
    }

    public func resume() {
        guard nowPlaying != nil else { return }
        if state == .loading {
            // Resuming during a load withdraws a pause asked for during the same load.
            pauseRequestedDuringLoad = false
            return
        }
        if state == .paused {
            deckIsSilenced = false
            pipeline.play(activeDeck)
            transportFade.in(apply: { [weak self] in self?.applyVolume() })
            state = .playing
            startClock()
            return
        }
        if state == .idle, let track = nowPlaying {
            load(track: track, startingAt: 0, autoplay: true)
        }
    }

    public func stop() {
        transportFade.out(apply: { [weak self] in self?.applyVolume() }) { [weak self] in
            guard let self else { return }
            teardownPlayback()
            deckIsSilenced = true
            pipeline.suspendIO()
            state = .idle
            currentTime = 0
        }
    }

    // `next()` and `previous()` used to live here. They navigated a queue that production
    // never filled, and no caller outside this file ever invoked them — `EngineDeckBridge`
    // does not even expose them. Transport Next reaches the deck as a fresh single-track
    // `load`, which is the only path that ever ran.

    // MARK: - Seek

    /// Seek to a track-logical position. Decision reuses `StreamSeek.strategy` verbatim —
    /// what changes is that "seekable ranges" are now the *spool's* honest answer instead
    /// of `AVPlayerItem.seekableTimeRanges`:
    ///  - `.direct` → reposition the decoder inside the spool: no network at all, exact
    ///    to the sample when the packet table is real. Backwards seeks are always here.
    ///  - `.reload` → re-request with `timeOffset` (still-encoding transcode; the same
    ///    delicate case the old engine solved — the solution transfers because it lives
    ///    in the URL, not in the player).
    public func seek(to seconds: TimeInterval) {
        guard let track = nowPlaying else { return }
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        let generation = bumpGeneration()
        let source = sources[activeDeck]
        Task { [weak self] in
            guard let self else { return }
            let reachable = await source?.reachableSeconds()
            guard generation == loadGeneration else { return } // superseded meanwhile
            let ranges = reachable.map { [$0] } ?? []
            switch StreamSeek.strategy(target: target, seekableRanges: ranges,
                                       streamStartOffset: streamStartOffset) {
            case .direct:
                await performInSpoolSeek(to: target, source: source, generation: generation)
            case .reload(let offset):
                // Ask the outgoing source where that second lives in the file *before*
                // `load` tears it down — it is the only thing that knows, and a moment
                // later it will not exist. Nil means the parser could not map it, and the
                // load falls back to fetching from zero.
                let resumeByte = await source?.fileByteOffset(forSeconds: offset - streamStartOffset,
                                                              trackDuration: track.duration)
                guard generation == loadGeneration else { return }
                load(track: track, startingAt: offset,
                     autoplay: state == .playing || state == .loading, resumeByte: resumeByte)
            }
        }
    }

    // MARK: - Graph restart (device / rate change)

    /// Re-anchor the current track after the graph restarted underneath us, reusing the
    /// bytes we already have.
    ///
    /// This used to be a plain `load(...)`, which tears down both decks *and their sources*
    /// — destroying the spool that already holds the audio — and then opens a fresh HTTP
    /// request. On a cold Navidrome transcode that is seconds of silence, and for a stream
    /// without `timeOffset` support (a raw mp3) the reload starts from byte zero and
    /// decode-discards to the playhead, so a route change mid-song re-downloads the entire
    /// prefix. On a phone this is an ordinary event: an AirPod in or out of an ear.
    ///
    /// The spool is still sitting there with the bytes. `StreamSeek.strategy` already knows
    /// how to decide between "reposition in what we have" and "ask the server", and it is
    /// the same decision a seek makes — so this asks it, and only falls back to the network
    /// when the spool genuinely cannot reach the position.
    func reanchorAfterGraphRestart() {
        guard let track = nowPlaying else { return }
        let wasPlaying = state == .playing || state == .loading
        guard let source = sources[activeDeck] else {
            // No live source (nothing loaded yet, or a previous failure tore it down) —
            // the old behaviour is the only option left.
            load(track: track, startingAt: currentTime, autoplay: wasPlaying)
            return
        }
        let target = currentTime
        let generation = bumpGeneration()
        Task { [weak self] in
            guard let self else { return }
            let reachable = await source.reachableSeconds()
            guard generation == loadGeneration else { return }
            let ranges = reachable.map { [$0] } ?? []
            switch StreamSeek.strategy(target: target, seekableRanges: ranges,
                                       streamStartOffset: streamStartOffset) {
            case .direct:
                await refeedFromSpool(to: target, source: source, generation: generation)
            case .reload(let offset):
                load(track: track, startingAt: offset, autoplay: wasPlaying)
            }
        }
    }

    /// Rebuild the deck from the spool we already have, at `target`.
    ///
    /// Nearly `performInSpoolSeek`, with one difference that matters: the format is replayed
    /// so the feeder calls `prepareDeck` again. A configuration change invalidates the
    /// engine's node connections, and `prepareDeck` is the only thing that reconnects a
    /// deck — a re-feed with `resuming: true` would schedule PCM into a disconnected node
    /// and play nothing at all.
    private func refeedFromSpool(to target: TimeInterval, source: TrackStreamSource, generation: Int) async {
        let outcome = await source.seek(toSeconds: target - streamStartOffset)
        guard generation == loadGeneration else { return }
        guard outcome == .repositioned, let track = nowPlaying else {
            if let track = nowPlaying {
                load(track: track, startingAt: target, autoplay: state == .playing || state == .loading)
            }
            return
        }
        await source.replayFormat()
        guard generation == loadGeneration else { return }
        #if DEBUG
        refeedCountForTesting += 1
        #endif
        feeders[activeDeck]?.cancel()
        pipeline.stopDeck(activeDeck)
        anchorFrames = 0
        clockBase = target
        currentTime = target
        finishedScheduling = false
        // `resuming: false` so the feeder consumes the replayed `.format` and re-prepares
        // the deck. It also restores intent-to-play there, after the connection exists.
        startFeeder(on: activeDeck, source: source, track: track, resuming: false, generation: generation)
    }

    private func performInSpoolSeek(to target: TimeInterval, source: TrackStreamSource?, generation: Int) async {
        guard let source else { return }
        let outcome = await source.seek(toSeconds: target - streamStartOffset)
        guard generation == loadGeneration else { return }
        guard outcome == .repositioned, let track = nowPlaying else {
            // The spool disagreed after all (estimate drift) — fall back to the reload
            // path rather than leave the scrubber lying about the position.
            if let track = nowPlaying {
                load(track: track, startingAt: target, autoplay: state == .playing)
            }
            return
        }
        // Flush the deck and re-feed from the repositioned source. The deck timeline
        // resets, so re-anchor the track clock at the target.
        feeders[activeDeck]?.cancel()
        pipeline.stopDeck(activeDeck)
        anchorFrames = 0
        clockBase = target
        currentTime = target
        finishedScheduling = false
        startFeeder(on: activeDeck, source: source, track: track, resuming: true, generation: generation)
        if state == .playing || state == .loading {
            pipeline.play(activeDeck)
        }
    }

    // MARK: - EQ / metering / volume

    /// Push EQ bands into the graph. Applies to every source including streams — the
    /// claim the whole experiment exists to prove; see `EngineStreamedEQTests`.
    public func applyEQ(bands: [EQBand], enabled: Bool) {
        pipeline.applyEQ(bands: bands, enabled: enabled)
    }

    /// Start feeding the now-playing bars. Works for streams (`EngineStreamedMeteringTests`),
    /// so the offline-envelope fallback (`TrackLevelTimeline`) is unnecessary here.
    public func startMetering(into snapshot: LevelSnapshot) { pipeline.startMetering(into: snapshot) }
    public func stopMetering() { pipeline.stopMetering() }

    /// True once a fade-out has actually paused the deck, until something plays again.
    ///
    /// `TransportFade` ends every fade-out by restoring the envelope to 1 and re-applying
    /// it, on the stated grounds that "the player is paused now, so restoring is silent".
    /// That is true of `AVPlayer`, whose `pause()` stops the audio outright. It is not true
    /// of `AVAudioPlayerNode`: pausing stops scheduling, but the render pipeline still
    /// holds buffered audio, so putting the level back to full makes that tail audible —
    /// the sound stops, briefly returns at full volume, and stops again.
    ///
    /// The invariant TransportFade is protecting (never leave the envelope at silence) is
    /// right, and this does not fight it: the envelope is still restored. This just
    /// declines to *hear* it until there is something to play.
    /// A pause asked for while a track was still loading, honoured when the load lands.
    private var pauseRequestedDuringLoad = false

    /// Re-requests spent recovering from a stream that ended before the track did.
    ///
    /// A transcode can die and still close its response cleanly — ffmpeg exits, Navidrome
    /// closes the chunked stream properly — and nothing downstream could tell that from a
    /// finished track: the boundary advanced the queue mid-song with no recovery. AVPlayer
    /// has been guarded against this since `StreamSeek` was written; the engine never was,
    /// while the design doc said it had been. On this failure class the engine was the
    /// worse of the two, on the path this project is proudest of.
    private var spuriousEndRecoveries = 0

    private var deckIsSilenced = false

    private func applyVolume() {
        guard !deckIsSilenced else {
            pipeline.masterVolume = 0
            return
        }
        pipeline.masterVolume = PlaybackVolume.effective(
            percent: isMuted ? 0 : volumePercent, loudness: 1, fade: externalEnvelope,
            transport: transportFade.multiplier
        )
    }

    /// Loudness normalization rides the deck gain (the crossfade ramp scales it), using
    /// the same pure ReplayGain math as the old engine.
    private func applyDeckGain() {
        pipeline.setDeckVolume(activeDeck, deckGain(for: nowPlaying))
    }

    private func deckGain(for track: Track?) -> Float {
        guard let song = track?.song else { return 1 }
        return StreamingPlaybackController.loudnessMultiplier(
            for: song, mode: loudnessMode, preampDB: loudnessPreampDB
        )
    }

    // MARK: - Loading

    private func bumpGeneration() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    /// - Parameter resumeByte: the file byte the target time lives at, when a caller has
    ///   been able to work it out from the *outgoing* source before this tore it down (see
    ///   `seek`). Turns a seek on a non-transcoded track from "fetch the whole prefix and
    ///   decode-discard it" into one ranged request. Nil keeps the old path, which is also
    ///   the fallback for every case that cannot use a range.
    private func load(track: Track, startingAt offset: TimeInterval, autoplay: Bool,
                      resumeByte: Int64? = nil) {
        #if DEBUG
        loadCountForTesting += 1
        #endif
        let generation = bumpGeneration()
        // A new track is audio we intend to be heard; whatever silenced the deck last time
        // does not apply to it. Without this, loading after a pause or a stop would render
        // into a muted graph and play nothing at all — a far worse bug than the blip this
        // gate exists to remove.
        // A new track supersedes any pause still owed by a fade in flight. Without this,
        // pausing and then picking a different track within ~280 ms handed the *new* track
        // the old track's pause: silenced, paused, and reported as playing.
        transportFade.supersede(apply: { [weak self] in self?.applyVolume() })
        // A new load is a fresh intent; a pause asked for during the *previous* load is
        // not owed to this one.
        pauseRequestedDuringLoad = false
        deckIsSilenced = false
        // Clearing the flag is not enough on its own: the graph is still carrying the zero
        // that was applied when it was silenced, and nothing else recomputes it until the
        // next volume event. Re-apply now, or the track loads and plays into a muted graph.
        applyVolume()
        cancelStallWatchdog()
        teardownDeck(activeDeck)
        teardownDeck(otherDeck)

        // Clamp like the old engine: an offset at/past the end fetches an empty stream.
        let clamped = max(0, min(offset, max(0, track.duration - 1)))
        let useTimeOffset = clamped >= StreamSeek.minimumOffset && track.supportsTimeOffset
        // The third way to reach a position, for the streams that can use neither of the
        // other two: ask the server for the bytes at that position. A track the server will
        // not offset is a stored file, and a stored file is byte-range seekable — which is
        // the same fact that made `format` get dropped from its URL in the first place.
        //
        // Only for formats whose frames carry their own headers: an MP4 needs its `moov` and
        // LPCM needs the WAVE header, so neither can begin mid-file.
        let hint = AudioStreamDecoder.fileTypeHint(forSuffix: track.song?.suffix)
        let rangeByte: Int64? = (!useTimeOffset && clamped >= StreamSeek.minimumOffset && hint != nil)
            ? resumeByte : nil

        // With `timeOffset` the stream's zero is the target (the old engine's
        // `streamStartOffset`). A ranged fetch is the same shape — its zero is the target
        // too — so the playhead arithmetic below is shared rather than special-cased. Only
        // the fetch-from-zero path still decode-discards.
        streamStartOffset = (useTimeOffset || rangeByte != nil) ? clamped : 0
        pendingLoadSkipSeconds = (useTimeOffset || rangeByte != nil) ? 0 : clamped
        anchorFrames = 0
        clockBase = clamped
        currentTime = clamped
        duration = track.duration
        finishedScheduling = false
        // The deck timeline restarts here, so the next reading is a baseline, not a verdict.
        playheadStall.reset()
        state = autoplay ? .loading : .paused
        isBuffering = autoplay

        let url = useTimeOffset ? StreamSeek.streamURL(track.url, offset: clamped) : track.url
        #if DEBUG
        lastStreamURLForTesting = url
        #endif
        let source = TrackStreamSource(url: url, headers: streamHeaders)
        sources[activeDeck] = source
        let deck = activeDeck
        Task { [weak self] in
            do {
                try await source.start(fromByte: rangeByte ?? 0, fileTypeHint: rangeByte != nil ? (hint ?? 0) : 0)
            } catch {
                self?.handleLoadFailure("\(error)", generation: generation)
                return
            }
            guard let self, generation == loadGeneration else { return }
            startFeeder(on: deck, source: source, track: track, resuming: false, generation: generation)
            if autoplay {
                // The deck itself starts inside the feeder, after `prepareDeck` has
                // connected it for the track's format. Starting it here would race the
                // connection — and `AVAudioPlayerNode.play()` on a never-connected node
                // raises an ObjC exception that, thrown through Swift-concurrency
                // frames, corrupts the task allocator and aborts far away ("freed
                // pointer was not the last allocation"; found by bisection).
                if pauseRequestedDuringLoad {
                    // Asked for while this was loading. Honour it now rather than starting
                    // audio the user has already said they do not want.
                    pauseRequestedDuringLoad = false
                    state = .playing      // so pause() has something to act on
                    applyDeckGain()
                    pause()
                    return
                }
                // Reaching `.playing` is *not* success, and clearing the retry ladder here
                // is what made a bad stream loop forever: a stream whose parse fails
                // milliseconds in still gets this far, so every cycle read load → playing →
                // reset → fail → "retry 1", the counter never climbed, `.error` never
                // arrived, and the host — which owns the skip — was never told. The reset
                // now lives in `clockTick`, gated on audio actually rendering (§2.4's
                // intent, which was that a track that *plays* ends a failure run).
                state = .playing
                applyDeckGain()
                startClock()
            }

        }
    }

    /// Per-feeder mutable state, held in one place instead of loop-local vars that
    /// would have to live across suspension points.
    private final class FeederContext {
        let deck: EngineAudioPipeline.DeckID
        let generation: Int
        var source: TrackStreamSource
        /// Whether the next `.format` chunk should (re)configure the deck. True for a
        /// fresh load; false after a gapless roll-over (the deck keeps its connection —
        /// a transcoded library shares one format; a genuine mismatch is the crossfade
        /// path's job).
        var expectFormatChunk = true
        /// Decode-discard resume for sources without `timeOffset` (seconds until the
        /// format announces a rate, frames after).
        var skipSeconds: TimeInterval = 0
        var skipFrames: Int64 = 0
        /// One-chunk lookahead: the previous buffer is scheduled only when the next
        /// arrives, so the *last* buffer is known and can carry the boundary callback.
        var pending: AVAudioPCMBuffer?
        /// The `DecodeDutyCycle` hysteresis latch: true once this feeder has filled to the
        /// high-water mark and is waiting for the buffer to drain before decoding again.
        var toppedUp = false

        init(deck: EngineAudioPipeline.DeckID, generation: Int, source: TrackStreamSource) {
            self.deck = deck
            self.generation = generation
            self.source = source
        }
    }

    /// The feeder: pulls decoded chunks and schedules them, holding one chunk of
    /// lookahead so the *last* buffer can carry the boundary callback — the audio-true
    /// end-of-track moment. On a clean end with a planned next track it rolls straight
    /// into the next source on the same deck: gapless by construction.
    private func startFeeder(
        on deck: EngineAudioPipeline.DeckID,
        source: TrackStreamSource,
        track: Track,
        resuming: Bool,
        generation: Int
    ) {
        feeders[deck]?.cancel()
        let context = FeederContext(deck: deck, generation: generation, source: source)
        context.skipSeconds = pendingLoadSkipSeconds
        if resuming { context.expectFormatChunk = false }
        pendingLoadSkipSeconds = 0
        feeders[deck] = Task { @MainActor [weak self] in
            await self?.runFeeder(context)
        }
    }

    /// Feed one track, then place the boundary callback and stop.
    ///
    /// This was a `while` loop, and the only thing that made it loop was `rollIntoGaplessNext`
    /// starting the *next* track's source on the same deck. With the queue gone there is no
    /// next track to roll into — the host loads it as a fresh track — so the loop had exactly
    /// one iteration and is now written that way.
    private func runFeeder(_ context: FeederContext) async {
        let endedCleanly: Bool
        do {
            endedCleanly = try await feedTrack(context)
        } catch {
            guard context.generation == loadGeneration else { return }
            if let held = context.pending { pipeline.schedule(held, on: context.deck) }
            context.pending = nil
            handleLoadFailure("\(error)", generation: context.generation)
            return
        }
        guard endedCleanly, context.generation == loadGeneration, !Task.isCancelled else { return }
        scheduleBoundary(context)
    }

    /// Pull-and-schedule loop for one track's stream. Returns true at a clean end of
    /// stream, false when superseded; throws on network/decode failure.
    private func feedTrack(_ context: FeederContext) async throws -> Bool {
        while !Task.isCancelled {
            guard context.generation == loadGeneration else { return false }
            // Backpressure, with hysteresis: fill to the high-water mark, then stay away
            // until the buffer has drained to the low-water mark, sleeping for as long as
            // that will take rather than polling. See `DecodeDutyCycle` for why the second
            // mark is the whole point and why the thinner buffer costs no resilience.
            switch Self.dutyCycle.next(aheadSeconds: pipeline.aheadSeconds(on: context.deck),
                                       toppedUp: &context.toppedUp) {
            case .idle(let seconds):
                #if DEBUG
                feederIdleWakeupsForTesting += 1
                #endif
                try await Task.sleep(for: .seconds(seconds))
                continue
            case .decode:
                break
            }
            #if DEBUG
            feederPullsForTesting += 1
            #endif
            guard let chunk = try await context.source.nextChunk() else { return true }
            guard context.generation == loadGeneration else { return false }
            switch chunk {
            case .format(let format):
                guard context.expectFormatChunk else { break }
                pipeline.prepareDeck(context.deck, format: format)
                trackSampleRate = format.sampleRate
                context.skipFrames = Int64(context.skipSeconds * format.sampleRate)
                context.expectFormatChunk = false
                // prepareDeck stops the node; restore intent-to-play.
                if state == .playing || state == .loading {
                    pipeline.play(context.deck)
                }
            case .pcm(let buffer):
                var buffer = buffer
                if context.skipFrames > 0 {
                    // Decode-discard resume for sources without `timeOffset`.
                    let drop = min(context.skipFrames, Int64(buffer.frameLength))
                    context.skipFrames -= drop
                    guard let kept = TrackStreamSource.dropFirst(frames: Int(drop), of: buffer),
                          kept.frameLength > 0 else { break }
                    buffer = kept
                }
                if let held = context.pending { pipeline.schedule(held, on: context.deck) }
                context.pending = buffer
            }
        }
        return false
    }

    private func scheduleBoundary(_ context: FeederContext) {
        finishedScheduling = true
        let generation = context.generation
        if let held = context.pending {
            context.pending = nil
            pipeline.schedule(held, on: context.deck) { [weak self] in
                self?.handleTrackAudioEnded(generation: generation)
            }
        } else {
            handleTrackAudioEnded(generation: generation)
        }
    }

    // `rollIntoGaplessNext` used to sit here: it started the next track's source on the
    // same deck so the audio crossed without a gap. It could only fire for a multi-track
    // queue, which production never built. It also carried an Appendix B latent bug — it
    // set `expectFormatChunk = false`, so a 44.1 → 48 kHz change at a boundary would have
    // scheduled mismatched buffers into the node, raising an ObjC exception and corrupting
    // the task allocator (the §1.1 crash class). Deleting the code removes the bug.

    /// How the feeder duty-cycles: fill to 8 s of scheduled PCM, then let it drain to 4 s
    /// before decoding again. The 8 s / 4 s pair is the one
    /// `docs/audio-engine-rearchitecture.md` specified from the start; only the high-water
    /// half had ever been built, so the feeder topped the buffer off in sips and woke five
    /// times a second to do it.
    private static let dutyCycle = DecodeDutyCycle()

    private func scheduledFramesSnapshot(_ deck: EngineAudioPipeline.DeckID) -> Int64 {
        Int64(pipeline.scheduledSeconds(on: deck) * max(trackSampleRate, 1))
    }

    /// The audio actually reached the end of the track (final buffer played).
    ///
    /// This is the **production end-of-track path for every engine track**, which is why the
    /// queue deletion had to rewrite it rather than delete it: the branch that advanced a
    /// multi-track queue was dead, but the spurious-end guard around it and the
    /// `onPlaybackEnded` hand-off underneath it are the live parts, and they stay exactly as
    /// they were. What the host does next — repeat, next track, autoplay radio, stop — has
    /// always been the host's decision, taken in `advanceAfterEnd`.
    private func handleTrackAudioEnded(generation: Int) {
        guard generation == loadGeneration else { return } // flushed, not played

        // An end that arrives well short of the track's own duration is not an end.
        //
        // A dying transcode can close its response cleanly — ffmpeg exits, Navidrome closes
        // the chunked stream properly — and that is indistinguishable from a finished track
        // to everything downstream: `markComplete` → `nextChunk` nil → boundary → end.
        // The track ends mid-song and nothing recovers. AVPlayer has been guarded against
        // exactly this since `StreamSeek` was written, with the same tolerance and the same
        // bounded budget; the engine never was, though the design doc said it had been.
        //
        // Re-request from the playhead instead, under a budget, so a genuinely short track
        // or a repeatedly-failing stream still ends rather than looping forever.
        let expected = nowPlaying?.duration ?? 0
        if let track = nowPlaying,
           expected > 0,
           currentTime < expected - StreamSeek.spuriousEndTolerance,
           spuriousEndRecoveries < StreamingPlaybackController.maxSpuriousEndRecoveries {
            spuriousEndRecoveries += 1
            let shortBy = expected - currentTime
            let attempt = spuriousEndRecoveries
            engineLog.notice(
                "engine: stream ended \(shortBy, format: .fixed(precision: 1))s early — re-requesting from the playhead (attempt \(attempt))"
            )
            load(track: track, startingAt: currentTime, autoplay: state == .playing)
            return
        }
        spuriousEndRecoveries = 0
        state = .idle
        currentTime = duration
        stopClock()
        onPlaybackEnded?()
    }

    // MARK: - Crossfade — deleted

    // `maybeStartCrossfade` and `cancelCrossfade` used to sit here: a clock-driven ramp that
    // started the next track on the idle deck and crossfaded the two deck volumes.
    //
    // It could never run. The ramp was gated on the *engine's* own `crossfadeSeconds`, and
    // nothing in production ever assigned it — every `player.crossfadeSeconds = …` site (the
    // menu command, Settings, the MCP tool, first-run personalization, the iPhone's settings)
    // targets `StreamingPlaybackController`'s separate property of the same name, which
    // drives the *host's* AVPlayer crossfade. So the `>= 0.05` guard never passed, and the
    // second guard could not have passed either: it needed a multi-track queue.
    //
    // It also held the second Appendix B latent bug — `seek()` bumps the generation without
    // cancelling a running ramp, whose guards then return without clearing `isCrossfading`,
    // after which every boundary was refused and the deck's download leaked until the next
    // load. Deleted as code rather than fixed, which is the point of Stage 5.
    //
    // Crossfade is not lost to users: the host's AVPlayer path still implements it, and
    // `maybeStartCrossfade` there refuses only while the engine owns playback.

    // MARK: - Clock + stall

    private func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.clockTick()
                try? await Task.sleep(for: .seconds(Self.clockInterval))
            }
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
    }

    private func clockTick() {
        guard state == .playing else { return }
        if trackSampleRate > 0 {
            let played = pipeline.playedFrames(on: activeDeck)
            currentTime = clockBase + Double(played - anchorFrames) / trackSampleRate
        }
        // Audio rendered since this load began — `clockBase` is where the load started, and
        // `currentTime` advances only on frames the deck actually played. Time the *stream*
        // has been alive would be the wrong measure: a dead stream can sit at `.playing`
        // indefinitely with nothing coming out.
        let renderedThisLoad = currentTime - clockBase
        if sameTrackRetries > 0, renderedThisLoad >= Self.retryResetDwellSeconds {
            sameTrackRetries = 0
        }
        if episodeRetries > 0, renderedThisLoad >= Self.episodeResetDwellSeconds {
            episodeRetries = 0
        }
        // Cleared by *playing*, on the same principle as the ladder above: a restart that
        // bought a healthy stretch of audio worked, and the next stall is a new one.
        if playheadRecoveries > 0, renderedThisLoad >= Self.retryResetDwellSeconds {
            playheadRecoveries = 0
        }
        // Buffering: intending to play, nothing left scheduled, and the track isn't
        // fully scheduled — the deck has genuinely run dry.
        let ahead = pipeline.aheadSeconds(on: activeDeck)
        let dry = ahead <= 0 && !finishedScheduling
        if dry != isBuffering {
            isBuffering = dry
            if dry { armStallWatchdog() } else { cancelStallWatchdog() }
        }

        // The complementary failure, which the check above structurally cannot see: audio
        // *is* queued and the playhead still is not moving. Every term in `dry` is about
        // data, so a wedged AUHAL reads as perfectly healthy there — see
        // `PlayheadStallDetector` for the overnight-sleep case that motivated this.
        guard pipeline.isSelfDriven else { return }
        if playheadStall.observe(playedFrames: pipeline.playedFrames(on: activeDeck),
                                 hasQueuedAudio: ahead > 0,
                                 intendsToPlay: state == .playing && !isBuffering,
                                 elapsed: Self.clockInterval) {
            recoverFromPlayheadStall()
        }
    }

    /// Audio is queued, the transport intends to play, and nothing is rendering.
    ///
    /// The ladder mirrors `handleLoadFailure`'s shape rather than inventing a second one:
    /// try the cheap local fix a bounded number of times, then hand over to the recovery
    /// that re-requests the stream. Restarting the I/O and re-feeding from the spool costs
    /// no network at all, which is why it goes first.
    private func recoverFromPlayheadStall() {
        playheadStall.reset()
        guard playheadRecoveries < Self.maxPlayheadRecoveries else {
            engineLog.error("engine: playhead still frozen after \(Self.maxPlayheadRecoveries) I/O restarts — falling through to the retry ladder")
            playheadRecoveries = 0
            handleLoadFailure("Playback stopped responding.", generation: loadGeneration)
            return
        }
        playheadRecoveries += 1
        let queued = Int(pipeline.aheadSeconds(on: activeDeck))
        engineLog.error("engine: playhead frozen at \(Int(self.currentTime))s with \(queued)s queued — restarting I/O (attempt \(self.playheadRecoveries))")
        guard pipeline.restartIO() else {
            playheadRecoveries = 0
            handleLoadFailure("Playback stopped responding.", generation: loadGeneration)
            return
        }
        // `restartIO` zeroed the deck's played-frame count, and the re-anchor below is
        // async (it asks the spool what it holds). Re-anchor the track clock *now* so the
        // scrubber holds its position in between instead of reading `-anchorFrames`.
        anchorFrames = 0
        clockBase = currentTime
        reanchorAfterGraphRestart()
    }

    /// Same policy as the old engine's watchdog: a stall that outlives the timeout is
    /// recovered by re-requesting the stream at the playhead, not waited out forever.
    private func armStallWatchdog() {
        guard stallWatchdog == nil else { return }
        let timeout = stallTimeoutSeconds
        stallWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, isBuffering, state == .playing else { return }
            stallWatchdog = nil
            engineLog.error("engine: buffering stalled > \(timeout)s — recovering at playhead")
            handleLoadFailure("Playback stalled — the connection may be blocked or too slow.",
                              generation: loadGeneration)
        }
    }

    private func cancelStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    /// The same recovery ladder shape as the old engine: retry the SAME
    /// track at the playhead a bounded number of times, then skip; cap total failures so
    /// an all-dead queue can't loop.
    private func handleLoadFailure(_ message: String, generation: Int) {
        guard generation == loadGeneration else { return }
        isBuffering = false
        cancelStallWatchdog()
        if sameTrackRetries < StreamingPlaybackController.maxSameTrackRetries,
           episodeRetries < Self.maxEpisodeRetries,
           let track = nowPlaying {
            sameTrackRetries += 1
            episodeRetries += 1
            let resumeAt = currentTime
            let attempt = sameTrackRetries
            state = .loading
            engineLog.error("engine: load failure (\(message, privacy: .public)) — retry \(attempt) of episode \(self.episodeRetries) at \(Int(resumeAt))s")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Double(attempt)))
                guard let self else { return }
                // A rung that decides not to climb used to do it in silence, and silence
                // here looks exactly like a track that stopped for no reason: no retry, no
                // `.error`, nothing for the host to act on. Say so.
                guard case .loading = state else {
                    engineLog.error("engine: retry \(attempt) abandoned — state moved to \("\(self.state)", privacy: .public) during the backoff")
                    return
                }
                load(track: track, startingAt: resumeAt, autoplay: true)
            }
            return
        }
        sameTrackRetries = 0
        // The end of the ladder was the one step with no log line, so a track that stopped
        // here was indistinguishable from one whose failure never arrived — which is exactly
        // the question that matters, because `.error` is what the host listens for.
        engineLog.error("engine: giving up on this track (\(message, privacy: .public)) — reporting .error to the host")
        state = .error(message)
        // The ladder ends here, at `.error`, which the bridge surfaces to the host through
        // `onFailure`. There used to be a tail below this that waited 1.5 s and called
        // `next()` — dead twice over: it was gated on `queue.count > 1`, and production
        // never built a queue with more than one track in it. Its removal is also the
        // direction §2.6 wants, which is that deck mode should have *one* retry ladder
        // rather than the engine's and the host's multiplying into ~9 fetch cycles of dead
        // air. The host's `handleLoadFailure` owns the skip.
    }

    // MARK: - Teardown

    private func retireSource(for deck: EngineAudioPipeline.DeckID) async {
        let source = sources[deck]
        sources[deck] = nil
        await source?.cancel()
    }

    private func teardownDeck(_ deck: EngineAudioPipeline.DeckID) {
        feeders[deck]?.cancel()
        feeders[deck] = nil
        pipeline.stopDeck(deck)
        if let source = sources[deck] {
            sources[deck] = nil
            Task { await source.cancel() }
        }
    }

    private func teardownPlayback() {
        _ = bumpGeneration()
        cancelStallWatchdog()
        stopClock()
        teardownDeck(.a)
        teardownDeck(.b)
        isBuffering = false
        finishedScheduling = false
        playheadStall.reset()
        playheadRecoveries = 0
    }
}

#endif
