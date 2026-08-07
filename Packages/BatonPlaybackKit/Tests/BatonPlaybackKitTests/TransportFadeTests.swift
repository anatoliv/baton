import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// The volume ramps around pause, stop and resume.
///
/// `AVPlayer.pause()` cuts mid-waveform, which is a step discontinuity — an audible click.
/// A ramp removes it. But the ramp introduces failure modes of its own, and those are what
/// most of these tests are about: **an interrupted fade must never strand the envelope at
/// silence**, and **a resume inside the fade-out window must not be paused by the ramp it
/// interrupted**.
///
/// The suite this replaces asserted the ramps were *imperceptibly short* — which is
/// precisely the bug. It was a de-click, and it was reported from a car as "it just
/// stopped when I stopped the track". A fade nobody can hear is not a fade.
@MainActor
final class TransportFadeTests: XCTestCase {
    /// Long enough for any ramp here to finish.
    private func settle() async { try? await Task.sleep(for: .milliseconds(600)) }

    // MARK: - The action always happens

    /// Whatever the ramp does, the pause must land. Someone pressed pause.
    func testTheActionRunsAfterTheFade() async {
        let fade = TransportFade()
        var paused = false

        fade.out(apply: {}, then: { paused = true })
        await settle()

        XCTAssertTrue(paused, "the transport action must run — silence isn't the point, stopping is")
    }

    /// Superseding a fade-out with another must not lose the first one's pause.
    func testASupersededFadeStillDeliversItsPause() async {
        let fade = TransportFade()
        var pauses = 0

        fade.out(apply: {}, then: { pauses += 1 })
        try? await Task.sleep(for: .milliseconds(40))
        fade.out(apply: {}, then: { pauses += 1 })
        await settle()

        XCTAssertEqual(pauses, 2, "an obligation to pause can't be dropped by being overwritten")
    }

    /// Abandoning a ramp still honours the pause it promised — dropping it would leave
    /// music playing after someone pressed pause.
    func testCancellingStillPauses() async {
        let fade = TransportFade()
        var paused = false

        fade.out(apply: {}, then: { paused = true })
        try? await Task.sleep(for: .milliseconds(40))
        fade.cancel(apply: {})

        XCTAssertTrue(paused)
    }

    // MARK: - The envelope always comes back

    func testTheEnvelopeIsRestoredAfterFadingOut() async {
        let fade = TransportFade()

        fade.out(apply: {}, then: {})
        await settle()

        XCTAssertEqual(fade.multiplier, 1, accuracy: 0.001,
                       "the player is paused, so restoring the envelope is silent — and the next "
                       + "play() must start at the right level, not at whatever the fade left")
    }

    func testFadingInEndsAtFullLevel() async {
        let fade = TransportFade()

        fade.in(apply: {})
        await settle()

        XCTAssertEqual(fade.multiplier, 1, accuracy: 0.001)
    }

    /// The dangerous case: a second action arrives mid-ramp.
    func testAnInterruptedFadeDoesNotStrandTheEnvelopeAtSilence() async {
        let fade = TransportFade()

        fade.out(apply: {}, then: {})
        try? await Task.sleep(for: .milliseconds(40))   // interrupt mid-ramp
        fade.cancel(apply: {})

        XCTAssertEqual(fade.multiplier, 1, accuracy: 0.001,
                       "cancelling must restore the level immediately, not leave a partial fade")
    }

    func testAFadeInDuringAFadeOutStillEndsAtFullLevel() async {
        let fade = TransportFade()

        fade.out(apply: {}, then: {})
        try? await Task.sleep(for: .milliseconds(40))
        fade.in(apply: {})
        await settle()

        XCTAssertEqual(fade.multiplier, 1, accuracy: 0.001)
    }

    // MARK: - Resuming inside the fade-out window

    /// The race the longer fade makes reachable: pause, then resume 40ms later. The
    /// fade-out's pending `pause()` must be cancelled, or the resume is silently undone
    /// and the user is left staring at a "playing" transport with no sound.
    func testResumingDuringAFadeOutCancelsThePendingPause() async {
        let fade = TransportFade()
        var paused = false

        fade.out(apply: {}, then: { paused = true })
        try? await Task.sleep(for: .milliseconds(40))
        fade.in(apply: {})
        await settle()

        XCTAssertFalse(paused, "resuming means the owed pause is void — otherwise the ramp "
                       + "pauses the playback that just replaced it")
    }

