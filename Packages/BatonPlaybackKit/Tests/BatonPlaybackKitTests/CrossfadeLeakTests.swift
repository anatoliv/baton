import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// A crossfade must never leave a player running that nothing can stop.
///
/// Reported as: one track kept playing, and choosing another gave you both at once, with
/// no way to silence the first. The cause was two pieces of state that could disagree —
/// `isCrossfading` (a flag) and `crossfadeRamp` (an actual second `AVQueuePlayer`).
/// `finishCrossfade` bailed out of its guard without stopping the incoming player, and
/// `cancelCrossfade` then refused to act because the flag said no fade was running. The
/// flag is a belief; the ramp is the truth, and these tests are about that gap.
@MainActor
final class CrossfadeLeakTests: XCTestCase {
    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(defaults: UserDefaults(suiteName: "eq.xfade.\(UUID().uuidString)")!)
    }

    /// The exact stuck state: a ramp is live while the flag says otherwise.
    func testCancellingStopsALiveRampEvenWhenTheFlagSaysThereIsNoFade() {
        let controller = makeController()
        let ramp = controller.crossfadeRampForTesting

        ramp.begin(
            item: AVPlayerItem(url: URL(string: "https://example.com/a.mp3")!),
            targetIn: 1, isMuted: false,
            outgoing: AVQueuePlayer(), startOut: 1,
            duration: 5, steps: 50
        ) { _ in }
        XCTAssertTrue(ramp.isActive, "precondition: a second player is running")
        controller.setCrossfadingForTesting(false)   // the drift that made this unstoppable

        controller.cancelCrossfade()

        XCTAssertFalse(ramp.isActive,
                       "a live second player must be stopped regardless of what the flag believes")
    }

    /// And the ordinary case still works.
    func testCancellingStopsARampWhileTheFlagAgrees() {
        let controller = makeController()
        let ramp = controller.crossfadeRampForTesting

        ramp.begin(
            item: AVPlayerItem(url: URL(string: "https://example.com/b.mp3")!),
            targetIn: 1, isMuted: false,
            outgoing: AVQueuePlayer(), startOut: 1,
            duration: 5, steps: 50
        ) { _ in }
        controller.setCrossfadingForTesting(true)

        controller.cancelCrossfade()

        XCTAssertFalse(ramp.isActive)
        XCTAssertFalse(controller.isCrossfadingForTesting)
    }

    /// Nothing running, nothing to do — cancelling must stay cheap and safe.
    func testCancellingWithNoFadeRunningIsHarmless() {
        let controller = makeController()

        controller.cancelCrossfade()

        XCTAssertFalse(controller.crossfadeRampForTesting.isActive)
    }
}
