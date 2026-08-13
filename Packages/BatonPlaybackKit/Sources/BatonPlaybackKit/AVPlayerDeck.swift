import AVFoundation
import Foundation
import OSLog
import BatonDSP
import BatonSubsonicKit
import BatonSubsonicModels
#if os(macOS)
import CoreAudio
#endif

/// The `AVPlayer` renderer, behind `PlaybackDeck` — the third implementation the seam was
/// named for, and the one that was not a deck until now.
///
/// `EngineDeckBridge` was always a clean deck: `StreamingPlaybackController` handed it a
/// track and got a clock back. The AVPlayer side was not separable the same way, so the
/// controller carried it inline and chose between the two at twenty-two branch sites, each
/// one written by hand. Everything here is the *inline half* of those branches, moved
/// verbatim: the queue player, its item lifecycle and observers, the clock, the seek
/// primitive and its `StreamSeek` decision, the stall watchdog, the transport fade, and the
/// two AVPlayer-only transitions — gapless preload and crossfade.
///
/// **Mechanics moved; policy did not.** The queue, `currentIndex`, repeat and shuffle,
/// scrobbling, now-playing, persistence, the retry ladder, and which deck takes a track all
/// stayed on the controller. The rule that decides what lives where is the one that made the
/// engine deck tractable: this type answers *render this*, the controller answers *why*.
///
/// **What it deliberately cannot do**, and says so rather than pretending:
/// `applyEQ`, the metering pair and `setOutputDevice` are no-ops here. AVFoundation gives no
/// render tap on a streamed item and no per-app output device, which is the whole reason the
/// engine deck exists — and a deck that quietly accepted those calls would make the two look
/// interchangeable when the audible difference between them is the entire experiment.
/// The equalizer still reaches *downloads* on this path, through `configureItem` (an
/// `AVAudioMix` on the item), because that is a property of the item rather than of the deck.
///
/// **Two things it owns that read like policy and are not.** `streamStartOffset` is the
/// mapping between this stream's clock and the track's — a stream fetched with Subsonic
/// `timeOffset` starts its clock at zero (see `StreamSeek`) — so only the thing holding the
/// player can convert one to the other, and every reading published from here is already
/// track-logical. And the transport fade shapes *this* player's own level around pause and
/// stop; the engine deck has always shaped its own, which is why the host used to carry two.
@MainActor
public final class AVPlayerDeck: PlaybackDeck {

    // MARK: - What the host hears back

    /// Track-logical position, best-known duration, and whether audio is waiting on the
    /// network. Pushed at the player's own 4 Hz, and *only* while an item is loaded — an
    /// emptied player has nothing to say about a track it is not playing.
    public var onClock: (@MainActor (TimeInterval, TimeInterval, Bool) -> Void)?
    /// The track reached its end, either by notification or by the parked-player fallback
    /// below. The host de-dupes and decides what happens next.
    public var onEnded: (@MainActor () -> Void)?
    /// The item failed, or the stall watchdog gave up on it.
    public var onFailure: (@MainActor (String) -> Void)?

    /// This stream cannot reach the seek target, so the host must re-request the track from
    /// `offset`. Building that URL needs the queue's provenance and the track's format —
    /// both policy — so the deck reports the finding instead of acting on it.
    var onReloadStream: (@MainActor (TimeInterval) -> Void)?
    /// The current item reached `readyToPlay`.
    var onItemReady: (@MainActor () -> Void)?
    /// A seek this deck issued has landed on the target.
    var onSeekLanded: (@MainActor () -> Void)?
    /// A duration the asset itself reported, once it was determinable — which for a
    /// transcode is often never, hence the metadata seed the host loads with.
    var onDuration: (@MainActor (TimeInterval) -> Void)?
    /// The buffering signal, derived from `timeControlStatus` rather than from the clock.
    var onBuffering: (@MainActor (Bool) -> Void)?

