import XCTest

/// Saving an alarm and starting a timer with the system path on (AlarmKit on iOS 26 and later,
/// notifications before), so Baton cuts the chosen track's clip into `Library/Sounds`
/// (TBX-1000000410, specs/alarm-and-timer.md). The clip itself is read from outside the app
/// afterwards (`simctl get_app_container … data`, then `afinfo`), which a UI test cannot do.
///
/// Evidence, not a gate: it answers the system's own permission prompt and leaves an alarm eight
/// hours ahead and an hour's timer scheduled, so it runs only with `BATON_ALARM_CLIP_EVIDENCE=1`
/// in the test runner's environment (`TEST_RUNNER_BATON_ALARM_CLIP_EVIDENCE=1` through
/// xcodebuild), on a simulator made for it and deleted after. Nothing rings while it runs.
final class AlarmClipEvidenceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private let chosen = "Variatio 6, Canone alla Seconda"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["BATON_ALARM_CLIP_EVIDENCE"] == "1" else {
            throw XCTSkip("set BATON_ALARM_CLIP_EVIDENCE=1 (TEST_RUNNER_BATON_ALARM_CLIP_EVIDENCE=1) to cut a real alarm clip")
        }
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testSavingAnAlarmAndStartingATimerCutTheTracksClip() throws {
        launchForReleaseNavigation(app)
        selectReleaseTab("Search", in: app, screenTitle: "Search")
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Canone\n")
        let row = app.staticTexts[chosen].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))

        // An alarm eight hours ahead, so nothing rings during the run.
        row.press(forDuration: 1.2)
        let setAlarm = app.buttons["Set Alarm…"]
        XCTAssertTrue(setAlarm.waitForExistence(timeout: 5))
        setAlarm.tap()
        let later = app.buttons["In 8 hours"].firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: 10), "the quick pick In 8 hours")
        later.tap()
        attach(app, "alarm-in-8-hours")
        app.buttons["alarm-save"].tap()
        allowPrompt()
        XCTAssertTrue(app.buttons["alarm-save"].waitForNonExistence(timeout: 10))

        // An hour's timer of the same track.
        row.press(forDuration: 1.2)
        let startTimer = app.buttons["Start Timer…"]
        XCTAssertTrue(startTimer.waitForExistence(timeout: 5))
        startTimer.tap()
        let hour = app.buttons["timer-preset-60"]
        XCTAssertTrue(hour.waitForExistence(timeout: 10))
        hour.tap()
        app.buttons["timer-start"].tap()
        allowPrompt()
        XCTAssertTrue(app.buttons["alarm-pill"].firstMatch.waitForExistence(timeout: 10), "the timer runs")
        // The clips are cut after the first schedule; give them a moment before the app goes.
        sleep(8)
        attach(app, "timer-running")
    }

    /// AlarmKit's prompt, or the notification prompt on iOS 18 to 25, the first time.
    private func allowPrompt() {
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 8) {
            attach(springboard, "permission")
            allow.tap()
        }
    }

    private func attach(_ target: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: target.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
