import AVFoundation
import Foundation

/// Short volume ramps around transport actions, so pausing, stopping and resuming are
/// shaped rather than switched.
///
/// `AVPlayer.pause()` cuts the signal at whatever sample it happens to be on. Mid-waveform
/// that is a step discontinuity — an audible click or thud, worst on bass-heavy material.
/// Removing the click needs only ten or twenty milliseconds. Sounding like a *fade* needs
/// considerably more, and needs the right curve:
///
/// **Perceived loudness is roughly logarithmic, so a linear amplitude ramp is heard as a
/// cut.** Halfway through a linear fade you are still at −6 dB — plainly audible — and the
/// entire remaining 20-odd dB collapses into the last few milliseconds. The ear registers
/// "loud, then gone". Squaring the ramp spends the time where the ear actually is, and the
/// same fade becomes something you can hear happening. Road noise in a car masks the quiet
/// tail outright, which is where a short linear ramp stops being a fade at all.
///
/// This drives a 0…1 **envelope** rather than writing `AVPlayer.volume`. The controller
/// folds `multiplier` into `applyVolume()` alongside the user's level, loudness
/// normalization and the sleep-timer fade, so the four compose instead of overwriting one
/// another — before, adjusting the volume mid-fade snapped it straight back to full.
///
/// Deliberately not a crossfade. `CrossfadeRamp` overlaps two players across a track
/// boundary; this shapes one player's own level around starting and stopping, and the two
/// never run on the same player at once — `cancelCrossfade()` precedes every transport
/// action that uses this.
///
/// **The invariant that matters: the envelope always ends where the model says it should.**
/// A fade that is interrupted, superseded or abandoned must never leave the player sitting
/// at silence — a silent player is a far worse bug than a click, and an untraceable one.
@MainActor
public final class TransportFade {
    /// Long enough to be heard as a fade over road noise, short enough that the button
    /// still feels responsive. Transport UI updates immediately; only audio is shaped.
    public static let outDuration: Double = 0.28
    public static let inDuration: Double = 0.18

    /// ~8 ms between updates: fine enough to be heard as a slope rather than a staircase,
    /// coarse enough not to flood the main actor. The old ramp used 8 steps total, which
    /// at these durations would be audible stepping.
    static let tick: Double = 0.008

    /// The envelope the controller multiplies into its volume math. 1 = untouched.
    public private(set) var multiplier: Float = 1

    private var task: Task<Void, Never>?
    /// The pause a fade-out has promised but not yet delivered. Held so that whatever
    /// interrupts the ramp can decide the promise's fate — see `settlePendingStop()`.
    private var pendingStop: (@MainActor () -> Void)?

    public init() {}

    public var isFading: Bool { task != nil }

    /// Perceptually even ramps. See the type comment for why these aren't linear.
    static func outCurve(_ p: Float) -> Float { (1 - p) * (1 - p) }
    static func inCurve(_ p: Float) -> Float { p * p }

    /// Ramps the envelope to silence, then runs `then` — normally `pause()`.
    ///
    /// `apply` is called on every step; the controller wires it to `applyVolume()`.
    public func out(over duration: Double = TransportFade.outDuration,
                    apply: @escaping @MainActor () -> Void,
                    then: @escaping @MainActor () -> Void) {
        // A previous fade-out still owes a pause. Settle it before taking over, so the
        // obligation can't be lost by being overwritten.
        settlePendingStop()
        task?.cancel()
        pendingStop = then
        let start = multiplier
        task = Task { @MainActor [weak self] in
            let steps = max(1, Int((duration / Self.tick).rounded()))
            for step in 1 ... steps {
                // A newer ramp owns the envelope now; it is responsible for both the level
                // and the pending stop. Touching either here would fight it.
                if Task.isCancelled { return }
                self?.multiplier = start * Self.outCurve(Float(step) / Float(steps))
                apply()
                try? await Task.sleep(for: .seconds(Self.tick))
            }
            guard let self else { return }
            self.settlePendingStop()
            // Hand the level back. The player is paused now, so restoring is silent — and
            // it means the next play() starts at the right level rather than at whatever
            // the fade left behind.
            self.multiplier = 1
            apply()
            self.task = nil
        }
    }

    /// Ramps the envelope up to full. Call after `play()`.
    ///
    /// Starts from wherever an interrupted fade-out left the level, so pausing and
    /// immediately resuming glides back up instead of dipping to silence first.
    public func `in`(over duration: Double = TransportFade.inDuration,
                     apply: @escaping @MainActor () -> Void) {
        // Resuming cancels any owed pause — that is precisely what resuming means. Without
        // this, a resume inside the fade-out window would be paused by the ramp it
        // interrupted, a race that widens with every millisecond of fade.
        pendingStop = nil
        let start = task != nil ? multiplier : 0
        task?.cancel()
        task = Task { @MainActor [weak self] in
            let steps = max(1, Int((duration / Self.tick).rounded()))
            for step in 1 ... steps {
                if Task.isCancelled { return }
                let p = Self.inCurve(Float(step) / Float(steps))
                self?.multiplier = start + (1 - start) * p
                apply()
                try? await Task.sleep(for: .seconds(Self.tick))
            }
            guard let self else { return }
            self.multiplier = 1
            apply()
            self.task = nil
        }
    }

    /// Abandons any ramp in flight and restores full level immediately. Any pause the
    /// abandoned ramp had promised is still honoured — dropping it would leave music
    /// playing after someone pressed pause, the one outcome worse than a click.
    public func cancel(apply: @MainActor () -> Void) {
        task?.cancel()
        task = nil
        settlePendingStop()
        multiplier = 1
        apply()
    }

    private func settlePendingStop() {
        guard let stop = pendingStop else { return }
        pendingStop = nil
        stop()
    }
}
