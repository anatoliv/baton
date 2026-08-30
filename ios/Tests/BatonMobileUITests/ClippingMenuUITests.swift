import XCTest

/// The player's long-press menu must offer to delete a **clipping**.
///
/// This test exists because its absence cost two releases. `SongMenuDownloadUITests` asserts what
/// the menu does *not* offer on a local file, and an assertion of absence passes just as happily
/// when the feature is broken as when it is right: "Delete Clipping…" shipped twice as an item
/// nobody could see, and nothing went red either time. The lookup behind it compared a file URL
/// to a clipping id — both `String`, so it compiled and answered "not a clipping" forever.
///
/// So the app is launched with a real clipping seeded in the store (`-baton.seedClipping`, DEBUG
/// only) and the assertion is positive: the item is there, and pressing it asks the two-way
/// question rather than deleting anything on the spot.
final class ClippingMenuUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession", "-baton.demoMode", "YES",
            "-uitestBypassBiometrics",
            "-baton.seedClipping",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testAClippingOffersToBeDeletedAndAsksWhereFirst() throws {
        app.launch()

        // Clippings is a row inside Library, not a tab of its own — see `LibrarySection`.
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20), "no Library tab")
        library.tap()

        let entry = app.cells.containing(.staticText, identifier: "Clippings").firstMatch
        let fallback = app.buttons["Clippings"].firstMatch
        if entry.waitForExistence(timeout: 10) {
            entry.tap()
        } else {
            XCTAssertTrue(fallback.waitForExistence(timeout: 10), "no route to Clippings")
            fallback.tap()
        }

        let row = app.cells.containing(.staticText, identifier: "Deploy products").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the seeded clipping is not listed — the seed did not run")

        // Play it and open the full player: the menu under test hangs off the player's title
        // (`NowPlayingViews`), which is the surface this was reported from. The Clippings list
        // row deliberately has no context menu — it deletes by swipe.
        row.tap()
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "nothing started playing")
        bar.tap()
        // `descendants(matching: .any)`, as the other player tests do: the identifier is on a
        // SwiftUI container that does not reliably surface as `otherElements`.
        let player = app.descendants(matching: .any)
            .matching(identifier: "FullPlayerContent").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10), "the full player did not open")

        // Long-press the queue row rather than the player's title. Same modifier
        // (`songContextMenu`) on both, but a row is a cell, and pressing a cell is the
        // interaction the other UI tests here already do reliably; pressing the player's
        // title opened no menu at all under XCUITest.
        app.buttons["Up Next"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "QueueSheet").firstMatch.waitForExistence(timeout: 10),
                      "the queue sheet did not open")

        let queueRow = app.cells.containing(.staticText, identifier: "Deploy products").firstMatch
        XCTAssertTrue(queueRow.waitForExistence(timeout: 10), "the clipping is not in the queue")
        queueRow.press(forDuration: 1.2)

        // The item this test exists for. Present on a clipping, and absent on a demo track,
        // which `SongMenuDownloadUITests` asserts from the other side.
        // Assert the menu opened before asserting what is in it, or a long-press that did
        // nothing is indistinguishable from a missing item.
        XCTAssertTrue(app.buttons["Play Next"].waitForExistence(timeout: 5),
                      "the long-press opened no menu at all")

        let delete = app.buttons["Delete Clipping…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5),
                      "a clipping must offer to be deleted from the menu you are already in")
        XCTAssertFalse(app.buttons["Download"].exists, "a clipping has nothing to download")

        delete.tap()

        // Deleting asks where, because one of these destroys the only copy. A bare confirmation,
        // or none, would be the bug this wording exists to prevent.
        XCTAssertTrue(app.buttons["Remove from this iPhone"].waitForExistence(timeout: 5),
                      "the two-way question is the safeguard; it must be asked")
        XCTAssertTrue(app.buttons["Delete Everywhere"].exists)

        // Best-effort dismissal. This test proves the question is *asked*, not that the delete
        // works, and deleting here would leave the store empty for whatever runs next. The tap
        // is not asserted: the dialog's cancel is presented by the system and does not always
        // surface as a queryable button, and failing the test on its teardown would report a
        // working feature as broken.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
    }
}
