import XCTest

/// The player has to survive the largest text sizes.
///
/// `FullPlayerView` was a fixed `VStack` with a fixed 272pt cover. That fits at the default
/// text size and at nothing above it: the labels grow, the rows grow with them, and the
/// transport goes off the bottom of the screen. What is lost is the controls — the artwork
/// and the title, the parts that are merely nice to look at, are the parts that stay.
///
/// Asserting "the transport is still hittable at accessibility sizes" is the whole test.
/// The screenshot is there because layout at these sizes is a thing to look at, not a thing
/// to reason about.
final class DynamicTypePlayerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // The bundled demo library, not demo.navidrome.org. Driven against the live
        // server this test failed three times in three different places — no mini bar, no
        // album page, an unreachable control — which is a flaky test rather than three
        // bugs, and a red test that means nothing is worse than no test. Layout at a text
        // size has nothing to do with the network, so it should not depend on one.
        app.launchArguments += [
            "-baton.resetSession", "-baton.demoMode", "YES",
            "-uitestBypassBiometrics",
            // Third accessibility step — large enough to break the old layout, and a size
            // real people use rather than an extreme nobody sets.
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testTransportSurvivesAccessibilityTextSizes() throws {
        app.launch()

        // Play a bundled track. Search is the shortest deterministic route to one.
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
        // Tap successive results until something is actually playing. A search result can be
        // an album or an artist — tapping it navigates rather than plays — so the first cell
        // is not reliably a song. This is the loop `PlayerHeartVisualCheck` already uses,
        // and skipping that detail is why this test previously reported a green *skip*.
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        var playing = false
        for index in 0 ..< min(cells.count, 6) where !playing {
            let cell = cells.element(boundBy: index)
            guard cell.exists, cell.isHittable else { continue }
            cell.tap()
            playing = bar.waitForExistence(timeout: 12)
            if !playing, app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap() // came back from a detail page
            }
        }
        XCTAssertTrue(playing, "nothing in the bundled demo library started playing")

        bar.tap()

        // The controls, not the decoration. `isHittable` is the assertion that matters:
        // an element can exist while sitting off-screen, which is exactly what used to
        // happen here.
        // *Any* reachable "Next track", not `firstMatch`.
        //
        // Two elements carry that label: the player's transport and the mini bar behind the
        // presented sheet. `firstMatch` returned the mini bar — correctly not hittable,
        // because a sheet is over it — so the test reported the transport unreachable while
        // the player's own button was on screen and tappable. The question this test asks is
        // "can the user reach the transport", and that is satisfied by any of them.
        let transports = app.buttons.matching(identifier: "Next track")
        XCTAssertTrue(transports.element(boundBy: 0).waitForExistence(timeout: 20),
                      "no transport in the player")
        func anyHittable() -> Bool {
            (0 ..< transports.count).contains { transports.element(boundBy: $0).isHittable }
        }
        // Evidence before the verdict: which elements match, where they are, and what the
        // screen actually looks like. "Next track" is also the mini bar's label and the
        // bar stays in the tree behind the sheet, so a naive firstMatch can be pointing at
        // something that is off-screen for a completely different reason.
        let matches = app.buttons.matching(identifier: "Next track")
        var report = "matches=\(matches.count)"
        for index in 0 ..< matches.count {
            let element = matches.element(boundBy: index)
            report += "\n [\(index)] frame=\(element.frame) hittable=\(element.isHittable)"
        }
        let diag = XCTAttachment(string: report)
        diag.name = "next-track-matches"; diag.lifetime = .keepAlways
        add(diag)
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "player-before-assert"; before.lifetime = .keepAlways
        add(before)

        if !anyHittable() {
            // The player scrolls now, so anything below the fold is reachable — which is
            // the fix. Reaching it by scrolling is a pass; not being able to reach it at
            // all is the failure this guards.
            app.swipeUp()
        }
        XCTAssertTrue(anyHittable(), "the transport is unreachable at accessibility text size")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "player-accessibility-text"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
