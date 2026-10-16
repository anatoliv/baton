import XCTest

/// A book made on the Mac with its own voices plays on the phone, every chapter: the
/// phone adopts it from a real home server, lists both chapters ready, and plays chapter 1 and
/// then chapter 2. Before the fix the Mac could mark such a book sent with no chapter on the home
/// server, and the phone waited on "0 of 2 chapters ready" for ever.
///
/// Opt-in: it skips unless the runner has `BATON_LIVE_GATEWAY_URL`, `BATON_LIVE_GATEWAY_TOKEN` and
/// `BATON_LIVE_BOOK_TITLE` (a book a Mac probe made and sent there, `scripts/probe-mac-book-upload.sh`).
/// Everything reaches the app by its launch environment, never argv.
final class MacMadeBookLiveWalkUITests: XCTestCase {
    private var app: XCUIApplication!

    func testABookMadeOnTheMacListsEveryChapterReadyAndPlaysThem() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["BATON_LIVE_GATEWAY_URL"], let token = env["BATON_LIVE_GATEWAY_TOKEN"], !token.isEmpty,
              let title = env["BATON_LIVE_BOOK_TITLE"], !title.isEmpty else {
            throw XCTSkip("set BATON_LIVE_GATEWAY_URL, BATON_LIVE_GATEWAY_TOKEN and BATON_LIVE_BOOK_TITLE")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = url
        app.launchEnvironment["uitestGatewayToken"] = token
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Allow", "Don’t Allow", "Don't Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        app.launch()
        BooksScreen.open(app)

        let row = labelled(title)
        XCTAssertTrue(row.waitForExistence(timeout: 90), "the Mac's book was not adopted\n\(app.debugDescription)")
        // Its chapters come down after the book does: wait until the row says nothing is waiting.
        let waiting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Waiting'")).firstMatch
        let deadline = Date().addingTimeInterval(90)
        while waiting.exists && Date() < deadline { pause(2) }
        attach("m1-books-list")
        XCTAssertFalse(waiting.exists, "a chapter is still waiting on the home server")
        XCTAssertTrue(labelled("2 chapters").exists, "the row does not list both chapters")
        row.tap()
        XCTAssertTrue(BooksScreen.playButton(app).waitForExistence(timeout: 10))
        pause(2)
        attach("m2-open-book-all-chapters")
        XCTAssertFalse(app.staticTexts["waiting"].exists, "a chapter row still says waiting")

        BooksScreen.playButton(app).tap()
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'The Air-Ship'"))
        pause(3)
        attach("m3-playing-chapter-1")
        XCTAssertGreaterThan(first.count, 1, "chapter 1 is not in the player")

        let second = labelled("The Mending Apparatus")
        XCTAssertTrue(second.exists)
        second.tap()
        pause(3)
        attach("m4-playing-chapter-2")
        let playing = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'The Mending Apparatus'"))
        XCTAssertGreaterThan(playing.count, 1, "chapter 2 is not in the player")
    }

    private func labelled(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND (elementType == %d OR elementType == %d OR elementType == %d)",
                                                             text, XCUIElement.ElementType.button.rawValue,
                                                             XCUIElement.ElementType.staticText.rawValue,
                                                             XCUIElement.ElementType.cell.rawValue)).firstMatch
    }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
