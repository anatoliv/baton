import XCTest

/// Drives the disconnect flow against a real running app.
///
/// The unit tests prove each store clears itself. What they cannot prove is that the
/// *screen* reaches them: that Disconnect is present when a server is configured, that the
/// confirmation tells the truth about what it will delete, and that after confirming, the
/// app is genuinely back at setup with the library gone. That path only exists at runtime.
///
/// Uses the accessibility tree rather than synthetic taps for the reason the screen audit
/// records: CGEvent taps reach the Simulator only intermittently, so a manual pass can miss
/// a control that is genuinely broken — or, worse, "confirm" one that is.
final class SessionPurgeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // A configured server, without typing: text entry is the one thing synthetic input
        // reliably cannot do, and every screen behind "connect" is otherwise unreachable.
        app.launchArguments += [
            "-uitestServer", "https://demo.navidrome.org",
            "-uitestUser", "demo",
            "-uitestSecret", "demo",
            "-uitestBypassBiometrics",
        ]
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// The confirmation must name what it deletes. A destructive action that says only
    /// "are you sure?" is asking someone to agree to something they haven't been told.
    func testDisconnectConfirmationNamesWhatItRemoves() {
        app.launch()

        openSettings()

        let disconnect = app.buttons["Disconnect…"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 20),
                      "a configured server must offer a way out of it")
        disconnect.tap()

        // The dialog's message is what makes the choice informed.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "expected a confirmation")

        let text = sheet.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " ")
        XCTAssertTrue(text.contains("remove its data from this iPhone"),
                      "the message must say data is removed, not just that we disconnect. Got: \(text)")
        XCTAssertTrue(text.lowercased().contains("play counts are untouched")
                        || !text.contains("plays will be cleared"),
                      "if we mention clearing plays we must also say the server keeps its own")

        // Leave without acting — this test is about the words, not the deletion. The
        // cancel button of a confirmationDialog is presented by the system outside the
        // sheet's own element subtree, so it's queried on the app.
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }
    }

    /// Confirming must actually land back at setup. The previous implementation cleared
    /// in-memory state and left the app in a half-configured limbo.
    func testDisconnectReturnsToSetup() {
        app.launch()

        openSettings()

        let disconnect = app.buttons["Disconnect…"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 20))
        disconnect.tap()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))

        // Whichever destructive button is offered (the copy varies with download count).
        let confirm = sheet.buttons.allElementsBoundByIndex.first {
            $0.label.hasPrefix("Disconnect")
        }
        XCTAssertNotNil(confirm, "expected a Disconnect button in the sheet")
        confirm?.tap()

        // The setup gate is a full-screen cover; its title is the tell.
        XCTAssertTrue(app.staticTexts["Connect to Navidrome"].waitForExistence(timeout: 10),
                      "after disconnecting, the app must ask for a server rather than sit empty")
    }

    // MARK: - Helpers

    private func openSettings() {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "app should reach its tab bar")
        settings.tap()
    }
}
