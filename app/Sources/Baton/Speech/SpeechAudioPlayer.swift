import AVFoundation
import Foundation
@_exported import BatonSpeech
#if os(macOS)
import CoreAudio
#endif

/// Plays a spoken summary through an `AVAudioEngine` of its own, so it can be sent to the
/// output device the user picked.
///
/// **Why this exists at all.** The picker in the transport bar moves *music* and nothing
/// else, and it says so in its own menu. The reason was not an oversight: speech played
/// through `AVAudioPlayer(data:)` and `AVSpeechSynthesizer`, and **neither of those has any
/// output-device API**. There is no property to set. Route Baton to a kitchen speaker,
/// trigger a summary, and the summary comes out of the laptop. The only way to route audio
/// to a chosen CoreAudio device is to render it through a graph whose output unit you own —
/// which is what this is.
///
/// **Why its own engine rather than the music engine's.** Playing speech through
/// `EngineAudioPipeline` would have worked, and it is what the optimization plan's §3.5
/// suggested, but it ties speech to three things it should not depend on:
///
/// - **The experiment.** The music engine sits behind the `baton.music.experimentalEngine`
///   developer toggle and stays there for the whole of the audio-engine plan. Speech routing
///   would then work only for people who had opted into an unrelated experiment, or would
///   force that toggle on early — which is the one decision the plan explicitly defers to
///   its Stage 6 measurements.
/// - **A permanent lifecycle.** The music engine renders from launch to quit, and Stage 1
///   spent real effort teaching it to idle. Speech is short and bounded, so this engine
///   starts when there is something to say and stops when there is not. There is no idle
///   cost to fix because there is no idle.
/// - **The music graph's EQ and metering.** Riding those was listed as a benefit of sharing;
///   it is closer to a bug. A ten-band curve tuned for music has no business shaping a
///   spoken sentence, and the now-playing bars should not dance to a summary.
///
/// **What it deliberately does not do: borrow the render quantum.** `EngineAudioPipeline`
/// raises the output device's buffer frame size to cut IOProc wake-ups, under a careful
/// borrower's policy — raise, never shrink someone else's, put it back on the way out. That
/// policy is written for one claimant. A second engine on the same device applying it would
/// be two parties borrowing the same property, and the failure mode is ugly and quiet: the
/// speech engine finishing a two-second clip would hand the device back "its" original size
/// mid-song and shrink the music engine's buffer underneath it. So this engine takes the
/// device exactly as it finds it. Speech is a few seconds long and its wake-up cost is
/// irrelevant next to that risk.
@MainActor
final class SpeechAudioPlayer {

    /// Fired when the clip reaches its end on its own. Not called for `stop()`, a seek, or a
    /// replaced clip — only a genuine play-out.
    var onFinish: (@MainActor () -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    /// The whole clip, decoded. Summaries are seconds long, so holding one in memory is
    /// simpler and more predictable than streaming it, and it is what makes seeking exact:
    /// a seek is "schedule the same buffer from frame N", with no re-decode.
    private var buffer: AVAudioPCMBuffer?

    /// Where the currently-scheduled segment starts within `buffer`. The node's own clock
    /// restarts from zero at every `scheduleBuffer`, so the playhead is this plus the node's
    /// elapsed time — the same shape as the music engine's `clockBase`/`anchorFrames`.
    private var startFrame: AVAudioFramePosition = 0

    /// Invalidates callbacks from buffers that were flushed rather than played.
    ///
    /// `scheduleBuffer`'s completion handler fires when a buffer is *dropped* as well as when
    /// it finishes, so a stop or a seek would otherwise report the clip as finished and
    /// advance the utterance queue. The music engine learned this the same way; every
    /// callback checks its generation first.
    private var generation = 0

    private var isPlayingSegment = false

    /// True while a clip is parked mid-sentence by `pause()`, as opposed to finished.
    ///
    /// `isPlayingSegment` alone cannot tell those apart, and the linger below has to: a paused
    /// clip still owns the node's schedule, so tearing the engine down under it would discard
    /// the buffer and `resume()` would come back to silence.
    private var isPausedMidClip = false

    /// Frames of Bluetooth warm-up padding scheduled ahead of the current segment, so the
    /// playhead can subtract them. The node's clock counts the pad; the listener should not.
    private var prerollFrames: AVAudioFramePosition = 0

    /// When the graph was last started, for measuring how long the output device actually took
    /// to produce audio. Reported once per cold Bluetooth start (see `bluetoothWarmup`).
    private var engineStartedAt: Date?

    /// Holds the graph open for a short window after an utterance, on Bluetooth only.
    private var lingerTask: Task<Void, Never>?

    private(set) var duration: TimeInterval = 0

    init() {
        engine.attach(node)
    }

    // MARK: - Loading

    /// Decode `data` (a WAV/MP3/M4A clip from the speech server) into a playable buffer.
    ///
    /// Routed through a temp file because `AVAudioFile` reads URLs, not `Data`, and it is
    /// worth the round trip: it decodes every format the system knows rather than only the
    /// one the server happens to send today. The file is removed immediately.
    func load(data: Data) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-speech-decode-\(UUID().uuidString)")
        try data.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try load(fileURL: scratch)
    }

