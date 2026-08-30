import XCTest

/// The long-press menu must not offer a download it cannot perform.
///
/// The menu offered a bare "Download" on every song, having asked nothing about the song.
/// On a clipping — a reading kept as audio, already a file on the phone with no server copy
/// anywhere — that is an action that cannot happen, and tapping it does nothing at all. It
/// was reported from the player: Play Next, Add to Queue, Download, on a clipping.
///
/// The Mac had already decided this and the phone had not, which is the recurring shape here
/// rather than a one-off. `MusicDownloadStore.offlineAction(for:)` is now the single rule and
/// `DownloadsTests` covers its three answers. This test exists because that unit test cannot
/// see a menu: the rule can be right while the menu still renders the old branch, and a menu
/// item that quietly does nothing looks exactly like a menu item that works.
///
/// The bundled demo library stands in for a clipping. Both are `isLocalOnly` — a `file://`
/// id, already on the device, no server behind it — so they take the same branch, and demo
/// content needs no network, which is why every layout test here uses it.
final class SongMenuDownloadUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession", "-baton.demoMode", "YES",
            "-uitestBypassBiometrics",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testTheMenuOffersNoDownloadForAFileAlreadyOnThisDevice() throws {
        app.launch()

        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch
            : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText(DemoFixtures.searchTerm + "\n")

        let cells = app.cells
        XCTAssertTrue(cells.element(boundBy: 0).waitForExistence(timeout: 20),
                      "the bundled demo library returned nothing")

        // A search result can be an album or an artist, so the first cell is not reliably a
        // song. Press each in turn until one opens a menu with the song actions in it — the
        // same tolerance the other tests here need for the same reason.
        var opened = false
        for index in 0 ..< min(cells.count, 6) where !opened {
            let cell = cells.element(boundBy: index)
            guard cell.exists, cell.isHittable else { continue }
            cell.press(forDuration: 1.2)
            if app.buttons["Play Next"].waitForExistence(timeout: 5) { opened = true }
        }
        XCTAssertTrue(opened, "no long-press menu with song actions appeared")

        // The assertion. "Add to Queue" is checked alongside it so a menu that failed to
        // render at all cannot pass this by having no Download in it either.
        XCTAssertTrue(app.buttons["Add to Queue"].exists,
                      "precondition: this is the song menu")
        XCTAssertFalse(app.buttons["Download"].exists,
                       "a file already on this device has nothing to download")
        XCTAssertFalse(app.buttons["Remove Download"].exists,
                       "and nothing to remove either — it is not a download, it is the only copy")
    }
}
