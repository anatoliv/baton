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

/// The **transport core** of the AVAudioEngine playback experiment: queue-of-tracks
/// playback over `EngineAudioPipeline` + `TrackStreamSource`, with EQ and metering that
/// apply to *streamed* audio — the thing `StreamingPlaybackController` structurally
/// cannot do (see docs/audio-engine-rearchitecture.md).
///
/// Deliberately a **sibling, not a replacement**: `StreamingPlaybackController`'s 87
/// public members are mostly queue/focus/persistence *policy*, and this type does not
/// duplicate them. What lives here is exactly the engine-facing transport the old
/// controller implements over AVPlayer — load/play/pause/stop, seek (including into a
/// still-encoding transcode), gapless track boundaries, crossfade, buffering + stall
/// recovery — implemented over scheduled PCM, and reusing the same pure decision types
/// (`StreamSeek`, `Crossfade`, `TransportFade`, `PlaybackVolume`,
/// `StreamingPlaybackController.onTrackEnd`) so the two engines cannot drift on policy.
///
/// The migration seam this implies is described in the design doc: policy stays in the
/// existing controller; this becomes the deck it drives for library streams.
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
    public private(set) var queue: [Track] = []
    public private(set) var currentIndex = 0
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    /// True while the transport intends to play but the deck has run dry — the engine's
    /// buffering signal, computed from facts (scheduled-ahead, spool growth) rather than
    /// inferred from `timeControlStatus`.
    public private(set) var isBuffering = false

    public var isPlaying: Bool { state == .playing }
    public var nowPlaying: Track? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }

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
    /// Fired when the queue genuinely ends (no next track, no replay) — the deck-mode
    /// hook a host controller uses to run its own advance policy.
    @ObservationIgnored public var onPlaybackEnded: (@MainActor () -> Void)?
    public var crossfadeSeconds: Double = 0
    public var repeatMode: StreamingPlaybackController.RepeatMode = .off
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
    @ObservationIgnored private var crossfadeTask: Task<Void, Never>?
    @ObservationIgnored private var isCrossfading = false

    @ObservationIgnored private var sameTrackRetries = 0
    @ObservationIgnored private var consecutiveFailures = 0

    #if DEBUG
    /// Test instrumentation, mirroring the old engine's boundary counters.
    public private(set) var gaplessAdvanceCountForTesting = 0
    public private(set) var loadCountForTesting = 0
    public var activeDeckForTesting: EngineAudioPipeline.DeckID { activeDeck }
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
            guard let self, let track = nowPlaying, isPlaying else { return }
            let at = currentTime
            load(track: track, startingAt: at, autoplay: true)
        }
        applyVolume()
    }

    // MARK: - Transport

    /// `atTime` starts the first track part-way in — one load, via `timeOffset` when the
    /// track supports it (deck-mode restore/seek lands in a single fetch). `autoplay:
    /// false` loads paused — a restored queue must never start sounding on its own, and
    /// a play-then-pause would (the pause lands while still `.loading` and no-ops).
    public func play(_ tracks: [Track], startAt index: Int = 0, atTime: TimeInterval = 0,
                     autoplay: Bool = true) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        guard let track = nowPlaying else { return }
        load(track: track, startingAt: max(0, atTime), autoplay: autoplay)
    }

    public func pause() {
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

    public func next() {
        guard !queue.isEmpty else { return }
        let wasPlaying = state == .playing
        switch StreamingPlaybackController.onManualNext(current: currentIndex, count: queue.count, repeatMode: repeatMode) {
        case let .play(idx):
            currentIndex = idx
            if let track = nowPlaying { load(track: track, startingAt: 0, autoplay: wasPlaying) }
        case .replay:
            if let track = nowPlaying { load(track: track, startingAt: 0, autoplay: wasPlaying) }
        case .stop:
            stop()
        }
    }

    public func previous() {
        guard !queue.isEmpty else { return }
        let wasPlaying = state == .playing
        if StreamingPlaybackController.previousRestartsCurrent(
            currentTime: currentTime, currentIndex: currentIndex, force: false
        ) {
            seek(to: 0)
        } else {
            currentIndex -= 1
            if let track = nowPlaying { load(track: track, startingAt: 0, autoplay: wasPlaying) }
        }
    }

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
                load(track: track, startingAt: offset, autoplay: state == .playing || state == .loading)
            }
        }
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

    private func load(track: Track, startingAt offset: TimeInterval, autoplay: Bool) {
        #if DEBUG
        loadCountForTesting += 1
        #endif
        let generation = bumpGeneration()
        // A new track is audio we intend to be heard; whatever silenced the deck last time
        // does not apply to it. Without this, loading after a pause or a stop would render
        // into a muted graph and play nothing at all — a far worse bug than the blip this
        // gate exists to remove.
        deckIsSilenced = false
        // Clearing the flag is not enough on its own: the graph is still carrying the zero
        // that was applied when it was silenced, and nothing else recomputes it until the
        // next volume event. Re-apply now, or the track loads and plays into a muted graph.
        applyVolume()
        cancelCrossfade()
        cancelStallWatchdog()
        teardownDeck(activeDeck)
        teardownDeck(otherDeck)

        // Clamp like the old engine: an offset at/past the end fetches an empty stream.
        let clamped = max(0, min(offset, max(0, track.duration - 1)))
        let useTimeOffset = clamped >= StreamSeek.minimumOffset && track.supportsTimeOffset
        // With `timeOffset` the stream's zero is the target (the old engine's
        // `streamStartOffset`); without it we fetch from zero and decode-discard.
        streamStartOffset = useTimeOffset ? clamped : 0
        pendingLoadSkipSeconds = useTimeOffset ? 0 : clamped
        anchorFrames = 0
        clockBase = clamped
        currentTime = clamped
        duration = track.duration
        finishedScheduling = false
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
                try await source.start()
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

    private func runFeeder(_ context: FeederContext) async {
        while !Task.isCancelled, context.generation == loadGeneration {
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
            guard await rollIntoGaplessNext(context) else { return }
        }
    }

    /// Pull-and-schedule loop for one track's stream. Returns true at a clean end of
    /// stream, false when superseded; throws on network/decode failure.
    private func feedTrack(_ context: FeederContext) async throws -> Bool {
        while !Task.isCancelled {
            guard context.generation == loadGeneration else { return false }
            // Backpressure: hold the pull while enough audio is queued.
            if pipeline.aheadSeconds(on: context.deck) > Self.highWaterSeconds {
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
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

    /// A track's stream ended cleanly: schedule the held final buffer carrying the
    /// boundary callback (or fire it now if nothing is held).
    private func scheduleBoundary(_ context: FeederContext) {
        finishedScheduling = true
        let endingIndex = currentIndex
        let generation = context.generation
        if let held = context.pending {
            context.pending = nil
            // The boundary sits after the held final buffer — count it into the anchor,
            // or the next track's clock starts one buffer (~0.4 s) early.
            let boundaryFrames = scheduledFramesSnapshot(context.deck) + Int64(held.frameLength)
            pipeline.schedule(held, on: context.deck) { [weak self] in
                self?.handleTrackAudioEnded(endingIndex: endingIndex,
                                            boundaryFrames: boundaryFrames,
                                            generation: generation)
            }
        } else {
            handleTrackAudioEnded(endingIndex: endingIndex,
                                  boundaryFrames: scheduledFramesSnapshot(context.deck),
                                  generation: generation)
        }
    }

    /// Gapless continuation: start the next track's source and keep scheduling on the
    /// same deck — no gap by construction. Returns false when there is no next track
    /// (or crossfade owns the transition, or the feeder was superseded).
    private func rollIntoGaplessNext(_ context: FeederContext) async -> Bool {
        guard crossfadeSeconds < 0.05,
              case let .play(nextIndex) = StreamingPlaybackController.onTrackEnd(
                  current: currentIndex, count: queue.count, repeatMode: repeatMode
              ),
              queue.indices.contains(nextIndex) else { return false }
        // `currentIndex` still names the ending track here (the boundary callback fires
        // later, when the audio crosses); a same-index "next" is a replay, not a roll.
        guard nextIndex != currentIndex else { return false }
        let nextTrack = queue[nextIndex]
        let nextSource = TrackStreamSource(url: nextTrack.url, headers: streamHeaders)
        do {
            try await nextSource.start()
        } catch {
            return false // the boundary callback closes out the queue instead
        }
        guard context.generation == loadGeneration, !Task.isCancelled else {
            await nextSource.cancel()
            return false
        }
        await retireSource(for: context.deck)
        sources[context.deck] = nextSource
        context.source = nextSource
        context.expectFormatChunk = false
        finishedScheduling = false // the next track is now streaming in
        return true
    }

    private static let highWaterSeconds: TimeInterval = 8

    private func scheduledFramesSnapshot(_ deck: EngineAudioPipeline.DeckID) -> Int64 {
        Int64(pipeline.scheduledSeconds(on: deck) * max(trackSampleRate, 1))
    }

    /// The audio actually crossed a track boundary (final buffer played). Reconcile the
    /// logical state — the engine equivalent of `gaplessAdvanced(to:)`, minus the item
    /// juggling it existed for.
    private func handleTrackAudioEnded(endingIndex: Int, boundaryFrames: Int64, generation: Int) {
        guard generation == loadGeneration else { return } // flushed, not played
        guard !isCrossfading else { return } // the ramp owns this transition
        switch StreamingPlaybackController.onTrackEnd(current: endingIndex, count: queue.count, repeatMode: repeatMode) {
        case let .play(nextIndex) where nextIndex != endingIndex && queue.indices.contains(nextIndex):
            #if DEBUG
            gaplessAdvanceCountForTesting += 1
            #endif
            currentIndex = nextIndex
            anchorFrames = boundaryFrames
            clockBase = 0
            streamStartOffset = 0
            currentTime = 0
            duration = queue[nextIndex].duration
            applyDeckGain()
        case .replay, .play:
            // `.play(same index)` is repeat-all on a single-track queue — a replay.
            if let track = nowPlaying { load(track: track, startingAt: 0, autoplay: true) }
        default:
            state = .idle
            currentTime = duration
            stopClock()
            onPlaybackEnded?()
        }
    }

    // MARK: - Crossfade

    /// Clock-driven, like the old engine: entering the window starts the incoming track
    /// on the idle deck and ramps the two deck volumes with the same `Crossfade.gains`
    /// steps. Readiness is no longer a heuristic — the ramp starts once the incoming
    /// deck has real audio scheduled (a fact), which is what 's readiness gate was
    /// approximating from outside AVPlayer.
    private func maybeStartCrossfade() {
        guard crossfadeSeconds >= 0.05, state == .playing, !isCrossfading else { return }
        guard Crossfade.inWindow(currentTime: currentTime, duration: duration, window: crossfadeSeconds) else { return }
        guard case let .play(nextIndex) = StreamingPlaybackController.onTrackEnd(
            current: currentIndex, count: queue.count, repeatMode: repeatMode
        ), nextIndex != currentIndex, queue.indices.contains(nextIndex) else { return }

        isCrossfading = true
        let generation = loadGeneration
        let incomingDeck = otherDeck
        let incomingTrack = queue[nextIndex]
        let outgoingDeck = activeDeck
        let source = TrackStreamSource(url: incomingTrack.url, headers: streamHeaders)
        sources[incomingDeck] = source
        let seconds = crossfadeSeconds

        crossfadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await source.start() } catch {
                isCrossfading = false
                return
            }
            guard generation == loadGeneration else { return }
            pipeline.setDeckVolume(incomingDeck, 0)
            startFeeder(on: incomingDeck, source: source, track: incomingTrack,
                        resuming: false, generation: generation)
            // (The deck starts inside the feeder once prepared — see `load`.)
            // Wait until the incoming deck holds real audio before fading — the engine's
            // readiness gate, exact where the old one guessed.
            while pipeline.aheadSeconds(on: incomingDeck) < 0.3 {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let startOut = pipeline.deckVolume(outgoingDeck)
            let targetIn = deckGain(for: incomingTrack)
            let steps = 24
            for i in 1 ... steps {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                let g = Crossfade.gains(step: i, of: steps, startOut: startOut, targetIn: targetIn)
                pipeline.setDeckVolume(outgoingDeck, g.out)
                pipeline.setDeckVolume(incomingDeck, g.in)
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // Promote: the incoming deck is now the main deck; retire the outgoing one.
            feeders[outgoingDeck]?.cancel()
            await retireSource(for: outgoingDeck)
            pipeline.stopDeck(outgoingDeck)
            activeDeck = incomingDeck
            currentIndex = nextIndex
            anchorFrames = 0
            clockBase = 0
            streamStartOffset = 0
            duration = incomingTrack.duration
            isCrossfading = false
        }
    }

    private func cancelCrossfade() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        if isCrossfading {
            isCrossfading = false
            feeders[otherDeck]?.cancel()
            pipeline.stopDeck(otherDeck)
            Task { [source = sources[otherDeck]] in await source?.cancel() }
            sources[otherDeck] = nil
            pipeline.setDeckVolume(activeDeck, deckGain(for: nowPlaying))
        }
    }

    // MARK: - Clock + stall

    private func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.clockTick()
                try? await Task.sleep(for: .milliseconds(250))
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
        // Buffering: intending to play, nothing left scheduled, and the track isn't
        // fully scheduled — the deck has genuinely run dry.
        let dry = pipeline.aheadSeconds(on: activeDeck) <= 0 && !finishedScheduling
        if dry != isBuffering {
            isBuffering = dry
            if dry { armStallWatchdog() } else { cancelStallWatchdog() }
        }
        maybeStartCrossfade()
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
        if sameTrackRetries < StreamingPlaybackController.maxSameTrackRetries, let track = nowPlaying {
            sameTrackRetries += 1
            let resumeAt = currentTime
            let attempt = sameTrackRetries
            state = .loading
            engineLog.error("engine: load failure (\(message, privacy: .public)) — retry \(attempt) at \(Int(resumeAt))s")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Double(attempt)))
                guard let self, case .loading = state else { return }
                load(track: track, startingAt: resumeAt, autoplay: true)
                sameTrackRetries = attempt // load() resets nothing; keep the ladder honest
            }
            return
        }
        sameTrackRetries = 0
        state = .error(message)
        consecutiveFailures += 1
        guard queue.count > 1, consecutiveFailures < queue.count else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, case .error = state else { return }
            next()
        }
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
        cancelCrossfade()
        cancelStallWatchdog()
        stopClock()
        teardownDeck(.a)
        teardownDeck(.b)
        isBuffering = false
        finishedScheduling = false
    }
}

#endif
