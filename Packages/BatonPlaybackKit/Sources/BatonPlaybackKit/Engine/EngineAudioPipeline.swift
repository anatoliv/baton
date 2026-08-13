#if os(macOS) || os(iOS)
// The engine is macOS/iOS only. watchOS has no AudioToolbox — no `AudioFileStream`, so no
// decoder, so no engine — and it plays downloaded files through AVPlayer. See
// `EngineDeckUnavailable.swift` for the stand-in that keeps the policy layer compiling.

import AVFoundation
import Foundation
import BatonDSP

/// The `AVAudioEngine` graph Baton owns end-to-end:
///
/// ```
/// deckA ─┐
///        ├→ blend → timePitch → eq → mainMixer → output (or offline render)
/// deckB ─┘                      │
///                               └ installTap → LevelAnalyzer → LevelSnapshot
/// ```
///
/// Owning the graph is the entire point of the rearchitecture: the EQ is a *node* every
/// sample passes through — streamed, downloaded, podcast, all of it — and the meter is a
/// tap on that node, not a workaround. Compare `AudioEQProcessor`, which exists only
/// because `MTAudioProcessingTap` was the sole entry into AVPlayer's render path (and
/// never runs for HTTP streams, the motivating bug).
///
/// Two decks: one active, the second only for crossfade overlap. Gapless does NOT use
/// the second deck — back-to-back `scheduleBuffer` on one deck is gapless by
/// construction, which deletes the preload/hot-swap machinery the AVPlayer engine needs.
///
/// Volume split (mirrors the old engine's per-player/master split so the composition
/// rules port verbatim): per-deck `volume` = loudness normalization × crossfade ramp;
/// `mainMixerNode.outputVolume` = user volume × transport fade × sleep fade.
///
/// `@MainActor`: all graph mutation happens here. The render thread runs only Apple's
/// nodes plus the metering tap, which calls the allocation-free `LevelAnalyzer` and one
/// atomic store — the same absolute rules `EQTapContext` documents.
@MainActor
public final class EngineAudioPipeline {
    public enum DeckID: CaseIterable, Sendable { case a, b }

    /// `.device` plays through the default output; `.offline` enables manual rendering so
    /// tests can pull deterministic audio with no audio hardware at all.
    public enum OutputMode {
        case device
        case offline(format: AVAudioFormat, maxFrames: AVAudioFrameCount)
    }

    private let engine = AVAudioEngine()
    private let deckA = AVAudioPlayerNode()
    private let deckB = AVAudioPlayerNode()
    private let blend = AVAudioMixerNode()
    /// Podcast speed (0.5×–2×) without pitch shift — the engine's `defaultRate`.
    /// Bypassed at 1× so the music path pays nothing for it.
    private let timePitch = AVAudioUnitTimePitch()
    private let eq: AVAudioUnitEQ

    private struct DeckState {
        var scheduledFrames: Int64 = 0
        var format: AVAudioFormat?
        /// Last observed played-frame count, kept so position survives pauses (a paused
        /// node reports no render time).
        var lastKnownPlayedFrames: Int64 = 0
    }

    private var decks: [DeckID: DeckState] = [.a: DeckState(), .b: DeckState()]
    private let analyzer = LevelAnalyzer()
    private var meteringSnapshot: LevelSnapshot?
    private var configurationChangeObserver: (any NSObjectProtocol)?
    /// Fired when the output device configuration changed under us (device switch, rate
    /// change). The engine restarts here; the *controller* re-schedules from its playhead
    /// — the graph can't know track positions. This is the honest cost of owning the
    /// pipeline: AVPlayer got this for free.
    public var onConfigurationChange: (@MainActor () -> Void)?

    /// Kept because output routing has to distinguish a live device graph (where a device
    /// can be chosen) from an offline render (where there is no device at all).
    private let outputMode: OutputMode

