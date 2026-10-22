import XCTest

/// Voice the dialogue on the phone against a real home server and a real voice server
/// a two-chapter book imported with the switch on, its cast proposed by the home
/// server's model, checked and used, the lines placed, and the book made with a voice per
/// character; then Change Voice… turns the cast off and the book is made again with one narrator.
///
/// Opt-in like `ChangeVoiceLiveWalkUITests`: it skips unless the runner has
/// `BATON_LIVE_GATEWAY_URL`, `BATON_LIVE_GATEWAY_TOKEN` and `BATON_LIVE_IMPORT_FILE`;
/// `ios/scripts/dialogue-cast-live-walk.sh` sets them for a throwaway loopback gateway and checks
/// from outside what the gateway stored and which voices Kokoro was asked for.
final class DialogueCastLiveWalkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["BATON_LIVE_GATEWAY_URL"], let token = env["BATON_LIVE_GATEWAY_TOKEN"], !token.isEmpty,
              let file = env["BATON_LIVE_IMPORT_FILE"], !file.isEmpty else {
            throw XCTSkip("set BATON_LIVE_GATEWAY_URL, BATON_LIVE_GATEWAY_TOKEN and BATON_LIVE_IMPORT_FILE (ios/scripts/dialogue-cast-live-walk.sh)")
        }
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestNoOnDeviceModel"] = "1"
        app.launchEnvironment["uitestGatewayURL"] = url
        app.launchEnvironment["uitestGatewayToken"] = token
        app.launchEnvironment["uitestImportFile"] = file
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    func testABookIsMadeWithItsCastThenWithOneNarrator() throws {
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Allow", "Don’t Allow", "Don't Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for name in ["Allow", "Don’t Allow", "Don't Allow"] where springboard.buttons[name].firstMatch.waitForExistence(timeout: name == "Allow" ? 8 : 1) {
            springboard.buttons[name].firstMatch.tap(); break
        }
        XCTAssertTrue(app.staticTexts["The Machine"].firstMatch.waitForExistence(timeout: 60), "the import screen did not open")
        XCTAssertTrue(app.buttons["narrator-kokoro:af_heart"].firstMatch.waitForExistence(timeout: 30), "the home server's voices")
        app.buttons["narrator-kokoro:af_heart"].firstMatch.tap()

        // Voice the dialogue: the home server's model proposes the cast; check it and use it.
        setSwitch(true)
        reveal(app.buttons["check-the-cast"].firstMatch, timeout: 120).tap()
        mark("cast-proposed")
        let use = app.buttons["use-this-cast"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 15), "Check the Cast opened")
        attach("01-check-the-cast")
        use.tap()
        let placed = reveal(app.staticTexts["placed-line"].firstMatch, timeout: 120)
        mark("lines-placed: \(placed.label)")
        attach("02-lines-placed")
        let make = reveal(app.buttons["make-audiobook"].firstMatch, timeout: 20)
        make.tap()
        app.tap()
        XCTAssertTrue(waitUntilGone(app.staticTexts["The Machine"].firstMatch, timeout: 60), "the import screen closes once the book is sent")
        mark("book-sent")
        BooksScreen.open(app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch
            .waitForExistence(timeout: 300), "the book with its cast was not made")
        mark("made-with-cast")
        attach("03-made-with-cast")

        // Change Voice…: the switch is on for the cast it has; off, and Make Again.
        let row = app.buttons.containing(NSPredicate(format: "identifier BEGINSWITH 'book-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the book row is not in Books")
        row.press(forDuration: 1.2)
        let change = app.buttons["Change Voice…"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10), "the book's menu has no Change Voice…")
        change.tap()
        let toggle = reveal(app.switches["voice-the-dialogue"].firstMatch, timeout: 30)
        XCTAssertEqual(toggle.value as? String, "1", "the book has its cast")
        XCTAssertTrue(app.buttons["check-the-cast"].firstMatch.exists, "Edit Cast… for the cast it has")
        attach("04-change-voice-with-cast")
        setSwitch(false)
        attach("05-cast-off")
        app.buttons["make-again"].firstMatch.tap()
        mark("make-again-pressed")
        let making = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Making again'")).firstMatch
        XCTAssertTrue(making.waitForExistence(timeout: 30), "the row says it is being made again")
        let deadline = Date(timeIntervalSinceNow: 400)
        while making.exists && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        XCTAssertFalse(making.exists, "the book was not made again within the time allowed")
        mark("made-again-one-narrator")
        attach("06-made-again")
    }

    private func setSwitch(_ on: Bool) {
        let toggle = reveal(app.switches["voice-the-dialogue"].firstMatch, timeout: 20)
        guard (toggle.value as? String == "1") != on else { return }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let deadline = Date(timeIntervalSinceNow: 5)
        while (toggle.value as? String == "1") != on && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25)) }
        XCTAssertEqual(toggle.value as? String == "1", on, "Voice the dialogue did not turn \(on ? "on" : "off")")
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, timeout: TimeInterval) -> XCUIElement {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var swipes = 0
        while Date() < deadline {
            if element.exists && element.isHittable { return element }
            if swipes < 8 { app.swipeUp(); swipes += 1 }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        }
        XCTAssertTrue(element.exists && element.isHittable, "not found: \(element)")
        return element
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return !element.exists
    }

    private func mark(_ step: String) {
        let note = XCTAttachment(string: "\(ISO8601DateFormatter().string(from: Date())) \(step)")
        note.name = "step-\(step.prefix(40))"
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
