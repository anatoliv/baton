import XCTest

/// The connection badge, against a real server.
///
/// A badge claiming "Connected" is only worth having if it was earned, so this earns it:
/// sign in to Navidrome's public demo server through the app's own form, then assert the
/// badge turns to Connected. Nothing here is mocked — the failure this guards against is
/// precisely a green light that appears without a request having succeeded.
///
/// It skips when the demo server is unreachable rather than failing. That server is not
/// ours; treating someone else's downtime as a broken build is the mistake that had a
/// sleeping LAN model reporting "more than 20% of ordinary messages did the wrong thing".
@MainActor
final class ServerStatusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try Self.skipUnlessDemoServerIsUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-baton.resetSession", "-baton.demoMode", "YES"]
        app.launch()
        if app.navigationBars["What's New"].waitForExistence(timeout: 3), app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        }
    }

    /// `nonisolated static` on purpose: as an instance method on a `@MainActor` class it
    /// hands `self` to a background URLSession callback, which Swift 6 rejects — and the
    /// whole UI-test target then fails to compile, taking every other test with it.
    private nonisolated static func skipUnlessDemoServerIsUp() throws {
        var request = URLRequest(url: URL(string: "https://demo.navidrome.org/ping")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = response != nil
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        try XCTSkipIf(!reachable, "demo.navidrome.org isn't answering — skipping rather than blaming the app")
    }

    /// Opens Settings from Home's header.
    ///
    /// It used to be a tab. Six tabs don't fit on a phone, so with the Friend tab enabled
    /// iOS folded both Search *and* Settings behind "More" — and Search is the one people
    /// use constantly.
    private func openSettings() {
        app.tabBars.buttons["Home"].tap()
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "Home's header must offer Settings")
        gear.tap()
        // "Server" rather than "Settings": the gear's accessibility label is also
        // "Settings", so waiting on that text can match the button that was just tapped
        // instead of the screen it opened. The Server section only exists once Settings
        // is actually on screen.
        XCTAssertTrue(app.staticTexts["Server"].waitForExistence(timeout: 20),
                      "Settings must open")
    }

    /// One tap should get you in, not fill a form and wait for you to notice a button.
    ///
    /// The whole point of this row is someone with no server asking "what is this app".
    /// Populating fields and leaving them to find Connect is a step that teaches nothing,
    /// and it fails opaquely: when the demo server is down it surfaced as a bare error
    /// under the sign-in form, with no hint that the built-in demo would have worked.
    func testTheDemoServerRowConnectsOnItsOwn() {
        openSettings()
        let connect = app.buttons["Connect to Navidrome…"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()

        let useDemo = app.buttons["Use Navidrome's public demo server"]
        XCTAssertTrue(useDemo.waitForExistence(timeout: 10))
        useDemo.tap()

        // No second tap: connecting is the button's job now.
        let badge = app.buttons["ServerStatus"]
        var connected = false
        for _ in 0 ..< 60 {
            if badge.exists, badge.label.localizedCaseInsensitiveContains("Connected") {
                connected = true
                break
            }
            _ = badge.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(connected,
                      "one tap must sign in — saw: \(badge.exists ? badge.label : "no badge")")
    }

    /// The other outcome: their server is down, and the app says so and offers the demo
    /// that needs no connection.
    ///
    /// Pointed at a reserved-unreachable address, because this path is otherwise only
    /// testable by waiting for someone else's server to break. Untested failure handling
    /// is how you discover the fallback never appeared, months later, from a user.
    /// Every album cell must be the same width as its neighbours.
    ///
    /// Cover art is not all square — a real library is full of 16:9 thumbnails — and the
    /// grid used to let the *image* decide the cell size. One wide cover made its cell
    /// wider than the column: rows went ragged and titles ran off the edge. That never
    /// showed up in any audit because the bundled demo's four covers are all square, so
    /// this signs in to a real library first.
    func testAlbumCellsAreAllTheSameSize() {
        openSettings()
        let connect = app.buttons["Connect to Navidrome…"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()
        let useDemo = app.buttons["Use Navidrome's public demo server"]
        XCTAssertTrue(useDemo.waitForExistence(timeout: 10))
        useDemo.tap()

        // Wait for the badge to confirm the sign-in *finished*. The first version of this
        // test raced ahead while it was still "Checking the demo server…", found the
        // connect screen's own buttons, measured those, and passed — proving nothing at
        // all. A test that can pass without reaching the screen it names is worse than no
        // test, because it is counted as coverage.
        let badge = app.buttons["ServerStatus"]
        var connected = false
        for _ in 0 ..< 60 {
            if badge.exists, badge.label.localizedCaseInsensitiveContains("Connected") {
                connected = true
                break
            }
            _ = badge.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(connected, "the library must actually load before measuring its grid")

        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.tabBars.buttons["Albums"].tap()

        // Proof we are on the grid, not somewhere that merely has buttons.
        XCTAssertTrue(app.staticTexts["Albums"].waitForExistence(timeout: 20),
                      "the Albums screen must be open")
        let countLine = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "album")).firstMatch
        XCTAssertTrue(countLine.waitForExistence(timeout: 30),
                      "the header must report a real album count — an empty grid measures nothing")

        let cells = app.scrollViews.buttons.allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
        XCTAssertGreaterThan(cells.count, 3, "the demo library should fill a grid")

        // The invariant the bug broke: one wide cover must not widen its cell.
        let widths = Set(cells.map { ($0.frame.width * 10).rounded() / 10 })
        XCTAssertLessThanOrEqual(widths.count, 1,
                                 "album cells must share one width — got \(widths.sorted())")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "albums-grid-real-library"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAnUnreachableDemoServerOffersTheBuiltInDemo() {
        // First run, not Settings. Reached from Settings this screen is "change servers",
        // where offering a bundled demo would make no sense and the fallback is
        // deliberately absent — so testing it there proved nothing. A wiped session with
        // no demo mode is what a new install actually looks like.
        app.terminate()
        let fresh = XCUIApplication()
        fresh.launchArguments = ["-baton.resetSession", "-uitestPublicDemoURL", "https://invalid."]
        fresh.launch()

        let useDemo = fresh.buttons["Use Navidrome's public demo server"]
        XCTAssertTrue(useDemo.waitForExistence(timeout: 30),
                      "a fresh install must open on the setup screen")
        useDemo.tap()

        let fallback = fresh.buttons["Use the built-in demo instead"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 40),
                      "a dead demo server must offer the offline demo, not just fail")

        let text = fresh.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " ")
        XCTAssertTrue(text.contains("isn't answering"),
                      "and it must say the server is down rather than blaming the sign-in")

        // And the offer must work, not merely appear.
        fallback.tap()
        XCTAssertTrue(fresh.tabBars.buttons["Home"].waitForExistence(timeout: 20),
                      "taking the built-in demo must get you into the app")
    }
}
