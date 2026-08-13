import XCTest
@testable import BatonPlaybackKit

/// The feeder's duty cycle: fill to the high-water mark, then get out of the way until the
/// buffer has drained to the low-water mark.
///
/// Worth its own suite because the change it encodes is **invisible in every other
/// observable**. The decode work per track is identical by design — same bytes, same
/// decoder, same scheduled audio — so a regression to the old poll-every-200 ms behaviour
/// would sound the same, measure the same in every audio assertion, and cost the same
/// number of chunks. The only thing that moves is when the work happens, which is why the
/// rules are a pure type and why they are pinned here rather than inferred from a graph.
final class DecodeDutyCycleTests: XCTestCase {

    private let cycle = DecodeDutyCycle()

    // MARK: - Filling

    /// A cold start must not be slowed by any of this: an empty buffer decodes immediately.
    func testAnEmptyBufferDecodesAtOnce() {
        var toppedUp = false
        XCTAssertEqual(cycle.next(aheadSeconds: 0, toppedUp: &toppedUp), .decode)
        XCTAssertFalse(toppedUp, "an empty buffer is not topped up")
    }

    /// Between the marks while *filling* is still filling — this is the half a single
    /// high-water mark gets right, and it must not change.
    func testFillingContinuesThroughTheLowWaterMark() {
        var toppedUp = false
        for ahead in [1.0, 3.9, 4.0, 6.0, 8.0] {
            XCTAssertEqual(cycle.next(aheadSeconds: ahead, toppedUp: &toppedUp), .decode,
                           "filling stopped early at \(ahead)s, which would starve the deck")
        }
    }

    /// Past the high-water mark the latch closes and the feeder naps.
    func testPassingTheHighWaterMarkLatchesAndIdles() {
        var toppedUp = false
        guard case .idle = cycle.next(aheadSeconds: 8.5, toppedUp: &toppedUp) else {
            return XCTFail("kept decoding past the high-water mark — the buffer grows unbounded")
        }
        XCTAssertTrue(toppedUp, "the latch did not close, so the low-water mark can never apply")
    }

    // MARK: - Draining — the half that was missing

    /// The point of the second mark. Between the two marks while *draining*, the old code
    /// decoded (it only knew about 8 s); this must idle instead, all the way down to 4 s.
    func testDrainingBetweenTheMarksIdlesRatherThanToppingUp() {
        var toppedUp = true
        for ahead in [7.9, 6.0, 5.0, 4.1] {
            guard case .idle = cycle.next(aheadSeconds: ahead, toppedUp: &toppedUp) else {
                return XCTFail("""
                    topped the buffer off at \(ahead)s instead of letting it drain to the \
                    low-water mark — this is the sip-forever behaviour the hysteresis replaces
                    """)
            }
            XCTAssertTrue(toppedUp, "the latch reopened early at \(ahead)s")
        }
    }

    /// Reaching the low-water mark reopens the latch and starts the next burst.
    func testReachingTheLowWaterMarkDecodesAgain() {
        var toppedUp = true
        XCTAssertEqual(cycle.next(aheadSeconds: 4.0, toppedUp: &toppedUp), .decode)
        XCTAssertFalse(toppedUp, "the latch must reopen, or the burst would be one chunk long")
    }

    /// And the burst then runs to the high-water mark rather than stopping at one chunk —
    /// batching is the whole reason the second mark is worth having.
    func testABurstRefillsAllTheWayBackUp() {
        var toppedUp = true
        _ = cycle.next(aheadSeconds: 4.0, toppedUp: &toppedUp)   // latch reopens
        var decodes = 0
        var ahead = 4.0
        while case .decode = cycle.next(aheadSeconds: ahead, toppedUp: &toppedUp) {
            decodes += 1
            ahead += 2.0                                          // ~2 s of PCM per chunk
            if decodes > 20 { break }
        }
        XCTAssertEqual(decodes, 3, "a burst should refill 4s → 8s in whole chunks, not one sip")
    }

    // MARK: - The nap

    /// The nap tracks what is actually there to drain, rather than being a fixed poll.
    func testTheNapIsAsLongAsThereIsAudioToDrain() {
        var toppedUp = true
        guard case .idle(let short) = cycle.next(aheadSeconds: 4.5, toppedUp: &toppedUp),
              case .idle(let long) = cycle.next(aheadSeconds: 5.5, toppedUp: &toppedUp) else {
            return XCTFail("expected naps while draining")
        }
        XCTAssertLessThan(short, long, """
            the nap does not scale with the buffer, so this is a fixed poll wearing \
            hysteresis — the wake-ups it exists to remove are still there
            """)
    }

    /// Bounded, because `aheadSeconds` can be **stale-positive**: a wedged node stops
    /// draining while still reporting a full buffer, and an unbounded nap would stop looking.
    /// That is not hypothetical here — it is what an output-device change used to do.
    func testTheNapIsBoundedSoAWedgedNodeIsStillNoticed() {
        var toppedUp = true
        guard case .idle(let seconds) = cycle.next(aheadSeconds: 3600, toppedUp: &toppedUp) else {
            return XCTFail("expected a nap")
        }
        XCTAssertLessThanOrEqual(seconds, cycle.maxIdleSeconds,
                                 "an unbounded nap means a wedged deck is never re-examined")
    }

    /// Floored, so a wake-up landing a hair above the low-water mark cannot spin.
    func testTheNapHasAFloorSoItCannotSpin() {
        var toppedUp = true
        guard case .idle(let seconds) = cycle.next(aheadSeconds: 4.001, toppedUp: &toppedUp) else {
            return XCTFail("expected a nap")
        }
        XCTAssertGreaterThanOrEqual(seconds, cycle.minIdleSeconds,
                                    "a near-zero nap is a busy loop with extra steps")
    }

    // MARK: - The cycle as a whole

    /// The claim in one test: over a stretch of playback, idle wake-ups per decode fall by
    /// about an order of magnitude against the old fixed 200 ms poll.
    ///
    /// Simulated rather than rendered, deliberately. Driving a real graph for the tens of
    /// seconds this needs would be a slow test whose failures are about timing, and the
    /// thing being asserted is arithmetic over the buffer level — exactly what a pure type
    /// is for.
    func testTheDutyCycleWakesFarLessOftenThanTheOldPoll() {
        let chunkSeconds = 2.0        // ~32 KB of a 128 kbps stream
        let audioSeconds = 120.0

        var toppedUp = false
        var ahead = 0.0
        var clock = 0.0
        var wakeups = 0
        var decodes = 0
        while clock < audioSeconds {
            switch cycle.next(aheadSeconds: ahead, toppedUp: &toppedUp) {
            case .decode:
                decodes += 1
                ahead += chunkSeconds
            case .idle(let seconds):
                wakeups += 1
                clock += seconds
                ahead = max(0, ahead - seconds)   // the deck plays while the feeder sleeps
            }
        }

        // The work is unchanged: the same audio still had to be decoded.
        XCTAssertEqual(Double(decodes) * chunkSeconds, audioSeconds + ahead, accuracy: chunkSeconds,
                       "the duty cycle changed how much was decoded, which it must not")

        let oldPollWakeups = audioSeconds / 0.2   // the fixed 200 ms poll it replaces
        XCTAssertLessThan(Double(wakeups), oldPollWakeups / 5, """
            \(wakeups) idle wake-ups over \(Int(audioSeconds))s of audio, against \
            \(Int(oldPollWakeups)) for the 200 ms poll this replaced. Less than a fivefold \
            reduction means the feeder is polling again in all but name.
            """)
    }
}
