import XCTest

extension XCTestCase {
    /// A reused release simulator can upgrade between runs. Resetting the account keeps
    /// the changelog marker, so its visible sheet must be dismissed before browsing.
    func launchForReleaseNavigation(_ app: XCUIApplication) {
        app.launch()
        let whatsNew = app.navigationBars["What's New"]
        if whatsNew.waitForExistence(timeout: 5) {
            captureReleaseNavigation(app, named: "release-upgrade-whats-new")
            let done = whatsNew.buttons["Done"]
            XCTAssertTrue(done.isHittable, "the upgrade sheet must offer a visible Done button")
            done.tap()
            XCTAssertTrue(whatsNew.waitForNonExistence(timeout: 10),
                          "Done must dismiss the upgrade sheet before the test navigates")
        }
    }

    func selectReleaseTab(_ title: String, in app: XCUIApplication,
                          screenTitle: String, timeout: TimeInterval = 30) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout), "expected the \(title) tab")
        let hittable = NSPredicate(format: "hittable == true")
        let visible = expectation(for: hittable, evaluatedWith: tab)
        wait(for: [visible], timeout: 10)
        tab.tap()
        let selected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: tab)
        wait(for: [selected], timeout: 10)
        let header = title == "Home" ? app.buttons["Settings"] : app.staticTexts[screenTitle].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: timeout), "expected the visible \(screenTitle) screen")
        XCTAssertTrue(header.isHittable, "the \(screenTitle) header must be visible, not behind a sheet")
        captureReleaseNavigation(app, named: "release-tab-\(title.lowercased())")
    }

    func captureReleaseNavigation(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
