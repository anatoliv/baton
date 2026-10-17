import XCTest

@MainActor
final class PrivateContactUITests: XCTestCase {
    func testConsentAndEphemeralContactSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["uitestSkipSpeechAuthorization"] = "1"
        app.launchEnvironment["baton.launchProbe"] = UUID().uuidString
        app.launchEnvironment["baton.defaultsSuite"] = "io.tonebox.tests.contact." + UUID().uuidString
        // Existing DEBUG probe seam: contact rejects HTTP before any network request.
        app.launchEnvironment["baton.share.baseURL"] = "http://127.0.0.1:14792"
        // The entry is hidden by default while the feature is dormant.
        app.launchEnvironment["baton.share.privateContact"] = "1"
        app.launch()
        defer { app.terminate() }
        if app.navigationBars["What's New"].waitForExistence(timeout: 5) { app.buttons["Done"].tap() }
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 25))
        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let links = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shared Links")).firstMatch
        for _ in 0..<16 where !links.isHittable { app.swipeUp() }
        XCTAssertTrue(links.isHittable)
        links.tap()
        XCTAssertTrue(app.buttons["Private Contact"].waitForExistence(timeout: 10))
        app.buttons["Private Contact"].tap()
        XCTAssertTrue(app.navigationBars["Private Contact"].waitForExistence(timeout: 10))
        let email = app.textFields["Email address"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connect email"].isEnabled)
        email.tap()
        email.typeText("fixture@recipient.invalid")
        XCTAssertFalse(app.buttons["Connect email"].isEnabled, "address alone is not consent")
        app.switches["I agree to use this email for private notices"].switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["Connect email"].isEnabled)
        app.buttons["Connect email"].tap()
        XCTAssertTrue(app.staticTexts["Private contact is unavailable. Check the code or try again later."].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "private-contact-consent-unavailable"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Done"].tap()
        app.buttons["Private Contact"].tap()
        XCTAssertTrue(app.textFields["Email address"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Email address"].value as? String, "Email address")
        XCTAssertFalse(app.buttons["Connect email"].isEnabled)
    }
}
