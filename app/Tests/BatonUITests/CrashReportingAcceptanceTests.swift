import BatonSubsonicKit
import XCTest

@MainActor
final class CrashReportingAcceptanceTests: XCTestCase {
    private func launch(_ mode: String) throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRASH_REPORTING_ACCEPTANCE_TESTS"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        let suite = ThrowawayDefaults.name("8557")
        app.launchEnvironment["baton.defaultsSuite"] = suite
        app.launchEnvironment["baton.supportDirectory"] = "/private/tmp/\(suite)"
        app.launchEnvironment["BATON_CRASH_REPORTING_ACCEPTANCE"] = mode
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 15), app.debugDescription)
        let toggle = app.switches["crash-reporting-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), app.debugDescription)
        let pane = app.windows["Settings"].scrollViews.element(boundBy: 1)
        for _ in 0 ..< 8 where toggle.frame.maxY > pane.frame.maxY {
            pane.scroll(byDeltaX: 0, deltaY: -250)
        }
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let pane = app.windows["Settings"].scrollViews.element(boundBy: 1)
        let unavailable = app.staticTexts["crash-reporting-unavailable"]
        for _ in 0 ..< 4 where unavailable.exists && unavailable.frame.maxY > pane.frame.maxY {
            pane.scroll(byDeltaX: 0, deltaY: -200)
        }
        let attachment = XCTAttachment(screenshot: app.windows["Settings"].screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testUnconfiguredBuildCannotEnableReporting() throws {
        let app = try launch("unconfigured")
        XCTAssertFalse(app.switches["crash-reporting-toggle"].isEnabled)
        XCTAssertFalse(app.staticTexts["crash-reporting-unavailable"].exists)
        capture(app, "TBX-8557-mac-unconfigured")
    }

    func testRealSDKParserRejectionShowsUnavailableInSettings() throws {
        let app = try launch("rejected")
        XCTAssertTrue(app.staticTexts["crash-reporting-unavailable"].waitForExistence(timeout: 15))
        capture(app, "TBX-8557-mac-sdk-rejected")
    }

    func testRealSDKStartupFailureShowsUnavailableAndExplicitRetryRecovers() throws {
        let app = try launch("recovery")
        let unavailable = app.staticTexts["crash-reporting-unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15))
        capture(app, "TBX-8557-mac-sdk-cache-failure")
        let toggle = app.switches["crash-reporting-toggle"]
        print(toggle.debugDescription)
        if toggle.switches.firstMatch.exists {
            toggle.switches.firstMatch.click()
        } else {
            toggle.click()
        }
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
        print(toggle.debugDescription)
        if toggle.switches.firstMatch.exists {
            toggle.switches.firstMatch.click()
        } else {
            toggle.click()
        }
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true)
        XCTAssertTrue(unavailable.waitForNonExistence(timeout: 15))
        capture(app, "TBX-8557-mac-explicit-retry")
        print(toggle.debugDescription)
        if toggle.switches.firstMatch.exists {
            toggle.switches.firstMatch.click()
        } else {
            toggle.click()
        }
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
    }
}
