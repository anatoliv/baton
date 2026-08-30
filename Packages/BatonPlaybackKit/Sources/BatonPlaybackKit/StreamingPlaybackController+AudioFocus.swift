import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// Audio-focus coordination, extracted from `StreamingPlaybackController` as a 
/// decomposition step: owner-token capture so an assistant/recording can pause or duck the music
/// and have it restored, last-writer-wins between owners, generation-guarded auto-resume (a manual
/// transport change cancels it), the capture-shim wrappers, and crash recovery of a stranded duck
/// on next launch. Kept as an extension (not a separate type) so it shares the controller's
/// transport state directly and every call site is unchanged; the members it touches
/// (currentFocus, captureToken, stateGeneration, defaults, pauseInternal, cancelCrossfade) are
/// module-internal for this reason.
extension StreamingPlaybackController {
    // MARK: - Audio focus API (owner-token capture coordination, REQ-13)

    /// Acquire audio focus by suspending playback for `owner`. If something is currently
    /// `.playing`, pause it (without registering as a user intervention) and record the
    /// owner + the current `stateGeneration`; otherwise return a token flagged
    /// `didSuspend == false` so its release is a clean no-op.
    ///
    /// Only one owner holds the suspend at a time — **last-writer-wins**: a new acquire
    /// replaces any prior holder, and the older token then releases as a no-op (it's no
    /// longer `currentFocus`). Returns the token to hand back to `releaseAudioFocus(_:)`.
    @discardableResult
    public func acquireAudioFocusSuspend(owner: String) -> AudioFocusToken {
        cancelCrossfade()
        // Capture the generation BEFORE our own pause so the internal pause doesn't read
        // back as intervention; pauseInternal() deliberately doesn't bump it either.
        let generation = stateGeneration
        let didSuspend = state == .playing
        if didSuspend { pauseInternal() }
        let token = AudioFocusToken(owner: owner, generation: generation, didSuspend: didSuspend, mode: .pause)
        currentFocus = token
        persistActiveSuspend(token)
        return token
    }

    /// The level to duck to, given where the volume actually is.
    ///
    /// "Duck to 20%" is an absolute level, and it silently does nothing to anyone listening at
    /// or below it: the old rule only ducked when `target < previous`, so at volume 20 with a
    /// duck of 20 the whole feature was a clean no-op — no dip, nothing to restore, no error
    /// anywhere. That is not an edge case. The slider runs to 80, quiet listening is common, and
    /// once you are under the line every announcement for ever is silently undimmed. It was
    /// reported as "ducking stopped working", which is exactly what it looks like from outside.
    ///
    /// So the absolute level is honoured whenever it can dim, and when it cannot the same number
    /// is applied as a **proportion** of the present level instead. At volume 100 a 20% duck
    /// still lands on 20, unchanged; at volume 20 it lands on 4 rather than doing nothing.
    ///
    /// A floor of 1 rather than 0, because ducking means "dim but still audible" — silence is
    /// what `pause` mode is for.
    public static func duckTarget(from previous: Int, requested: Int) -> Int {
        let absolute = max(0, min(requested, 100))
        if absolute < previous { return absolute }
        guard previous > 0 else { return previous }
        let proportional = (Double(previous) * Double(absolute) / 100).rounded()
        return max(1, min(previous - 1, Int(proportional)))
    }

