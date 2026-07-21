import Foundation

/// Sleep timer — pause after N minutes (with a gentle fade-out) or when the current track ends.
/// Extracted from `StreamingPlaybackController` (W-50). Kept as an extension so it drives the same
/// fade/volume envelope; the members it touches are module-internal for that reason.
extension StreamingPlaybackController {
    // MARK: - Sleep timer

    /// Pauses playback after `minutes` (nil/≤0 cancels). Clears any "after current
    /// track" timer. The countdown is exposed via `sleepTimerEndsAt` for the UI.
    func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        sleepAfterCurrentTrack = false
        guard let minutes, minutes > 0 else {
            sleepTimerEndsAt = nil
            return
        }
        sleepTimerEndsAt = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard let self, !Task.isCancelled else { return }
            // Gentle fade-out over ~5s, then pause. resume()/next track resets the envelope.
            self.fade(to: 0, duration: 5) { [weak self] in
                self?.pause()
                self?.fadeMultiplier = 1
                self?.applyVolume()
                self?.onSleepFire?() // also stop internet radio (separate engine)
            }
            self.sleepTimerEndsAt = nil
        }
    }

    /// Arms a sleep timer that pauses when the current track finishes.
    func sleepAtEndOfTrack() {
        sleepTimerTask?.cancel()
        sleepTimerEndsAt = nil
        sleepAfterCurrentTrack = true
    }

    /// Clears any pending sleep timer (fixed-time or end-of-track). Also aborts an
    /// in-progress fade-out and restores full volume if the timer was mid-fade.
    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
        sleepAfterCurrentTrack = false
        if fadeMultiplier < 1 { resetFade() }
    }

    /// Whether any sleep timer is currently armed.
    var sleepTimerArmed: Bool {
        sleepTimerEndsAt != nil || sleepAfterCurrentTrack
    }

    // Audio-focus API (acquire/duck/release, capture shims, crash recovery — REQ-13) lives
    // in StreamingPlaybackController+AudioFocus.swift (W-50 extraction).
}
