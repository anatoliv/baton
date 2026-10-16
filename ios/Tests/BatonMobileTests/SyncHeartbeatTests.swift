import XCTest
@testable import BatonMobile

/// The phone has to keep reconciling while it is on screen, not only at the moment it arrives.
///
/// Reported as "renaming a clip on desktop did not affect the mobile app". The shared
/// state was correct throughout — the Mac's rename was in the ledger and on the gateway, verified
/// there — and the phone simply never asked again. It synced on launch and on every foreground
/// transition and at no other time, so an app left open, which is what happens while a clipping
/// plays, saw nothing for as long as it stayed open.
///
/// The Mac has had `PreferenceSyncScheduler`'s heartbeat since it was written, for the reason its
/// own doc comment gives: a feature that only fires on a trigger nobody happens to pull is
/// indistinguishable from a broken one. This is the phone's half of that.
///
/// These assert the wiring, which is the part that was missing. The interval itself is not worth
/// a test — but whether anything starts at all is exactly what nobody could see.
@MainActor
final class SyncHeartbeatTests: XCTestCase {

    func testForegroundingStartsTheHeartbeatAndBackgroundingStopsIt() {
        let model = MobileModel()
        XCTAssertFalse(model.isSyncHeartbeatRunning, "nothing should be running before the app is on screen")

        model.startSyncHeartbeat()
        XCTAssertTrue(model.isSyncHeartbeatRunning,
                      "an app left open must keep asking, or a rename made elsewhere never arrives")

        model.stopSyncHeartbeat()
        XCTAssertFalse(model.isSyncHeartbeatRunning, "a backgrounded app must not keep polling")
    }

    /// Foregrounding fires more than once in ordinary use — a glance at Control Center is a
    /// transition — and each one must not stack another loop on the gateway.
    func testStartingTwiceRunsOneHeartbeat() {
        let model = MobileModel()

        model.startSyncHeartbeat()
        model.startSyncHeartbeat()
        model.stopSyncHeartbeat()

        XCTAssertFalse(model.isSyncHeartbeatRunning,
                       "a second start must be a no-op, or one stop would leave a loop behind")
    }

    /// Matches the Mac's `PreferenceSyncScheduler.heartbeat`. Long enough that an app open all
    /// day is quiet, short enough that "I renamed it on the Mac a few minutes ago" resolves on
    /// its own rather than needing someone to background the app and come back.
    func testTheIntervalMatchesTheMacs() {
        XCTAssertEqual(MobileModel.syncHeartbeat, 600)
    }

    // MARK: - The book ledger push

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    /// Pause and Stop each push the book ledger after the debounce, and a burst is one push.
    /// Before this a book stopped on the phone reached the Mac at its next heartbeat.
    func testPauseAndStopPushTheBookLedgerDebounced() async throws {
        var pushes = 0
        let paused = MobileModel()
        paused.installBookLedgerPush(delay: .milliseconds(50)) { pushes += 1; return true }
        paused.music.pause()
        XCTAssertEqual(pushes, 0, "debounced, not at once")
        try await settle()
        XCTAssertEqual(pushes, 1, "pause")

        let stopped = MobileModel()
        stopped.installBookLedgerPush(delay: .milliseconds(50)) { pushes += 1; return true }
        stopped.music.pause()
        stopped.music.stop()
        try await settle()
        XCTAssertEqual(pushes, 2, "pause then stop: one push")
    }

    /// Leaving the foreground pushes at once, under a background task, in place of a pause push
    /// still waiting out its delay.
    func testLeavingTheForegroundPushesAtOnce() async throws {
        var pushes = 0
        let model = MobileModel()
        model.installBookLedgerPush(delay: .seconds(30)) { pushes += 1; return true }
        model.music.pause()
        model.pushBookLedgerLeavingForeground()
        try await settle()
        XCTAssertEqual(pushes, 1)
        XCTAssertEqual(model.bookLedgerPush?.isPending, false)
    }

    /// The real push is the forced sync, which sends nothing from a phone switched off with
    /// `BATON_DEBUG_PREFERENCE_SYNC=off` (as these tests run) or with no gateway set up.
    func testTheRealPushIsTheSyncAndHonoursTheSwitch() async {
        let model = MobileModel()
        XCTAssertNotNil(model.bookLedgerPush, "installed at launch")
        let reached = await model.syncPreferences(force: true)
        XCTAssertFalse(reached)
    }

    /// Play on a book pulls the Mac's place first, through the same forced sync; a
    /// phone switched off with `BATON_DEBUG_PREFERENCE_SYNC=off` has nothing to pull with, so
    /// Play starts at once.
    func testASwitchedOffPhonePullsNothingBeforePlay() {
        let model = MobileModel()
        XCTAssertNil(model.bookPlacePull(environment: ["BATON_DEBUG_PREFERENCE_SYNC": "off"]))
    }
}