    /// Resuming mid-fade should glide up from where the fade-out got to, not dip to
    /// silence first and climb back.
    func testResumingMidFadePicksUpFromTheCurrentLevel() async {
        let fade = TransportFade()
        var levels: [Float] = []

        fade.out(apply: { levels.append(fade.multiplier) }, then: {})
        try? await Task.sleep(for: .milliseconds(60))
        let atInterrupt = fade.multiplier
        fade.in(apply: { levels.append(fade.multiplier) })
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertGreaterThan(atInterrupt, 0, "precondition: interrupted partway, not at the end")
        XCTAssertFalse(levels.contains { $0 < atInterrupt * 0.5 },
                       "the fade-in must not drop the level below where it started")
    }

    // MARK: - The shape of the ramp

    /// Perceived loudness is logarithmic. A linear ramp is still at −6 dB halfway through
    /// and dumps the remaining 20-odd dB into the final milliseconds, which the ear reads
    /// as a cut. The curve must be below linear throughout, so the perceived change is
    /// spread across the ramp rather than crammed into its tail.
    func testTheFadeOutCurveIsPerceptualNotLinear() {
        for p in stride(from: Float(0.1), through: 0.9, by: 0.1) {
            XCTAssertLessThan(TransportFade.outCurve(p), 1 - p,
                              "at \(p) through the ramp the level must be below the linear line")
        }
        XCTAssertEqual(TransportFade.outCurve(0), 1, accuracy: 0.001)
        XCTAssertEqual(TransportFade.outCurve(1), 0, accuracy: 0.001)
    }

    func testTheCurvesAreMonotonic() {
        var lastOut = Float(2), lastIn = Float(-1)
        for step in 0 ... 20 {
            let p = Float(step) / 20
            let out = TransportFade.outCurve(p), fadeIn = TransportFade.inCurve(p)
            XCTAssertLessThan(out, lastOut + 0.0001, "fade-out must never rise")
            XCTAssertGreaterThan(fadeIn, lastIn - 0.0001, "fade-in must never fall")
            lastOut = out; lastIn = fadeIn
        }
    }

    /// Audible, but not sluggish. Below ~0.2s a fade reads as a cut — especially over road
    /// noise, which masks the quiet tail. Above ~0.5s the button stops feeling responsive.
    func testTheRampsAreLongEnoughToHearAndShortEnoughToFeelResponsive() {
        XCTAssertGreaterThanOrEqual(TransportFade.outDuration, 0.2)
        XCTAssertLessThanOrEqual(TransportFade.outDuration, 0.5)
        XCTAssertGreaterThanOrEqual(TransportFade.inDuration, 0.1)
        XCTAssertLessThanOrEqual(TransportFade.inDuration, 0.4)
    }

    /// Enough updates that the ramp is a slope, not a staircase. The old ramp used 8 steps
    /// total; at these durations that is 35ms per step, which is audible stepping.
    func testTheRampHasEnoughStepsToSoundSmooth() {
        let steps = TransportFade.outDuration / TransportFade.tick
        XCTAssertGreaterThan(steps, 20, "fewer than ~20 updates and the ramp is heard as steps")
    }

    // MARK: - Composition with the other envelopes

    /// The bug behind the original report: the fade wrote `AVPlayer.volume` directly, so
    /// any `applyVolume()` during the ramp — a volume nudge, a loudness change, the sleep
    /// timer — snapped it back to full and erased the fade.
    func testTheTransportEnvelopeComposesWithTheOthers() {
        let full = PlaybackVolume.effective(percent: 80, loudness: 1, fade: 1, transport: 1)
        let half = PlaybackVolume.effective(percent: 80, loudness: 1, fade: 1, transport: 0.5)
        XCTAssertEqual(half, full * 0.5, accuracy: 0.0001)

        // A pause during a sleep-timer fade must compose with it, not replace it.
        let both = PlaybackVolume.effective(percent: 80, loudness: 1, fade: 0.5, transport: 0.5)
        XCTAssertEqual(both, full * 0.25, accuracy: 0.0001)
    }
}
