import XCTest

/// What the QR pairing path actually does in a simulator — recorded rather than asserted.
///
/// The sheet swap this is meant to exercise (`MacTransferView` turning `showsScanner` off
/// and `checkSummary` on in one state change, while `PairingScannerView` also calls
/// `dismiss()`) cannot be reached without a real scan: `redeem` needs a `DevicePairing`
/// code, and `PairingClient.redeem` then fetches the payload from a live Mac. So the honest
/// thing to establish is what stops us — a camera, or a Mac — and what a person sees here.
final class ScannerReachabilityTests: XCTestCase {
    func testWhatTheScannerShowsWithoutACamera() {
        let app = XCUIApplication()
        // TBX-5336: launchEnvironment, not launchArguments — see CLAUDE.md's UI-test section.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))

        app.tabBars.buttons["Home"].tap()
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 20))
        gear.tap()
        XCTAssertTrue(app.staticTexts["Server"].waitForExistence(timeout: 20))

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Set up from a Mac"))
            .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        XCTAssertNotNil(row)
        row?.tap()

        let scan = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Scan a code'")).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 15), "the transfer screen must offer the scanner")
        scan.tap()

        // The first sheet on its own: does it present at all, and what is in it?
        let presented = app.staticTexts["Scan to Set Up"].waitForExistence(timeout: 20)
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 4)
        let cameraDenied = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Camera access is off'")).firstMatch.exists
        let scanningHint = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'On your Mac'")).firstMatch.exists
        capture(app, "40-scanner-presented-\(presented)-denied-\(cameraDenied)-hint-\(scanningHint)")

        // Grant the permission and see what the scanner does with no capture device at all.
        // A real phone never hits this, but it is the one branch a simulator can exercise,
        // and "granted, but there is no camera" is a state the view has no case for.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 10) { allow.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 6)
        let stillRunning = app.state == .runningForeground
        let deniedAfterAllow = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Camera access is off'")).firstMatch.exists
        capture(app, "40b-after-allowing-alive-\(stillRunning)-showsDenied-\(deniedAfterAllow)")
        XCTAssertTrue(stillRunning, "the scanner must not take the app down when there is no camera")

        // And that the sheet's own way out works, which is the half of the swap that does
        // not need a scan: Cancel calls the same `dismiss()` the success path calls.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 3)
        capture(app, "41-after-cancelling-scanner-backOnTransferScreen-\(scan.exists)")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }
}
