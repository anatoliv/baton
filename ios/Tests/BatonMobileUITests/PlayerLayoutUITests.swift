import XCTest

/// Where the player's slack goes.
///
/// The complaint this guards against is not that anything is unreachable — the accessibility
/// test next door covers that — but that the vertical space is distributed badly: a large
/// gap between the collapse chevron and the artwork, and the star rating pressed against the
/// bottom edge with the home indicator running through it.
///
/// Both are geometry, so both are measurable. The screenshot is attached because layout is a
/// thing to look at, but the assertions are on real frames: the rating's clearance from the
/// bottom of the screen, and the gap above the artwork.
final class PlayerLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Bundled demo library, not the network — the same reasoning as
        // `DynamicTypePlayerUITests`: layout has nothing to do with a server.
        app.launchArguments += [
            "-baton.resetSession", "-baton.demoMode", "YES",
            "-uitestBypassBiometrics",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testTheStackDistributesItsSlack() throws {
        app.launch()
        try openThePlayer()

        let screen = app.frame
        // Scoped to the player's own content. The mini bar and the tab bar stay in the tree
        // behind a presented sheet, so an app-wide query happily measures a 30pt cover in
        // the bar underneath and a tab button below the sheet — which is how the first run
        // of this test "measured" an artwork 537 points down the screen.
        let player = app.descendants(matching: .any)
            .matching(identifier: "FullPlayerContent").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10), "the full player never appeared")

        let artwork = largestImage(in: player)
        XCTAssertGreaterThan(artwork.height, 100, "no hero artwork in the player")

        let topShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        topShot.name = "player-top"; topShot.lifetime = .keepAlways
        add(topShot)

        // Scroll to the end before measuring the bottom. On a small phone the content
        // overflows, so the lowest *visible* control is simply whatever the fold cut it off
        // at — a number that says nothing about the padding under the last row. The
        // question is what the bottom of the content looks like, so go there.
        var previous = CGRect.zero
        for _ in 0 ..< 4 {
            let current = lowestControl(in: player)
            if current == previous { break }
            previous = current
            app.swipeUp()
        }
        let bottomMost = lowestControl(in: player)
        XCTAssertGreaterThan(bottomMost.height, 0, "no controls found in the player")

        // The empty space at each end, with the navigation bar discounted — that band is
        // chrome the chevron lives in, not slack the layout chose to leave.
        let chromeBottom = app.navigationBars.firstMatch.exists
            ? app.navigationBars.firstMatch.frame.maxY
            : 0
        let slackAbove = artwork.minY - chromeBottom
        let slackBelow = screen.maxY - bottomMost.maxY

        var report = "screen=\(screen)\nartwork=\(artwork)\nbottomMost=\(bottomMost)"
        report += "\nnavBarBottom=\(chromeBottom)"
        report += "\nslackAbove=\(slackAbove)\nslackBelow=\(slackBelow)"
        let diag = XCTAttachment(string: report)
        diag.name = "player-geometry"; diag.lifetime = .keepAlways
        add(diag)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "player-bottom"; shot.lifetime = .keepAlways
        add(shot)

        // The bottom-most control must clear the home indicator, which owns roughly the
        // last 34 points on a phone that has one. Anything less and the control is being
        // competed for by a system gesture. This was **-8** before the fix: the content
        // ended past the edge of the screen.
        XCTAssertGreaterThanOrEqual(slackBelow, 24,
                                    "the last control is flush against the bottom edge")

        // And the two ends must be comparable. This is the whole complaint stated as a
        // measurement: whatever room is going spare should be shared, not hoarded at one
        // end while the other end runs out. A little more at the top is fine — the eye
        // expects a title-ish gap under a bar — a lot more is the bug.
        XCTAssertLessThanOrEqual(slackAbove, slackBelow + 40,
                                 "the slack pooled above the artwork instead of distributing")
    }

    /// The lowest-sitting control in the player, whatever it happens to be for this session
    /// — the star rating on a real server, the icon row in demo mode where the stars are
    /// hidden. Either way it is the thing the bottom edge is crowding.
    private func lowestControl(in player: XCUIElement) -> CGRect {
        var lowest = CGRect.zero
        let buttons = player.descendants(matching: .button)
        for index in 0 ..< buttons.count {
            let element = buttons.element(boundBy: index)
            guard element.exists, element.isHittable else { continue }
            let frame = element.frame
            // Real controls only. A 13pt sliver is a scroll indicator or a chevron glyph,
            // not something a thumb is aiming at.
            guard frame.height >= 20, frame.height < 200 else { continue }
            if frame.maxY > lowest.maxY { lowest = frame }
        }
        return lowest
    }

    /// The hero cover: the biggest image inside the player.
    private func largestImage(in player: XCUIElement) -> CGRect {
        var largest = CGRect.zero
        let images = player.descendants(matching: .image)
        for index in 0 ..< images.count {
            let frame = images.element(boundBy: index).frame
            if frame.width * frame.height > largest.width * largest.height { largest = frame }
        }
        return largest
    }

    /// Play something from the bundled library and open the full player. Lifted from
    /// `DynamicTypePlayerUITests`, including the tap-until-something-plays loop: a search
    /// result can be an album or an artist, so the first cell is not reliably a song.
    private func openThePlayer() throws {
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
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
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
        bar.tap()
    }
}
