import XCTest

/// Measures the rendered Friend composer against the system tab bar's capsule, without a live
/// model. On an iPhone with iOS 26 both sit 21pt in from each edge
/// (`BottomChrome.floatingInset`); before, the composer used the standalone 20pt and was a
/// point wider on each side. Environment, never launch arguments.
final class BottomChromeAlignmentUITests: XCTestCase {
    func testFriendComposerAlignsWithTheSystemBottomColumn() throws {
        continueAfterFailure = false
        let app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestVerifiedAgent"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        launchForReleaseNavigation(app)
        selectReleaseTab("Friend", in: app, screenTitle: "Music Friend")
        let composer = app.descendants(matching: .any)["FriendComposerCapsule"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        captureReleaseNavigation(app, named: "friend-composer-column")
        let screenWidth = app.frame.width
        let column = try XCTUnwrap(app.tabBars.firstMatch.descendants(matching: .other)
            .allElementsBoundByIndex.map { $0.frame }
            .filter { $0.width < screenWidth }.max { $0.width < $1.width },
            "the system tab bar's visible capsule")
        XCTAssertEqual(composer.frame.minX, column.minX, accuracy: 0.25,
                       "composer \(composer.frame), system column \(column)")
        XCTAssertEqual(composer.frame.maxX, column.maxX, accuracy: 0.25,
                       "composer \(composer.frame), system column \(column)")
    }

    /// With an alarm set, the Friend tab shows both the alarm pill and the composer, one above the
    /// other. The pill was drawn exactly where the composer sits, covering it,
    /// while the composer's element still existed under it.
    func testWithAnAlarmSetThePillAndTheComposerBothShowWithoutOverlapping() throws {
        continueAfterFailure = false
        let app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestVerifiedAgent"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        // Baton's own scheduling only: no AlarmKit prompt, nothing left on the simulator's system.
        app.launchEnvironment["BATON_DEBUG_ALARM_SYSTEM"] = "off"
        launchForReleaseNavigation(app)

        // An alarm, the way a person sets one: long-press a song, Set Alarm…, Save.
        selectReleaseTab("Search", in: app, screenTitle: "Search")
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText("Canone\n")
        let row = app.staticTexts["Variatio 6, Canone alla Seconda"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the demo library has the Canone")
        row.press(forDuration: 1.2)
        let setAlarm = app.buttons["Set Alarm…"]
        XCTAssertTrue(setAlarm.waitForExistence(timeout: 5))
        setAlarm.tap()
        let save = app.buttons["alarm-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        // Hours ahead, so it cannot ring while the test runs.
        let later = app.buttons["In 8 hours"].firstMatch
        if later.waitForExistence(timeout: 3) { later.tap() }
        // Turned off in teardown, so a failed assertion below cannot leave it set for a later
        // test, which is how this card's pill was found.
        addTeardownBlock { @MainActor [app] in
            let off = app.buttons["alarm-pill-cancel"].firstMatch
            for _ in 0 ..< 5 where off.exists {
                off.tap()
                _ = off.waitForNonExistence(timeout: 2)
            }
            XCTAssertFalse(off.exists, "the alarm is off again")
        }
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "Save closes the sheet")

        selectReleaseTab("Friend", in: app, screenTitle: "Music Friend")
        let composer = app.descendants(matching: .any)["FriendComposerCapsule"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let pill = app.descendants(matching: .any)["alarm-pill-capsule"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the alarm pill shows on the Friend tab")
        captureReleaseNavigation(app, named: "friend-composer-with-alarm-pill")

        let composerFrame = composer.frame, pillFrame = pill.frame
        XCTAssertFalse(composerFrame.isEmpty)
        XCTAssertFalse(pillFrame.isEmpty)
        XCTAssertTrue(composerFrame.intersection(pillFrame).isNull || composerFrame.intersection(pillFrame).height < 0.5,
                      "the pill covers the composer: pill \(pillFrame), composer \(composerFrame)")
        XCTAssertTrue(app.frame.contains(composerFrame) && app.frame.contains(pillFrame),
                      "both on screen: pill \(pillFrame), composer \(composerFrame)")
        let tabBar = app.tabBars.firstMatch.frame
        XCTAssertLessThanOrEqual(max(composerFrame.maxY, pillFrame.maxY), tabBar.minY + 1,
                                 "both sit above the tab bar \(tabBar)")
        XCTAssertTrue(app.textFields["FriendComposerField"].firstMatch.isHittable, "the composer can be typed in")
    }
}
