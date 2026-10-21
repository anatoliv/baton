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
}
