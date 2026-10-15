import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// `baton.documents.enabled` on the Mac: on for everyone until Settings → Speech →
/// Documents stores `false`. A fresh install has no key at all, and `bool(forKey:)` would read
/// that as off, so the default is pinned here rather than assumed.
@MainActor
final class DocumentsFlagTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = ThrowawayDefaults.name("documents-flag")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAnAbsentKeyReadsOn() {
        XCTAssertNil(defaults.object(forKey: DocumentLibrary.enabledKey), "the suite must start empty")
        XCTAssertTrue(DocumentLibrary.isEnabled(in: defaults), "documents are on by default")
    }

    func testAStoredFalseReadsOffAndTrueReadsOnAgain() {
        defaults.set(false, forKey: DocumentLibrary.enabledKey)
        XCTAssertFalse(DocumentLibrary.isEnabled(in: defaults), "the Settings toggle turns documents off")
        defaults.set(true, forKey: DocumentLibrary.enabledKey)
        XCTAssertTrue(DocumentLibrary.isEnabled(in: defaults))
        defaults.removeObject(forKey: DocumentLibrary.enabledKey)
        XCTAssertTrue(DocumentLibrary.isEnabled(in: defaults), "removing the key is a reset to on")
    }
}
