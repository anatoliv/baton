import XCTest
@testable import Baton

/// Ducking under a spoken summary should be a ramp, not two hard cuts.
///
/// Reported by ear: the music snapped down when a summary started and snapped back when it
/// ended. Both were real steps — `setVolumeForFocus` assigned the persisted volume directly in
/// each direction — and two abrupt level changes a few seconds apart is exactly the
/// discontinuity `TransportFade` exists to prevent on pause, made more obvious here because the
/// music is audible through both of them.
///
/// The constraint that shapes the fix: the *persisted* volume must still step, because
/// `recoverStuckDuckFromPreviousSession()` reads it to undo a duck the app died in the middle
/// of. So the ramp rides `duckEnvelope`, which is set to cancel the step exactly and then
/// ramped to 1. These pin both halves of that.
@MainActor
final class DuckRampTests: XCTestCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "duck-ramp-\(UUID().uuidString)")!
    }

    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { URL(string: "https://example.invalid/\($0)")! },
            defaults: suite,
            systemNowPlaying: false
        )
    }

    /// The persisted level still lands immediately, ramp or no ramp.
    ///
    /// This is the part that must **not** change: a crash mid-duck leaves the stored level low,
    /// and recovery puts it back. Ramping the persisted value instead would have meant twenty
    /// `UserDefaults` writes per fade and a stored level that is briefly a lie.
    func testTheDuckStillLandsOnThePersistedLevelImmediately() {
        let c = makeController()
        c.play([song("a")])
        c.setVolume(percent: 80)

        let token = c.acquireAudioFocusDuck(owner: "test.speech", toPercent: 20)
        XCTAssertTrue(token.didSuspend, "a duck from 80 to 20 should take")
        XCTAssertEqual(c.volumePercent, 20,
                       "the persisted level must step immediately — crash recovery reads it")
        _ = c.releaseAudioFocus(token)
    }

    /// The seam is silent: at the instant the persisted level steps, the envelope cancels it.
    ///
    /// `effective ≈ percent × envelope`, so 80 → (20 × 4.0) is the same audible level. Without
    /// this the ramp would still begin with the very cut it exists to remove.
    func testTheEnvelopeCancelsTheStepSoTheSeamIsInaudible() {
        let c = makeController()
        c.play([song("a")])
        c.setVolume(percent: 80)

        let token = c.acquireAudioFocusDuck(owner: "test.speech", toPercent: 20)
        // 80/20 = 4.0 — the envelope opens at exactly the ratio of the step.
        XCTAssertEqual(Double(c.duckEnvelope), 4.0, accuracy: 0.01,
                       "the envelope does not cancel the step, so the duck still begins with a cut")
        XCTAssertEqual(Double(c.volumePercent) * Double(c.duckEnvelope), 80, accuracy: 1.0,
                       "effective level moved at the seam — that is the audible click")
        _ = c.releaseAudioFocus(token)
    }

    /// And the same on the way back up, which is the edge the report was actually about.
    func testTheRestoreAlsoStartsLevelContinuous() {
        let c = makeController()
        c.play([song("a")])
        c.setVolume(percent: 80)

        let token = c.acquireAudioFocusDuck(owner: "test.speech", toPercent: 20)
        XCTAssertTrue(c.releaseAudioFocus(token), "the duck should restore")

        XCTAssertEqual(c.volumePercent, 80, "the persisted level must return to the pre-duck value")
        // Coming back the other way the envelope opens *below* 1 (20/80) and rises to it.
        XCTAssertEqual(Double(c.duckEnvelope), 0.25, accuracy: 0.01,
                       "the restore does not start level-continuous, so the music snaps back up")
        XCTAssertEqual(Double(c.volumePercent) * Double(c.duckEnvelope), 20, accuracy: 1.0,
                       "effective level jumped at the restore seam")
    }

    /// The envelope must actually arrive at 1, or the music is left quiet forever.
    ///
    /// A ramp that starts correctly and never finishes is worse than the step it replaced: the
    /// step at least ended at the right level.
    func testTheRampReachesFullLevel() async throws {
        let c = makeController()
        c.play([song("a")])
        c.setVolume(percent: 80)

        let token = c.acquireAudioFocusDuck(owner: "test.speech", toPercent: 20)
        _ = c.releaseAudioFocus(token)

        let deadline = Date().addingTimeInterval(4)
        while c.duckEnvelope != 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(Double(c.duckEnvelope), 1.0, accuracy: 0.001,
                       "the restore ramp never completed — the music would sit quietly at a fraction of its level")
        XCTAssertEqual(c.volumePercent, 80)
    }

    /// A user reaching for the volume mid-ramp takes it back immediately.
    ///
    /// Otherwise their new level keeps sliding on its own for the rest of the ramp, which reads
    /// as the slider fighting them.
    func testAUserVolumeChangeCancelsTheRamp() {
        let c = makeController()
        c.play([song("a")])
        c.setVolume(percent: 80)

        let token = c.acquireAudioFocusDuck(owner: "test.speech", toPercent: 20)
        XCTAssertNotEqual(c.duckEnvelope, 1, "precondition: a ramp is in flight")

        c.setVolume(percent: 55)
        XCTAssertEqual(Double(c.duckEnvelope), 1.0, accuracy: 0.001,
                       "the in-flight ramp was left running over the user's own volume change")
        XCTAssertEqual(c.volumePercent, 55)
        _ = c.releaseAudioFocus(token)
    }

    /// A duck to silence has nothing to interpolate and must not divide by zero.
    func testADuckToSilenceDoesNotProduceANonsenseEnvelope() {
        let c = makeController()
        c.play([song("a")])
        c.setVolume(percent: 80)

        let token = c.acquireAudioFocusDuck(owner: "test.speech", toPercent: 0)
        XCTAssertEqual(c.volumePercent, 0)
        XCTAssertEqual(Double(c.duckEnvelope), 1.0, accuracy: 0.001,
                       "a duck to zero produced a degenerate envelope instead of falling back to a step")
        _ = c.releaseAudioFocus(token)
    }

    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: id, artist: "t", album: "t", duration: 10)
    }
}