    /// Attaches the host's `AVAudioMix` (the equalizer tap) to an item before it plays.
    /// Every item this deck creates goes through it — current, preloaded and crossfading —
    /// because an item that misses it is one the EQ silently stops applying to.
    var configureItem: (@MainActor (AVPlayerItem) -> Void)?
    /// Whether the host still *intends* to be playing. Asked rather than mirrored: a copy
    /// of the host's transport state kept up to date by hand is the exact drift this whole
    /// extraction exists to end.
    var hostIntendsToPlay: (@MainActor () -> Bool)?

    // MARK: - The player

    /// `AVQueuePlayer` (an `AVPlayer` subclass, so seek/volume/observers all work) so that
    /// true **gapless** playback can preload the next item and let the OS auto-advance with
    /// no gap. Non-gapless paths keep exactly one item queued at a time.
    ///
    /// A `var` because a completed crossfade promotes its second player in place of this
    /// one; `promoteCrossfade()` is the only writer.
    private(set) var player = AVQueuePlayer()

    /// The item we consider "current" — the anchor a gapless preload is inserted after.
    private var loadedItem: AVPlayerItem?
    /// The track the player is rendering, kept so loudness normalization and the duration
    /// refinement read the song actually sounding rather than whatever the queue has moved
    /// on to. They used to read the host's `nowPlaying`, which during a skip blend is
    /// already the *incoming* track — so the outgoing player briefly carried the incoming
    /// track's ReplayGain.
    private var loadedSong: NavidromeSong?
    /// The server's metadata length for `loadedSong`, which outranks anything an offset
    /// stream reports about itself (`StreamSeek.logicalDuration`).
    private var metadataDuration: TimeInterval = 0
    /// Best-known duration: the metadata seed, refined once the asset can say.
    private(set) var duration: TimeInterval = 0

    /// How many seconds into the track this stream *begins*, when it was fetched with
    /// Subsonic `timeOffset` to reach a position a still-encoding transcode could not seek
    /// to (see `StreamSeek`). The player's clock restarts at zero for such a stream, so
    /// every track-logical reading is `streamStartOffset + player clock`. Zero otherwise.
    private(set) var streamStartOffset: TimeInterval = 0

    /// Custom server headers (Cloudflare Access etc.) for every asset this deck builds,
    /// carried from the last `load` so the preload and crossfade items get them too.
    private var streamHeaders: [String: String] = [:]

    // MARK: - Level

    private var volumePercent = 70
    private var isMuted = false
    /// The host's own envelope — sleep-timer fade × audio-focus duck — which multiplies
    /// with this deck's transport ramp rather than overwriting it.
    private var hostEnvelope: Float = 1
    private var loudnessMode: StreamingPlaybackController.LoudnessMode = .off
    private var loudnessPreampDB: Double = 0
    private var playbackRate: Float = 1

    /// Shapes this player's own volume around pause/stop/resume so transport actions don't
    /// click. Distinct from `crossfadeRamp`, which overlaps two players at a boundary.
    private let transportFade = TransportFade()
    let crossfadeRamp = CrossfadeRamp()

    // MARK: - Observers

    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var endObserver: (any NSObjectProtocol)?

    // MARK: - Seeking

    /// True while a seek this deck issued is in flight, so the clock cannot publish a stale
    /// position over the target and the parked-at-end fallback cannot mistake a seek for the
    /// end of the track.
    private var isSeeking = false
    /// Stamps each seek so only the newest one's completion is believed.
    private var seekGeneration = 0

    // MARK: - Stalls

    /// Watchdog for a mid-stream buffering STALL. `automaticallyWaitsToMinimizeStalling`
    /// waits *indefinitely* on a slow-but-open connection — the classic symptom behind a
    /// corporate proxy / TLS-inspection middlebox — so the UI shows an endless spinner and
    /// never recovers. Armed while the player waits with intent to play; cancelled the
    /// instant audio flows or the transport stops.
    private var stallWatchdog: Task<Void, Never>?
    private var stallTimeoutSeconds: Double = StreamingPlaybackController.defaultStallTimeout
    /// Recovery bookkeeping for a *parked* player with a healthy buffer (see
    /// `AVPlayerDeck+StallRecovery`), which is a different failure from waiting on bytes.
    var stallPolicy = StallRecoveryPolicy()

