import BatonSubsonicKit
import XCTest

@MainActor
final class CrashReportingAcceptanceTests: XCTestCase {
    private func launch(_ mode: String) throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRASH_REPORTING_ACCEPTANCE_TESTS"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.defaultsSuite"] = ThrowawayDefaults.name("8557")
        app.launchEnvironment["BATON_CRASH_REPORTING_ACCEPTANCE"] = mode
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launch()
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 20), app.debugDescription)
        gear.tap()
        let toggle = app.switches["crash-reporting-toggle"]
        for _ in 0 ..< 15 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testUnconfiguredBuildCannotEnableReporting() throws {
        let app = try launch("unconfigured")
        XCTAssertFalse(app.switches["crash-reporting-toggle"].isEnabled)
        XCTAssertFalse(app.staticTexts["crash-reporting-unavailable"].exists)
        capture(app, "TBX-8557-ios-unconfigured")
    }

    func testRealSDKParserRejectionShowsUnavailableInSettings() throws {
        let app = try launch("rejected")
        XCTAssertTrue(app.staticTexts["crash-reporting-unavailable"].waitForExistence(timeout: 15))
        capture(app, "TBX-8557-ios-sdk-rejected")
    }

    func testRealSDKStartupFailureShowsUnavailableAndExplicitRetryRecovers() throws {
        let app = try launch("recovery")
        let unavailable = app.staticTexts["crash-reporting-unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15))
        capture(app, "TBX-8557-ios-sdk-cache-failure")
        let toggle = app.switches["crash-reporting-toggle"]
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(unavailable.waitForNonExistence(timeout: 15))
        capture(app, "TBX-8557-ios-explicit-retry")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }
}
