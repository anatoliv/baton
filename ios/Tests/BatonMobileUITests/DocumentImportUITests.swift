import XCTest

/// The phone's import screen, walked offline (M5.2, M5.5): a document handed over at launch
/// opens the screen with the title and chapters Baton read, and with no home server set up the
/// screen says so instead of offering a button that would fail.
///
/// The words are passed in the environment (`uitestImportText`, DEBUG only) rather than as a
/// file, because the test runner and the app do not share a sandbox. Environment, never launch
/// arguments.
final class DocumentImportUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        // As if just updated, so What's New also wants the launch sheet: the two used to race
        // and the import screen lost.
        app.launchEnvironment["uitestWhatsNewUpgradedFrom"] = "0.1"
        app.launchEnvironment["uitestImportText"] = """
        Two Rooms
        by Nobody in Particular

        Chapter 1 The Cell

        A small room, like the cell of a bee. The air was fresh, though there was no window.

        Chapter 2 The Surface

        The light at the top was grey, and the hills were bare.
        """
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testADocumentOpensTheImportScreenAndSaysItNeedsTheHomeServer() throws {
        app.launch()

        let title = app.staticTexts["Two Rooms"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the import screen did not open with the document's title")
        XCTAssertTrue(app.staticTexts["The Cell"].firstMatch.waitForExistence(timeout: 5), "chapter 1 is not listed")
        XCTAssertTrue(app.staticTexts["The Surface"].firstMatch.exists, "chapter 2 is not listed")

        // No gateway on a fresh install: the screen says what making a book needs.
        let needs = app.otherElements["needs-home-server"].firstMatch
        let needsText = app.staticTexts["Making a book needs your home server"].firstMatch
        XCTAssertTrue(needs.waitForExistence(timeout: 15) || needsText.waitForExistence(timeout: 15),
                      "the screen should say the home server is needed")
        XCTAssertFalse(app.buttons["make-audiobook"].exists, "Make Audiobook must not be offered without a home server")
        // With no home server to use, the screen suggests AirDrop to the Mac instead,
        // and never Send to my Mac, which needs one. "No home server" or "one that does not
        // answer": a gateway address a UI test gave an earlier run (`uitestGatewayURL`) survives
        // `baton.resetSession`, and both say the same thing here.
        XCTAssertTrue(app.buttons["airdrop-to-mac"].firstMatch.waitForExistence(timeout: 5),
                      "the screen should offer to AirDrop the file to the Mac")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "AirDrop this to")).firstMatch.exists,
                      "and say why in a sentence")
        XCTAssertFalse(app.buttons["send-to-mac"].exists, "Send to my Mac needs a home server")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "import-screen-no-home-server"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(title.waitForExistence(timeout: 3), "Cancel should close the import screen")
    }
}
