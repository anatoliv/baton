import XCTest
import BatonPlaybackKit
import BatonSubsonicKit
@testable import BatonMobile

/// The phone's Documents switch read live: Clippings reads it through
/// `MobileModel.documentsSwitch`, so turning documents off in Settings hides books and the
/// import menu at once rather than at the next launch.
@MainActor
final class DocumentsSwitchPhoneTests: XCTestCase {
    func testTheDocumentsSwitchIsReadLive() {
        let defaults = UserDefaults(suiteName: ThrowawayDefaults.name("phone-documents-live"))!
        let toggle = DefaultsSwitch(key: MobileDocuments.enabledKey, defaultValue: true, defaults: defaults)
        XCTAssertTrue(toggle.isOn)
        defaults.set(false, forKey: MobileDocuments.enabledKey)
        XCTAssertFalse(toggle.isOn, "Settings turned it off: Clippings hides books at once")
        defaults.removeObject(forKey: MobileDocuments.enabledKey)
        XCTAssertTrue(toggle.isOn, "a reset reads as on again")
    }
}
