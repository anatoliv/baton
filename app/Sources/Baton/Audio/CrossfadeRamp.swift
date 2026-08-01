import AVFoundation
import Foundation

/// Owns the **second player** and the volume ramp that make a crossfade audible, extracted from
/// `StreamingPlaybackController` as a collaborator type. The controller still owns the
/// transport core — it decides *when* to fade (`maybeStartCrossfade`) and does the promotion
/// (`finishCrossfade` reassigns the main player + advances the queue) — but the messy part, a
/// whole second `AVQueuePlayer` playing under an async gain ramp, lives here behind a narrow
/// begin / cancel / clear interface.
///
/// The blend *curve* is `Crossfade.gains` (pure, unit-tested). What can only be judged on-device
/// is that the two streams actually overlap smoothly — that's the manual-verify step.
@MainActor
final class CrossfadeRamp {
    /// The incoming (second) player while a fade is running; nil when idle. The controller reads
    /// this to confirm identity before promoting it in `finishCrossfade`.
    private(set) var player: AVQueuePlayer?
    private var task: Task<Void, Never>?

    /// True while a fade is in flight.
    var isActive: Bool { player != nil }

    /// Start a fresh second player on `item` at silence and ramp the two volumes past each other
    /// over `duration`: the `outgoing` player fades `startOut → 0` while the incoming rises
    /// `0 → targetIn`, in `steps` linear increments. `onComplete(promoted)` fires on the main
    /// actor once the ramp finishes cleanly (not cancelled) — the caller promotes `promoted` to
    /// the main player. A `cancel()` mid-ramp drops the incoming player and never completes.
    func begin(
        item: AVPlayerItem,
        targetIn: Float,
        isMuted: Bool,
        outgoing: AVQueuePlayer,
        startOut: Float,
        duration seconds: Double,
        steps: Int = 24,
        readinessTimeout: Double = Crossfade.readinessTimeout,
        onComplete: @escaping @MainActor (AVQueuePlayer) -> Void
    ) {
        let next = AVQueuePlayer(playerItem: item)
        next.isMuted = isMuted
        next.volume = 0
        next.play()
        player = next
        task = Task { @MainActor [weak self] in
            // Hold the outgoing track at FULL volume until the incoming stream is genuinely
            // audible. Ramping straight from `play()` fades into silence whenever the incoming
            // stream is still buffering — which on a transcoding server is most of the time for
            // a cold start. The outgoing track keeps playing; only the blend is deferred.
            let pollSeconds = 0.05
            var waited = 0.0
            while true {
                guard let self, self.player === next else { return }
                let state = Crossfade.readiness(
                    isReadyToPlay: item.status == .readyToPlay,
                    likelyToKeepUp: item.isPlaybackLikelyToKeepUp,
                    elapsedTime: next.currentTime().seconds,
                    waited: waited,
                    timeout: readinessTimeout
                )
                if state == .ready { break }
                if state == .timedOut {
                    // Never hang and never fade to silence: promote immediately, which is
                    // exactly the hard cut this code did before the gate existed.
                    outgoing.volume = 0
                    next.volume = targetIn
                    onComplete(next)
                    return
                }
                try? await Task.sleep(for: .seconds(pollSeconds))
                waited += pollSeconds
            }
            for i in 1 ... steps {
                // Bail if this ramp was cancelled/superseded (player no longer ours).
                guard let self, self.player === next else { return }
                let g = Crossfade.gains(step: i, of: steps, startOut: startOut, targetIn: targetIn)
                outgoing.volume = g.out
                next.volume = g.in
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
            }
            guard let self, self.player === next else { return }
            onComplete(next)
        }
    }

    /// Abort an in-flight fade: cancel the ramp and stop + drop the incoming player. The caller
    /// restores the outgoing player's volume.
    func cancel() {
        task?.cancel()
        task = nil
        player?.pause()
        player = nil
    }

    /// Release the ramp's reference **without** pausing — used after `finishCrossfade` has
    /// promoted the incoming player to be the main player (pausing it would kill playback).
    func clearAfterPromotion() {
        task = nil
        player = nil
    }
}
