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
        startEngineIfNeeded()
        guard engine.isRunning else { return }

        let remaining = AVAudioFrameCount(max(0, AVAudioFramePosition(buffer.frameLength) - startFrame))
        guard remaining > 0 else { finishNaturally(); return }

        generation &+= 1
        let scheduled = generation
        let segment = startFrame == 0 ? buffer : Self.slice(buffer, from: startFrame, frames: remaining)
        guard let segment else { return }

        node.stop()
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
    }

    /// Resume after `pause()` without re-scheduling — the node keeps its position.
    func resume() {
        guard buffer != nil, !isPlayingSegment else { return }
        startEngineIfNeeded()
        node.play()
        isPlayingSegment = true
    }

    /// Stop and release the graph. Idempotent.
    func stop() {
        generation &+= 1   // any callback in flight is now stale
        node.stop()
        isPlayingSegment = false
        startFrame = 0
        if engine.isRunning { engine.stop() }
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
        return Double(startFrame + played.sampleTime) / rate
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
        node.stop()
        isPlayingSegment = false
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

    /// Start the graph on demand. Nothing renders between summaries — that is the whole point
    /// of speech having its own engine rather than living on the music engine's permanent one.
    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        #if os(macOS)
        applyPinnedDeviceIfNeeded()
        #endif
        engine.prepare()
        do {
            try engine.start()
        } catch {
            speechLog.error("speech engine failed to start: \(error.localizedDescription)")
        }
    }

    private func finishNaturally() {
        isPlayingSegment = false
        startFrame = 0
        onFinish?()
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
