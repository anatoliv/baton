import Foundation

// A gentle alarm's 30-second rise in Baton's player (TBX-1000000445, specs/alarm-and-timer.md).
// The curve and its clock are `AlarmVolumeRamp`'s; this is where it meets the output level.
extension StreamingPlaybackController {
    /// Whether a gentle alarm's rise is under way (a level held after Pause is not a rise).
    public var isWakeRamping: Bool { wakeRamp != nil }

    /// Starts a gentle alarm's rise: the output drops to the floor now and rises to the person's
    /// volume over `duration` once the track is playing. `tick` is how often it moves; nil leaves
    /// the stepping to the caller (`stepWakeRamp`), which is how a test drives it with its own
    /// clock. Replaces a rise already under way.
    public func startWakeRamp(duration: TimeInterval = GentleWake.playerRampSeconds,
                              now: @escaping () -> Date = Date.init,
                              tick: Duration? = .milliseconds(250)) {
        wakeRampTask?.cancel()
        wakeRampTask = nil
        wakeRamp = AlarmVolumeRamp(duration: duration, now: now, isPlaying: { [weak self] in self?.isPlaying == true }) {
            [weak self] level in
            guard let self else { return }
            self.wakeEnvelope = max(0, min(1, level))
            self.applyVolume()
        }
        guard let tick else { return }
        wakeRampTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled, let self else { return }
                if !self.stepWakeRamp() { return }
            }
        }
    }

    /// Moves the rise on to now. False when no rise is under way any more.
    @discardableResult
    public func stepWakeRamp() -> Bool {
        guard let ramp = wakeRamp else { return false }
        if ramp.step() { return true }
        wakeRamp = nil
        wakeRampTask = nil
        return false
    }

    /// Ends a rise at the level it reached, for Pause and Stop: raising the level at that moment
    /// would sound through the deck's pause fade as a quarter-second blast at full volume. The
    /// held level is let go (`releaseHeldWakeLevel`) when anything plays again.
    public func endWakeRampHoldingLevel() {
        wakeRampTask?.cancel()
        wakeRampTask = nil
        wakeRamp = nil
    }

    /// Back to the person's volume after a rise ended by Pause or Stop. No-op while a rise is
    /// under way or nothing is held.
    func releaseHeldWakeLevel() {
        guard wakeRamp == nil, wakeEnvelope != 1 else { return }
        wakeEnvelope = 1
        applyVolume()
    }

    /// Ends a rise at the person's volume: their change to the volume, or mute, sets the level
    /// they want.
    public func cancelWakeRamp() {
        wakeRampTask?.cancel()
        wakeRampTask = nil
        guard wakeRamp != nil || wakeEnvelope != 1 else { return }
        wakeRamp = nil
        wakeEnvelope = 1
        applyVolume()
    }
}
