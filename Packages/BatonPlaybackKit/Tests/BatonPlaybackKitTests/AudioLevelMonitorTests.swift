import XCTest
import BatonDSP
@testable import BatonPlaybackKit

/// The meter that drives the now-playing bars.
///
/// Two things matter beyond "does it read the level": it must **idle all the way off** when
/// nothing is displaying bars — an indicator that quietly wakes the CPU 24 times a second
/// for an app sitting in the background is a battery bug nobody reports — and it must not
/// republish unchanged values, because `@Observable` invalidates every reader on assignment.
@MainActor
final class AudioLevelMonitorTests: XCTestCase {
    private func makeMonitor() -> AudioLevelMonitor {
        AudioLevelMonitor(defaults: UserDefaults(suiteName: "baton.levels.\(UUID().uuidString)")!)
    }

    func testItIsOnByDefault() {
        XCTAssertTrue(makeMonitor().isEnabled, "the reactive indicator is the default experience")
    }

    func testDisablingIsRemembered() {
        let defaults = UserDefaults(suiteName: "baton.levels.\(UUID().uuidString)")!
        let monitor = AudioLevelMonitor(defaults: defaults)
        monitor.isEnabled = false
        XCTAssertFalse(AudioLevelMonitor(defaults: defaults).isEnabled)
    }

    // MARK: - Idling

    func testNoSubscribersMeansNoTimer() {
        let monitor = makeMonitor()
        XCTAssertFalse(monitor.isRunning, "nothing on screen — nothing to sample")
    }

    func testASubscriberStartsItAndReleasingStopsIt() {
        let monitor = makeMonitor()
        monitor.retain()
        XCTAssertTrue(monitor.isRunning)
        monitor.release()
        XCTAssertFalse(monitor.isRunning, "the last bar left the screen; the timer must go too")
    }

    /// Several rows can show bars at once (a list row and the player, say). The timer runs
    /// once for all of them and stops only when the last one goes.
    func testNestedSubscribersAreBalanced() {
        let monitor = makeMonitor()
        monitor.retain(); monitor.retain(); monitor.retain()
        monitor.release(); monitor.release()
        XCTAssertTrue(monitor.isRunning, "one subscriber remains")
        monitor.release()
        XCTAssertFalse(monitor.isRunning)
    }

    /// An unbalanced release (a view torn down in an order SwiftUI chose) must not drive the
    /// count negative and wedge the meter off for the rest of the session.
    func testExtraReleasesCannotWedgeIt() {
        let monitor = makeMonitor()
        monitor.release(); monitor.release()
        monitor.retain()
        XCTAssertTrue(monitor.isRunning)
    }

    func testDisablingWhileRunningStopsIt() {
        let monitor = makeMonitor()
        monitor.retain()
        XCTAssertTrue(monitor.isRunning)
        monitor.isEnabled = false
        XCTAssertFalse(monitor.isRunning)
    }

    func testDisabledNeverStarts() {
        let monitor = makeMonitor()
        monitor.isEnabled = false
        monitor.retain()
        XCTAssertFalse(monitor.isRunning)
    }

    // MARK: - Publishing

    func testStoppingClearsTheLevelsSoBarsDoNotFreezeOnTheLastFrame() {
        let monitor = makeMonitor()
        monitor.retain()
        monitor.snapshot.store(.init(low: 1, lowMid: 1, highMid: 1, high: 1))
        monitor.release()
        XCTAssertEqual(monitor.levels, .silent)
        XCTAssertFalse(monitor.isLive)
        XCTAssertEqual(monitor.snapshot.load(), .silent, "the tap's slot is cleared too")
    }

    /// The republish guard: an unchanged meter must not invalidate every list row 24×/second.
    func testUnchangedLevelsAreNotRepublished() {
        let a = BandLevels(low: 0.5, lowMid: 0.5, highMid: 0.5, high: 0.5)
        XCTAssertFalse(AudioLevelMonitor.differs(a, a))
        let sub = BandLevels(low: 0.5 + 0.001, lowMid: 0.5, highMid: 0.5, high: 0.5)
        XCTAssertFalse(AudioLevelMonitor.differs(a, sub), "below a byte of resolution is invisible")
        let visible = BandLevels(low: 0.6, lowMid: 0.5, highMid: 0.5, high: 0.5)
        XCTAssertTrue(AudioLevelMonitor.differs(a, visible))
    }

    /// The sampled values must reach `levels`, or the bars would never move.
    func testSamplingPublishesWhatTheTapWrote() {
        let monitor = makeMonitor()
        monitor.retain()
        monitor.snapshot.store(.init(low: 0.8, lowMid: 0.2, highMid: 0.4, high: 0.6))
        monitor.sampleNow()
        XCTAssertEqual(monitor.levels.low, 0.8, accuracy: 0.01)
        XCTAssertEqual(monitor.levels.highMid, 0.4, accuracy: 0.01)
        XCTAssertTrue(monitor.isLive)
    }

    /// Silence is not "live": the view falls back to its canned animation rather than
    /// drawing four bars pinned flat at the floor.
    func testSilenceIsNotLive() {
        let monitor = makeMonitor()
        monitor.retain()
        monitor.snapshot.clear()
        monitor.sampleNow()
        XCTAssertFalse(monitor.isLive)
    }
}
