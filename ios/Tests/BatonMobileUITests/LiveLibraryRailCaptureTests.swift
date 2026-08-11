import XCTest

/// Every screen that can draw the A–Z rail, captured against a *real* library.
///
/// Skips unless credentials are supplied, so it is inert in CI and on anyone else's
/// machine. It exists because the demo server cannot exercise this feature at all:
/// demo.navidrome.org reports 26 artists and 19 playlists against a 30-item gate, so every
/// rail screen renders railless there and three rail bugs shipped without a single failing
/// test. Run it with:
///
///     TEST_RUNNER_BATON_SERVER_URL=… TEST_RUNNER_BATON_USERNAME=… TEST_RUNNER_BATON_SECRET=… \
///       xcodebuild test -only-testing:BatonMobileUITests/LiveLibraryRailCaptureTests …
///
/// Known gap: the Liked capture reaches the screen but its sort menu and its Select button
/// sit in the same corner, and this taps Select. Liked is therefore *not* covered — the
/// screenshot it produces shows no rail for the wrong reason.
final class LiveLibraryRailCaptureTests: XCTestCase {
    private var app: XCUIApplication!

    private var serverURL: String { ProcessInfo.processInfo.environment["BATON_SERVER_URL"] ?? "" }
    private var username: String { ProcessInfo.processInfo.environment["BATON_USERNAME"] ?? "" }
    private var secret: String { ProcessInfo.processInfo.environment["BATON_SECRET"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(serverURL.isEmpty || secret.isEmpty, "live server credentials not provided")
        app = XCUIApplication()
        app.launchArguments += ["-baton.resetSession"]
        // Artists defaults to list; the grid is the layout that collapsed to one column.
        app.launchArguments += ["-tonebox.music.artistLayout", "grid"]
        app.launch()
    }

    private func capture(_ name: String) {
        let rail = app.descendants(matching: .any)
            .matching(identifier: "AlphabetIndexRail").firstMatch
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(name)-rail-\(rail.exists ? "present" : "absent")"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The sort menus are `Menu`s labelled with an SF Symbol and carry no identifier, so
    /// they are found by geometry — the trailing-most control in the top strip — rather
    /// than by a fixed coordinate, which lands on whatever happens to be there.
    private func tapTopTrailingControl() {
        let top = app.frame.height * 0.20
        let right = app.frame.width * 0.55
        let candidate = app.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable && $0.frame.minY < top && $0.frame.minX > right }
            .sorted { $0.frame.minX > $1.frame.minX }
            .first
        candidate?.tap()
    }

    /// Tab taps are routinely swallowed right after a sheet or a tab change, so switch
    /// until the screen we asked for is actually the screen we are on.
    @discardableResult
    private func switchTab(_ tab: String, until marker: XCUIElement) -> Bool {
        for _ in 0..<6 {
            app.tabBars.buttons[tab].tap()
            if marker.waitForExistence(timeout: 12) { return true }
        }
        return false
    }

    private func chooseMenuItem(_ label: String) {
        let item = app.buttons[label].firstMatch
        if item.waitForExistence(timeout: 5) { item.tap() }
    }

    func testCaptureEveryRailScreen() {
        signIn()

        // Artists is forced to `grid` in setUp: the grid is the layout that collapsed to a
        // single column when the rail's reserve grew, and the list layout would have hidden
        // it. Genres, Folders and Playlists come along for the ride.
        for destination in ["Artists", "Playlists", "Folders", "Genres"] {
            openLibrary()
            let row = app.buttons[destination].firstMatch
            guard row.waitForExistence(timeout: 20) else {
                XCTFail("no \(destination) row in Library"); continue
            }
            row.tap()
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 45)
            sleepBriefly()
            capture(destination.lowercased())
        }
    }

    private func sleepBriefly() {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 3)
    }

    private func openLibrary() {
        // Already inside a Library destination: pop back before switching tabs.
        while app.navigationBars.buttons.firstMatch.exists,
              !app.buttons["Playlists"].firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 10)
        }
        switchTab("Library", until: app.buttons["Playlists"].firstMatch)
    }

    private func signIn() {
        let url = app.textFields["https://music.example.com"]
        XCTAssertTrue(url.waitForExistence(timeout: 30), "expected the first-run screen")
        url.tap(); url.typeText(serverURL)
        let user = app.textFields["Username"]
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        user.tap(); user.typeText(username)
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText(secret)
        app.buttons["Connect"].tap()

        // The keychain "Save Password?" sheet belongs to SpringBoard and blocks every tap.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notNow = springboard.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 30) { notNow.tap() }

        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 120),
                      "expected to reach the app after connecting")
    }
}
