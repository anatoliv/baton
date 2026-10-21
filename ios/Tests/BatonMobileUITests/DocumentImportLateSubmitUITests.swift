import XCTest

/// A Make Audiobook that answers late must not close the import screen of the document opened
/// after it.
///
/// Cancel stays enabled while Make Audiobook's upload runs, and the upload keeps going after
/// it. When the home server finally answers (and the notification prompt is settled), the submit
/// closes "its" screen. Before `MobileModel.endImport(generation:)` that close cleared whatever
/// was pending by then, so a second document opened in the meantime lost its import screen under
/// the person. This walks the real path against `FakeHomeServer`, which holds the submit's reply:
/// Make Audiobook, Cancel, a second document shared from another app, let the first reply land,
/// and the second document's screen is still there.
///
/// The second document arrives through the share inbox on a trip Home and back
/// (`uitestSharedTextWhenAway`, as `ImportOverSheetUITests` does), not `XCUIApplication.open`:
/// opening a file URL relaunches the app under test, which ends the first submit with its
/// process, so the late answer this is about would never come.
///
/// Demo mode, loopback only. Environment, never launch arguments.
final class DocumentImportLateSubmitUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!
    /// Long enough for Cancel and the second document to happen while the first submit waits.
    private let submitDelay: TimeInterval = 15
    private let firstTitle = "Two Rooms"
    private let secondTitle = "A Second Door"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        server = try FakeHomeServer()
        server.setSubmitDelay(submitDelay)
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = server.baseURL
        app.launchEnvironment["uitestGatewayToken"] = "uitest-fake-home-server"
        app.launchEnvironment["uitestSharedTextWhenAway"] = """
        \(secondTitle)
        by Somebody Else

        Chapter 1 The Hinge

        The door opened onto a second room, as small as the first.
        """
        app.launchEnvironment["uitestImportText"] = """
        \(firstTitle)
        by Nobody in Particular

        Chapter 1 The Cell

        A small room, like the cell of a bee. The air was fresh, though there was no window.
        """
    }

    override func tearDown() {
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    @MainActor
    func testALateMakeAudiobookDoesNotCloseTheNextDocumentsImportScreen() throws {
        app.launch()
        let first = app.staticTexts[firstTitle].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "the first document's import screen did not open")

        let make = app.buttons["make-audiobook"].firstMatch
        var tries = 0
        while !make.exists && tries < 6 {
            app.swipeUp()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            tries += 1
        }
        XCTAssertTrue(make.waitForExistence(timeout: 20), "Make Audiobook was not offered")
        make.tap()
        XCTAssertTrue(waitFor(10) { self.server.requests("PUT").count == 1 }, "Make Audiobook sent nothing")
        let submitted = try XCTUnwrap(server.requests("PUT").first?.at)

        // Cancel while the home server still holds the answer.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitFor(5) { !first.exists }, "Cancel should close the first import screen")

        // A second document, shared from another app while Baton is away.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.springboard").wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let second = app.staticTexts[secondTitle].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 20), "the second document's import screen did not open")
        XCTAssertLessThan(Date().timeIntervalSince(submitted), submitDelay,
                          "the second screen must be up before the first submit answers, or this proves nothing")
        attach("second-import-before-late-answer")

        // The first submit answers now. After it, the app asks for notifications once; answer
        // that, since the late close only runs once the prompt is settled.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let settleBy = submitted.addingTimeInterval(submitDelay + 15)
        var promptAnswered = false
        while Date() < settleBy {
            for name in ["Don’t Allow", "Don't Allow"] where springboard.buttons[name].exists {
                springboard.buttons[name].tap()
                promptAnswered = true
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        XCTAssertGreaterThan(Date().timeIntervalSince(submitted), submitDelay + 5, "waited past the late answer")
        attach("second-import-after-late-answer")
        // The first submit did come back and carry on (its watch asks for the book's status), so
        // its late close really ran while the second screen was up.
        let answered = submitted.addingTimeInterval(submitDelay)
        XCTAssertFalse(server.statusReads(since: answered).isEmpty,
                       "the first submit never came back; requests: \(server.requests.map { "\($0.method) \($0.path)" })")
        XCTAssertTrue(second.exists,
                      "the first document's late Make Audiobook closed the second document's import screen (prompt answered: \(promptAnswered))")
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.exists, "the second import screen is still the one on show")

        // And the second screen still closes with its own Cancel.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitFor(5) { !second.exists }, "Cancel should close the second import screen")
    }

    private func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        return condition()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