    /// Acquire audio focus by **ducking** the player volume for `owner` — lowering it to
    /// `toPercent` (0–100) instead of pausing, so an assistant can talk over quieted music.
    /// Records the pre-duck `volumePercent` on the token and restores it verbatim on release.
    /// Only ducks when currently `.playing`; otherwise returns a `didSuspend == false` no-op
    /// token (release is then a clean no-op). Like the pause path, it doesn't bump the
    /// intervention counter, so a user's subsequent volume/transport change still cancels the
    /// auto-restore.
    @discardableResult
    public func acquireAudioFocusDuck(owner: String, toPercent: Int) -> AudioFocusToken {
        cancelCrossfade()
        let generation = stateGeneration
        let previous = volumePercent
        let target = Self.duckTarget(from: previous, requested: toPercent)
        // Only a genuine downward duck counts as "suspended". Nothing playing, or a target
        // at/above the current level, leaves a clean no-op token.
        let didSuspend = state == .playing && target < previous
        if didSuspend {
            // Lower the persisted `volumePercent` to the target WITHOUT bumping the
            // intervention counter — this is a focus duck, not a user volume change, so a
            // later user volume/transport change still cancels the auto-restore. Persisting
            // the ducked level (rather than only touching AVPlayer.volume) is what makes the
            // duck observable and crash-recoverable: a crash while ducked leaves the stored
            // level low, which `recoverStuckDuckFromPreviousSession()` puts back on relaunch.
            // Ramped rather than stepped — see `rampFocusVolume`. The persisted value still
            // lands on `target` immediately, so nothing about recovery changes.
            rampFocusVolume(from: previous, to: target, duration: Self.duckRampSeconds)
        }
        let token = AudioFocusToken(
            owner: owner, generation: generation, didSuspend: didSuspend,
            mode: .duck, previousVolumePercent: didSuspend ? previous : nil
        )
        currentFocus = token
        persistActiveSuspend(token)
        return token
    }

    /// Set the player volume for an audio-focus duck/restore without bumping the intervention
    /// counter. Assigns `volumePercent` (which persists + drives `applyVolume()`), so the
    /// change is observable and survives across launches — but skips the user-facing
    /// `setVolume(percent:)` so it doesn't register as user intervention.
    private func setVolumeForFocus(_ percent: Int) {
        volumePercent = max(0, min(percent, 100))
    }

    /// Move the persisted volume `from` → `to` as a **ramp** rather than a step.
    ///
    /// Ducking under a spoken summary used to be two hard cuts: the music dropped to 20% the
    /// instant speech started and snapped back the instant it ended. Two abrupt level changes a
    /// few seconds apart is the same discontinuity `TransportFade` exists to avoid on pause, and
    /// it is more noticeable here because the music is still playing through both of them.
    ///
    /// The trick is that the *persisted* value still steps, exactly as before — the crash
    /// recovery in `recoverStuckDuckFromPreviousSession()` and the observability of the ducked
    /// level both depend on it. `duckEnvelope` is then set to precisely cancel that step at the
    /// moment it happens (`from / to`), so the audible level does not move at all, and is ramped
    /// to 1 across `duration`. Effective level is `percent × envelope`, so the seam is silent
    /// and the listener hears a single smooth slope.
    ///
    /// Restoring is given the longer ramp of the two. Music dropping away under a voice reads
    /// as intentional even when it is quick; music swelling back is the moment that sounds
    /// abrupt, and it is also the one the listener is waiting for.
    private func rampFocusVolume(from: Int, to: Int, duration: Double) {
        duckRampTask?.cancel()
        setVolumeForFocus(to)
        // Guard the degenerate cases rather than dividing by them: a duck to silence, or a
        // "ramp" between equal levels, has nothing to interpolate.
        guard from > 0, to > 0, from != to else {
            duckEnvelope = 1
            applyVolume()
            return
        }
        let start = Float(from) / Float(to)   // cancels the step exactly
        duckEnvelope = start
        applyVolume()
        duckRampTask = Task { @MainActor [weak self] in
            let steps = 20
            for i in 1 ... steps {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                if Task.isCancelled { return }
                self?.duckEnvelope = Fade.multiplier(step: i, of: steps, start: start, target: 1)
                self?.applyVolume()
            }
            if Task.isCancelled { return }
            self?.duckEnvelope = 1
            self?.applyVolume()
        }
    }

    /// How long each direction takes. Short enough not to clip the first word of a summary,
    /// long enough that neither edge reads as a cut.
    private static let duckRampSeconds = 0.25
    private static let restoreRampSeconds = 0.5

