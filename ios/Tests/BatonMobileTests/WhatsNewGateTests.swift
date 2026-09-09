import XCTest
@testable import BatonMobile

/// Whether the What's New sheet can ever present itself.
///
/// It could not. `baton.whatsNew.lastShownVersion` was written in exactly one place — the
/// Done button inside the sheet — and `shouldShow` requires it to be non-empty. So on a
/// fresh install the key stayed empty for ever, the automatic sheet never appeared on any
/// later update, and the only way to reach it was to open Settings by hand. Every 1.0 App
/// Store install is in that state.
///
/// The second half is the mirror image: someone who *was* shown the sheet and swiped it
/// away rather than tapping Done left the key untouched and saw the same notes on every
/// launch for the rest of the version's life.
@MainActor
final class WhatsNewGateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "baton.whatsnew.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - The decision

    func testAFreshInstallIsShownNothing() {
        XCTAssertFalse(WhatsNewView.shouldShow(lastShown: "", current: "1.1"),
                       "a new user needs onboarding, not a changelog")
    }

    func testAnUpdateIsShownTheNotes() {
        XCTAssertTrue(WhatsNewView.shouldShow(lastShown: "1.0", current: "1.1"))
    }

    func testTheSameVersionIsNotShownTwice() {
        XCTAssertFalse(WhatsNewView.shouldShow(lastShown: "1.1", current: "1.1"))
    }

    // MARK: - The stamp that was missing

    /// The whole bug in one assertion: a fresh install must end its first launch with the
    /// running version recorded, or no later update can ever be compared against anything.
    func testFirstLaunchRecordsTheInstalledVersion() {
        XCTAssertEqual(defaults.string(forKey: WhatsNewView.lastShownKey) ?? "", "",
                       "precondition: a fresh install")

        WhatsNewView.stampInstalledVersion(defaults)

        XCTAssertEqual(defaults.string(forKey: WhatsNewView.lastShownKey),
                       WhatsNewView.currentVersion)
    }

    /// Stamping shows nothing now — it is a record, not a trigger.
    func testStampingDoesNotItselfCauseTheSheetToAppear() {
        WhatsNewView.stampInstalledVersion(defaults)
        let stamped = defaults.string(forKey: WhatsNewView.lastShownKey) ?? ""
        XCTAssertFalse(WhatsNewView.shouldShow(lastShown: stamped, current: WhatsNewView.currentVersion))
        // ...and the very next release is.
        XCTAssertTrue(WhatsNewView.shouldShow(lastShown: stamped, current: WhatsNewView.currentVersion + "9"))
    }

    /// A second launch must not move the marker forward past notes that were never shown.
    func testStampingIsOnlyEverDoneOnce() {
        defaults.set("0.9", forKey: WhatsNewView.lastShownKey)

        WhatsNewView.stampInstalledVersion(defaults)

        XCTAssertEqual(defaults.string(forKey: WhatsNewView.lastShownKey), "0.9",
                       "an existing marker is somebody's unseen release notes")
    }
}
