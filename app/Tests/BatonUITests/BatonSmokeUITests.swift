import XCTest

/// : launch/smoke UI test — proves Baton boots to the foreground without crashing, the
/// baseline every UI regression builds on. Runs via the `BatonUITests` scheme in a GUI-capable
/// environment (the XCUITest runner + a signed/bundled app); it is intentionally excluded from the
/// `Baton` unit-test scheme so the headless `scripts/test.sh` gate never attempts a UI session.
final class BatonSmokeUITests: XCTestCase {
    func testAppLaunchesToForeground() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground, "Baton should reach the foreground after launch")
        // The main player window exists once the app is up.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "the main window should appear")
    }

    func testAppTerminatesCleanly() {
        let app = XCUIApplication()
        app.launch()
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
    }
}