    /// Release audio focus held by `token`, resuming playback **only if** all hold: this is
    /// still the current holder, it actually suspended playback, and the user hasn't touched
    /// the transport since (the live `stateGeneration` still equals the token's). Any manual
    /// play/pause/seek/next/previous/stop in between bumps `stateGeneration` and cancels the
    /// auto-resume. Otherwise this is a no-op. Clears the holder either way.
    /// Returns whether it actually resumed/restored (`true`) or declined as a no-op
    /// (`false`) — the cross-process registry uses this to report an accurate `resumed`
    /// outcome for ducks, whose restore isn't otherwise observable from transport state.
    @discardableResult
    public func releaseAudioFocus(_ token: AudioFocusToken) -> Bool {
        guard currentFocus == token else { return false } // stale/superseded token → no-op
        currentFocus = nil
        clearActiveSuspend()
        guard token.didSuspend, stateGeneration == token.generation else { return false }
        switch token.mode {
        case .pause:
            // Only unpause if still paused (user hasn't intervened into another state).
            guard state == .paused else { return false }
            resume()
            return true
        case .duck:
            // Restore the exact pre-duck level, but only if the user hasn't changed the
            // volume/transport since (generation is unchanged, checked above). Route through
            // the focus setter so restoring doesn't itself count as user intervention.
            guard let previous = token.previousVolumePercent else { return false }
            // The moment the listener is waiting for, so it gets the longer of the two ramps:
            // the music swells back rather than snapping.
            rampFocusVolume(from: volumePercent, to: previous, duration: Self.restoreRampSeconds)
            return true
        }
    }

    /// Owner string used by the `suspendForCapture()` / `resumeAfterCapture()` shims.
    private static let captureOwner = "capture"

    /// Pauses music because a recording/dictation session is starting. Thin wrapper over
    /// `acquireAudioFocusSuspend(owner:)` — stores the `"capture"` token so
    /// `resumeAfterCapture()` can restore it. Behaviour is identical to before.
    public func suspendForCapture() {
        captureToken = acquireAudioFocusSuspend(owner: Self.captureOwner)
    }

    /// Resumes music after recording/dictation ends — but only if this controller paused it
    /// and the user didn't intervene. Thin wrapper over `releaseAudioFocus(_:)`; idempotent
    /// (a nil / already-released capture token is a clean no-op).
    public func resumeAfterCapture() {
        guard let token = captureToken else { return }
        captureToken = nil
        releaseAudioFocus(token)
    }

    // MARK: - Audio-focus crash recovery

    /// Persist the pre-duck volume the moment a ducking focus is placed, so a crash while
    /// ducked can be undone on next launch. Pause-mode focus needs no record (a relaunch
    /// restores the queue paused regardless). Clears any stale record for the pause path.
    private func persistActiveSuspend(_ token: AudioFocusToken) {
        if token.mode == .duck, token.didSuspend, let previous = token.previousVolumePercent {
            defaults.set(previous, forKey: Self.activeSuspendVolumeKey)
        } else {
            defaults.removeObject(forKey: Self.activeSuspendVolumeKey)
        }
    }

    /// Clear the active-suspend record — the focus was released cleanly.
    private func clearActiveSuspend() {
        defaults.removeObject(forKey: Self.activeSuspendVolumeKey)
    }

    /// If a previous run persisted a pending duck volume and never cleared it, that run
    /// died while ducked — restore the user's stored level now. Runs once at launch, before
    /// any new focus is placed, so it can't fight a live duck. Idempotent: clears the record
    /// so a subsequent launch doesn't re-restore.
    public func recoverStuckDuckFromPreviousSession() {
        guard defaults.object(forKey: Self.activeSuspendVolumeKey) != nil else { return }
        let previous = defaults.integer(forKey: Self.activeSuspendVolumeKey)
        defaults.removeObject(forKey: Self.activeSuspendVolumeKey)
        // Restore the persisted user level (the queue loads paused, so applyVolume() alone
        // suffices — no need to touch the transport).
        volumePercent = max(0, min(previous, 100))
        streamingLog.error("audio-focus: recovered stranded duck volume → \(previous, privacy: .public)%")
    }
}
