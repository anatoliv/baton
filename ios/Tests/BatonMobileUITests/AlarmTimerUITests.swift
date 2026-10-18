import XCTest

/// The quick Timer, end to end (TBX-1000000112, specs/alarm-and-timer.md).
///
/// The owner's three complaints about TestFlight 1.5.4, walked in order: the timer is set from the
/// player's clock, not Settings; "Then play" is changed through the picker to a track that is not
/// in the player (with the player paused, so nothing is playing); and when it goes off over
/// Settings, "Keep playing, open player" lands in the full player. A second timer then rings over
/// the full player and Stop pauses it.
///
/// The demo library supplies the tracks, so this needs no server. The system path (AlarmKit, or a
/// notification) is switched off with `BATON_DEBUG_ALARM_SYSTEM=off`, so no permission prompt
/// covers the screen, and `uitestTimerSeconds` makes the 5-minute preset count a few seconds.
final class AlarmTimerUITests: XCTestCase {
    private var app: XCUIApplication!
    private let playing = "Variatio 6, Canone alla Seconda"
    private let chosen = "Variatio 10, Fughetta"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication.batonUnderTest()
        // TBX-5336: launchEnvironment, not launchArguments.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_ALARM_SYSTEM"] = "off"
        app.launchEnvironment["uitestTimerSeconds"] = "30"
    }

    override func tearDown() {
        if testRun?.hasSucceeded == false, let app {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "failure"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app = nil
        super.tearDown()
    }

    func testTimerFromThePlayerRingsOverSettingsAndLandsInThePlayer() throws {
        launchForReleaseNavigation(app)

        // Something in the player, then paused: nothing is playing.
        selectReleaseTab("Search", in: app, screenTitle: "Search")
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText("Canone\n")
        let row = app.staticTexts[playing].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the demo library has no \(playing)")
        row.tap()
        XCTAssertTrue(openFullPlayer(in: app))
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 10), "it plays")
        tapOnScreen("Pause")
        XCTAssertTrue(waitOnScreen("Play"), "the player is paused")

        // The clock beside the moon opens the quick sheet on Timer.
        let clock = app.buttons["player-alarm-clock"]
        XCTAssertTrue(clock.waitForExistence(timeout: 5), "the player has a clock button")
        clock.tap()
        let five = app.buttons["timer-preset-5"]
        XCTAssertTrue(five.waitForExistence(timeout: 10), "the Timer presets")
        for minutes in [10, 15, 30, 60] { XCTAssertTrue(app.buttons["timer-preset-\(minutes)"].exists) }
        XCTAssertTrue(app.buttons["timer-preset-custom"].exists)
        five.tap()
        let thenPlay = app.descendants(matching: .any)["alarm-then-play"].firstMatch
        XCTAssertTrue(thenPlay.waitForExistence(timeout: 5))
        XCTAssertTrue(label(containing: playing).exists, "Then play starts as what the player holds")
        attach("01-sheet-timer")

        // The picker, with nothing playing: search, preview, choose.
        thenPlay.tap()
        let search = app.textFields["alarm-picker-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the What to Play picker")
        attach("02-picker")
        search.tap()
        search.typeText("Fughetta")
        let pick = app.buttons.matching(identifier: "alarm-pick-row").containing(.staticText, identifier: chosen).firstMatch
        let pickByText = app.staticTexts[chosen].firstMatch
        XCTAssertTrue(pickByText.waitForExistence(timeout: 15), "the picker finds \(chosen)")
        let preview = app.buttons["Preview \(chosen)"].firstMatch
        if preview.waitForExistence(timeout: 3) {
            preview.tap()
            XCTAssertTrue(app.buttons["Stop preview"].firstMatch.waitForExistence(timeout: 5), "a preview plays")
            attach("03-picker-preview")
        }
        (pick.exists ? pick : pickByText).tap()
        XCTAssertTrue(five.waitForExistence(timeout: 10), "choosing returns to the sheet")
        XCTAssertTrue(label(containing: chosen).waitForExistence(timeout: 5), "Then play is the chosen track")
        attach("04-sheet-then-play-changed")
        app.buttons["timer-start"].tap()

        // The pill above the mini player, counting down.
        XCTAssertTrue(five.waitForNonExistence(timeout: 5), "Start closes the sheet")
        dismissFullPlayer(in: app)
        let pill = app.buttons["alarm-pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the pill shows while the timer runs")
        XCTAssertTrue(pill.label.hasPrefix("Timer "), pill.label)
        XCTAssertTrue(pill.label.contains("then \(chosen)"), pill.label)
        attach("05-pill")
        // As wide as the mini player under it, not sized to its text. The
        // system accessory exposes no element for the player's capsule, so the tab bar's capsule
        // stands in: on iOS 26 the accessory sits at the tab bar's inset (the same 21pt edges on
        // the screenshot for the pill, the player and the tab bar).
        let capsule = app.descendants(matching: .any)["alarm-pill-capsule"].firstMatch
        XCTAssertTrue(capsule.exists, "the pill's capsule")
        if #available(iOS 26.0, *) {
            let screenWidth = app.frame.width
            let tabCapsule = app.tabBars.firstMatch.descendants(matching: .other).allElementsBoundByIndex
                .map { $0.frame }.filter { $0.width < screenWidth }.max { $0.width < $1.width }
            let column = try XCTUnwrap(tabCapsule, "the tab bar's capsule")
            XCTAssertEqual(capsule.frame.minX, column.minX, accuracy: 1, "pill \(capsule.frame) vs tab bar \(column)")
            XCTAssertEqual(capsule.frame.maxX, column.maxX, accuracy: 1, "pill \(capsule.frame) vs tab bar \(column)")
        }

        // Settings, and the timer goes off over it.
        selectReleaseTab("Home", in: app, screenTitle: "Home")
        app.buttons["Settings"].firstMatch.tap()
        let permissionRow = app.descendants(matching: .any)["settings-alarm-permission"].firstMatch
        XCTAssertTrue(permissionRow.waitForExistence(timeout: 10), "Settings is open, with its one Alarm and Timer row")
        let ringing = app.descendants(matching: .any)["alarm-ringing"].firstMatch
        XCTAssertTrue(ringing.waitForExistence(timeout: 45), "the timer went off")
        XCTAssertTrue(permissionRow.exists, "it rang over Settings, which is still underneath")
        XCTAssertTrue(label(containing: chosen).exists, "the ringing card names what plays")
        XCTAssertTrue(app.buttons["alarm-snooze"].exists, "Snooze 9 min")
        XCTAssertTrue(app.buttons["alarm-stop"].exists, "Stop")
        attach("06-ringing-over-settings")

        // Keep playing, open player: Settings goes, the full player comes, the track plays.
        app.buttons["alarm-open-player"].tap()
        XCTAssertTrue(ringing.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[PlayerControls.dismissFullPlayer].waitForExistence(timeout: 10), "landed in the full player")
        XCTAssertFalse(permissionRow.exists, "Settings was closed on the way")
        XCTAssertTrue(app.staticTexts[chosen].waitForExistence(timeout: 10), "the player holds the chosen track")
        let elapsed = app.staticTexts["player-elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let first = elapsed.label
        wait(for: [expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: elapsed)], timeout: 10)
        attach("07-landed-in-player")

        // A second timer, ringing over the full player this time; Stop pauses.
        clock.tap()
        XCTAssertTrue(five.waitForExistence(timeout: 10))
        five.tap()
        app.buttons["timer-start"].tap()
        XCTAssertTrue(ringing.waitForExistence(timeout: 45), "the second timer went off over the player")
        attach("08-ringing-over-player")
        app.buttons["alarm-stop"].tap()
        XCTAssertTrue(ringing.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitOnScreen("Play"), "Stop paused the music")
        let stopped = elapsed.label
        sleep(2)
        XCTAssertEqual(elapsed.label, stopped, "nothing plays after Stop")
        attach("09-stopped")
    }

    /// The button with this label that is on screen: the mini bar's twin sits under the full player.
    private func onScreen(_ label: String) -> XCUIElement? {
        app.buttons.matching(identifier: label).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            ?? app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
    }

    private func tapOnScreen(_ label: String) {
        guard let button = onScreen(label) else { return XCTFail("no \(label) button on screen") }
        button.tap()
    }

    private func waitOnScreen(_ label: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if onScreen(label) != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func label(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
