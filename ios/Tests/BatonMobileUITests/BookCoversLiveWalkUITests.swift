import XCTest

/// Book covers on the phone against a real home server: a book the Mac made and gave
/// a cover is adopted here with that cover (the row, the open book, the player), then the phone
/// finds one on Open Library and makes one of its own from the title and author, each of which
/// goes back to the home server for the Mac.
///
/// Opt-in like `DocumentImportLiveWalkUITests`: it skips unless the runner has
/// `BATON_LIVE_GATEWAY_URL` and `BATON_LIVE_GATEWAY_TOKEN`, a throwaway loopback gateway that
/// already lists a book with a cover (`scripts/probe-book-covers.sh` makes one on a Mac probe).
/// `BATON_LIVE_FIND=0` leaves out the Open Library step. The covers are measured from outside
/// (the gateway's `cover.json` and the app's own cover index); this walk drives the screens and
/// keeps a screenshot of each. Everything reaches the app by its launch environment, never argv.
final class BookCoversLiveWalkUITests: XCTestCase {
    private var app: XCUIApplication!
    private var find = true

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["BATON_LIVE_GATEWAY_URL"], let token = env["BATON_LIVE_GATEWAY_TOKEN"], !token.isEmpty else {
            throw XCTSkip("set BATON_LIVE_GATEWAY_URL and BATON_LIVE_GATEWAY_TOKEN to walk book covers against a home server")
        }
        find = env["BATON_LIVE_FIND"] != "0"
        app = XCUIApplication()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = url
        app.launchEnvironment["uitestGatewayToken"] = token
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    func testTheMacsCoverArrivesAndThePhonesCoversGoBack() throws {
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Allow", "Don’t Allow", "Don't Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        app.launch()
        BooksScreen.open(app)
        let row = BooksScreen.row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 90), "the Mac's book was not adopted from the home server")
        // The cover comes down on the same round as the book; give the row a moment to draw it.
        pause(6)
        attach("01-books-list-with-the-macs-cover")

        BooksScreen.openBook(app)
        pause(2)
        attach("02-open-book-with-the-macs-cover")
        BooksScreen.playButton(app).tap()
        pause(4)
        attach("03-playing-with-the-cover")

        let cover = app.buttons["cover-menu"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 10), "the open book's cover is not a menu")
        if find {
            cover.tap()
            let findItem = app.buttons["Find Cover…"].firstMatch
            XCTAssertTrue(findItem.waitForExistence(timeout: 5), "no Find Cover… in the cover menu")
            attach("04-cover-menu")
            findItem.tap()
            XCTAssertTrue(app.staticTexts["Only the title and author are sent to Open Library."].firstMatch
                .waitForExistence(timeout: 10), "the finder does not say what is sent")
            let use = app.buttons["cover-use"].firstMatch
            XCTAssertTrue(use.waitForExistence(timeout: 10))
            let deadline = Date().addingTimeInterval(40)
            while !use.isEnabled && Date() < deadline { pause(1) }
            XCTAssertTrue(use.isEnabled, "Open Library offered no cover to pick")
            pause(4)   // the candidates' pictures
            attach("05-find-cover-candidates")
            use.tap()
            XCTAssertTrue(waitUntilGone(use, timeout: 40), "Use Cover did not close the finder")
            pause(2)
            attach("06-open-library-cover")
        }

        cover.tap()
        let make = app.buttons["Make a Cover"].firstMatch
        XCTAssertTrue(make.waitForExistence(timeout: 5), "Make a Cover is not offered for a book with an author")
        if !find { attach("04-cover-menu") }
        make.tap()
        pause(3)
        attach("07-made-cover")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }
        pause(2)
        attach("08-books-list-made-cover")
    }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
