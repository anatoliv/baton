import XCTest

/// The Timer, the way Clock's works, ending in a Baton track instead of a ringtone (TBX-11171,
/// specs/alarm-and-timer.md).
///
/// A song's long-press menu offers "Start Timer…"; the timer is set to five seconds on Clock's
/// wheels with Baton in front; when it ends the chosen track starts and the ringing card says so.
/// The demo library supplies the track, so this needs no server. The system path (AlarmKit, or a
/// notification) is switched off with `BATON_DEBUG_ALARM_SYSTEM=off`, so no permission prompt
/// covers the screen: what is under test is Baton's own clock playing the item.
final class AlarmTimerUITests: XCTestCase {
    private var app: XCUIApplication!
    private let chosen = "Variatio 6, Canone alla Seconda"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication.batonUnderTest()
        // TBX-5336: launchEnvironment, not launchArguments.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_ALARM_SYSTEM"] = "off"
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testAFiveSecondTimerPlaysTheChosenTrackWhenItEnds() throws {
        launchForReleaseNavigation(app)

        // The chosen track, from its own long-press menu.
        selectReleaseTab("Search", in: app, screenTitle: "Search")
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText("Canone\n")
        let row = app.cells.containing(.staticText, identifier: chosen).firstMatch
        let rowByText = app.staticTexts[chosen].firstMatch
        XCTAssertTrue(rowByText.waitForExistence(timeout: 20), "the demo library has no \(chosen)")
        (row.exists ? row : rowByText).press(forDuration: 1.2)
        let startTimer = app.buttons["Start Timer…"]
        XCTAssertTrue(startTimer.waitForExistence(timeout: 5), "the song's menu offers Start Timer…")
        startTimer.tap()

        // Clock's wheels: 0 hours, 0 min, 5 sec.
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 2).waitForExistence(timeout: 10), "the timer's three wheels")
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "0")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "0")
        wheels.element(boundBy: 2).adjust(toPickerWheelValue: "5")
        let playRow = app.descendants(matching: .any)["alarm-play-choice"]
        XCTAssertTrue(playRow.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", chosen)).firstMatch.exists,
                      "When Timer Ends names the chosen track")
        attach("timer-set")
        app.buttons["timer-start"].tap()

        // Nothing plays before it ends; then the chosen track does, and the card says so.
        let ringing = app.descendants(matching: .any)["alarm-ringing"]
        XCTAssertFalse(ringing.exists, "the timer is still counting")
        XCTAssertTrue(ringing.waitForExistence(timeout: 20), "the timer ended and Baton rang")
        attach("timer-ended")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", chosen)).firstMatch.exists,
                      "the ringing card names what plays")
        app.buttons["alarm-keep-playing"].tap()
        XCTAssertTrue(ringing.waitForNonExistence(timeout: 5))

        // The chosen track is what the player holds, and it is playing.
        XCTAssertTrue(openFullPlayer(in: app))
        XCTAssertTrue(app.staticTexts[chosen].waitForExistence(timeout: 10), "the player holds the chosen track")
        let elapsed = app.staticTexts["player-elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let first = elapsed.label
        let moved = expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: elapsed)
        wait(for: [moved], timeout: 10)
        attach("player-playing")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
