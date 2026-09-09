import XCTest

/// An empty-state placeholder must cover the screen it is placed over, not share it.
///
/// Ten of them were bare `.overlay { ContentUnavailableView(...) }` with no ground under
/// them and no frame, while the shared `contentState(...)` modifier had carried both all
/// along. At the default text size the difference is invisible, which is how nine screens
/// bypassed the helper without anyone noticing. At the largest accessibility size the
/// Downloads screen was illegible: "Nothing downloaded" and its description drew straight
/// over the "Offline mode" toggle, its footer and the "0 downloads" header, all at once.
///
/// The assertion is that the placeholder and a known piece of content are never both
/// hittable. Two things can only both take a tap if they are not on top of each other, so
/// this is the collision stated in the one term the accessibility layer can answer. The
/// screenshots are attached because layout at these sizes is a thing to look at.
final class DynamicTypeEmptyStateUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // The bundled demo library, not demo.navidrome.org. Layout at a text size has
        // nothing to do with the network, so it should not depend on one — the same
        // reasoning DynamicTypePlayerUITests already records.
        app.launchArguments += [
            "-baton.resetSession", "-baton.demoMode", "YES",
            "-uitestBypassBiometrics",
            // AX5, the size the finding was photographed at.
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scroll a row into view. The tab's own list is long at AX5, where every row is
    /// roughly three times its usual height.
    private func reveal(_ element: XCUIElement, swipes: Int = 8) -> Bool {
        for _ in 0 ..< swipes {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    func testDownloadsPlaceholderCoversTheScreenAtAccessibilityTextSize() {
        app.launch()

        XCTAssertTrue(app.buttons["Library"].firstMatch.waitForExistence(timeout: 30),
                      "the app never reached the tab bar")
        app.buttons["Library"].firstMatch.tap()

        let row = app.buttons["Downloads"]
        XCTAssertTrue(reveal(row) || row.waitForExistence(timeout: 15), "no Downloads row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 15),
                      "Downloads never opened")

        let placeholder = app.staticTexts["Nothing downloaded"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 15),
                      "the demo library has downloads, so this screen is not empty and the test proves nothing")

        // "Offline mode" is the first row on the screen the placeholder sits over. On the
        // old code it stayed hittable through a transparent overlay, at the same moment
        // the placeholder was drawn across it.
        let content = app.switches["Offline mode"]

        // Evidence before the verdict, per this repo's habit: what is where, and a picture.
        var report = "placeholder hittable=\(placeholder.isHittable) frame=\(placeholder.frame)"
        report += "\ncontent exists=\(content.exists) hittable=\(content.exists ? "\(content.isHittable)" : "n/a")"
        if content.exists { report += " frame=\(content.frame)" }
        let diag = XCTAttachment(string: report)
        diag.name = "downloads-empty-overlap"
        diag.lifetime = .keepAlways
        add(diag)
        capture("20-dynamictype-ax5-downloads")

        XCTAssertFalse(
            placeholder.isHittable && content.exists && content.isHittable,
            "the empty-state placeholder and the Offline mode toggle are both hittable, "
                + "so the placeholder is drawing over live content instead of covering it"
        )
    }

    /// Home is the other screen the finding photographed: shelf titles clipped to "Varia…"
    /// because the card width ignored the text size. There is nothing hittable to assert
    /// about a truncated label, so this is a screenshot plus the weaker check that the
    /// shelves are still reachable at all.
    func testHomeShelvesSurviveAccessibilityTextSize() {
        app.launch()

        XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 30),
                      "the app never reached the tab bar")
        app.buttons["Home"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Your Mixes"].waitForExistence(timeout: 20),
                      "no shelf on Home")
        capture("21-dynamictype-ax5-home")
    }

    /// The A-Z rail used to be withheld entirely at accessibility sizes, so the one screen
    /// with hundreds of rows lost its only jump-to-letter affordance at exactly the setting
    /// that makes scrolling through them slowest. It scales now, capped, and stays.
    ///
    /// Against the demo *server*, not the bundled demo library, which holds one artist and
    /// so can never draw a rail at any threshold. `AlphabetIndex.minimumItems` carries the
    /// `-baton.railMinimum` override for exactly this: demo.navidrome.org reports 26
    /// artists against a gate of 30, and three rail defects shipped behind that gap.
    /// Skips when the server is not answering, per the rule the conversation eval set: an
    /// unreachable provider is not measurable rather than broken.
    func testAlphabetRailStaysAtAccessibilityTextSize() throws {
        let live = XCUIApplication()
        live.launchArguments += [
            "-baton.resetSession",
            "-uitestServer", "https://demo.navidrome.org",
            "-uitestUser", "demo", "-uitestSecret", "demo",
            "-uitestBypassBiometrics",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            "-baton.railMinimum", "1",
        ]
        try Self.skipUnlessDemoServerIsUp()
        app = live
        app.launch()

        XCTAssertTrue(app.buttons["Library"].firstMatch.waitForExistence(timeout: 40),
                      "the app never reached the tab bar")
        app.buttons["Library"].firstMatch.tap()

        let row = app.buttons["Artists"]
        XCTAssertTrue(reveal(row) || row.waitForExistence(timeout: 20), "no Artists row")
        row.tap()

        let rail = app.descendants(matching: .any)
            .matching(identifier: "AlphabetIndexRail").firstMatch
        let found = rail.waitForExistence(timeout: 30)
        capture("22-dynamictype-ax5-rail")
        XCTAssertTrue(found,
                      "the A-Z rail is absent at accessibility text size, which is the defect")
    }

    /// The offline half of the rail test above. `testAlphabetRailStaysAtAccessibilityTextSize`
    /// proves the rail scales against a real server and skips when one is not reachable, which is the
    /// right call for that test — but it left the rail with no coverage at all on a machine with no
    /// network, or in `ui-tests.sh`'s release set if `demo.navidrome.org` happens to be down that day.
    ///
    /// The bundled demo library holds one artist by design (Goldberg Variations is the curated story
    /// App Review and everyday users see), and one artist can never clear a positive rail threshold no
    /// matter how low `-baton.railMinimum` goes. `-baton.demoRailFixture` adds a dozen artist-only rows
    /// spanning distinct letters (`DemoLibrary.railFixtureArtists`) only when this test asks for them.
    func testAlphabetRailStaysAtAccessibilityTextSizeOffline() {
        let offline = XCUIApplication()
        offline.launchArguments += [
            "-baton.resetSession", "-baton.demoMode", "YES", "-baton.demoRailFixture",
            "-uitestBypassBiometrics",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            "-baton.railMinimum", "1",
        ]
        app = offline
        app.launch()

        XCTAssertTrue(app.buttons["Library"].firstMatch.waitForExistence(timeout: 30),
                      "the app never reached the tab bar")
        app.buttons["Library"].firstMatch.tap()

        let row = app.buttons["Artists"]
        XCTAssertTrue(reveal(row) || row.waitForExistence(timeout: 20), "no Artists row")
        row.tap()

        let rail = app.descendants(matching: .any)
            .matching(identifier: "AlphabetIndexRail").firstMatch
        let found = rail.waitForExistence(timeout: 30)
        capture("23-dynamictype-ax5-rail-offline")
        XCTAssertTrue(found,
                      "the A-Z rail is absent against the bundled demo library plus its rail fixture, "
                          + "with no network involved")
    }

    /// Later's overflow menu (`Menu { Button("Clear All", ...) } label: { Image(systemName:
    /// "ellipsis.circle") }` in `LaterView.swift`) was one of the 55 icon-only controls with
    /// no VoiceOver label outside the  lint's old nine-file scope. A
    /// screenshot cannot show a missing accessibility label, but a runtime walk that reaches
    /// the screen at AX5 is still worth more than reading the diff — this repo's own habit
    /// (`CLAUDE.md`, "verify against the running app, not the code").
    func testLaterScreenRendersAtAccessibilityTextSize() {
        app.launch()

        XCTAssertTrue(app.buttons["Library"].firstMatch.waitForExistence(timeout: 30),
                      "the app never reached the tab bar")
        app.buttons["Library"].firstMatch.tap()

        let row = app.buttons["Later"]
        XCTAssertTrue(reveal(row) || row.waitForExistence(timeout: 20), "no Later row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Later"].waitForExistence(timeout: 15), "Later never opened")
        capture("24-dynamictype-ax5-later")
    }

    private nonisolated static func skipUnlessDemoServerIsUp() throws {
        var request = URLRequest(url: URL(string: "https://demo.navidrome.org/ping")!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = response != nil; done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        try XCTSkipIf(!reachable, "demo.navidrome.org isn't answering")
    }
}
