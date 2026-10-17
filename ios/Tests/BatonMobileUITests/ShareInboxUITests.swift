import XCTest

/// What the Baton share extension leaves in the App Group inbox opens the import screen when the
/// app becomes active, once.
///
/// The share sheet itself belongs to another app's process and is not drivable from XCUITest, so
/// the share is written by the extension's own writer (`PendingShareInbox.writeText`) from the app
/// at launch (`uitestSharedText`, DEBUG only) into the real App Group container. Everything after
/// that, the activation pickup, the exactly-once claim and the import screen, is the real path.
/// The share sheet half is walked on the phone.
final class ShareInboxUITests: XCTestCase {
    func testASharedDocumentOpensTheImportScreenOnceOnActivation() throws {
        continueAfterFailure = false
        let app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        // As if just updated, so What's New also wants the launch sheet: the two used to race
        // and the import screen lost.
        app.launchEnvironment["uitestWhatsNewUpgradedFrom"] = "0.1"
        app.launchEnvironment["uitestSharedText"] = """
        Shared Pages
        by Nobody in Particular

        Chapter 1 The Porch

        Someone shared this from another app, and Baton picked it up when it was opened.

        Chapter 2 The Garden

        The second chapter is here so the import has more than one.
        """
        app.launch()

        let title = app.staticTexts["Shared Pages"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the shared document did not open the import screen")
        XCTAssertTrue(app.staticTexts["The Porch"].firstMatch.waitForExistence(timeout: 5), "chapter 1 is not listed")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "import-screen-from-share-inbox"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(title.waitForExistence(timeout: 3), "Cancel should close the import screen")

        // Away and back: the share was claimed, so nothing opens again.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertFalse(title.waitForExistence(timeout: 5), "a share must open once, not on every activation")

        // A fresh launch with nothing new shared finds the inbox empty too.
        app.terminate()
        app.launchEnvironment["uitestSharedText"] = nil
        app.launch()
        XCTAssertFalse(title.waitForExistence(timeout: 8), "a claimed share must not come back after a relaunch")
    }

    /// Force-quit with the import screen open: the share has left the inbox, so only the kept
    /// copy can bring it back. The next launch opens it again; Cancel then ends it.
    func testASharedDocumentSurvivesAForceQuitUntilItsScreenCloses() throws {
        continueAfterFailure = false
        let app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestSharedText"] = """
        Kept Pages
        by Nobody in Particular

        Chapter 1 The Hall

        Shared from another app, and the app was quit before the import screen closed.
        """
        app.launch()
        let title = app.staticTexts["Kept Pages"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the shared document did not open the import screen")

        // Force-quit and relaunch with nothing new shared and no reset: the kept copy opens.
        app.terminate()
        app.launchEnvironment["uitestSharedText"] = nil
        app.launchEnvironment["baton.resetSession"] = nil
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 30), "a share lost to a force-quit")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(title.waitForExistence(timeout: 3), "Cancel should close the import screen")

        // Handled: it does not come back.
        app.terminate()
        app.launch()
        XCTAssertFalse(title.waitForExistence(timeout: 8), "a handled share must not come back after a relaunch")
    }
}