    // MARK: - Gapless look-ahead

    /// The item queued ahead of the current one for a gap-free boundary, and what it is.
    ///
    /// This was `(index: Int, item: AVPlayerItem)`, and the missing field was the song.
    /// Everything that validated the preload compared the *index* — but an index is a
    /// position, not an identity, and the queue moves underneath it. Remove the track
    /// sitting at index 1 and index 1 still exists, now holding a different song: the
    /// preload matched, survived, and the boundary played the removed track's audio while
    /// the host reconciled state onto whatever had shifted into that slot. The app named one
    /// track and played another, which is the defect class this codebase has already paid
    /// for once at the Lock Screen.
    struct PreloadSlot {
        /// Where the preload sits between being queued and being played.
        enum Stage: Equatable {
            /// Queued as a network stream. A disk prefetch may still be in flight.
            case stream
            /// Queued as a local file — already cached, downloaded, or swapped in by the
            /// host's prefetcher. The boundary is guaranteed gap-free.
            case local
        }
        let index: Int
        let song: NavidromeSong
        let item: AVPlayerItem
        var stage: Stage

        var songID: String { song.id }

        /// Whether this preload still describes the track the queue plans to play next.
        /// Both halves are required: the index can stay while the song changes (a removal
        /// shifts the queue up) and the song can stay while the index changes (a reorder).
        func matches(index plannedIndex: Int?, songID plannedSongID: String?) -> Bool {
            index == plannedIndex && song.id == plannedSongID
        }
    }

    private(set) var preload: PreloadSlot?

    /// The song a crossfade is blending *into*, adopted when its ramp is promoted.
    private var crossfadingInto: NavidromeSong?

    public init() {
        attachPlayerObservers()
    }

    // MARK: - Assets

    /// Builds the `AVURLAsset` for a stream/local URL, attaching the active server's custom
    /// headers for remote URLs. Local files skip the options — AVFoundation ignores headers
    /// for file URLs anyway.
    ///
    /// **The MIME hint is what makes the audio tap possible on streams.** A Subsonic stream
    /// URL has no file extension, so `loadTracks` — the *inspection* path — fails with
    /// "Cannot Open" even while the *playback* path happily sniffs and plays the bytes. And
    /// no inspection means no track, no `audioMix`, no tap: the equalizer and the level
    /// meter silently applied only to downloaded files, never to streams. Because that
    /// failure was `try?`-swallowed, nothing ever said so.
    ///
    /// The hint is exact by construction, not a guess: `streamURL(songID:)` always requests
    /// `format=mp3`, so any URL carrying that marker delivers MPEG audio — Navidrome
    /// transcodes everything else to match. Podcast enclosures and local files don't carry
    /// the marker and are left for AVFoundation to identify on its own.
    static func streamAsset(_ url: URL, headers: [String: String]) -> AVURLAsset {
        guard !url.isFileURL else { return AVURLAsset(url: url) }
        var options: [String: Any] = [:]
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        if let mime = mimeHint(for: url) { options[AVURLAssetOverrideMIMETypeKey] = mime }
        return options.isEmpty ? AVURLAsset(url: url) : AVURLAsset(url: url, options: options)
    }

    /// The out-of-band MIME type for a URL whose payload format we *know*, or nil to let
    /// AVFoundation work it out. Only our own `format=mp3` stream request qualifies — a
    /// wrong hint here wouldn't break an indicator, it would break playback.
    static func mimeHint(for url: URL) -> String? {
        guard let query = url.query, query.contains("format=mp3") else { return nil }
        return "audio/mpeg"
    }

    // MARK: - Transport

