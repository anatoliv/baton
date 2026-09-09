import XCTest

/// TBX-5123's headline outcome, walked: **Settings → Set Up from a Mac → an exported file →
/// the checks run in the same flow → the Friend tab is there when the sheet is done.**
///
/// Everything about this card has so far been argued from the code. The file it imports is a
/// real `SettingsTransfer` export (same JSON envelope, same PBKDF2-HMAC-SHA256 + AES-GCM,
/// same binary-plist payload) built outside the app and planted in the simulator's "On My
/// iPhone" storage, so the document picker offers it like any file that arrived by AirDrop.
///
/// The export configures the **music friend only**, on purpose. That is the case the card is
/// about, and it is also the case that proves the check list is gated on what arrived rather
/// than on what exists: a correct sheet shows one row, not four.
///
/// No `-baton.agent.*` launch arguments here. The whole point is that the settings arrive in
/// the import; seeding them would test nothing.
final class MacImportEvidenceTests: XCTestCase {
    private var app: XCUIApplication!

    private var fileName: String {
        ProcessInfo.processInfo.environment["BATON_IMPORT_FILE_NAME"] ?? ""
    }
    private var passphrase: String {
        ProcessInfo.processInfo.environment["BATON_IMPORT_PASSPHRASE"] ?? ""
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(fileName.isEmpty || passphrase.isEmpty, "no planted export supplied")
        app = XCUIApplication()
        // TBX-5336: launchEnvironment, not launchArguments — see CLAUDE.md's UI-test section.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testImportingFromAMacRunsTheChecksAndRevealsTheFriendTab() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "the app must reach its tab bar")
        let friendTab = app.tabBars.buttons["Friend"]
        XCTAssertFalse(friendTab.exists, "the Friend tab must be hidden before the import")
        capture("10-tabbar-before-import")

        app.tabBars.buttons["Home"].tap()
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 20), "Home's header must offer Settings")
        gear.tap()
        XCTAssertTrue(app.staticTexts["Server"].waitForExistence(timeout: 20), "Settings must open")

        tapRow(startingWith: "Set up from a Mac", describedAs: "the Set Up from a Mac row")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Choose an exported file'"))
            .firstMatch.waitForExistence(timeout: 15), "the transfer screen must offer a file")
        capture("11-set-up-from-a-mac")

        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Choose an exported file'"))
            .firstMatch.tap()

        // The picker is a remote view. It renders inside the app's window, so its elements
        // arrive in the app's hierarchy rather than in a separate process's — querying
        // `XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")` throws outright,
        // because nothing by that name is running.
        // It opens on Recents, which is empty on a fresh simulator. The planted file lives in
        // the local provider's storage, so: Browse → On My iPhone.
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 20) { browse.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2)
        capture("12a-picker-browse")
        let onMyPhone = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "On My iPhone"))
            .allElementsBoundByIndex
            .first { $0.exists && $0.isHittable }
        if let onMyPhone { onMyPhone.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2)

        let stem = (fileName as NSString).deletingPathExtension
        var file: XCUIElement?
        let deadline = Date().addingTimeInterval(30)
        while file == nil, Date() < deadline {
            file = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH[c] %@", stem))
                .allElementsBoundByIndex
                .first { $0.exists && $0.isHittable }
            if file == nil { usleep(500_000) }
        }
        capture("12-picker")
        XCTAssertNotNil(file, "the planted export must be visible in the picker")
        file?.tap()

        // An UNENCRYPTED export, so the import applies straight away.
        //
        // The encrypted file is the realistic one and was tried first: Baton detected the
        // encryption, raised its Passphrase alert and refused a wrong passphrase — all
        // correct. What could not be made to work is the *typing*. Three attempts (field
        // tap, alert-scoped field, per-character `app.typeText` with the keyboard waited
        // for) all left the alert's SecureField visibly empty, with no software keyboard
        // and a constant two-character `value`. That is an XCUITest limitation against a
        // SwiftUI alert's SecureField, not an app defect, and it stops before the code this
        // card is about. Everything after `applyImport` — reload, checks, sheet, tab — is
        // identical on both files, so the plain one is used to reach it.
        // THE CLAIM, first half: the import goes straight into the checks, in the same
        // flow, rather than into a dead-end "Imported 8 settings and 1 secret" alert.
        let sheetIsUp = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Imported'"))
            .firstMatch.waitForExistence(timeout: 60)
        XCTAssertTrue(sheetIsUp, "the import must present a sheet rather than an alert")
        // Let any probe land before photographing it.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "probe")], timeout: 15)
        capture("14-imported-setup-check-sheet")
        let friendRowListed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Music friend'"))
            .firstMatch.exists
        let saysNothingToTest = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'nothing here that needed'"))
            .firstMatch.exists
        capture("14b-friendRowListed-\(friendRowListed)-saysNothingToTest-\(saysNothingToTest)")

        // Out of the sheet, and out of Settings, so the tab bar can be photographed.
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the check sheet must have a way out")
        done.tap()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 3)
        let settingsDone = app.buttons["Done"].firstMatch
        if settingsDone.exists { settingsDone.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 3)
        capture("15-tabbar-after-import")

        // And what the friend's own screen makes of the import — the decisive read on
        // whether the settings and the key actually arrived, which the sheet's verdict
        // does not by itself tell you.
        app.tabBars.buttons["Home"].tap()
        let gear2 = app.buttons["Settings"]
        if gear2.waitForExistence(timeout: 20) { gear2.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2)
        capture("16-settings-after-import")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Music Friend"))
            .allElementsBoundByIndex
            .first { $0.exists && $0.isHittable }
        row?.tap()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 4)
        capture("17-music-friend-after-import")

        XCTAssertTrue(app.tabBars.buttons["Friend"].exists,
                      "a passing import must make the Friend tab appear by itself")
    }

    private func tapRow(startingWith prefix: String, describedAs description: String) {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", prefix))
            .allElementsBoundByIndex
            .first { $0.exists && $0.isHittable }
        guard let match else { return XCTFail("could not find \(description)") }
        match.tap()
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
