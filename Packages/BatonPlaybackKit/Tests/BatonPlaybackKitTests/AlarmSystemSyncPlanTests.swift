import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// What a system sync may do to the alarms AlarmKit already holds (TBX-11171 review): a launch,
/// background launches included, must not silence a ringing alarm or throw away a snooze, and
/// must leave unchanged alarms alone.
@MainActor
final class AlarmSystemSyncPlanTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    /// A fresh launch: the saved fingerprints are back from defaults, the alarm is ringing, and
    /// the store still wants it. Nothing is cancelled or scheduled again.
    func testRelaunchLeavesARingingAlarmAlone() {
        let plan = AlarmSystemSyncPlan.plan(existing: [.init(id: a, isActive: true)], desired: [a: "7:00 daily"],
                                            lastScheduled: [a: "7:00 daily"], stoppedByUser: [])
        XCTAssertEqual(plan, .init())
    }

    /// The same with nothing saved (an upgrade from a build that kept fingerprints in memory):
    /// still not cancelled, because it is ringing.
    func testRelaunchWithNothingSavedStillSparesARingingOrSnoozingAlarm() {
        let plan = AlarmSystemSyncPlan.plan(existing: [.init(id: a, isActive: true)], desired: [a: "7:00 daily"],
                                            lastScheduled: [:], stoppedByUser: [])
        XCTAssertTrue(plan.cancel.isEmpty)
        XCTAssertTrue(plan.schedule.isEmpty)
    }

    /// A one-off that went off is off in the store, but its alert is still up: it finishes.
    func testAnAlarmThatWentOffIsNotTakenAwayMidRing() {
        let plan = AlarmSystemSyncPlan.plan(existing: [.init(id: a, isActive: true)], desired: [:],
                                            lastScheduled: [a: "x"], stoppedByUser: [])
        XCTAssertTrue(plan.cancel.isEmpty)
    }

    /// Deleted or switched off by the person: cancelled even while ringing.
    func testThePersonCanStillStopIt() {
        let plan = AlarmSystemSyncPlan.plan(existing: [.init(id: a, isActive: true)], desired: [:],
                                            lastScheduled: [a: "x"], stoppedByUser: [a])
        XCTAssertEqual(plan.cancel, [a])
    }

    /// Unchanged scheduled alarms are left alone; a changed one is replaced; a new one is added;
    /// one the store dropped is cancelled; the running timer is left to its own rule.
    func testScheduledAlarmsFollowTheirFingerprints() {
        let timer = UUID(), dropped = UUID()
        let plan = AlarmSystemSyncPlan.plan(
            existing: [.init(id: a, isActive: false), .init(id: b, isActive: false),
                       .init(id: dropped, isActive: false), .init(id: timer, isActive: true)],
            desired: [a: "same", b: "changed", c: "new"],
            lastScheduled: [a: "same", b: "old"], managedElsewhere: [timer], stoppedByUser: [])
        XCTAssertEqual(plan.cancel, [b, dropped])
        XCTAssertEqual(plan.schedule, [b, c])
    }

    /// An edit to an alarm that is ringing waits until it is back to scheduled.
    func testAnEditWaitsForTheRingToFinish() {
        let plan = AlarmSystemSyncPlan.plan(existing: [.init(id: a, isActive: true)], desired: [a: "8:00"],
                                            lastScheduled: [a: "7:00"], stoppedByUser: [])
        XCTAssertEqual(plan, .init())
    }

    /// Who stopped what survives a relaunch, and saving or switching on clears it.
    func testStoppedByUserIsKeptAcrossLaunches() {
        let defaults = ThrowawayDefaults.make("alarms.stopped")
        let first = AlarmStore(defaults: defaults)
        let song = NavidromeSong(id: "s", title: "Wake")
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        first.save(alarm)
        XCTAssertFalse(first.stoppedByUser.contains(alarm.id))
        first.setEnabled(false, id: alarm.id)
        let timer = first.startTimer(duration: 60, choice: .song(song))
        first.cancelTimer()
        let second = AlarmStore(defaults: defaults)
        XCTAssertEqual(second.stoppedByUser, [alarm.id, timer.id])
        second.setEnabled(true, id: alarm.id)
        XCTAssertEqual(second.stoppedByUser, [timer.id])
        // An alarm that only went off is not "stopped by the person".
        let once = BatonAlarm(hour: 6, minute: 0, choice: .song(song))
        second.save(once, now: Date().addingTimeInterval(-2 * 86_400))
        _ = second.due(at: Date())
        XCTAssertFalse(second.stoppedByUser.contains(once.id))
    }
}
