import Foundation

/// When the feeder should decode, and how long it should get out of the way.
///
/// **The lever.** `EngineAudioPipeline` holds decoded PCM scheduled ahead of the playhead,
/// and the feeder's job is to keep that stocked. It used to do so with a single high-water
/// mark and a 200 ms poll: sleep while more than 8 s is queued, otherwise pull a chunk. In
/// steady state that tops the buffer off in ~2 s sips forever and wakes the main actor five
/// times a second to discover there is nothing to do — about ten no-op wake-ups for every
/// decode. Batching is a large part of why AVPlayer is cheap, and this was the opposite of
/// batching.
///
/// So: fill to the high-water mark, then **stay away until it has drained to the low-water
/// mark**, and sleep for as long as that will actually take instead of polling. The decode
/// work per track is identical — the same bytes through the same decoder — but it arrives in
/// bursts with real idle between them, which is the shape a CPU can take advantage of.
/// `docs/audio-engine-rearchitecture.md` specified 8 s / 4 s hysteresis from the start; only
/// the high-water half was ever built.
///
/// **Why draining to 4 s costs no resilience.** The scheduled PCM is not what protects
/// playback from a network hiccup — the spool is. `TrackStreamSource` downloads at wire speed
/// into a spool on disk, independently of this loop, and `nextChunk()` decodes from that. So
/// deferring a decode defers CPU work over bytes that have *already arrived*; the only case
/// where a thinner PCM buffer is thinner protection is one where the spool is empty too, and
/// there the old 8 s bought eight seconds rather than a fix.
///
/// Pure, and separate from the feeder, for the reason `StallRecoveryPolicy` is: the rules are
/// worth testing exhaustively and cheaply, and doing that through a live graph would prove
/// less and break more.
struct DecodeDutyCycle: Equatable, Sendable {
    /// Fill to here, then stop.
    var highWaterSeconds: TimeInterval = 8
    /// Don't decode again until the buffer has drained to here.
    var lowWaterSeconds: TimeInterval = 4
    /// Floor on a nap, so a wake-up that lands a hair above the low-water mark cannot spin.
    var minIdleSeconds: TimeInterval = 0.2

    /// Never sleep longer than the drain window itself.
    ///
    /// **Derived, not chosen**, and the first version of this got it wrong by choosing: a
    /// flat 1 s cap left the feeder waking four times per drain instead of once, which is a
    /// fivefold improvement wearing a twentyfold one's clothes. `testTheDutyCycleWakesFarLess\
    /// OftenThanTheOldPoll` failed on exactly that, which is the whole reason it counts
    /// wake-ups rather than asserting the marks.
    ///
    /// At `high - low` the cap can never bind in healthy operation — a nap is by definition
    /// the time to drain from at most the high-water mark to the low one. It binds only when
    /// the buffer reads *deeper* than the high-water mark, which means it is not draining:
    /// **`aheadSeconds` can be stale-positive**. If the node wedges — which is exactly what
    /// an output-device change used to do, leaving a frozen playhead behind a buffer that
    /// still looked full — nothing drains and an unbounded nap would stop looking. So the
    /// bound exists precisely for the case it is reached in, and costs nothing otherwise.
    ///
    /// (Not about responsiveness: a load, seek or stop cancels the feeder task outright,
    /// which interrupts the sleep, so a napping feeder never delays the transport.)
    var maxIdleSeconds: TimeInterval { max(minIdleSeconds, highWaterSeconds - lowWaterSeconds) }

    enum Action: Equatable, Sendable {
        /// Pull and schedule the next chunk now.
        case decode
        /// Sleep this long, then ask again.
        case idle(TimeInterval)
    }

    /// What to do, given how much audio is scheduled ahead of the playhead.
    ///
    /// `toppedUp` is the hysteresis latch and belongs to the caller's feeder: without it the
    /// two marks would collapse back into one, because a single reading cannot tell "filling
    /// towards 8" from "draining towards 4" — the buffer sits between the marks in both
    /// cases, and that is the whole state the second mark adds.
    func next(aheadSeconds: TimeInterval, toppedUp: inout Bool) -> Action {
        if toppedUp {
            let drainable = aheadSeconds - lowWaterSeconds
            guard drainable > 0 else {
                toppedUp = false
                return .decode
            }
            return .idle(min(maxIdleSeconds, max(minIdleSeconds, drainable)))
        }
        if aheadSeconds > highWaterSeconds {
            toppedUp = true
            // Latched, but say nothing about how long to wait — the next call reads the
            // buffer again and computes the nap from what is actually there.
            return .idle(min(maxIdleSeconds, max(minIdleSeconds, aheadSeconds - lowWaterSeconds)))
        }
        return .decode
    }
}