    public func load(song: NavidromeSong, url: URL, startingAt offset: TimeInterval,
                     autoplay: Bool, headers: [String: String], supportsTimeOffset: Bool) {
        cancelStallWatchdog() // a fresh load supersedes any pending stall watchdog
        // Settle any transport ramp still in flight, *before* the item is replaced. A
        // pending stop finishes with pause() + seek(.zero); arriving after the new item is
        // in place, it would pause and rewind the track that just started — press Stop,
        // pick another song inside the fade, and the app looks frozen with no error.
        transportFade.cancel(apply: { [weak self] in self?.applyVolume() })
        retireItemObservers()

        streamHeaders = headers
        loadedSong = song
        metadataDuration = Double(song.duration ?? 0)
        // Seed duration from the track's metadata immediately — Navidrome transcodes on the
        // fly, so AVPlayer often can't determine the stream's duration, which left the
        // scrubber stuck at 0:00. `refineDuration` improves it if the asset ever can.
        duration = metadataDuration
        streamStartOffset = offset
        isSeeking = false

        // The host hands over the *base* annotated URL and the offset separately, the same
        // way the engine deck takes them, because the two decks want different things from
        // an offset: the engine skips decoded frames, this one re-requests the stream with
        // Subsonic `timeOffset`. Rewriting it here is what lets `load` be one call rather
        // than a branch that builds two URLs.
        let streamURL = StreamSeek.streamURL(url, offset: offset, transcode: supportsTimeOffset)
        lastLoadedURL = streamURL
        let item = AVPlayerItem(asset: Self.streamAsset(streamURL, headers: headers))
        setCurrentItem(item)
        configureItem?(item)
        applyVolume()
        attachItemObservers(item)
        if autoplay {
            player.play()
        }
        refineDuration(of: item)
    }

    public func pause() {
        // Ramped rather than cut. The host updates state and Now Playing immediately, so
        // the UI still responds instantly; only the audio is shaped.
        transportFade.out(apply: { [weak self] in self?.applyVolume() },
                          then: { [weak self] in self?.player.pause() })
        cancelStallWatchdog()
    }

    public func resume() {
        player.play()
        // Ramped up rather than switched on: resuming mid-waveform is the same
        // discontinuity as pausing mid-waveform, just in the other direction.
        transportFade.in(apply: { [weak self] in self?.applyVolume() })
    }

    public func stop() {
        // Fade, then pause and rewind — seeking a still-audible player is the other way to
        // produce a click. The rewind is what makes a later play() resume from 0:00,
        // matching the scrubber the host resets, instead of continuing from where Stop was
        // pressed.
        transportFade.out(apply: { [weak self] in self?.applyVolume() }) { [weak self] in
            guard let self else { return }
            player.pause()
            player.seek(to: .zero)
        }
        cancelStallWatchdog()
    }

    /// Put the player down entirely: nothing queued, nothing observed, no ramp owed.
    ///
    /// Called when the engine deck takes a track. Nothing may be left on this side — a
    /// stale item would play in parallel — and the emptied queue is also what makes the
    /// clock below stand down, so the two decks can never both publish a playhead.
    func clear() {
        transportFade.cancel(apply: { [weak self] in self?.applyVolume() })
        cancelStallWatchdog()
        crossfadeRamp.cancel()
        retireItemObservers()
        player.removeAllItems()
        loadedItem = nil
        preload = nil
        loadedSong = nil
        crossfadingInto = nil
        streamStartOffset = 0
        isSeeking = false
    }

    public func seek(to seconds: TimeInterval) {
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeeking = true
        // Can this stream actually reach the target? A transcode the server is still
        // encoding reports `Accept-Ranges: none`, so AVPlayer's seek silently runs off the
        // end and the item reports EOF — which used to advance the queue. Ask the item what
        // it can reach, and have the host re-request the stream when it can't.
        switch StreamSeek.strategy(target: seconds,
                                   seekableRanges: seekableRanges(),
                                   streamStartOffset: streamStartOffset) {
        case .reload(let offset):
            isSeeking = false
            onReloadStream?(offset)
        case .direct:
            player.seek(to: CMTime(seconds: seconds - streamStartOffset, preferredTimescale: 600)) { [weak self] finished in
                Task { @MainActor in
                    guard let self, generation == self.seekGeneration else { return }
                    self.isSeeking = false
                    // `finished == false` past the generation guard is a genuine failure,
                    // not a superseding seek — the item couldn't reach the target after
                    // all. Recover by re-requesting rather than leaving the scrubber
                    // claiming a position the audio never went to.
                    guard !finished else { self.onSeekLanded?(); return }
                    streamingLog.info("direct seek did not complete; re-requesting stream at \(Int(seconds))s")
                    self.onReloadStream?(seconds)
                }
            }
        }
    }

