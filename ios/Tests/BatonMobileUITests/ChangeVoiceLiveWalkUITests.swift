import XCTest

/// Change Voice… on the phone against a real home server and a real voice server: a
/// two-chapter book made in Heart, the listener's place set in chapter 2, then Change Voice… to
/// another narrator. The row says "Making again in …" while the home server makes it, each
/// chapter is replaced in its row, and Play afterwards resumes in chapter 2 at the same place.
///
/// Opt-in like `DocumentImportLiveWalkUITests`: it skips unless the runner has
/// `BATON_LIVE_GATEWAY_URL`, `BATON_LIVE_GATEWAY_TOKEN` and `BATON_LIVE_IMPORT_FILE`;
/// `ios/scripts/change-voice-live-walk.sh` sets them for a throwaway loopback gateway and
/// measures the voice from outside (the voice server's request log and the files' digests).
/// Everything reaches the app through its launch environment, never argv.
final class ChangeVoiceLiveWalkUITests: XCTestCase {
    private var app: XCUIApplication!
    private var target = "am_michael"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["BATON_LIVE_GATEWAY_URL"], let token = env["BATON_LIVE_GATEWAY_TOKEN"], !token.isEmpty,
              let file = env["BATON_LIVE_IMPORT_FILE"], !file.isEmpty else {
            throw XCTSkip("set BATON_LIVE_GATEWAY_URL, BATON_LIVE_GATEWAY_TOKEN and BATON_LIVE_IMPORT_FILE (ios/scripts/change-voice-live-walk.sh)")
        }
        if let voice = env["BATON_LIVE_TARGET_VOICE"], !voice.isEmpty { target = voice }
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = url
        app.launchEnvironment["uitestGatewayToken"] = token
        app.launchEnvironment["uitestImportFile"] = file
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    func testChangingABooksVoiceReplacesItsChaptersAndKeepsThePlace() throws {
        // The notification question can come at any point once a book exists; answer it so it
        // cannot hold the walk. XCUITest runs the monitor on the next interaction.
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Allow", "Don’t Allow", "Don't Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        app.launch()
        allowNotifications()
        XCTAssertTrue(app.staticTexts["The Lighthouse"].firstMatch.waitForExistence(timeout: 60), "the import screen did not open")
        let heart = app.buttons["narrator-kokoro:af_heart"].firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 30), "Heart is not offered")
        heart.tap()
        let make = app.buttons["make-audiobook"].firstMatch
        var tries = 0
        while !make.isHittable && tries < 6 { app.swipeUp(); tries += 1 }
        attach("01-import-heart")
        make.tap()
        app.tap()
        XCTAssertTrue(waitUntilGone(app.staticTexts["The Lighthouse"].firstMatch, timeout: 60),
                      "the import screen should close once the book is sent")
        openBooks()
        let made = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch
        XCTAssertTrue(made.waitForExistence(timeout: 300), "the book was not made in Heart")
        mark("made-in-heart")
        attach("02-made-in-heart")

        // The listener is 5 s into chapter 2 (the DEBUG seed writes the shared ledger's place).
        app.terminate()
        app.launchEnvironment["uitestImportFile"] = nil
        app.launchEnvironment["baton.resetSession"] = nil
        app.launchEnvironment["uitestBookPosition"] = "1:5"
        app.launch()
        openBooks()
        let row = app.buttons.containing(NSPredicate(format: "identifier BEGINSWITH 'book-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the book row is not in Books")
        row.press(forDuration: 1.2)
        let change = app.buttons["Change Voice…"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10), "the book's menu has no Change Voice…")
        attach("03-book-menu")
        change.tap()

        // Among the suggested voices, or else under All voices.
        var option = app.buttons["narrator-kokoro:\(target)"].firstMatch
        if !option.waitForExistence(timeout: 30) {
            app.buttons["all-voices"].firstMatch.tap()
            option = app.buttons["voice-kokoro:\(target)"].firstMatch
            var scrolls = 0
            while !option.isHittable && scrolls < 12 { app.swipeUp(); scrolls += 1 }
        }
        XCTAssertTrue(option.waitForExistence(timeout: 10), "\(target) is not among the home server's voices")
        XCTAssertTrue(app.staticTexts["Now read by Heart, American, female."].firstMatch.exists, "the screen names the voice it has")
        option.tap()
        attach("04-change-voice-picker")
        app.buttons["make-again"].firstMatch.tap()
        mark("change-voice-pressed")

        let making = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Making again in \(target) on Kokoro'")).firstMatch
        XCTAssertTrue(making.waitForExistence(timeout: 30), "the row does not say it is being made again")
        attach("05-making-again")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch.exists,
                      "both chapters stay playable while the new voice is made")
        // Chapter 1 may land on its own ("… chapter 2 of 2"), or both in one round of the watch.
        let halfway = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'chapter 2 of 2'")).firstMatch
        let deadline = Date(timeIntervalSinceNow: 400)
        var sawHalfway = false
        while making.exists && Date() < deadline {
            if !sawHalfway, halfway.exists {
                sawHalfway = true
                mark("chapter-1-replaced")
                attach("06-chapter-1-replaced")
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        XCTAssertFalse(making.exists, "the book was not made again within the time allowed")
        mark("made-again")
        attach("07-made-again")

        // Play resumes at the place: chapter 2, a little after 0:05, in the new voice.
        row.tap()
        mark("play-pressed")
        let mini = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'The Storm'")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "Play did not start chapter 2, The Storm")
        attach("08a-mini-player-chapter-2")
        tapMiniBar(in: app)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        mark("playing")
        attach("08-playing-after-change")
    }

    /// A fresh install asks about notifications at launch, over the import screen.
    private func allowNotifications() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for name in ["Allow", "Don’t Allow", "Don't Allow"] {
            let button = springboard.buttons[name].firstMatch
            if button.waitForExistence(timeout: name == "Allow" ? 8 : 1) { button.tap(); return }
        }
    }

    /// Books has its own Library section since TBX-11018; the route is `BooksScreen`.
    private func openBooks() {
        BooksScreen.open(app)
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return !element.exists
    }

    /// A timestamped step, for the walk's timeline beside the gateway's log.
    private func mark(_ step: String) {
        let note = XCTAttachment(string: "\(ISO8601DateFormatter().string(from: Date())) \(step)")
        note.name = "step-\(step)"
        note.lifetime = .keepAlways
        add(note)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
