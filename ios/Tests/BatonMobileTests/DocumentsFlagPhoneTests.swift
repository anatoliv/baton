import BatonSubsonicKit
import Foundation
import XCTest
@testable import BatonMobile

/// `baton.documents.enabled` on the phone: on until the Documents toggle in Settings
/// stores `false`. `SessionPurge` removes the key on disconnect, which reads as on again.
@MainActor
final class DocumentsFlagPhoneTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = ThrowawayDefaults.name("phone-documents-flag")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAnAbsentKeyReadsOn() {
        XCTAssertNil(defaults.object(forKey: MobileDocuments.enabledKey), "the suite must start empty")
        XCTAssertTrue(MobileDocuments.isEnabled(in: defaults), "documents are on by default")
    }

    func testAStoredFalseReadsOffAndRemovingTheKeyReadsOnAgain() {
        defaults.set(false, forKey: MobileDocuments.enabledKey)
        XCTAssertFalse(MobileDocuments.isEnabled(in: defaults), "the Settings toggle turns documents off")
        defaults.set(true, forKey: MobileDocuments.enabledKey)
        XCTAssertTrue(MobileDocuments.isEnabled(in: defaults))
        defaults.removeObject(forKey: MobileDocuments.enabledKey)
        XCTAssertTrue(MobileDocuments.isEnabled(in: defaults), "a session purge resets to on")
    }
}
