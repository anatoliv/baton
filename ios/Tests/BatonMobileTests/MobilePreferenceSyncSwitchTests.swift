import XCTest
@testable import BatonMobile

/// A test or probe phone must stay out of the owner's shared settings. On 2026-10-14 a simulator
/// taking part in the live walk published its reset state as the newest word, which emptied the
/// shared agent settings on the owner's Mac and swapped the gateway address for a loopback
/// relay. The switch is the phone's half of the Mac's `PreferenceSyncScheduler.isSwitchedOff`.
@MainActor
final class MobilePreferenceSyncSwitchTests: XCTestCase {
    func testAWalkCanSwitchSyncOffThroughTheEnvironment() {
        XCTAssertTrue(MobileModel.isPreferenceSyncSwitchedOff(by: ["BATON_DEBUG_PREFERENCE_SYNC": "off"]))
        XCTAssertFalse(MobileModel.isPreferenceSyncSwitchedOff(by: ["BATON_DEBUG_PREFERENCE_SYNC": "on"]))
        XCTAssertFalse(MobileModel.isPreferenceSyncSwitchedOff(by: [:]))
    }
}
