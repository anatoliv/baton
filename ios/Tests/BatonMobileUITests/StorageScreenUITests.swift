import XCTest

/// The phone's book storage (TBX-10850, M6.3 and M6.4) walked on screen: a book made on a home
/// server comes down into Books, Settings > Storage shows it with its size beside the home
/// server's own listing and the cleanup rules, and Remove Download moves it to Recently removed
/// while the book keeps its row.
///
/// Opt-in, like `DocumentImportLiveWalkUITests`, whose launch it shares: it skips unless the
/// runner has `BATON_STORAGE_GATEWAY_URL`, `BATON_STORAGE_GATEWAY_TOKEN` and
/// `BATON_STORAGE_IMPORT_FILE` (passed as `TEST_RUNNER_…`). The gateway may be a stand-in on
/// 127.0.0.1 answering the book routes with synthetic chapters; nothing here needs the real one.
final class StorageScreenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["BATON_STORAGE_GATEWAY_URL"], !url.isEmpty,
              let token = env["BATON_STORAGE_GATEWAY_TOKEN"], !token.isEmpty,
              let file = env["BATON_STORAGE_IMPORT_FILE"], !file.isEmpty else {
            throw XCTSkip("set BATON_STORAGE_GATEWAY_URL, BATON_STORAGE_GATEWAY_TOKEN and BATON_STORAGE_IMPORT_FILE to walk the Storage screen")
        }
        app = XCUIApplication()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = url
        app.launchEnvironment["uitestGatewayToken"] = token
        app.launchEnvironment["uitestImportFile"] = file
    }

    func testTheStorageScreenShowsTheBookAndRemoveDownloadMovesItToRecentlyRemoved() throws {
        app.launch()

        // Make the book on the home server from the import screen.
        let make = app.buttons["make-audiobook"].firstMatch
        var tries = 0
        while !make.waitForExistence(timeout: 5) && tries < 8 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(make.exists, "Make Audiobook was not offered: the home server did not answer")
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Allow", "Don’t Allow", "Don't Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        make.tap()
        app.tap()

        // Books collects every chapter (TBX-11018: books have their own section).
        BooksScreen.open(app)
        let complete = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '3 chapters'")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 60), "the book's chapters did not all come down")
        XCTAssertTrue(app.staticTexts["On this phone"].firstMatch.exists)
        attach("phone-books-book")

        // Settings > Storage.
        app.buttons["Home"].firstMatch.tap()
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "no Settings button on Home")
        gear.tap()
        let storage = app.buttons["settings-storage"].firstMatch
        tries = 0
        while !storage.exists && tries < 10 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(storage.waitForExistence(timeout: 5), "no Storage link in Settings")
        storage.tap()
        XCTAssertTrue(app.staticTexts["The Machine Stops"].firstMatch.waitForExistence(timeout: 10), "the book is not listed")
        let server = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Using '")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 15), "the home server's listing did not arrive")
        attach("phone-storage")

        let remove = app.buttons["Remove Download"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(app.buttons["Download Again"].firstMatch.waitForExistence(timeout: 10),
                      "the book keeps its row, now offering Download Again")
        app.swipeUp()
        let removed = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Download removed today'")).firstMatch
        XCTAssertTrue(removed.waitForExistence(timeout: 10), "Recently removed does not list it")
        attach("phone-storage-removed")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
