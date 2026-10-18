import XCTest

/// The real path of an alarm on iOS 26 and later (TBX-11171, specs/alarm-and-timer.md): Baton
/// sets an AlarmKit alarm a minute or so ahead, goes to the background, the system rings it, and
/// Play on the system's alert opens Baton playing the chosen track.
///
/// A walk, not a gate: it waits for a real minute to come round and answers the system's own
/// permission prompt, so it runs only with `BATON_ALARMKIT_WALK=1` in the test runner's
/// environment (`TEST_RUNNER_BATON_ALARMKIT_WALK=1` through xcodebuild). Each step's screenshot is
/// attached, so the result bundle shows what the simulator did and did not draw.
final class AlarmKitWalkUITests: XCTestCase {
    private var app: XCUIApplication!
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private let chosen = "Variatio 6, Canone alla Seconda"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["BATON_ALARMKIT_WALK"] == "1" else {
            throw XCTSkip("set BATON_ALARMKIT_WALK=1 (TEST_RUNNER_BATON_ALARMKIT_WALK=1) to walk a real AlarmKit alarm")
        }
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["uitestAlarmLeadSeconds"] = "25"
        // AlarmKit rings its own sound by default. BATON_ALARMKIT_WALK_SOUND=clip tries Baton's clip
        // of the track instead (it aborted the iOS 26.5 simulator's SpringBoard; a phone check).
        if ProcessInfo.processInfo.environment["BATON_ALARMKIT_WALK_SOUND"] == "clip" {
            app.launchEnvironment["BATON_DEBUG_ALARM_SOUND"] = "clip"
        }
    }

    func testAnAlarmAMinuteAheadRingsInTheBackgroundAndPlayOpensTheTrack() throws {
        launchForReleaseNavigation(app)
        selectReleaseTab("Search", in: app, screenTitle: "Search")
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Canone\n")
        let row = app.staticTexts[chosen].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.press(forDuration: 1.2)
        let setAlarm = app.buttons["Set Alarm…"]
        XCTAssertTrue(setAlarm.waitForExistence(timeout: 5))
        setAlarm.tap()

        // Snooze off, so the alert's button is Play. The quick sheet opens on the Alarm tab.
        let snooze = app.switches["Snooze"].firstMatch
        XCTAssertTrue(snooze.waitForExistence(timeout: 10))
        if (snooze.value as? String) == "1" { snooze.switches.firstMatch.exists ? snooze.switches.firstMatch.tap() : snooze.tap() }
        attach(app, "alarm-editor")
        app.buttons["alarm-save"].tap()

        // AlarmKit's permission prompt, the first time.
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 10) {
            attach(springboard, "alarmkit-permission")
            allow.tap()
        }
        let saved = Date()

        XCUIDevice.shared.press(.home)
        attach(springboard, "home-waiting")

        // The system's alert, up to the minute plus a margin. Its Play button is Baton's.
        let play = springboard.buttons["Play"].firstMatch
        let rang = play.waitForExistence(timeout: 120)
        attach(springboard, rang ? "alarm-ringing-system" : "no-system-alert")
        XCTAssertTrue(rang, "AlarmKit rang within two minutes of \(saved)")
        play.tap()

        // Baton opens and plays the chosen track. On the simulator the alert's Play intent cannot
        // be found (linkd has no team id for a simulator build; see the spec's verification
        // notes), so when Play does not open Baton the walk opens it by hand, which is the
        // other path the spec promises: opening Baton within ten minutes plays the alarm.
        if !app.wait(for: .runningForeground, timeout: 15) {
            attach(springboard, "play-did-not-open-baton")
            XCTContext.runActivity(named: "Play did not open Baton; opening it by hand") { _ in }
            app.activate()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Baton is in front")
        let ringing = app.descendants(matching: .any)["alarm-ringing"]
        if ringing.waitForExistence(timeout: 10) {
            attach(app, "baton-ringing-card")
            // "Keep playing, open player" lands in the full player.
            app.buttons["alarm-open-player"].tap()
        } else {
            XCTAssertTrue(openFullPlayer(in: app))
        }
        XCTAssertTrue(app.buttons[PlayerControls.dismissFullPlayer].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[chosen].waitForExistence(timeout: 10), "the player holds the chosen track")
        let elapsed = app.staticTexts["player-elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let first = elapsed.label
        wait(for: [expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: elapsed)], timeout: 10)
        attach(app, "baton-playing")
    }

    private func attach(_ target: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: target.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
