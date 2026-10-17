import XCTest

/// A document handed to Baton while something else is on screen still opens the import screen
///.
///
/// The import screen is a sheet at the root, and UIKit will not present a sheet from a view
/// controller that is already presenting one. With the full player or Settings up, the request
/// was dropped without a word and the document looked lost. The case that hits people: the
/// player is open, they go to another app, share a document to Baton and come back.
///
/// That is what these walk, offline on the bundled demo library. The share is written into the
/// real App Group inbox by the extension's own writer when the app goes to the background
/// (`uitestSharedTextWhenAway`, DEBUG only), and everything after that is the real path: the
/// activation pickup, the screen in the way closing, the import screen opening. Environment,
/// never launch arguments.
final class ImportOverSheetUITests: XCTestCase {
    private var app: XCUIApplication!
    private let title = "Pages From Elsewhere"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestSharedTextWhenAway"] = """
        \(title)
        by Nobody in Particular

        Chapter 1 The Window

        Shared from another app while the player was open in Baton.

        Chapter 2 The Door

        The second chapter is here so the import has more than one.
        """
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testADocumentSharedWhileThePlayerIsOpenStillOpensTheImportScreen() throws {
        app.launch()
        startPlaying()
        XCTAssertTrue(openFullPlayer(in: app, timeout: 15))
        XCTAssertFalse(app.staticTexts[title].firstMatch.exists, "nothing was shared yet")

        awayAndBack()

        let heading = app.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "the shared document did not open the import screen over the player")
        XCTAssertTrue(app.staticTexts["The Window"].firstMatch.waitForExistence(timeout: 5), "chapter 1 is not listed")
        attach("import-over-full-player")
        XCTAssertFalse(app.buttons[PlayerControls.dismissFullPlayer].exists, "the player made way for the import")

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(heading.waitForExistence(timeout: 3), "Cancel should close the import screen")
        // The player closed for the import, and opens again with a tap: nothing was left
        // thinking it was still on screen.
        XCTAssertTrue(openFullPlayer(in: app, timeout: 10), "the full player should open again after the import")
    }

    func testADocumentSharedWhileSettingsIsOpenStillOpensTheImportScreen() throws {
        app.launch()
        // Home first: a verified agent left by an earlier test (FriendMemoryUITests) survives
        // `baton.resetSession`, and then the Friend tab comes first and is selected.
        selectReleaseTab("Home", in: app, screenTitle: "Home")
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Home's Settings button")
        gear.tap()
        // "Music server", not "Settings": the gear's own label is "Settings" (see FullWalkUITests).
        let settings = app.staticTexts["Music server"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings did not open")

        awayAndBack()

        let heading = app.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "the shared document did not open the import screen over Settings")
        attach("import-over-settings")

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(heading.waitForExistence(timeout: 3), "Cancel should close the import screen")
        XCTAssertFalse(settings.exists, "Settings made way for the import")
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "back on Home")
        gear.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings should open again after the import")
    }

    /// Files "Open in Baton" while Settings is up: the document comes through
    /// `onOpenURL` as a file URL rather than through the share inbox, and lands in the same
    /// pending import, so Settings has to make way for it the same way.
    func testADocumentOpenedFromFilesWhileSettingsIsOpenStillOpensTheImportScreen() throws {
        app.launchEnvironment.removeValue(forKey: "uitestSharedTextWhenAway")
        app.launch()
        selectReleaseTab("Home", in: app, screenTitle: "Home")
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Home's Settings button")
        gear.tap()
        let settings = app.staticTexts["Music server"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings did not open")

        let heading = try openFromFiles()
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "the opened document did not open the import screen over Settings")
        XCTAssertTrue(app.staticTexts["The Shelf"].firstMatch.waitForExistence(timeout: 5), "chapter 1 is not listed")
        attach("open-in-over-settings")
        XCTAssertFalse(settings.exists, "Settings made way for the import")

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(heading.waitForExistence(timeout: 3), "Cancel should close the import screen")
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "back on Home")
    }

    // MARK: - Steps

    /// Home and back: the share arrives while Baton is away, and the activation picks it up.
    private func awayAndBack() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.springboard").wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    /// A bundled track playing, by the route `DynamicTypePlayerUITests` uses: search, then tap
    /// results until one plays (a result can be an album or an artist).
    private func startPlaying() {
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText(DemoFixtures.searchTerm + "\n")
        let cells = app.cells
        XCTAssertTrue(cells.element(boundBy: 0).waitForExistence(timeout: 20), "the bundled demo library returned nothing")
        let bar = app.descendants(matching: .any).matching(identifier: PlayerControls.miniBar).firstMatch
        var playing = false
        for index in 0 ..< min(cells.count, 6) where !playing {
            let cell = cells.element(boundBy: index)
            guard cell.exists, cell.isHittable else { continue }
            cell.tap()
            playing = bar.waitForExistence(timeout: 12)
            if !playing, app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(playing, "nothing in the bundled demo library started playing")
    }

    /// What Files does for "Open in Baton": the system hands the app a file URL, which arrives
    /// through `onOpenURL`. Returns the import screen's heading for this document.
    private func openFromFiles() throws -> XCUIElement {
        let fileTitle = "Pages From Files"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Opened From Files.txt")
        try """
        \(fileTitle)
        by Nobody in Particular

        Chapter 1 The Shelf

        Opened in Baton from Files while another screen was up.

        Chapter 2 The Drawer

        The second chapter is here so the import has more than one.
        """.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let heading = app.staticTexts[fileTitle].firstMatch
        XCTAssertFalse(heading.exists, "nothing was opened yet")
        app.open(file)
        return heading
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
