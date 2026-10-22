import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// Sleep timer — pause after N minutes (with a gentle fade-out) or when the current track ends.
/// Extracted from `StreamingPlaybackController`. Kept as an extension so it drives the same
/// fade/volume envelope; the members it touches are module-internal for that reason.
extension StreamingPlaybackController {
    // MARK: - Sleep timer

    /// The longest sleep timer anyone can arm. Every UI call site picks from a fixed list well
    /// inside this, but the MCP tool surface takes whatever number a client or a model sends,
    /// and `minutes * 60` on a large one overflows and traps the whole app. The clamp lives
    /// here rather than at the tool because there are five call sites and only one guarded it.
    public static let maxSleepTimerMinutes = 24 * 60

    /// Pauses playback after `minutes` (nil/≤0 cancels). Clears any "after current
    /// track" timer. The countdown is exposed via `sleepTimerEndsAt` for the UI.
    /// Values above `maxSleepTimerMinutes` are clamped to it.
    public func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        // A fade under way belongs to the timer being replaced. Left running it reaches
        // silence, and the stop it was heading for is refused, so the music plays on unheard.
        resetFade()
        sleepAfterCurrentTrack = false
        guard let requested = minutes, requested > 0 else {
            sleepTimerEndsAt = nil
            return
        }
        let minutes = min(requested, Self.maxSleepTimerMinutes)
        armSleepTimer(seconds: TimeInterval(minutes) * 60)
    }

    /// The timed stop itself, in seconds so a test can arm one that fires in a moment
    /// The clock runs on its own, not per item: a queue of clippings or chapters
    /// moving on to the next one leaves it alone, so it stops wherever the listener has got to.
    ///
    /// `sleepTimerEndsAt` stays set through the fade and is cleared by the stop, which is how
    /// both paths below know whether this timer has stopped yet. The fade's own ending is not
    /// enough on its own: a new item starting resets the fade and drops that ending, and with a
    /// queue of short clippings the next one can easily start inside the five seconds. Before
    /// this the timer then cleared itself and the queue played on at full volume.
    func armSleepTimer(seconds: TimeInterval, fadeSeconds: Double = 5) {
        let deadline = Date().addingTimeInterval(seconds)
        sleepTimerEndsAt = deadline
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            // Gentle fade-out over ~5s, then pause. resume()/next track resets the envelope.
            self.fade(to: 0, duration: fadeSeconds) { [weak self] in
                self?.finishSleepTimer(deadline)
            }
            // The fallback, for a fade that a new item cut short.
            try? await Task.sleep(for: .seconds(fadeSeconds + 0.25))
            guard !Task.isCancelled else { return }
            self.finishSleepTimer(deadline)
        }
    }

    /// Stop for the timer that was due at `deadline`, once. A timer cancelled or replaced since
    /// has a different (or no) deadline and stops nothing.
    private func finishSleepTimer(_ deadline: Date) {
        guard sleepTimerEndsAt == deadline else { return }
        sleepTimerEndsAt = nil
        pause()
        fadeMultiplier = 1
        applyVolume()
        // A sleep timer means "stop the music", and a station on the air is the
        // music — the library pause can't reach its engine.
        stopOnAirStation()
    }

    /// Arms a sleep timer that pauses when the current track finishes.
    public func sleepAtEndOfTrack() {
        sleepTimerTask?.cancel()
        resetFade() // as in `setSleepTimer`: the replaced timer's fade must not run on to silence
        sleepTimerEndsAt = nil
        sleepAfterCurrentTrack = true
        // Gapless may already have the next track queued up in the `AVQueuePlayer` from
        // before this was armed — withdraw it, or the OS hands off to it anyway and the
        // sleep timer never gets a boundary to stop at. See
        // `withdrawGaplessPreloadForSleepTimer` for why this can't just be a guard in
        // `preloadGaplessNextIfNeeded`.
        withdrawGaplessPreloadForSleepTimer()
    }

    /// Clears any pending sleep timer (fixed-time or end-of-track). Also aborts an
    /// in-progress fade-out and restores full volume if the timer was mid-fade.
    public func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
        sleepAfterCurrentTrack = false
        if fadeMultiplier < 1 { resetFade() }
    }

    /// Whether any sleep timer is currently armed.
    public var sleepTimerArmed: Bool {
        sleepTimerEndsAt != nil || sleepAfterCurrentTrack
    }

    // Audio-focus API (acquire/duck/release, capture shims, crash recovery — REQ-13) lives
    // in StreamingPlaybackController+AudioFocus.swift.
}
