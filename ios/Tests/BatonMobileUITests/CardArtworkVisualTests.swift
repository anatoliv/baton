import XCTest

/// Captures the album grid against a real library, so the card artwork can be *looked at*.
///
/// The change this covers is one no assertion can judge: covers are now drawn whole over a
/// blurred enlargement of themselves instead of being cropped to the cell. Whether that
/// reads as "beautiful" or "muddy" is a matter for eyes. What a test can do is prove the
/// grid still lays out — the previous attempt at artwork here made every cell drive its own
/// width, and the whole grid went ragged the moment it met non-square art.
final class CardArtworkVisualTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession",
            "-uitestServer", "https://demo.navidrome.org",
            "-uitestUser", "demo",
            "-uitestSecret", "demo",
            "-uitestBypassBiometrics",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    private nonisolated static func skipUnlessDemoServerIsUp() throws {
        var request = URLRequest(url: URL(string: "https://demo.navidrome.org/ping")!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = response != nil
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        try XCTSkipIf(!reachable, "demo.navidrome.org isn't answering — skipping the visual pass")
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Layout only — see the note on the capture below for why nothing here asserts that
    /// artwork actually loaded.
    func testTheAlbumGridStillLaysOutWithWholeCovers() throws {
        try Self.skipUnlessDemoServerIsUp()
        app.launch()

        app.buttons["Albums"].firstMatch.tap()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 30),
                      "the Albums grid must appear")

        // Give artwork a chance to arrive before capturing. Deliberately *not* asserted
        // on: `app.images` counts chrome as well as covers, so any threshold here passes
        // whether or not a single cover loaded — which is worse than no assertion, because
        // it reads like proof. Judging the artwork is the screenshot's job and a human's.
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, app.images.count < 3 { usleep(400_000) }
        capture("album-grid-whole-covers")

        // The failure this guards: artwork driving cell width. Every cell in a row must
        // share a width, and cells must not exceed the screen.
        let cells = app.scrollViews.buttons.allElementsBoundByIndex.prefix(6)
        XCTAssertGreaterThan(cells.count, 1, "expected a populated grid")
        let widths = Set(cells.map { ($0.frame.width * 10).rounded() })
        XCTAssertLessThanOrEqual(widths.count, 2,
                                 "cells must share a width — artwork must not size its own cell")
        for cell in cells {
            XCTAssertLessThanOrEqual(cell.frame.width, app.frame.width,
                                     "a cell wider than the screen is the ragged-grid bug")
        }
    }

    /// The mix cards' backdrops. Unlike cover art these are *bundled* assets, so they
    /// render without a server and the capture is worth looking at whatever the library.
    func testMixCardsDrawTheSharedBackdrops() throws {
        app.launch()

        XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["Home"].firstMatch.tap()

        // "Most Played" is the first auto-mix and carries MixArtMostPlayed.
        let mix = app.staticTexts["Most Played"]
        XCTAssertTrue(mix.waitForExistence(timeout: 30), "the mixes row must appear on Home")
        capture("home-mix-cards")
    }

}
