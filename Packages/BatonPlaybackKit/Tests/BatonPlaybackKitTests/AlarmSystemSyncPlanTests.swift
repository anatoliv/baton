import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// What a system sync may do to the alarms AlarmKit already holds: a launch,
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

    /// A timer and an alarm at once: scheduling the alarm leaves the running
    /// timer to its own rule, and cancelling the timer (gone from the store, stopped by the person)
    /// leaves the alarm scheduled.
    func testAnAlarmAndATimerAreScheduledTogetherAndCancelledApart() {
        let alarm = a, timer = b
        let both = AlarmSystemSyncPlan.plan(existing: [.init(id: timer, isActive: true)], desired: [alarm: "7:00"],
                                            lastScheduled: [:], managedElsewhere: [timer], stoppedByUser: [])
        XCTAssertEqual(both.schedule, [alarm])
        XCTAssertTrue(both.cancel.isEmpty, "the timer is not touched")

        let timerCancelled = AlarmSystemSyncPlan.plan(
            existing: [.init(id: alarm, isActive: false), .init(id: timer, isActive: true)], desired: [alarm: "7:00"],
            lastScheduled: [alarm: "7:00"], stoppedByUser: [timer])
        XCTAssertEqual(timerCancelled.cancel, [timer])
        XCTAssertTrue(timerCancelled.schedule.isEmpty, "the alarm stays as it was")

        let alarmOff = AlarmSystemSyncPlan.plan(
            existing: [.init(id: alarm, isActive: false), .init(id: timer, isActive: true)], desired: [:],
            lastScheduled: [alarm: "7:00"], managedElsewhere: [timer], stoppedByUser: [alarm])
        XCTAssertEqual(alarmOff.cancel, [alarm])
        XCTAssertTrue(alarmOff.schedule.isEmpty)
    }

    /// The running timer AlarmKit holds: scheduled when new; scheduled again
    /// once when its clip arrives while it counts down; left alone at a launch whose sound is
    /// unchanged, near its end, and while paused; paused and resumed in place.
    func testTheTimerIsScheduledOnceAndAgainOnlyWhenItsSoundChanges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let running = BatonTimer.State.running(endsAt: now.addingTimeInterval(600))
        let chime = "t BatonAlarmChime.caf", clip = "t baton-alarm-t.caf"
        typealias Plan = AlarmSystemTimerPlan
        XCTAssertEqual(Plan.action(running, held: .none, now: now, givenSound: chime, recordedSound: nil), .schedule,
                       "a fresh timer")
        XCTAssertEqual(Plan.action(running, held: .countdown, now: now, givenSound: clip, recordedSound: chime), .reschedule,
                       "the clip arrived while it counts down")
        XCTAssertEqual(Plan.action(running, held: .countdown, now: now, givenSound: clip, recordedSound: clip), .none,
                       "a launch with the same sound leaves it alone")
        XCTAssertEqual(Plan.action(.running(endsAt: now.addingTimeInterval(2)), held: .countdown, now: now,
                                   givenSound: clip, recordedSound: chime), .none, "too near its end to replace")
        XCTAssertEqual(Plan.action(.paused(remaining: 300), held: .paused, now: now, givenSound: clip, recordedSound: chime),
                       .none, "a paused timer keeps its sound until it runs again")
        XCTAssertEqual(Plan.action(.paused(remaining: 300), held: .countdown, now: now, givenSound: clip, recordedSound: clip),
                       .pause)
        XCTAssertEqual(Plan.action(running, held: .paused, now: now, givenSound: clip, recordedSound: clip), .resume)
        XCTAssertEqual(Plan.action(running, held: .other, now: now, givenSound: clip, recordedSound: chime), .none,
                       "ringing: never touched")
        XCTAssertEqual(Plan.action(.running(endsAt: now.addingTimeInterval(-1)), held: .none, now: now,
                                   givenSound: clip, recordedSound: nil), .none, "already over")
    }
}
