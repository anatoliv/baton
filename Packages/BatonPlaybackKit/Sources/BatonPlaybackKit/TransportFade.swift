import AVFoundation
import Foundation

/// Short volume ramps around transport actions, so pausing and stopping don't click.
///
/// `AVPlayer.pause()` cuts the signal at whatever sample it happens to be on. Mid-waveform
/// that is a step discontinuity — an audible click or thud, worst on bass-heavy material
/// and on good headphones, which is exactly the audience that notices. A ramp of ten or
/// twenty milliseconds is inaudible as a fade and removes the click entirely; this uses a
/// little more so the stop also *feels* deliberate rather than yanked.
///
/// Deliberately not a crossfade. `CrossfadeRamp` overlaps two players across a track
/// boundary; this only shapes one player's own volume around starting and stopping, and
/// the two never run on the same player at once — `cancelCrossfade()` precedes every
/// transport action that uses this.
///
/// **The invariant that matters: volume always ends where the model says it should.** A
/// fade that is interrupted, superseded, or abandoned must never leave the player sitting
/// at silence — a silent player is a far worse bug than a click, and an untraceable one.
/// Every path here ends by handing the level back to the caller's `applyVolume()`.
@MainActor
public final class TransportFade {
    /// Long enough to remove the discontinuity, short enough that the button still feels
    /// instant. Transport UI updates immediately; only the audio is shaped.
    public static let outDuration: Double = 0.12
    public static let inDuration: Double = 0.09
    private static let steps = 8

    private var task: Task<Void, Never>?

    public init() {}

    public var isFading: Bool { task != nil }

    /// Ramps `player` to silence, then runs `then` — normally `pause()`.
    ///
    /// `then` runs even if the ramp is cut short, because the caller's intent was to stop:
    /// swallowing it on cancellation would leave music playing after someone pressed pause,
    /// which is the one outcome worse than a click.
    public func out(_ player: AVPlayer, then: @escaping @MainActor () -> Void) {
        task?.cancel()
        let start = player.volume
        guard start > 0 else {
            task = nil
            then()
            return
        }
        task = Task { @MainActor [weak self] in
            let stepDelay = UInt64((Self.outDuration / Double(Self.steps)) * 1_000_000_000)
            for step in 1 ... Self.steps {
                if Task.isCancelled { break }
                player.volume = start * (1 - Float(step) / Float(Self.steps))
                try? await Task.sleep(nanoseconds: stepDelay)
            }
            then()
            // Hand the level back. The player is paused now, so restoring the volume is
            // silent — and it means the next play() starts at the right level instead of
            // at whatever the fade left behind.
            player.volume = start
            self?.task = nil
        }
    }

    /// Ramps `player` up to `target` from silence. Call after `play()`.
    public func `in`(_ player: AVPlayer, to target: Float) {
        task?.cancel()
        guard target > 0 else {
            task = nil
            player.volume = target
            return
        }
        player.volume = 0
        task = Task { @MainActor [weak self] in
            let stepDelay = UInt64((Self.inDuration / Double(Self.steps)) * 1_000_000_000)
            for step in 1 ... Self.steps {
                if Task.isCancelled { break }
                player.volume = target * (Float(step) / Float(Self.steps))
                try? await Task.sleep(nanoseconds: stepDelay)
            }
            // Unconditional, including on cancellation: whatever interrupted this ramp
            // wants its own level, and leaving a partial one behind is how a player ends
            // up quietly at 30% with nothing to explain it.
            player.volume = target
            self?.task = nil
        }
    }

    /// Abandons any ramp in flight and restores `target` immediately.
    public func cancel(restoring player: AVPlayer?, to target: Float) {
        task?.cancel()
        task = nil
        player?.volume = target
    }
}