    /// What the current item can actually seek to, in stream-local seconds.
    private func seekableRanges() -> [ClosedRange<TimeInterval>] {
        (player.currentItem?.seekableTimeRanges ?? []).compactMap {
            let r = $0.timeRangeValue
            let start = r.start.seconds
            let end = (r.start + r.duration).seconds
            guard start.isFinite, end.isFinite, end >= start else { return nil }
            return start...end
        }
    }

    // MARK: - Level

    public func applyLevel(volumePercent: Int, isMuted: Bool, envelope: Float) {
        self.volumePercent = volumePercent
        self.isMuted = isMuted
        hostEnvelope = envelope
        applyVolume()
    }

    public func applyLoudness(mode: StreamingPlaybackController.LoudnessMode, preampDB: Double) {
        loudnessMode = mode
        loudnessPreampDB = preampDB
        applyVolume()
    }

    /// The user's level times the loaded track's normalization multiplier, times the host's
    /// envelope, times this deck's own transport ramp — four independent reasons to be
    /// quieter, multiplied rather than overwriting one another.
    private func applyVolume() {
        let loudness = StreamingPlaybackController.loudnessMultiplier(
            for: loadedSong, mode: loudnessMode, preampDB: loudnessPreampDB
        )
        player.isMuted = isMuted
        player.volume = PlaybackVolume.effective(percent: volumePercent, loudness: loudness,
                                                 fade: hostEnvelope,
                                                 transport: transportFade.multiplier)
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        // Through `defaultRate` so pause/resume and gapless item advances keep the chosen
        // speed instead of snapping back to 1×.
        player.defaultRate = rate
        if hostIntendsToPlay?() == true { player.rate = rate }
    }

    public func setStallTimeout(_ seconds: Double) { stallTimeoutSeconds = seconds }

    // MARK: - What AVPlayer cannot do

    /// No-op: the equalizer reaches this path as an `AVAudioMix` on each item (see
    /// `configureItem`), not as a live graph node — which is why toggling it here needs a
    /// reload and why it never reached a streamed item at all before the MIME hint.
    public func applyEQ(bands: [EQBand], enabled: Bool) {}

    /// No-op: AVFoundation offers no render tap on a streamed item, so there is nothing to
    /// meter. The now-playing bars are dead on this deck by construction, and saying so
    /// here is better than accepting the call and rendering zeros — which is exactly what
    /// they did for a day while looking reactive.
    public func startMetering(into snapshot: LevelSnapshot) {}
    public func stopMetering() {}
    public func suspendMetering() {}
    public func resumeMetering() {}

    #if os(macOS)
    /// No-op: per-app output routing is a CoreAudio HAL facility the engine's own graph
    /// provides. AVPlayer follows the system default and cannot be told otherwise, so this
    /// reports the refusal rather than claiming a route it does not control.
    @discardableResult
    public func setOutputDevice(_ deviceID: AudioDeviceID?) -> Bool { false }
    public var currentOutputDeviceID: AudioDeviceID? { nil }
    #endif

    // MARK: - Item lifecycle

    /// Make `item` the sole queued item and adopt it as current. Replaces the old
    /// `replaceCurrentItem(with:)` — on a queue player we clear the queue (dropping any
    /// stale preload) and insert exactly one item.
    private func setCurrentItem(_ item: AVPlayerItem) {
        player.removeAllItems()
        if player.canInsert(item, after: nil) { player.insert(item, after: nil) }
        loadedItem = item
        preload = nil
    }

