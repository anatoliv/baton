import XCTest

/// The chrome has to be there in *both* layouts.
///
/// Podcasts, Radio and Artists each render `Group { grid or list }`, and every modifier that
/// makes the screen work — the data load, pull-to-refresh, the `+` button, the empty state,
/// the add-feed and add-station alerts — used to be attached to the *list* branch alone.
/// Podcasts and Radio default to `.grid`, so a first run showed a dead screen with nothing
/// on it and no way to add anything. Artists had the identical bug, harmless only because
/// its default is `.list` — which is a bug waiting for somebody to change a default.
///
/// A modifier on one branch of a layout switch is invisible from the other, and it is
/// invisible in review too: both branches read fine on their own. So this asserts the thing
/// that actually broke — that the controls exist while the *grid* is the one on screen — and
/// keeps a screenshot of each, because "the screen is not blank" is a claim for eyes.
final class GridLayoutChromeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession",
            "-uitestServer", "https://demo.navidrome.org",
            "-uitestUser", "demo", "-uitestSecret", "demo",
            "-uitestBypassBiometrics",
            // Force the branch under test. These are the real `@AppStorage` keys
            // (`BrowseLayout.key`), so this drives the screens exactly as a person who had
            // tapped the grid button would — including Artists, whose default hides the bug.
            "-tonebox.music.podcastLayout", "grid",
            "-tonebox.music.radioLayout", "grid",
            "-tonebox.music.artistLayout", "grid",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

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

    /// Open a Library destination by name, from a cold start.
    private func openLibrarySection(_ name: String) {
        app.buttons["Library"].firstMatch.tap()
        let row = app.buttons[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no \(name) row in Library")
        row.tap()
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPodcastsGridHasItsAddButtonAndEmptyState() throws {
        try Self.skipUnlessDemoServerIsUp()
        app.launch()
        openLibrarySection("Podcasts")

        // The layout control proves which branch is on screen; without it a passing test
        // could simply be looking at the list.
        XCTAssertTrue(app.otherElements["LayoutPicker"].firstMatch.waitForExistence(timeout: 20)
                      || app.segmentedControls.firstMatch.waitForExistence(timeout: 5),
                      "the layout picker should be present on Podcasts")
        XCTAssertTrue(app.buttons["Add podcast feed"].firstMatch.waitForExistence(timeout: 20),
                      "the + button was list-only: a grid user could never add a feed")
        // A fresh session has no subscriptions, so the empty state is the honest content —
        // and it is what used to be missing entirely, leaving a blank screen.
        XCTAssertTrue(app.staticTexts["No podcasts yet"].firstMatch.waitForExistence(timeout: 20),
                      "the empty state was list-only")
        capture("podcasts-grid")
    }

    func testRadioGridHasItsAddButtonAndLoads() throws {
        try Self.skipUnlessDemoServerIsUp()
        app.launch()
        openLibrarySection("Radio")

        XCTAssertTrue(app.buttons["Add station"].firstMatch.waitForExistence(timeout: 20),
                      "the + button was list-only: a grid user could never add a station")
        // Either stations arrived or the empty state explains why. Both prove the `.task`
        // ran; the bug was that neither ever happened.
        let loaded = app.staticTexts["No stations"].firstMatch.waitForExistence(timeout: 30)
            || app.scrollViews.buttons.firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(loaded, "Radio's grid never loaded and showed no empty state")
        capture("radio-grid")
    }

    func testArtistsGridLoadsItsContent() throws {
        try Self.skipUnlessDemoServerIsUp()
        app.launch()
        openLibrarySection("Artists")

        // The demo server has artists, so the grid must fill. Before the fix `loadArtists`
        // was attached to the list branch, so this stayed empty forever.
        let artist = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(artist.waitForExistence(timeout: 40),
                      "the artists grid never loaded — its .task was list-only")
        capture("artists-grid")
    }
}
