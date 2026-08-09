#if os(macOS) || os(iOS)
// The engine is macOS/iOS only. watchOS has no AudioToolbox — no `AudioFileStream`, so no
// decoder, so no engine — and it plays downloaded files through AVPlayer. See
// `EngineDeckUnavailable.swift` for the stand-in that keeps the policy layer compiling.

import AVFoundation
import Foundation
import BatonDSP
import BatonSubsonicModels

/// The staged seam between `StreamingPlaybackController` (which keeps ALL queue, focus,
/// scrobble, and persistence policy — its 87 public members are untouched) and the
/// AVAudioEngine deck: when attached, the host routes **library stream tracks** here and
/// keeps everything else — podcasts, local files, internet radio — on AVPlayer.
///
/// This is stage 1 of the migration path in docs/audio-engine-rearchitecture.md §6 made
/// concrete: the host asks `canPlay` per track, hands over transport verbs while a track
/// is engine-owned, and receives the clock / end-of-track / failure signals back through
/// closures the host wires with access to its own private state.
///
/// **Deck mode is deliberately narrower than the standalone engine.** The host advances
/// the queue, so each `load` is a single-track play: track transitions are *hard cuts*
/// (the host's crossfade and gapless machinery are AVPlayer-specific and are bypassed —
/// visibly documented in the experiment's Settings copy, never silently absent). What IS
/// live on this path is the prize: EQ on streams, real tap metering, in-spool seeks, and
/// `timeOffset` seeks into a cold transcode — all inside the engine.
@MainActor
public final class EngineDeckBridge {
    public let engine: EnginePlaybackController
    private let pipeline: EngineAudioPipeline

    /// Clock pushes to the host (track-logical seconds, duration, buffering) — the
    /// engine-side replacement for the AVPlayer periodic time observer.
    public var onClock: (@MainActor (TimeInterval, TimeInterval, Bool) -> Void)?
    /// The current track's audio genuinely ended — the host runs its advance policy.
    public var onEnded: (@MainActor () -> Void)?
    /// The engine gave up on the track (its own retry ladder exhausted) — the host runs
    /// its failure policy.
    public var onFailure: (@MainActor (String) -> Void)?

    private var clockTask: Task<Void, Never>?
    private var reportedFailure = false

    public init(pipeline: EngineAudioPipeline) {
        self.pipeline = pipeline
        engine = EnginePlaybackController(pipeline: pipeline)
        engine.onPlaybackEnded = { [weak self] in self?.onEnded?() }
    }

    /// The production bridge: a live device-output pipeline. Throws when the audio
    /// engine cannot start (no output device) — the host then simply keeps AVPlayer.
    public static func deviceBridge() throws -> EngineDeckBridge {
        EngineDeckBridge(pipeline: try EngineAudioPipeline(outputMode: .device))
    }

    /// Whether this deck takes the track. The staged scope: **library tracks streamed
    /// over HTTP** — the case the engine exists for (EQ + metering on streams). Local
    /// files, downloads (file URLs), and podcast enclosures stay on AVPlayer.
    public nonisolated static func canPlay(songID: String, url: URL) -> Bool {
        MediaKind(id: songID) == .libraryTrack && (url.scheme == "http" || url.scheme == "https")
    }

    // MARK: - Transport (forwarded by the host while a track is engine-owned)

    public func load(song: NavidromeSong, url: URL, startingAt offset: TimeInterval,
                     autoplay: Bool, headers: [String: String], supportsTimeOffset: Bool) {
        reportedFailure = false
        engine.streamHeaders = headers
        let track = EnginePlaybackController.Track(
            id: song.id, url: url, duration: Double(song.duration ?? 0),
            song: song, supportsTimeOffset: supportsTimeOffset
        )
        // Retire any tick in flight *before* the engine's state changes under it.
        stopClock()
        clockGeneration &+= 1
        engine.play([track], atTime: offset, autoplay: autoplay)
        startClock()
    }

    public func pause() { engine.pause() }
    public func resume() { engine.resume() }
    public func seek(to seconds: TimeInterval) { engine.seek(to: seconds) }

    public func stop() {
        stopClock()
        engine.stop()
    }

    // MARK: - Level / EQ / metering

    /// Host volume, mute, and fade envelopes, mapped onto the engine's own composition.
    public func applyLevel(volumePercent: Int, isMuted: Bool, envelope: Float) {
        engine.volumePercent = volumePercent
        engine.isMuted = isMuted
        engine.externalEnvelope = envelope
    }

    public func applyLoudness(mode: StreamingPlaybackController.LoudnessMode, preampDB: Double) {
        engine.loudnessMode = mode
        engine.loudnessPreampDB = preampDB
    }

    public func setPlaybackRate(_ rate: Float) { engine.playbackRate = rate }

    /// EQ into the graph — live, no reload (the whole point; see the engine tests).
    public func applyEQ(bands: [EQBand], enabled: Bool) {
        engine.applyEQ(bands: bands, enabled: enabled)
    }

    // Output-device selection is macOS-only — see the note in `EngineAudioPipeline`. On iOS
    // the route belongs to `AVAudioSession`, not to us.
    #if os(macOS)

    /// Route Baton's own audio to a device (nil = follow the system default). Per-app: no
    /// other app moves. See `AudioOutputDevices` for why the in-app AirPlay picker needed
    /// replacing rather than fixing.
    @discardableResult
    public func setOutputDevice(_ deviceID: AudioDeviceID?) -> Bool {
        pipeline.setOutputDevice(deviceID)
    }

    /// The device Baton is rendering to right now.
    public var currentOutputDeviceID: AudioDeviceID? { pipeline.currentOutputDeviceID }

    #endif

    public func startMetering(into snapshot: LevelSnapshot) { engine.startMetering(into: snapshot) }
    public func stopMetering() { engine.stopMetering() }

    // MARK: - Clock

    /// 4 Hz pushes, mirroring the AVPlayer periodic observer's cadence. Also the
    /// failure watch: the engine surfaces a dead track as `.error` after its own
    /// bounded retries, and the host must hear about it exactly once.
    private func startClock() {
        guard clockTask == nil else { return }
        let generation = clockGeneration
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, generation == clockGeneration else { return }
                if case .error(let message) = engine.state, !reportedFailure {
                    reportedFailure = true
                    onFailure?(message)
                } else if engine.state == .playing {
                    onClock?(engine.currentTime, engine.duration, engine.isBuffering)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Bumped on every load so a tick already past its `state == .playing` check cannot
    /// publish the *previous* track's position into the new one.
    ///
    /// This is what made Next flicker: the host reset the playhead to zero, an in-flight
    /// tick from the outgoing track then pushed its old position — the bar jumped
    /// mid-track — and the following tick, now reading the freshly loaded deck, put it back
    /// at the start. Previous never showed it because it restarts the current track rather
    /// than loading a new one, so there is no window to race.
    private var clockGeneration = 0

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
    }
}

#endif
