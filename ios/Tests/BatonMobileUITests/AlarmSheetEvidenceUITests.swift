import XCTest

/// Screenshots of the quick Alarm and Timer sheet in whatever appearance the simulator is in
///: the Timer tab from a song's menu, the What to Play picker, the Alarm tab with
/// its list, the pill above the mini player, and the ringing screen over Home.
///
/// Evidence, not a gate: it runs only with `BATON_ALARM_EVIDENCE=1` in the test runner's
/// environment (`TEST_RUNNER_BATON_ALARM_EVIDENCE=1` through xcodebuild), once with the simulator
/// light and once dark. The behaviour itself is `AlarmTimerUITests`.
final class AlarmSheetEvidenceUITests: XCTestCase {
    private var app: XCUIApplication!
    private let song = "Variatio 6, Canone alla Seconda"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["BATON_ALARM_EVIDENCE"] == "1" else {
            throw XCTSkip("set BATON_ALARM_EVIDENCE=1 (TEST_RUNNER_BATON_ALARM_EVIDENCE=1) for the sheet's screenshots")
        }
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_ALARM_SYSTEM"] = "off"
        app.launchEnvironment["uitestTimerSeconds"] = "20"
        // Listens in the play history, for What to Play's Recently played.
        app.launchEnvironment["uitestSeedPlayHistory"] = "1"
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testTheSheetPickerPillAndRingingScreen() throws {
        launchForReleaseNavigation(app)
        selectReleaseTab("Search", in: app, screenTitle: "Search")
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Canone\n")
        let row = app.staticTexts[song].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))

        // Nothing playing: the song's own menu opens the sheet with it as Then play.
        row.press(forDuration: 1.2)
        let startTimer = app.buttons["Start Timer…"]
        XCTAssertTrue(startTimer.waitForExistence(timeout: 5))
        startTimer.tap()
        let five = app.buttons["timer-preset-5"]
        XCTAssertTrue(five.waitForExistence(timeout: 10))
        five.tap()
        attach("sheet-timer")

        app.descendants(matching: .any)["alarm-then-play"].firstMatch.tap()
        let search = app.textFields["alarm-picker-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        attach("picker")
        // Recently played, under Browse: the demo's four tracks, each once, newest first, each
        // with its preview button (the history holds each twice).
        let rows = app.buttons.matching(identifier: "alarm-pick-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "Recently played lists the play history")
        // The list draws only the rows on screen: pull the sheet up and scroll until all are.
        var swipes = 0
        for _ in 0 ..< 4 where rows.count < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertEqual(app.buttons.matching(identifier: "alarm-pick-row").count, 4, "four tracks, each once")
        XCTAssertEqual(app.buttons.matching(identifier: "alarm-pick-preview").count, 4, "a preview button on each")
        attach("picker-recently-played")
        for _ in 0 ..< swipes { app.collectionViews.firstMatch.swipeDown() }
        search.tap()
        search.typeText("Variatio")
        XCTAssertTrue(app.buttons.matching(identifier: "alarm-pick-row").firstMatch.waitForExistence(timeout: 10))
        attach("picker-search")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(five.waitForExistence(timeout: 10))
        app.segmentedControls.buttons["Alarm"].tap()
        XCTAssertTrue(app.buttons["alarm-save"].waitForExistence(timeout: 5))
        attach("sheet-alarm")
        app.buttons["alarm-save"].tap()
        XCTAssertTrue(app.buttons["alarm-save"].waitForNonExistence(timeout: 5))

        // Again from the menu: the alarm is listed at the bottom of the Alarm tab.
        row.press(forDuration: 1.2)
        app.buttons["Set Alarm…"].tap()
        XCTAssertTrue(app.buttons["alarm-save"].waitForExistence(timeout: 10))
        // The list sits under the form: pull the sheet up and scroll to it.
        let alarmRow = app.descendants(matching: .any)["alarm-row"].firstMatch
        for _ in 0 ..< 4 where !alarmRow.exists { app.swipeUp() }
        XCTAssertTrue(alarmRow.waitForExistence(timeout: 5), "the saved alarm is listed in the sheet")
        attach("sheet-alarm-list")
        app.swipeDown()
        app.segmentedControls.buttons["Timer"].tap()
        five.tap()
        app.buttons["timer-start"].tap()

        // The pill above the mini player, then the ringing screen.
        let pill = app.buttons["alarm-pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        attach("pill")
        let ringing = app.descendants(matching: .any)["alarm-ringing"].firstMatch
        XCTAssertTrue(ringing.waitForExistence(timeout: 40))
        attach("ringing")
        app.buttons["alarm-open-player"].tap()
        XCTAssertTrue(app.buttons[PlayerControls.dismissFullPlayer].waitForExistence(timeout: 10))
        attach("player")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
