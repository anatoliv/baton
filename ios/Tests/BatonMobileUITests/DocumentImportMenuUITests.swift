import XCTest

/// Books' + menu (M5.2; on Clippings until an internal task): "Import a File…" and "Import a Link…" each reach the import screen.
/// `DocumentImportUITests` hands its document in at launch; these press the menu a person
/// presses.
///
/// The system file picker runs out of process and its Files locations cannot be seeded from a
/// test, so the file's words go in `uitestPickedFileText` (DEBUG only) and the menu item takes
/// that file in place of the picker. The staging and the import screen after it are the real
/// path. A link is typed into the real alert; offline, in demo mode, the page cannot be fetched,
/// and the screen says so. Environment, never launch arguments.
final class DocumentImportMenuUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
    }

    override func tearDown() { app = nil; super.tearDown() }

    private func openBooksMenu() {
        // Books is a row inside Library, not a tab of its own (`LibrarySection`); its + menu
        // imports, and the book lands there.
        BooksScreen.open(app)
        let plus = app.buttons["import-document"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "Books has no + menu (Documents is on by default)")
        plus.tap()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testImportAFileReachesTheImportScreen() throws {
        app.launchEnvironment["uitestPickedFileText"] = """
        # Picked Notes

        ## The Cell

        A small room, like the cell of a bee. The air was fresh, though there was no window.

        ## The Surface

        The light at the top was grey, and the hills were bare.
        """
        app.launch()
        openBooksMenu()

        let item = app.buttons["Import a File…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the + menu has no Import a File…")
        item.tap()

        let title = app.staticTexts["Picked Notes"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the import screen did not open on the picked file")
        XCTAssertTrue(app.staticTexts["The Cell"].firstMatch.waitForExistence(timeout: 5), "chapter 1 is not listed")
        XCTAssertTrue(app.staticTexts["The Surface"].firstMatch.exists, "chapter 2 is not listed")
        XCTAssertTrue(app.navigationBars["Import"].firstMatch.exists)
        attach("import-a-file")

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(title.waitForExistence(timeout: 3), "Cancel should close the import screen")
        XCTAssertTrue(app.buttons["import-document"].firstMatch.waitForExistence(timeout: 5), "back on Books")
    }

    func testImportALinkReachesTheImportScreen() throws {
        app.launch()
        openBooksMenu()

        let item = app.buttons["Import a Link…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the + menu has no Import a Link…")
        item.tap()

        let alert = app.alerts["Import a Link"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the link alert did not open")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // No scheme typed: the alert adds https:// itself. The .invalid name never resolves, so
        // the screen's answer is the same on any network.
        field.typeText("baton-uitest.invalid/article")
        alert.buttons["Import"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Import"].firstMatch.waitForExistence(timeout: 15),
                      "the import screen did not open on the link")
        let reading = app.staticTexts["Reading baton-uitest.invalid…"].firstMatch
        let failed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "could not be fetched")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 30) || reading.exists,
                      "the screen neither read the link nor said why it could not")
        attach("import-a-link")

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["import-document"].firstMatch.waitForExistence(timeout: 5), "back on Books")
    }
}
