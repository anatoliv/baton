import BatonPlaybackKit
import XCTest
@testable import BatonMobile

/// The timer's reschedule when its clip is ready. AlarmKit holds one alarm
/// per id, so the chime timer is cancelled before the clip timer is scheduled; when that schedule
/// was refused, no system timer was left at all.
@available(iOS 26.0, *)
@MainActor
final class AlarmKitTimerRescheduleTests: XCTestCase {
    func testARefusedClipFallsBackToTheSoundTheTimerHad() async {
        var asked: [String] = []
        let took = await AlarmKitBridge.scheduleFirst(of: ["clip-abc.caf", "chime.caf", ""]) { sound in
            asked.append(sound)
            return sound == "chime.caf"
        }
        XCTAssertEqual(took, "chime.caf", "a timer is put back with the chime")
        XCTAssertEqual(asked, ["clip-abc.caf", "chime.caf"])
    }

    func testTheClipIsUsedWhenAlarmKitTakesIt() async {
        var asked: [String] = []
        let took = await AlarmKitBridge.scheduleFirst(of: ["clip-abc.caf", "chime.caf", ""]) { sound in
            asked.append(sound)
            return true
        }
        XCTAssertEqual(took, "clip-abc.caf")
        XCTAssertEqual(asked, ["clip-abc.caf"], "one schedule when the first is taken")
    }

    func testEachSoundIsTriedOnceAndNilWhenNoneIsTaken() async {
        var asked: [String] = []
        let took = await AlarmKitBridge.scheduleFirst(of: ["", nil, "", "chime.caf"]) { sound in
            asked.append(sound)
            return false
        }
        XCTAssertNil(took)
        XCTAssertEqual(asked, ["", "chime.caf"])
    }

    /// After a fallback took, the next sync must find the clip already tried: the plan reschedules
    /// whenever the recorded sound differs from the one wanted, so recording the fallback cancelled
    /// and rescheduled the running timer on every sync.
    func testAFallbackDoesNotMakeEverySyncRescheduleTheTimer() {
        let id = UUID()
        let wanted = "\(id.uuidString) clip-abc.caf"
        let recorded = AlarmKitBridge.recorded(took: "chime.caf", wanted: "clip-abc.caf", for: id)
        let action = AlarmSystemTimerPlan.action(.running(endsAt: Date().addingTimeInterval(300)), held: .countdown,
                                                 now: Date(), givenSound: wanted, recordedSound: recorded)
        XCTAssertEqual(action, .none, "the running timer is left alone")
    }

    func testTheRecordedSoundIsReadOnlyForThisTimer() {
        let id = UUID(), other = UUID()
        XCTAssertEqual(AlarmKitBridge.sound(recorded: "\(id.uuidString) chime.caf", for: id), "chime.caf")
        XCTAssertEqual(AlarmKitBridge.sound(recorded: "\(id.uuidString) ", for: id), "")
        XCTAssertNil(AlarmKitBridge.sound(recorded: "\(other.uuidString) chime.caf", for: id))
        XCTAssertNil(AlarmKitBridge.sound(recorded: nil, for: id))
    }
}
