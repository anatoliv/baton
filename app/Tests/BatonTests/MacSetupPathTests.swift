import XCTest
import BatonPlaybackKit
@testable import Baton

/// The directions the phone gives to this app.
///
/// The iPhone tells you where to go in the Mac's Settings, and it cannot see the Mac to
/// check. Both first attempts were wrong: it sent people to "Settings → Export settings",
/// which has never existed — export lives in **About → Back up & restore** — and to
/// "Remote → Devices", where the section is actually called **Link a device**. Someone
/// followed those directions and went looking for a menu that was never there.
///
/// So the strings live in `MacSetupPath`, and these tests pin them against the Mac's own
/// labels. A renamed pane fails here rather than on a stranger's phone.
final class MacSetupPathTests: XCTestCase {
    func testThePaneNamesMatchTheSettingsSidebar() {
        XCTAssertEqual(MacSetupPath.remotePane, BatonSettingsCategory.remote.label)
        XCTAssertEqual(MacSetupPath.aboutPane, BatonSettingsCategory.about.label)
    }

    /// The full sentences the phone actually renders, spelled out so a change to any part
    /// is visible in the diff rather than hidden behind string interpolation.
    func testTheDirectionsReadAsTheyShould() {
        XCTAssertEqual(MacSetupPath.pairing,
                       "Settings → Remote → Link a device → Show pairing code")
        XCTAssertEqual(MacSetupPath.export,
                       "Settings → About → Back up & restore → Export…")
    }

    /// The guides quote the same paths in prose. They are the version most people read,
    /// and they were wrong in exactly the same two ways.
    func testTheHelpGuideGivesTheSameDirections() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "HELP", withExtension: "md"),
                                "HELP.md must be in the bundle for this to mean anything")
        let help = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(help.contains("Remote → Link a device → Show pairing code"),
                      "HELP.md must name the pairing section the Mac actually has")
        XCTAssertTrue(help.contains("About → Back up & restore → Export"),
                      "HELP.md must name where export actually lives")
        XCTAssertFalse(help.contains("Settings → Export settings"),
                       "that menu item does not exist")
        XCTAssertFalse(help.contains("Remote → Devices"),
                       "that section is called 'Link a device'")
    }
}
