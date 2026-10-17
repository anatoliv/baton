import XCTest

/// Speed and the sleep timer on a book, the phone's walk: a two-chapter book made on
/// `FakeHomeServer`, played from Books, sped up from the full player, the sleep timer opened
/// on it, and the speed found again after a relaunch.
///
/// Demo mode, no network beyond loopback. Environment, never launch arguments.
final class BookSpeedSleepUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        server = try FakeHomeServer()
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = server.baseURL
        app.launchEnvironment["uitestGatewayToken"] = "uitest-fake-home-server"
        app.launchEnvironment["uitestImportText"] = """
        Two Rooms
        by Nobody in Particular

        Chapter 1 The Cell

        A small room, like the cell of a bee. The air was fresh, though there was no window.

        Chapter 2 The Surface

        The light at the top was grey, and the hills were bare.
        """
    }

    override func tearDown() {
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    func testABookPlaysAtTheChosenSpeedAndOffersASleepTimerThatStopsAtTheChapter() throws {
        server.setReadyOnSubmit(2)
        app.launch()
        makeAudiobook()
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch
            .waitForExistence(timeout: 30), "both chapters should come down")
        playBookAndOpenPlayer()

        // Speed: the control is on the player for a book, as for a podcast.
        let speed = app.buttons["Playback speed"].firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 10), "a book should offer a playback speed\n\(app.debugDescription)")
        XCTAssertEqual(speed.value as? String, "1×")
        speed.tap()
        for label in ["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"] {
            XCTAssertTrue(app.buttons[label].firstMatch.waitForExistence(timeout: 5), "the speed menu should offer \(label)")
        }
        XCTAssertFalse(app.buttons["0.5×"].exists, "0.75× is the slowest")
        attach("speed-menu")
        app.buttons["1.5×"].firstMatch.tap()
        XCTAssertTrue(waitFor(5) { (speed.value as? String) == "1.5×" }, "the chosen speed should show on the player")
        attach("speed-1.5")

        // Sleep timer: the same choices as the Mac, and the end-of-item choice named for a book.
        let sleep = app.buttons["Sleep timer"].firstMatch
        XCTAssertTrue(sleep.waitForExistence(timeout: 5))
        sleep.tap()
        for label in ["15 minutes", "30 minutes", "45 minutes", "1 hour", "End of chapter"] {
            XCTAssertTrue(app.buttons[label].firstMatch.waitForExistence(timeout: 5), "the sleep timer should offer \(label)")
        }
        attach("sleep-menu")
        app.buttons["End of chapter"].firstMatch.tap()
        sleep.tap()
        XCTAssertTrue(app.buttons["Cancel sleep timer"].firstMatch.waitForExistence(timeout: 5),
                      "an armed timer offers Cancel")
        attach("sleep-armed")
        app.buttons["Cancel sleep timer"].firstMatch.tap()

        // Remembered across launches.
        app.terminate()
        app.launchEnvironment["baton.resetSession"] = nil
        app.launchEnvironment["uitestImportText"] = nil
        app.launch()
        openBooks()
        playBookAndOpenPlayer()
        let again = app.buttons["Playback speed"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        XCTAssertEqual(again.value as? String, "1.5×", "the speed should be remembered across launches")
        attach("speed-after-relaunch")
    }

    // MARK: - Steps

    private func playBookAndOpenPlayer() {
        // A book's row opens the book; its Play starts it, and the list is shown again so only
        // the player names a chapter.
        BooksScreen.playBookAndLeave(app)
        // The bar's title, not `openFullPlayer`'s first match on the bar: for a book that match
        // can be the bar's Play button, and tapping it pauses instead of opening the player.
        let title = app.staticTexts.matching(identifier: PlayerControls.miniBar).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "Play started nothing")
        title.tap()
        XCTAssertTrue(app.buttons[PlayerControls.dismissFullPlayer].waitForExistence(timeout: 15),
                      "tapping the mini player must open the full player")
    }

    private func makeAudiobook() {
        XCTAssertTrue(app.staticTexts["Two Rooms"].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")
        let make = app.buttons["make-audiobook"].firstMatch
        var tries = 0
        while !make.exists && tries < 6 {
            app.swipeUp()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            tries += 1
        }
        XCTAssertTrue(make.waitForExistence(timeout: 20), "Make Audiobook was not offered: the fake home server did not answer")
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Don’t Allow", "Don't Allow", "Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        make.tap()
        XCTAssertTrue(waitFor(10) { self.server.requests("PUT").count == 1 }, "Make Audiobook sent nothing")
        app.tap()
        // The notification question can arrive after that tap, when no further interaction
        // would wake the monitor; answer it on SpringBoard directly while waiting.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(waitFor(30) {
            for name in ["Don’t Allow", "Don't Allow"] where springboard.buttons[name].exists {
                springboard.buttons[name].tap()
            }
            return !self.app.buttons["make-audiobook"].exists
        }, "the import screen should close")
        removeUIInterruptionMonitor(monitor)
    }

    /// Books has its own Library section since TBX-11018; the route is `BooksScreen`.
    private func openBooks() {
        BooksScreen.open(app)
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
