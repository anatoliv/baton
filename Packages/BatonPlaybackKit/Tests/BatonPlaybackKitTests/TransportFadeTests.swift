import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// The short volume ramps around pause, stop and resume.
///
/// `AVPlayer.pause()` cuts mid-waveform, which is a step discontinuity — an audible click,
/// worst on bass and on good headphones. A ramp removes it. But the ramp introduces a
/// failure mode of its own, and it is the one these tests are mostly about: **a fade that
/// is interrupted must never leave the player at silence.** A player stuck at zero volume
/// is far worse than a click, because nothing on screen explains it.
@MainActor
final class TransportFadeTests: XCTestCase {
    private func player() -> AVPlayer {
        let p = AVPlayer()
        p.volume = 1
        return p
    }

    // MARK: - The action always happens

    /// Whatever the ramp does, the pause must land. Someone pressed pause.
    func testTheActionRunsAfterTheFade() async {
        let fade = TransportFade()
        let p = player()
        var paused = false

        fade.out(p) { paused = true }
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(paused, "the transport action must run — silence isn't the point, stopping is")
    }

    /// A player already at silence has nothing to fade; it must not wait to act.
    func testASilentPlayerActsImmediately() {
        let fade = TransportFade()
        let p = player()
        p.volume = 0
        var paused = false

        fade.out(p) { paused = true }

        XCTAssertTrue(paused, "no ramp to run, so no reason to defer")
    }

    // MARK: - Volume always comes back

    func testVolumeIsRestoredAfterFadingOut() async {
        let fade = TransportFade()
        let p = player()
        p.volume = 0.8

        fade.out(p) {}
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(p.volume, 0.8, accuracy: 0.001,
                       "the player is paused, so restoring the level is silent — and the next "
                       + "play() must start at the right volume, not at whatever the fade left")
    }

    func testFadingInEndsAtTheTarget() async {
        let fade = TransportFade()
        let p = player()

        fade.in(p, to: 0.6)
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(p.volume, 0.6, accuracy: 0.001)
    }

    /// The dangerous case: a second action arrives mid-ramp.
    func testAnInterruptedFadeDoesNotStrandThePlayerAtSilence() async {
        let fade = TransportFade()
        let p = player()

        fade.out(p) {}
        try? await Task.sleep(for: .milliseconds(30))   // interrupt mid-ramp
        fade.cancel(restoring: p, to: 1)

        XCTAssertEqual(p.volume, 1, accuracy: 0.001,
                       "cancelling must restore the level immediately, not leave a partial fade")
    }

    /// Superseding one ramp with another must also end at the new target.
    func testAFadeInDuringAFadeOutStillEndsAtTheTarget() async {
        let fade = TransportFade()
        let p = player()

        fade.out(p) {}
        try? await Task.sleep(for: .milliseconds(30))
        fade.in(p, to: 1)
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(p.volume, 1, accuracy: 0.001)
    }

    /// Muted is a legitimate target, and must not be mistaken for a fade to cancel.
    func testFadingInToSilenceIsHonoured() {
        let fade = TransportFade()
        let p = player()

        fade.in(p, to: 0)

        XCTAssertEqual(p.volume, 0, accuracy: 0.001, "a muted player should stay muted")
    }

    /// Short enough that a button still feels instant.
    func testTheRampsAreImperceptiblyShort() {
        XCTAssertLessThanOrEqual(TransportFade.outDuration, 0.15)
        XCTAssertLessThanOrEqual(TransportFade.inDuration, 0.15)
    }
}