    public init(outputMode: OutputMode, eqBandCount: Int = EQLimits.frequencies.count) throws {
        self.outputMode = outputMode
        eq = AVAudioUnitEQ(numberOfBands: eqBandCount)
        eq.globalGain = 0
        eq.bypass = false

        for node in [deckA, deckB, blend, timePitch, eq] as [AVAudioNode] {
            engine.attach(node)
        }

        let chainFormat: AVAudioFormat?
        switch outputMode {
        case .device:
            chainFormat = nil // let the engine negotiate the device's format
        case let .offline(format, maxFrames):
            engine.stop()
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
            chainFormat = format
        }

        // Deck → blend connections are made per-track in `prepareDeck` (each track keeps
        // its native rate/channels; the mixer converts). The rest of the chain is fixed.
        engine.connect(blend, to: timePitch, format: chainFormat)
        engine.connect(timePitch, to: eq, format: chainFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: chainFormat)
        timePitch.bypass = true

        if case .device = outputMode {
            configurationChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleConfigurationChange() }
            }
        }

        #if os(macOS)
        // Before `prepare()`: `maximumFramesToRender` is refused once the unit is
        // initialised, and the device should be running at the chosen size before the
        // I/O proc starts rather than being changed underneath it.
        adoptRenderQuantum()
        #endif

        engine.prepare()
        try engine.start()
    }

    // No deinit: the observer token is released in `shutdown()` (a nonisolated deinit
    // can't touch main-actor state under strict concurrency, and the app keeps one
    // pipeline for its lifetime anyway; tests call `shutdown()` explicitly).

    // MARK: - Output routing (macOS only)
    //
    // Choosing an output device is a CoreAudio HAL capability and the HAL does not exist on
    // iOS: no `AudioDeviceID`, no `AUAudioUnit.deviceID`. The phone routes through
    // `AVAudioSession` instead, where the *system* owns the route and an app asks for a
    // category rather than a device. So this is not "iOS support not written yet" — per-app
    // output routing is macOS-only by platform design, and the phone's equivalent question
    // ("where is my audio going?") is answered by the session's current route.
    //
    // Guarded rather than stubbed on purpose: a stub that silently returns false would let
    // an iOS caller compile and quietly do nothing. Absence makes the call a build error at
    // the one place it could be written by mistake.
    #if os(macOS)

    /// Send Baton's audio to a specific output device, leaving every other app alone.
    ///
    /// `nil` restores "follow the system default", which is the resting state and what the
    /// engine does untouched. This is per-app routing on purpose: switching the *system*
    /// default would also work — that is how AirPlay was proven reachable at all — but a
    /// music player re-pointing every app's audio from a button in its transport bar is not
    /// a thing to do to someone.
    ///
    /// The engine must be stopped to re-point its output unit, and stopping it drops the
    /// scheduled buffers, so the caller has to re-anchor playback afterwards — the same job
    /// `onConfigurationChange` already does when the *system* changes device under us. It is
    /// reused here rather than duplicated, which also means the reload-at-playhead behaviour
    /// is identical whether the change came from us or from macOS.
    @discardableResult
    public func setOutputDevice(_ deviceID: AudioDeviceID?) -> Bool {
        guard case .device = outputMode else { return false }   // offline render: no device
        let unit = engine.outputNode.auAudioUnit
        let target = deviceID ?? AudioOutputDevices.defaultOutputDeviceID()
        guard target != 0, unit.deviceID != target else { return false }

        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        do {
            try unit.setDeviceID(target)
        } catch {
            // A device can vanish between listing it and choosing it (unplugged, AirPlay
            // dropped). Fall back to running on whatever we had rather than leaving the
            // engine stopped and silent.
            if wasRunning { try? engine.start() }
            return false
        }
        // The engine is stopped and pointed at the new device: the moment to give the old
        // device its buffer size back and ask the new one for ours.
        adoptRenderQuantum()
        if wasRunning { try? engine.start() }
        // The stop above discarded whatever the decks had scheduled; say so before anyone
        // reads `aheadSeconds` again. Both stop paths need this, so both call it.
        if wasRunning { forgetSchedulingAcrossEngineStop() }
        onConfigurationChange?()   // re-anchor playback at the playhead
        return true
    }

    /// The device Baton is currently rendering to, or nil when it can't be read.
    public var currentOutputDeviceID: AudioDeviceID? {
        guard case .device = outputMode else { return nil }
        let id = engine.outputNode.auAudioUnit.deviceID
        return id == 0 ? nil : id
    }

    // MARK: - Render quantum
    //
    // The render quantum was left at whatever the device happened to be using — 512 frames
    // on this hardware, so the I/O proc woke about 86 times a second from app launch to
    // quit. Wake-up frequency weighs heavily in the energy-impact index, which is the number
    // the engine's adoption rests on, and this was the largest untouched lever on the
    // *playing* half of that gap.
    //
    // Two things make this delicate enough to be worth spelling out.
    //
    // **The property is the device's, not ours.** Unlike `setOutputDevice`, which is
    // per-app by design and deliberately leaves every other app alone, the buffer frame size
    // is shared by every client of that output. So the policy here is a borrower's: raise a
    // device that is running smaller than we want, never shrink one another app has already
    // raised, and put the original back on the way out.
    //
    // **The ceiling is the device's to state.** The built-in output tops out at 1024 frames,
    // so asking for the 4096 that the plan assumed would simply fail and forfeit the whole
    // optimisation. The target is clamped to the advertised range, which is why this reads
    // as "ask for a lot, take what is offered" rather than a constant.

    /// What we would like, before the device gets a say. Deliberately above any current
    /// hardware ceiling: the clamp decides, and a device that allows more should give more.
    private static let preferredRenderFrames: UInt32 = 4096

    /// The device we raised and the value it had before, so it can be handed back exactly.
    private var borrowedBufferSize: (device: AudioDeviceID, original: UInt32)?

    /// Raise the current output device's render quantum, remembering what to restore.
    ///
    /// Call with the engine stopped: `maximumFramesToRender` is rejected once the unit is
    /// initialised, and changing the device's buffer size under a live I/O proc is a glitch
    /// nobody asked for.
    private func adoptRenderQuantum() {
        guard case .device = outputMode else { return }
        let device = engine.outputNode.auAudioUnit.deviceID
        guard device != 0 else { return }

        // Switched devices? Give the previous one back first.
        if let borrowed = borrowedBufferSize, borrowed.device != device { releaseRenderQuantum() }

        guard let range = AudioOutputDevices.bufferFrameSizeRange(of: device),
              let current = AudioOutputDevices.bufferFrameSize(of: device)
        else { return }
        let target = min(max(Self.preferredRenderFrames, range.lowerBound), range.upperBound)

        // Already at or above what we want — someone else asked for it, and shrinking their
        // buffer to "our" number would be exactly the rudeness this whole comment is about.
        guard target > current else { return }

        // The unit must be willing to render a slice this large before the device starts
        // handing it one. Settable only while uninitialised, hence the stopped-engine rule.
        let unit = engine.outputNode.auAudioUnit
        if unit.maximumFramesToRender < target { unit.maximumFramesToRender = target }

        guard AudioOutputDevices.setBufferFrameSize(target, on: device) else {
            engineLog.notice("engine: device \(device) refused a \(target)-frame quantum; leaving it at \(current)")
            return
        }
        if borrowedBufferSize == nil { borrowedBufferSize = (device, current) }
        engineLog.notice("engine: render quantum \(current) → \(target) frames on device \(device)")
    }

    /// Hand the device back the buffer size it had. A setting that outlives the app that
    /// wanted it is a bug in someone else's audio.
    private func releaseRenderQuantum() {
        guard let borrowed = borrowedBufferSize else { return }
        borrowedBufferSize = nil
        // Only if nothing has since raised it further — that would be another app's ask, and
        // restoring "our" original over it would be the shrink this policy forbids.
        if let now = AudioOutputDevices.bufferFrameSize(of: borrowed.device), now > borrowed.original {
            AudioOutputDevices.setBufferFrameSize(borrowed.original, on: borrowed.device)
        }
    }

    #endif

    /// Let the I/O unit sleep while nothing is being played.
    ///
    /// Measured, not assumed: paused, the engine cost ~2.1 energy impact against AVPlayer's
    /// ~0.1 — *more* than the 1.8 it costs while actually playing music. Pausing a deck
    /// stops the player node, but the engine kept pulling blend → timePitch → EQ → mixer
    /// and rendering silence, for as long as the app was open. On a phone, paused and
    /// backgrounded is most of the day.
    ///
    /// `pause()` rather than `stop()`: it parks the I/O unit while keeping the graph,
    /// connections and formats intact, so waking is cheap and nothing needs rebuilding.
    /// `play()` restarts a stopped engine by construction (see the guard there), which is
    /// what makes this safe to do at all — and is why that fix had to land first.
    func suspendIO() {
        guard engine.isRunning else { return }
        engine.pause()
    }

    #if DEBUG
    /// Stop the engine the way an interruption does, so the crash hole above can be tested.
    public func stopEngineForTesting() { engine.stop() }
    /// The other half, so a test can drive the *whole* stop-and-restart a device change
    /// performs (`setOutputDevice` stops, re-points and starts) rather than only its first
    /// half. What survives that restart is the open question under §2.5.
    public func startEngineForTesting() throws { try engine.start() }
    /// Drive the whole device-change path (stop, restart, forget what was scheduled) without
    /// a device to change — the offline pipeline never receives the system notification.
    public func simulateConfigurationChangeForTesting() {
        engine.stop()
        handleConfigurationChange()
    }
    public var isEngineRunningForTesting: Bool { engine.isRunning }
    #endif

    private func handleConfigurationChange() {
        // The engine stops itself on a device/rate change. Restart it, then hand the
        // controller the job of rescheduling audio from the current playhead.
        //
        // A swallowed failure here used to be followed immediately by an autoplay reload
        // straight into a stopped engine — the crash above, reached through a *failed*
        // restart rather than an absent one, which no `isRunning` check downstream can
        // distinguish from success. `play()` now refuses on a stopped engine, so this can
        // no longer crash; it is logged because a silent no-audio is its own bug report.
        #if os(macOS)
        // The system may have moved us to a different device, which has its own ceiling and
        // its own original value — and the engine is stopped right now, which is when this
        // can be changed safely.
        adoptRenderQuantum()
        #endif
        do {
            try engine.start()
        } catch {
            engineLog.error("engine: restart after configuration change failed: \(error.localizedDescription, privacy: .public)")
        }
        forgetSchedulingAcrossEngineStop()
        onConfigurationChange?()
    }

    /// After the engine has been stopped underneath the decks, nothing that was scheduled on
    /// them is still there — so the bookkeeping must say so.
    ///
    /// This was §2.5's deliberately-unfinished half, held back because the correct line
    /// depended on a fact nobody had established: does `engine.stop()` discard buffers
    /// already scheduled on a player node? Measured both ways in `EngineStopFlushTests` and
    /// the answer is yes — offline, the audio is simply gone after a restart, and on a real
    /// device the buffer's completion handler never fires at all, which is stronger than it
    /// sounds: a four-second buffer that had played 0.4 s neither completed at the stop nor
    /// any time in the following five and a half seconds. It was dropped, not consumed.
    ///
    /// Leaving `scheduledFrames` behind made `aheadSeconds` stale-positive, so `clockTick`'s
    /// dry-detection read "there is audio queued" and never raised `isBuffering` — a stall
    /// invisible to the one thing that exists to notice stalls. The same measurement also
    /// showed why it stayed invisible: a starved player node's clock keeps advancing, so the
    /// playhead moves convincingly over silence.
    private func forgetSchedulingAcrossEngineStop() {
        for deck in [DeckID.a, .b] {
            decks[deck]?.scheduledFrames = 0
            decks[deck]?.lastKnownPlayedFrames = 0
        }
    }

    private func node(_ deck: DeckID) -> AVAudioPlayerNode { deck == .a ? deckA : deckB }

    // MARK: - Deck lifecycle

    /// (Re)connect a deck for a track's PCM format. Called once per track load; the
    /// scheduled buffers must match the connection format, and each track keeps its
    /// native rate/channels (the blend mixer converts onward).
    public func prepareDeck(_ deck: DeckID, format: AVAudioFormat) {
        let player = node(deck)
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: blend, format: format)
        decks[deck] = DeckState(format: format)
    }

    /// Schedule PCM on a deck. `onPlayed` (optional) fires on the main actor when the
    /// buffer has been **rendered** — the boundary-bookkeeping moment.
    ///
    /// `.dataRendered`, not `.dataPlayedBack`, deliberately: measured in this worktree,
    /// `.dataPlayedBack` completions **never fire in manual-rendering mode** (there is
    /// no output timeline to anchor "played back" to), while `.dataRendered` fires in
    /// both modes. Live, rendered precedes audible by only the output latency — a few
    /// ms, comparable to the old engine's end-notification precision.
    public func schedule(_ buffer: AVAudioPCMBuffer, on deck: DeckID,
                         onPlayed: (@MainActor @Sendable () -> Void)? = nil) {
        decks[deck]?.scheduledFrames += Int64(buffer.frameLength)
        if let onPlayed {
            // Explicitly `@Sendable`: AVFAudio invokes this on an internal queue, and a
            // closure formed in a @MainActor context without the annotation gets a
            // main-queue assertion injected by dynamic isolation checking — which then
            // fails on that queue (SIGTRAP in _dispatch_assert_queue_fail).
            let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { _ in
                Task { @MainActor in onPlayed() }
            }
            node(deck).scheduleBuffer(buffer, completionCallbackType: .dataRendered, completionHandler: completion)
        } else {
            node(deck).scheduleBuffer(buffer)
        }
    }

    /// Start a deck. Hard-guarded on the deck having been prepared (connected for a
    /// format): `AVAudioPlayerNode.play()` on a never-connected node raises an ObjC
    /// exception, and that exception unwinding through Swift-concurrency frames corrupts
    /// the task allocator — the process then aborts *somewhere else entirely* with
    /// "freed pointer was not the last allocation". Found by bisection; the guard turns
    /// a haunted-house crash into a loud log line.
    public func play(_ deck: DeckID) {
        guard decks[deck]?.format != nil else {
            engineLog.error("engine: refused play() on unprepared deck \(String(describing: deck))")
            return
        }
        // The engine must be running before a node is told to play, and nothing else
        // guarantees that it is.
        //
        // `AVAudioPlayerNode.play()` on a stopped engine raises an ObjC exception, and that
        // exception unwinding through Swift-concurrency frames corrupts the task allocator —
        // so the process dies somewhere else entirely, with a "freed pointer was not the
        // last allocation" that names none of this. It was found once by bisection already.
        //
        // An AVAudioSession interruption — a phone call — stops the engine, and an
        // interruption does not reliably post a configuration change, so the only restarts
        // in this file (init, the macOS device switch, the configuration-change handler)
        // may never run. All three `pipeline.play` callers are exposed: resume, seek, and
        // the feeder, which is reached by tapping *any* track. So the check belongs here,
        // where it covers them by construction, rather than on the resume path where only
        // the least likely of the three lives.
        if !engine.isRunning {
            do {
                try engine.start()
                engineLog.notice("engine: restarted a stopped engine before play()")
            } catch {
                // Refuse rather than proceed. Silence with a log is a bad outcome; an
                // abort in an unrelated frame minutes later is a far worse one.
                engineLog.error("engine: could not restart before play(): \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        node(deck).play()
    }
    public func pause(_ deck: DeckID) {
        _ = playedFrames(on: deck) // capture position before the node stops reporting it
        node(deck).pause()
    }

    /// Stop a deck and flush everything scheduled on it. Resets the deck's timeline —
    /// callers re-anchor their track clock afterwards.
    public func stopDeck(_ deck: DeckID) {
        node(deck).stop()
        decks[deck]?.scheduledFrames = 0
        decks[deck]?.lastKnownPlayedFrames = 0
    }

    // MARK: - Position / backpressure signals

    /// Frames this deck has actually rendered since its timeline began (survives pauses
    /// via the cached last-known value).
    ///
    /// The validity check is load-bearing, not defensive: after `play()` but before the
    /// first render (guaranteed to happen in manual-rendering mode, possible live),
    /// `lastRenderTime` exists with *neither* sample nor host time valid, and
    /// `playerTimeForNodeTime:` then raises an ObjC assertion. Worse, that exception
    /// unwinding through Swift-concurrency frames corrupts the task allocator, and the
    /// process aborts later, somewhere unrelated, with "freed pointer was not the last
    /// allocation" — found by bisection + lldb, documented in the design doc.
    public func playedFrames(on deck: DeckID) -> Int64 {
        let player = node(deck)
        if let nodeTime = player.lastRenderTime,
           nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
           let playerTime = player.playerTime(forNodeTime: nodeTime),
           playerTime.isSampleTimeValid {
            decks[deck]?.lastKnownPlayedFrames = playerTime.sampleTime
        }
        return decks[deck]?.lastKnownPlayedFrames ?? 0
    }

    public func playedSeconds(on deck: DeckID) -> TimeInterval {
        guard let rate = decks[deck]?.format?.sampleRate, rate > 0 else { return 0 }
        return Double(playedFrames(on: deck)) / rate
    }

    /// Seconds of audio scheduled but not yet played — the backpressure and stall signal.
    /// Zero while the deck intends to play means the pipeline has run dry (buffering).
    public func aheadSeconds(on deck: DeckID) -> TimeInterval {
        guard let state = decks[deck], let rate = state.format?.sampleRate, rate > 0 else { return 0 }
        return max(0, Double(state.scheduledFrames - playedFrames(on: deck)) / rate)
    }

    public func scheduledSeconds(on deck: DeckID) -> TimeInterval {
        guard let state = decks[deck], let rate = state.format?.sampleRate, rate > 0 else { return 0 }
        return Double(state.scheduledFrames) / rate
    }

    // MARK: - Volume

    /// Per-deck gain: loudness normalization × crossfade ramp position.
    public func setDeckVolume(_ deck: DeckID, _ volume: Float) {
        node(deck).volume = max(0, volume)
    }

    public func deckVolume(_ deck: DeckID) -> Float { node(deck).volume }

    /// Master level: user volume × transport fade × sleep fade (see `PlaybackVolume`).
    public var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, newValue) }
    }

    /// Playback rate (podcasts). 1 bypasses the time-pitch unit entirely.
    public var playbackRate: Float {
        get { timePitch.bypass ? 1 : timePitch.rate }
        set {
            let clamped = min(2.0, max(0.5, newValue))
            timePitch.rate = clamped
            timePitch.bypass = clamped == 1
        }
    }

    // MARK: - EQ

    /// Push the equalizer's parametric bands into the EQ node. Unlike the tap-based EQ,
    /// this needs no item reload, no re-fetch, and cannot be "left off" a new item at a
    /// boundary (the  bug class) — the node is simply always in the graph.
    public func applyEQ(bands: [EQBand], enabled: Bool) {
        for (index, band) in eq.bands.enumerated() {
            guard index < bands.count else {
                band.bypass = true
                continue
            }
            let spec = bands[index].clamped()
            band.filterType = .parametric
            band.frequency = Float(spec.frequency)
            band.bandwidth = Self.bandwidthOctaves(q: spec.q)
            band.gain = Float(spec.gainDB)
            band.bypass = false
        }
        // Click-free live toggle — the reload dance `refreshAudioMix` performs to attach
        // or drop the tap on AVPlayer simply doesn't exist here.
        eq.bypass = !enabled
    }

    /// `AVAudioUnitEQ` expresses bandwidth in octaves; the equalizer store speaks Q.
    /// Standard conversion: N = (2/ln 2) · asinh(1/(2Q)).
    static func bandwidthOctaves(q: Double) -> Float {
        let qSafe = max(q, 0.05)
        return Float((2.0 / log(2.0)) * asinh(1.0 / (2.0 * qSafe)))
    }

    // MARK: - Metering

    /// Attach the level meter: a tap on the EQ's output (post-EQ — the bars show what you
    /// hear) feeding the existing `LevelAnalyzer` → `LevelSnapshot` chain unchanged.
    /// This works for **every** source, which is the other half of the prize:
    /// `MTAudioProcessingTap` never ran for HTTP-streamed items.
    public func startMetering(into snapshot: LevelSnapshot) {
        guard meteringSnapshot == nil else { return }
        meteringSnapshot = snapshot
        let format = eq.outputFormat(forBus: 0)
        analyzer.prepare(sampleRate: format.sampleRate)
        let analyzer = self.analyzer
        // Explicitly `@Sendable` for the same reason as the schedule completion: the tap
        // runs on AVFAudio's render-adjacent queue, and an implicitly MainActor-assumed
        // closure would trip dynamic isolation checking there.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            // Render-context closure: no allocation, no locks. `floatChannelData` is a
            // pointer into the buffer; rebinding to the optional-pointer shape the
            // analyzer takes is layout-identical (a null pointer is `nil`).
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let count = Int(buffer.format.channelCount)
            UnsafeRawPointer(channels).withMemoryRebound(
                to: UnsafeMutablePointer<Float>?.self, capacity: count
            ) { pointers in
                snapshot.store(analyzer.analyze(
                    channelPointers: pointers, channelCount: count, frames: Int(buffer.frameLength)
                ))
            }
        }
        eq.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tap)
    }

    public func stopMetering() {
        guard meteringSnapshot != nil else { return }
        eq.removeTap(onBus: 0)
        meteringSnapshot?.clear()
        meteringSnapshot = nil
        analyzer.reset()
    }

    // MARK: - Offline rendering (tests)

    /// Pull `frames` of rendered output in manual-rendering mode. The test loop
    /// interleaves short renders with `Task.yield()` so scheduling hops can land.
    @discardableResult
    public func renderOffline(frames: AVAudioFrameCount, into buffer: AVAudioPCMBuffer) throws
        -> AVAudioEngineManualRenderingStatus {
        try engine.renderOffline(frames, to: buffer)
    }

    public var manualRenderingFormat: AVAudioFormat { engine.manualRenderingFormat }

    #if DEBUG
    func nodeForTesting(_ deck: DeckID) -> AVAudioPlayerNode { node(deck) }
    #endif

    /// Tear the graph down (tests; the app keeps one pipeline for its lifetime).
    public func shutdown() {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
            self.configurationChangeObserver = nil
        }
        stopMetering()
        deckA.stop()
        deckB.stop()
        engine.stop()
        #if os(macOS)
        releaseRenderQuantum()
        #endif
    }
}

#endif