    /// Decode a clip already on disk.
    func load(fileURL: URL) throws {
        let file = try AVAudioFile(forReading: fileURL)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { throw SpeechAudioError.emptyClip }
        try file.read(into: decoded)
        adopt(decoded)
    }

    /// Adopt an already-decoded buffer — the native-voice path, which synthesizes straight to
    /// PCM and never touches a file.
    func adopt(_ pcm: AVAudioPCMBuffer) {
        stop()
        buffer = pcm
        duration = pcm.format.sampleRate > 0
            ? Double(pcm.frameLength) / pcm.format.sampleRate
            : 0
        // Reconnect for this clip's format. The synthesizer's output and the server's clips
        // rarely agree on sample rate or channel count, and the mixer is what reconciles
        // them with the device — but only if it is told the input format.
        engine.connect(node, to: engine.mainMixerNode, format: pcm.format)
    }

    enum SpeechAudioError: Error { case emptyClip }

    // MARK: - Transport

    /// Start (or restart) playback from `startFrame`.
    func play() {
        guard let buffer else { return }
        // Whether the graph was cold decides the warm-up: a link that is already streaming has
        // nothing to wake. Read it *before* starting the engine, which is what makes it warm.
        let wasCold = !engine.isRunning
        startEngineIfNeeded()
        guard engine.isRunning else { return }

        let remaining = AVAudioFrameCount(max(0, AVAudioFramePosition(buffer.frameLength) - startFrame))
        guard remaining > 0 else { finishNaturally(); return }

        generation &+= 1
        let scheduled = generation
        let segment = startFrame == 0 ? buffer : Self.slice(buffer, from: startFrame, frames: remaining)
        guard let segment else { return }

        node.stop()
        isPausedMidClip = false
        prerollFrames = scheduleWarmUpIfNeeded(cold: wasCold, format: segment.format)
        node.scheduleBuffer(segment, at: nil, options: [], completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, scheduled == self.generation else { return }
                self.finishNaturally()
            }
        }
        node.play()
        isPlayingSegment = true
    }

    func pause() {
        guard isPlayingSegment else { return }
        node.pause()
        isPlayingSegment = false
        isPausedMidClip = true
    }

    /// Resume after `pause()` without re-scheduling — the node keeps its position.
    func resume() {
        guard buffer != nil, !isPlayingSegment else { return }
        startEngineIfNeeded()
        node.play()
        isPlayingSegment = true
        isPausedMidClip = false
    }

    /// Stop the current clip. Idempotent.
    ///
    /// Note what this deliberately no longer does: tear the graph down on the spot. `adopt()`
    /// calls `stop()` before *every* clip, so stopping the engine here would hand a Bluetooth
    /// link back to standby between two consecutive summaries and re-pay the wake-up on each —
    /// the exact cost the linger exists to avoid. The graph goes away when the linger expires,
    /// and immediately on any other output, where there is nothing to amortise.
    func stop() {
        generation &+= 1   // any callback in flight is now stale
        node.stop()
        isPlayingSegment = false
        isPausedMidClip = false
        prerollFrames = 0
        startFrame = 0
        beginLinger()
    }

    /// Drop the clip entirely, so nothing can be resumed or replayed from it.
    func unload() {
        stop()
        buffer = nil
        duration = 0
    }

    /// Absolute playhead, in seconds.
    ///
    /// `startFrame` is where the current segment began; the node reports how far into that
    /// segment it has rendered, and its clock resets at every schedule.
    var currentTime: TimeInterval {
        guard let buffer, buffer.format.sampleRate > 0 else { return 0 }
        let rate = buffer.format.sampleRate
        guard let render = node.lastRenderTime,
              let played = node.playerTime(forNodeTime: render)
        else { return Double(startFrame) / rate }
        // Any Bluetooth warm-up padding was scheduled on this same node, so the node's clock
        // counts it. The listener is not hearing the summary yet, so the playhead must not.
        let intoSegment = max(0, played.sampleTime - prerollFrames)
        return Double(startFrame + intoSegment) / rate
    }

    /// Seek to an absolute position, re-scheduling from that frame.
    func seek(to seconds: TimeInterval) {
        guard let buffer, buffer.format.sampleRate > 0 else { return }
        let wasPlaying = isPlayingSegment
        let clamped = min(max(seconds, 0), duration)
        startFrame = AVAudioFramePosition(clamped * buffer.format.sampleRate)
        if wasPlaying {
            play()
        } else {
            // Paused: park the playhead without sounding. The next resume() re-schedules.
            generation &+= 1
            node.stop()
            isPlayingSegment = false
            prerollFrames = 0
        }
    }

    // MARK: - Routing

    #if os(macOS)
    /// Send speech to a specific output device; `nil` follows the system default.
    ///
    /// Same mechanism and the same constraint as `EngineAudioPipeline.setOutputDevice`: the
    /// unit can only be re-pointed while the engine is stopped. Unlike the music engine
    /// there is nothing to re-anchor afterwards — a summary either has not started yet, or
    /// is mid-sentence and gets re-scheduled at its playhead, which `play()` already does
    /// from `startFrame`.
    @discardableResult
    func setOutputDevice(_ deviceID: AudioDeviceID?) -> Bool {
        let target = deviceID ?? AudioOutputDevices.defaultOutputDeviceID()
        guard target != 0 else { return false }
        pinnedDevice = deviceID

        let unit = engine.outputNode.auAudioUnit
        guard unit.deviceID != target else { return true }

        let resumeAt = isPlayingSegment ? currentTime : nil
        let wasRunning = engine.isRunning
        // Re-pointing the unit needs the engine stopped, so a pending linger has to go — it
        // would otherwise stop the graph again underneath the clip we are about to resume.
        lingerTask?.cancel()
        lingerTask = nil
        node.stop()
        isPlayingSegment = false
        isPausedMidClip = false
        prerollFrames = 0
        if wasRunning { engine.stop() }
        do {
            try unit.setDeviceID(target)
        } catch {
            speechLog.error("speech: output device \(target) refused — staying where we are")
            if let resumeAt { seek(to: resumeAt) }
            return false
        }
        // Mid-sentence: pick the words back up on the new device rather than dropping them.
        if let resumeAt {
            startFrame = 0
            seek(to: resumeAt)
        }
        return true
    }

    /// The device the user pinned, so a clip that starts *after* the choice still honours it.
    ///
    /// The engine is stopped between summaries, and a stopped engine does not reliably hold
    /// the assignment — so the choice is remembered here and re-applied on every start. This
    /// is the difference between "the summary I was listening to moved" and "speech follows
    /// the picker", which is the actual feature.
    private var pinnedDevice: AudioDeviceID?

    private func applyPinnedDeviceIfNeeded() {
        guard let pinnedDevice else { return }
        let unit = engine.outputNode.auAudioUnit
        guard unit.deviceID != pinnedDevice else { return }
        try? unit.setDeviceID(pinnedDevice)
    }
    #endif

    // MARK: - Engine lifecycle

    /// Start the graph on demand. Nothing renders between summaries — that is still the point
    /// of speech having its own engine rather than living on the music engine's permanent one.
    /// The one exception is the Bluetooth linger below, which is bounded and opt-outable.
    private func startEngineIfNeeded() {
        lingerTask?.cancel()
        lingerTask = nil
        guard !engine.isRunning else { return }
        #if os(macOS)
        applyPinnedDeviceIfNeeded()
        #endif
        engine.prepare()
        engineStartedAt = Date()
        do {
            try engine.start()
        } catch {
            speechLog.error("speech engine failed to start: \(error.localizedDescription)")
        }
    }

    private func finishNaturally() {
        isPlayingSegment = false
        isPausedMidClip = false
        prerollFrames = 0
        startFrame = 0
        beginLinger()
        onFinish?()
    }

    // MARK: - Bluetooth wake-up

    #if os(macOS)
    /// Whether speech is currently going out over Bluetooth — the engine's own device when it
    /// has one pinned, otherwise whatever the system is using.
    private var outputIsBluetooth: Bool {
        var device = engine.outputNode.auAudioUnit.deviceID
        if device == 0 { device = AudioOutputDevices.defaultOutputDeviceID() }
        guard device != 0 else { return false }
        return AudioOutputDevices.isBluetooth(device)
    }
    #else
    private var outputIsBluetooth: Bool { false }
    #endif

    /// Queue near-silence ahead of the utterance when the link has to wake up first, and
    /// report how long that took. Returns the frames scheduled, for the playhead to discount.
    ///
    /// This is scheduled on the same player node as the speech, which is what makes it a
    /// *first-render* gate rather than a blind sleep: the node consumes nothing until the
    /// device is actually rendering, so the padding is spent after audio starts flowing, not
    /// during the silence before it. The duration on top is the floor for the part CoreAudio
    /// cannot see — the speaker's amplifier unmuting.
    private func scheduleWarmUpIfNeeded(cold: Bool, format: AVAudioFormat) -> AVAudioFramePosition {
        guard cold, outputIsBluetooth else { return 0 }
        let seconds = SpeechConfig.bluetoothWarmup
        guard seconds > 0, let pad = Self.warmUpBuffer(format: format, seconds: seconds)
        else { return 0 }

        let startedAt = engineStartedAt
        node.scheduleBuffer(pad, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            guard let startedAt else { return }
            // The pad is only consumed once audio is flowing, so everything beyond its own
            // length is what the link took to wake. This is the number to set the floor from.
            let woke = String(format: "%.2f", max(0, Date().timeIntervalSince(startedAt) - seconds))
            let held = String(format: "%.2f", seconds)
            speechLog.info("""
                speech: bluetooth link woke in \(woke, privacy: .public)s, held \
                \(held, privacy: .public)s of warm-up — raise tonebox.speech.bluetoothWarmup \
                if the first word is still clipped
                """)
        }
        return AVAudioFramePosition(pad.frameLength)
    }

    /// A buffer of *near*-silence: noise at roughly −65 dBFS.
    ///
    /// Not digital silence, and that is the whole trick. Plenty of Bluetooth speakers decide
    /// they are idle by looking for signal, so a run of exact zeros can fail to wake one at
    /// all, or let it doze off again halfway through the padding — leaving the clipping
    /// exactly where it was. This is inaudible, but it is signal.
    /// Internal rather than private so the suite can assert the one property that matters and
    /// cannot be heard from a test: that the pad is inaudible but *not* digitally silent.
    static func warmUpBuffer(format: AVAudioFormat, seconds: TimeInterval) -> AVAudioPCMBuffer? {
        // Rounded, not truncated: 0.7 × 22050 is 15434.999… in binary floating point, and
        // `AVAudioFrameCount` would quietly take a frame off every pad whose length lands
        // just under an integer.
        let frames = AVAudioFrameCount(max(1, (seconds * format.sampleRate).rounded()))
        guard let pad = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pad.frameLength = frames
        let channels = Int(format.channelCount)
        let peak: Float = 0.00056   // ≈ −65 dBFS

        if let destination = pad.floatChannelData {
            for channel in 0 ..< channels {
                for frame in 0 ..< Int(frames) {
                    destination[channel][frame] = .random(in: -peak ... peak)
                }
            }
            return pad
        }
        if let destination = pad.int16ChannelData {
            let scale = max(Int16(1), Int16(peak * Float(Int16.max)))
            for channel in 0 ..< channels {
                for frame in 0 ..< Int(frames) {
                    destination[channel][frame] = .random(in: -scale ... scale)
                }
            }
            return pad
        }
        // Some other sample layout: skip the padding rather than schedule a buffer of
        // uninitialised memory at a speaker.
        return nil
    }

    // MARK: - Engine linger

    /// Hold the graph open briefly after a clip, so a burst of summaries wakes the link once.
    ///
    /// Bluetooth only. On built-in or wired output there is no wake-up to amortise, so the
    /// engine stops immediately exactly as it always did, and the idle cost the header worries
    /// about stays at zero for everyone who never plugs in a speaker.
    private func beginLinger() {
        lingerTask?.cancel()
        lingerTask = nil
        let seconds = outputIsBluetooth ? SpeechConfig.engineLinger : 0
        guard seconds > 0, engine.isRunning else { teardownEngine(); return }
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.teardownEngine()
        }
    }

    /// Actually stop the graph, unless something is still using it.
    private func teardownEngine() {
        lingerTask?.cancel()
        lingerTask = nil
        guard !isPlayingSegment, !isPausedMidClip else { return }
        if engine.isRunning { engine.stop() }
        engineStartedAt = nil
    }

    /// A view of `buffer` starting at `from`, because `scheduleBuffer` always plays a buffer
    /// from its beginning — a seek has to hand it a different buffer, not an offset.
    private static func slice(
        _ source: AVAudioPCMBuffer, from: AVAudioFramePosition, frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frames) else { return nil }
        out.frameLength = frames
        let offset = Int(from)
        let channels = Int(source.format.channelCount)
        if let src = source.floatChannelData, let dst = out.floatChannelData {
            for channel in 0 ..< channels {
                dst[channel].update(from: src[channel] + offset, count: Int(frames))
            }
            return out
        }
        if let src = source.int16ChannelData, let dst = out.int16ChannelData {
            for channel in 0 ..< channels {
                dst[channel].update(from: src[channel] + offset, count: Int(frames))
            }
            return out
        }
        if let src = source.int32ChannelData, let dst = out.int32ChannelData {
            for channel in 0 ..< channels {
                dst[channel].update(from: src[channel] + offset, count: Int(frames))
            }
            return out
        }
        return nil
    }
}
