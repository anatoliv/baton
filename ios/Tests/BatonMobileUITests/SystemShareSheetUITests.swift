import XCTest

/// "Baton" in the real system share sheet (TBX-10846, walked for TBX-10975): a web page shared
/// from Safari and a PDF shared from the Files app each open Baton's import screen exactly once.
///
/// `ShareInboxUITests` covers the handoff from the App Group inbox onwards without the sheet. This
/// walk drives the other half too: Safari (`com.apple.mobilesafari`) and Files
/// (`com.apple.DocumentsApp`), their Share button, the Baton entry in the sheet, the extension's
/// own "Saved … for Baton" screen and its Done button, and then Baton opened again.
///
/// Opt-in, never part of the release set: it needs the network (the page is fetched by Safari and
/// again by the importer) and a PDF already in Files, which a test runner cannot put there. It
/// skips unless the runner has `BATON_SYSTEM_SHARE_WALK=1` (`TEST_RUNNER_BATON_SYSTEM_SHARE_WALK`).
/// Before the Files walk, copy a PDF named `Machine_stops.pdf` (E. M. Forster, "The Machine Stops")
/// into the simulator's On My iPhone folder: the `File Provider Storage` folder of the
/// `group.com.apple.FileProvider.LocalStorage` App Group container, created once Files has run.
/// `BATON_SHARE_PAGE_URL` overrides the page (default: The Yellow Wallpaper on Project Gutenberg).
final class SystemShareSheetUITests: XCTestCase {
    private var baton: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        guard environment["BATON_SYSTEM_SHARE_WALK"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_BATON_SYSTEM_SHARE_WALK=1 to walk the system share sheet (network and a PDF in Files needed)")
        }
        baton = XCUIApplication.batonUnderTest()
        baton.launchEnvironment["baton.resetSession"] = "1"
        baton.launchEnvironment["baton.demoMode"] = "YES"
        baton.launchEnvironment["uitestBypassBiometrics"] = "1"
        // Never let the test phone's reset state travel into the owner's shared settings.
        baton.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
    }

    func testAWebPageSharedFromSafariOpensTheImportScreenOnce() throws {
        startBatonAndLeave()
        let page = environment["BATON_SHARE_PAGE_URL"] ?? "https://www.gutenberg.org/cache/epub/1952/pg1952-images.html"
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.open(try XCTUnwrap(URL(string: page)))
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "Safari did not come to the front")
        let heading = safari.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Yellow Wallpaper'")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 60), "the page did not load in Safari")
        attach(safari, "safari-page")

        openSafariShareSheet(safari)
        attach(safari, "safari-share-sheet")
        pickBaton(in: safari)
        finishExtension(in: safari, name: "safari-extension-saved")

        assertImportScreenOpensOnce(title: "The Yellow Wallpaper", shot: "import-screen-from-safari")
    }

    func testAPDFSharedFromFilesOpensTheImportScreenOnce() throws {
        startBatonAndLeave()
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.activate()
        XCTAssertTrue(files.wait(for: .runningForeground, timeout: 20), "Files did not come to the front")
        let browse = files.buttons["Browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), "no Browse tab in Files\n\(files.debugDescription)")
        browse.tap()
        // Tapped twice when Browse is already the tab: the second tap returns to its root.
        browse.tap()
        let onMyPhone = files.staticTexts["On My iPhone"].firstMatch
        XCTAssertTrue(onMyPhone.waitForExistence(timeout: 15), "no On My iPhone location\n\(files.debugDescription)")
        onMyPhone.tap()
        let pdf = files.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Machine_stops'")).firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 20), "Machine_stops.pdf is not in On My iPhone: stage it first\n\(files.debugDescription)")
        attach(files, "files-on-my-iphone")

        pdf.press(forDuration: 1.2)
        let share = files.descendants(matching: .any).matching(NSPredicate(format: "label == 'Share' AND (elementType == %d OR elementType == %d)",
                                                                          XCUIElement.ElementType.button.rawValue,
                                                                          XCUIElement.ElementType.menuItem.rawValue)).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10), "no Share in the file's menu\n\(files.debugDescription)")
        share.tap()
        attach(files, "files-share-sheet")
        pickBaton(in: files)
        finishExtension(in: files, name: "files-extension-saved")

        assertImportScreenOpensOnce(title: "The Machine Stops", shot: "import-screen-from-files")
    }

    // MARK: - Steps

    /// Baton set up (demo library, nothing pending) and sent to the background, as a phone whose
    /// owner opened Baton earlier and then went to read something else.
    private func startBatonAndLeave() {
        baton.launch()
        XCTAssertTrue(baton.tabBars.firstMatch.waitForExistence(timeout: 30) || baton.buttons["Library"].firstMatch.waitForExistence(timeout: 5),
                      "Baton did not finish launching")
        XCUIDevice.shared.press(.home)
    }

    /// Safari's Share is in the page menu of the compact tab bar (the button left of the address),
    /// or directly in the toolbar on layouts that still show it.
    private func openSafariShareSheet(_ safari: XCUIApplication) {
        let direct = safari.buttons["ShareButton"].firstMatch
        if direct.exists && direct.isHittable {
            direct.tap()
        } else {
            let menu = firstHittable(in: safari, labels: ["Page Menu", "Page Settings", "More", "Show Page Menu"],
                                     identifiers: ["PageFormatMenuButton", "PageMenuButton", "TabBarItemPageMenuButton"])
            XCTAssertNotNil(menu, "no page menu button in Safari\n\(safari.debugDescription)")
            menu?.tap()
            let share = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Share'")).firstMatch
            XCTAssertTrue(share.waitForExistence(timeout: 10), "no Share in Safari's page menu\n\(safari.debugDescription)")
            share.tap()
        }
    }

    /// The Baton entry in the sheet's row of apps. It is a share extension, so the sheet lists it
    /// under the app's display name.
    private func pickBaton(in host: XCUIApplication) {
        let entry = host.descendants(matching: .any).matching(NSPredicate(format: "label == 'Baton'"))
        let deadline = Date(timeIntervalSinceNow: 20)
        var picked: XCUIElement?
        while picked == nil && Date() < deadline {
            picked = (0..<entry.count).map { entry.element(boundBy: $0) }.first { $0.exists && $0.isHittable }
            if picked == nil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        }
        XCTAssertNotNil(picked, "no Baton in the share sheet\n\(host.debugDescription)")
        picked?.tap()
    }

    /// The extension's own screen: "Saved … for Baton", then Done hands the sheet back.
    private func finishExtension(in host: XCUIApplication, name: String) {
        let saved = host.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Saved ' AND label ENDSWITH ' for Baton'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30), "the Baton extension did not say it saved the document\n\(host.debugDescription)")
        XCTAssertFalse(host.staticTexts["Baton could not keep this"].exists, "the extension refused the document")
        attach(host, name)
        let done = host.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "no Done on the extension's screen")
        done.tap()
        XCTAssertTrue(waitUntilGone(saved, timeout: 10), "the extension's screen did not close")
    }

    /// Baton opened again from the home screen: the import screen shows the shared document, one
    /// sheet of it; after Cancel, leaving and coming back opens nothing.
    private func assertImportScreenOpensOnce(title: String, shot: String) {
        baton.activate()
        XCTAssertTrue(baton.wait(for: .runningForeground, timeout: 15), "Baton did not come back to the front")
        let heading = baton.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 60), "the import screen did not open with \"\(title)\"\n\(baton.debugDescription)")
        XCTAssertEqual(baton.navigationBars.matching(identifier: "Import").count, 1, "the import screen should be open once, not stacked")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        XCTAssertEqual(baton.navigationBars.matching(identifier: "Import").count, 1, "a second import screen opened after the first")
        attach(baton, shot)

        let cancel = baton.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "no Cancel on the import screen")
        cancel.tap()
        XCTAssertTrue(waitUntilGone(heading, timeout: 10), "Cancel should close the import screen")

        XCUIDevice.shared.press(.home)
        baton.activate()
        XCTAssertTrue(baton.wait(for: .runningForeground, timeout: 15))
        XCTAssertFalse(heading.waitForExistence(timeout: 6), "a share must open once, not on every activation")
        attach(baton, "\(shot)-after-return")
    }

    // MARK: - Helpers

    private func firstHittable(in app: XCUIApplication, labels: [String], identifiers: [String]) -> XCUIElement? {
        for id in identifiers {
            let button = app.buttons[id].firstMatch
            if button.waitForExistence(timeout: 1), button.isHittable { return button }
        }
        for label in labels {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if button.exists, button.isHittable { return button }
        }
        return nil
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return !element.exists
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