    /// Wire an item's status (decode/stream failures) + end-of-track notification. Shared by
    /// every path that adopts an item, so a loaded, gaplessly-advanced and crossfade-promoted
    /// item all behave identically.
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
                    self.onItemReady?()
                case .failed:
                    let message = failureMessage
                        ?? "Playback failed — the track may be an unsupported format (e.g. Ogg/Opus)."
                    streamingLog.error("stream item failed: \(message, privacy: .public)")
                    self.onFailure?(message)
                default:
                    break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
    }

    private func retireItemObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }

    /// Refine the duration from the asset when it's actually determinable (a real finite
    /// value) — otherwise the metadata seed stands.
    ///
    /// `StreamSeek.logicalDuration` owns the rule, notably that an offset stream's own
    /// duration must be ignored: it reports the whole track rather than the remainder, so
    /// adding the offset back inflates the track a little more with every seek.
    private func refineDuration(of item: AVPlayerItem) {
        let metadata = metadataDuration
        let offset = streamStartOffset
        Task { [weak self] in
            let seconds = await (try? item.asset.load(.duration))?.seconds
            guard let self, player.currentItem === item else { return }
            let logical = StreamSeek.logicalDuration(assetSeconds: seconds,
                                                     metadata: metadata,
                                                     streamStartOffset: offset)
            guard logical > 1, logical != duration else { return }
            duration = logical
            onDuration?(logical)
        }
    }

    // MARK: - The clock

    /// Wire the transport-status + periodic-clock observers to the current `player`.
    /// Factored out so a crossfade can promote its second player and re-observe it.
    private func attachPlayerObservers() {
        // Diagnose "playing but silent": log why the player is stalled, or confirm audio is
        // actually flowing. `.error` level so it persists to the log store. Doubles as the
        // UI buffering signal.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            // KVO can fire on AVFoundation's internal queues; read Sendable values here,
            // then hop to the main actor (assumeIsolated would trap off-main).
            let status = player.timeControlStatus
            let rate = player.rate
            let waitReason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .playing:
                    self.onBuffering?(false)
                    self.cancelStallWatchdog()
                    streamingLog.info("player: audio flowing (rate \(rate, privacy: .public))")
                case .waitingToPlayAtSpecifiedRate:
                    // Only "buffering" while the host actually intends to play (not paused).
                    let buffering = self.hostIntendsToPlay?() == true
                    self.onBuffering?(buffering)
                    streamingLog.error("player: waiting to play — reason \(waitReason, privacy: .public)")
                    // A slow-but-open connection can wait here forever (corporate proxy /
                    // VPN / TLS inspection). Arm the watchdog so playback recovers instead
                    // of spinning.
                    if buffering { self.armStallWatchdog() } else { self.cancelStallWatchdog() }
                case .paused:
                    self.onBuffering?(false)
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
                // **An empty player has nothing to say.** This observer stays installed for
                // the life of the deck, so while the engine deck owns playback it would
                // otherwise keep ticking with a zeroed clock and republish a stale
                // `streamStartOffset` as the playhead — the second writer that made the
                // scrubber jump and snap back on every Next, and the reason fixing the
                // engine's own stale tick did not end the symptom. The engine taking a
                // track empties this queue (`clear()`), so the guard is structural rather
                // than a flag someone has to remember to check.
                guard self.player.currentItem != nil else { return }
                // Nor during a crossfade, for the same reason: this observer stays attached
                // to the *outgoing* player until the incoming one is promoted, so it would
                // publish the old track's position over the new track's zero.
                guard !self.crossfadeRamp.isActive else { return }
                // Stalled-stream watchdog: runs on the same clock so a parked player with a
                // recovered buffer gets nudged (see +StallRecovery).
                self.stallRecoveryTick()
                // Don't let a stale clock tick override a just-issued seek target.
                guard !self.isSeeking else { return }
                // An offset stream's clock restarts at zero, so the track-logical playhead
                // is the offset plus the player's clock.
                let playhead = max(0, self.streamStartOffset + time.seconds)
                // The buffering flag rides the same condition the KVO above uses, so the
                // host has one sink and never two disagreeing writers. On this deck it is
                // nearly always false — a periodic observer does not tick while the player
                // is parked, which is exactly why `onBuffering` exists as its own channel.
                self.onClock?(playhead, self.duration,
                              self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                // Fallback end-of-track detection: some streams never post
                // AVPlayerItemDidPlayToEndTime. If the host intends to be playing but the
                // item has reached its end and the player has stopped advancing, drive the
                // end handler so the transport doesn't get stuck showing "playing" with a
                // parked player. The host de-dupes, so this won't re-fire.
                if self.hostIntendsToPlay?() == true,
                   TrackBoundary.isAtEnd(currentTime: playhead, duration: self.duration),
                   self.player.timeControlStatus == .paused
                {
                    self.onEnded?()
                }
            }
        }
    }

    /// Remove the current player's observers (before swapping players in a crossfade).
    private func detachPlayerObservers() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let timeObserverToken { player.removeTimeObserver(timeObserverToken) }
        timeObserverToken = nil
    }

    // MARK: - Stall watchdog

    /// Arm the watchdog if it isn't already running. Fires once after the timeout; before
    /// acting it re-checks that we're *still* stalled — the host intending to play and the
    /// player still waiting — so a connection that recovers on its own is left untouched.
    private func armStallWatchdog() {
        guard stallWatchdog == nil else { return }
        let timeout = stallTimeoutSeconds
        stallWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            stallWatchdog = nil
            guard hostIntendsToPlay?() == true,
                  player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            streamingLog.error("player: buffering stalled > \(timeout, privacy: .public)s — recovering")
            onFailure?(
                "Playback stalled — the connection may be blocked or too slow (check VPN or network filtering)."
            )
        }
    }

    /// Cancel any pending watchdog (audio resumed, the transport stopped, or recovery took over).
    private func cancelStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    // MARK: - Gapless look-ahead

    /// Queue `song` behind the current item so the OS advances to it with **no gap at all**.
    ///
    /// Inserted after `loadedItem` (the track we last made current) rather than after
    /// `player.currentItem`: `AVQueuePlayer` doesn't update `currentItem` synchronously
    /// after an insert, so requiring identity here would skip the preload and the boundary
    /// would fall back to a reload (a gap).
    @discardableResult
    func prepareNext(song: NavidromeSong, at index: Int, url: URL) -> Bool {
        guard preload == nil, let current = loadedItem else { return false }
        let item = AVPlayerItem(asset: Self.streamAsset(url, headers: streamHeaders))
        configureItem?(item) // attach EQ at preload creation, before it plays
        guard player.canInsert(item, after: current) else { return false }
        player.insert(item, after: current)
        preload = PreloadSlot(index: index, song: song, item: item,
                              stage: url.isFileURL ? .local : .stream)
        return true
    }

    /// Drop the queued next item (mode off, queue reordered, crossfade on…).
    func clearPreparedNext() {
        guard let preload else { return }
        player.remove(preload.item)
        self.preload = nil
    }

    /// Swap the queued *streaming* next item for a freshly prefetched local file, so the
    /// boundary is a gap-free local handoff. Refuses once the player has already advanced
    /// onto the queued item — replacing what is playing is not a swap, it's a cut.
    @discardableResult
    func swapPreparedNext(to localURL: URL, index: Int, songID: String) -> Bool {
        guard let slot = preload, slot.matches(index: index, songID: songID),
              player.currentItem !== slot.item, let current = loadedItem else { return false }
        let item = AVPlayerItem(asset: Self.streamAsset(localURL, headers: streamHeaders))
        configureItem?(item)
        guard player.canInsert(item, after: current) else { return false }
        player.remove(slot.item)
        player.insert(item, after: current)
        preload = PreloadSlot(index: slot.index, song: slot.song, item: item, stage: .local)
        return true
    }

    /// The OS gaplessly advanced onto the preloaded item — adopt it as current, with no
    /// reload and no re-buffer.
    ///
    /// The incoming track was preloaded from the top, so its clock is the track's. Carrying
    /// a previous track's `timeOffset` across the boundary would make the clock read
    /// `staleOffset + 0` as the new playhead — minutes into a track that just started, which
    /// reads as already-finished and skips it.
    @discardableResult
    func adoptPreparedNext() -> Bool {
        guard let slot = preload else { return false }
        retireItemObservers()
        loadedItem = slot.item
        preload = nil
        loadedSong = slot.song
        metadataDuration = Double(slot.song.duration ?? 0)
        duration = metadataDuration
        streamStartOffset = 0
        isSeeking = false
        attachItemObservers(slot.item)
        configureItem?(slot.item)
        applyVolume()
        refineDuration(of: slot.item)
        return true
    }

    // MARK: - Crossfade

    /// Start a second player on `url` at silence and ramp the two volumes past each other
    /// over `seconds`, then hand back through `onComplete` for the host to promote.
    ///
    /// The item is built and configured here so the EQ tap is attached *before* it plays —
    /// without that the equalizer silently switched off at the first crossfade boundary and
    /// stayed off for every crossfaded track thereafter.
    func beginCrossfade(into song: NavidromeSong, url: URL, targetIn: Float,
                        duration seconds: Double, steps: Int = 24,
                        onComplete: @escaping @MainActor () -> Void) {
        let item = AVPlayerItem(asset: Self.streamAsset(url, headers: streamHeaders))
        configureItem?(item)
        crossfadingInto = song
        crossfadeRamp.begin(
            item: item, targetIn: targetIn, isMuted: isMuted,
            outgoing: player, startOut: player.volume,
            duration: seconds, steps: steps
        ) { _ in onComplete() }
    }

    /// True while a second player is genuinely running. The host's own flag is a belief;
    /// this is the truth, and the two disagreeing is what once left a track playing that
    /// nothing could stop.
    var isCrossfadeRampActive: Bool { crossfadeRamp.isActive }

    /// Retire the outgoing player and promote the ramp's player in its place — the "hard
    /// cut" that happens under the cover of the completed fade. False when there is no ramp
    /// to promote.
    @discardableResult
    func promoteCrossfade() -> Bool {
        guard let promoted = crossfadeRamp.player else { return false }
        player.pause()
        detachPlayerObservers()
        retireItemObservers()

        player = promoted
        loadedItem = promoted.currentItem
        preload = nil
        crossfadeRamp.clearAfterPromotion() // release the ramp's ref without pausing the now-main player
        // The incoming stream starts at the track's top, so a previous track's `timeOffset`
        // must not carry across.
        streamStartOffset = 0
        isSeeking = false
        if let song = crossfadingInto {
            loadedSong = song
            metadataDuration = Double(song.duration ?? 0)
            duration = metadataDuration
        }
        crossfadingInto = nil

        attachPlayerObservers()
        if let item = promoted.currentItem {
            attachItemObservers(item)
            refineDuration(of: item)
        }
        applyVolume()
        return true
    }

    /// Abort an in-flight ramp: stop and drop the incoming player. The host restores the
    /// outgoing player's level through `applyLevel`.
    func cancelCrossfade() {
        crossfadeRamp.cancel()
        crossfadingInto = nil
    }

    // MARK: - What the host can ask

    /// Whether anything is loaded to resume. `AVQueuePlayer` *drains* its current item when
    /// a track (or the whole queue) plays to its end, so this goes false at a natural end
    /// and a `play()` would do nothing.
    var hasCurrentItem: Bool { player.currentItem != nil }

    /// The URL the player is actually sounding right now.
    ///
    /// The one observation that separates "named the right track" from "played the right
    /// track". Every other signal is our own bookkeeping, and the whole class of gapless bug
    /// is bookkeeping that disagrees with the audio.
    var currentItemURL: URL? { (player.currentItem?.asset as? AVURLAsset)?.url }

    /// The URL actually handed to `AVPlayerItem`, after the host's provenance annotation and
    /// this deck's `StreamSeek` rewrite — the only place the offset/transcode decisions
    /// become observable.
    private(set) var lastLoadedURL: URL?

    /// Stand in for "this stream was fetched with `timeOffset`", which a local file can't
    /// produce (it is fully seekable, so a seek never needs a re-request). Test seam.
    func setStreamStartOffsetForTesting(_ seconds: TimeInterval) { streamStartOffset = seconds }
}
