import Foundation

/// Whether the transport is playing without anything actually coming out.
///
/// **The gap this closes.** `EnginePlaybackController.clockTick` already carries a stall
/// signal, and it is a good one for the failure it was built for: `aheadSeconds <= 0 &&
/// !finishedScheduling` means the feeder cannot keep the deck stocked, so raise
/// `isBuffering` and let `armStallWatchdog` re-request the stream. But every term in it is
/// about *data*, and none of it is about *rendering* — and the two are not the same thing.
/// A deck can be stocked with audio that nothing is pulling.
///
/// That is not hypothetical. macOS stops the AUHAL across sleep and does not reliably post
/// `AVAudioEngineConfigurationChange` when it does — the same asymmetry an `AVAudioSession`
/// interruption has, which `EngineAudioPipeline.play` already guards against for the
/// *stopped* case. So `onConfigurationChange` never fires, nothing re-anchors, and the
/// engine sits with buffers queued and its I/O proc never cycling. `aheadSeconds` is
/// *positive*, so the dry-detector reads healthy and stays quiet: the app shows "playing",
/// the playhead sits at 0:00, `isBuffering` never rises and no watchdog is ever armed.
///
/// Observed on 0.16.23 after the machine had slept overnight. Pause/resume did not fix it
/// (the engine restarted — a new I/O thread appeared — and still rendered nothing), and
/// neither did skipping to a freshly loaded track; only relaunching the app did. Nothing in
/// the app noticed at any point, because nothing was watching this.
///
/// So the detector asks the complementary question, in the only terms that can see it:
/// **audio is queued, we intend to play, and the played-frame count is not moving.**
/// Queued-ness is what makes that unambiguous, and it is also what keeps the two honest
/// ends of a track out of it — a deck that has legitimately drained (buffering at the
/// start, the final buffer at the end) has nothing queued, and is the dry-detector's
/// business rather than this one's.
///
/// Pure and separate from the controller for the reason `DecodeDutyCycle` and
/// `StallRecoveryPolicy` are: the rules are worth testing exhaustively and cheaply, and
/// doing it through a live graph would prove less and break more. Here there is a second
/// reason — it *cannot* be tested through the offline pipeline at all. Manual rendering
/// advances the playhead only when a caller pulls frames, so "the playhead is not moving"
/// is the normal resting state there and means nothing. Hence `isSelfDriven` at the call
/// site: this question is only well-posed when the engine drives its own I/O.
struct PlayheadStallDetector: Equatable, Sendable {
    /// How long a queued-but-frozen playhead must persist before it counts.
    ///
    /// Long enough not to trip on a scheduling hiccup between two clock ticks, short
    /// enough that someone who just pressed play does not sit through it. Being slightly
    /// eager is cheap on purpose: the recovery it triggers re-feeds from the spool
    /// (`reanchorAfterGraphRestart`), so a false positive costs a re-anchor, not a
    /// re-download.
    var stalledAfterSeconds: TimeInterval = 2

    /// The previous reading, or nil when the next one is a baseline rather than a verdict.
    private var lastFrames: Int64?
    private var frozenForSeconds: TimeInterval = 0

    /// Spelled out because the stored state below is private, which would otherwise make
    /// the synthesized memberwise initializer private too.
    init(stalledAfterSeconds: TimeInterval = 2) {
        self.stalledAfterSeconds = stalledAfterSeconds
    }

    /// Feed one clock tick. Returns true on the tick that crosses the threshold — once per
    /// stall, because crossing it also re-arms the counter.
    ///
    /// `playedFrames` going *backwards* reads as progress, not as a stall. That is
    /// deliberate rather than tolerated: an engine restart resets the render clock (a
    /// player node's `sampleTime` was measured jumping back ~34k frames across
    /// `AVAudioEngine.pause()`), and a detector that treated a reset as "not moving" would
    /// fire on the recovery it had just asked for.
    mutating func observe(playedFrames: Int64,
                          hasQueuedAudio: Bool,
                          intendsToPlay: Bool,
                          elapsed: TimeInterval) -> Bool {
        guard intendsToPlay, hasQueuedAudio else {
            // Neither a stall nor evidence of health — a drained or paused deck simply
            // cannot answer the question. Drop the accumulated time so a stall has to be
            // observed continuously, and keep the last reading: crediting a deck with
            // progress it never made is the failure mode worth avoiding here.
            frozenForSeconds = 0
            return false
        }
        let previous = lastFrames
        lastFrames = playedFrames
        guard let previous else { return false }
        guard playedFrames == previous else {
            frozenForSeconds = 0
            return false
        }
        frozenForSeconds += elapsed
        guard frozenForSeconds >= stalledAfterSeconds else { return false }
        frozenForSeconds = 0
        return true
    }

    /// Forget everything observed so far — after a recovery, a load or a seek, where the
    /// frame count legitimately restarts and the next reading is a baseline again.
    mutating func reset() {
        lastFrames = nil
        frozenForSeconds = 0
    }
}
