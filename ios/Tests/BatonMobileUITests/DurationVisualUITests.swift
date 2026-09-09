import XCTest

/// Captures every screen that gained a play-time column, against a real library.
///
/// Durations only appear when the server reports them, so the bundled demo proves almost
/// nothing here — this signs in to Navidrome's public demo first. The captures are the
/// point: the risk with this change is not that the number is wrong but that it *crowds*,
/// since a song row can already carry three trailing signals before a duration joins them.
/// That is a question only a screenshot answers.
@MainActor
final class DurationVisualUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try Self.skipUnlessDemoServerIsUp()
        continueAfterFailure = true
        app = XCUIApplication()
        // The list style is set through the defaults rather than by driving the sort
        // menu: the first attempt tapped a Picker row that never matched, so Albums
        // stayed in grid and the row this pass exists to check went unverified.
        //
        // TBX-5336: launchEnvironment, not launchArguments — see CLAUDE.md's UI-test section.
        // NOTE (found while converting, not fixed here — out of this card's scope): the real
        // @AppStorage key for the album layout is `tonebox.music.albumLayout`
        // (`BrowseScreen.album.layoutKey`); `baton.albums.style` is a stale key nothing reads
        // any more, so this override has been a no-op since the rename. Carried over
        // faithfully rather than silently fixed.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.albums.style"] = "list"
        app.launch()
        if app.navigationBars["What's New"].waitForExistence(timeout: 8), app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        }
    }

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
        try XCTSkipIf(!reachable, "demo.navidrome.org isn't answering — skipping the visual pass")
    }

    /// Waits for an element to stop existing — "the screen I was on has gone".
    ///
    /// `waitForExistence` has no opposite in XCTest, and the absence of one is why this
    /// test waited on the wrong thing for its most important step.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureEveryScreenThatGainedPlayTime() {
        // Sign in to a real library — the whole point of this pass.
        let useDemo = app.buttons["Use Navidrome's public demo server"]
        XCTAssertTrue(useDemo.waitForExistence(timeout: 30), "expected the first-run screen")
        useDemo.tap()

        // Signed in is the first-run screen *going away*, not a tab bar appearing.
        //
        // The tab bar exists behind the connect screen from the first frame, so
        // `tabBars.buttons["Albums"].waitForExistence` returned instantly and the tap
        // below landed on the connect screen's backdrop. The walk then carried on down
        // Home, opened the empty "Most Played" mix, pressed its Play, and reported the
        // mini player as missing — four screens of consequences from one false landmark.
        XCTAssertTrue(waitForDisappearance(of: useDemo, timeout: 120),
                      "signing in should dismiss the first-run screen")
        XCTAssertTrue(app.tabBars.buttons["Albums"].waitForExistence(timeout: 30),
                      "signing in should get us into the app")

        // 1. Albums — list style carries play time in the subtitle.
        app.tabBars.buttons["Albums"].tap()
        XCTAssertTrue(app.staticTexts["Albums"].waitForExistence(timeout: 30))
        _ = app.scrollViews.firstMatch.waitForExistence(timeout: 20)

        // 2. Album detail — the numbered track listing. Generous, because this is a real
        // library over a real connection: the rows arrive when the server sends them.
        let album = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 60),
                      "the demo server's albums must arrive")
        capture("albums-list-playtime")
        album.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 30))
        capture("album-detail-track-durations")

        // 3. Queue — per-row time and the "left" footer.
        app.buttons["Play"].tap()
        openFullPlayer(in: app, timeout: 30)
        let queue = app.buttons["Up Next"]
        XCTAssertTrue(queue.waitForExistence(timeout: 10))
        queue.tap()
        XCTAssertTrue(app.navigationBars["Up Next"].waitForExistence(timeout: 15))
        capture("queue-durations-and-remaining")
        app.buttons["Close"].tap()
        // Not optional, and not "Done". This used to be `if app.buttons["Done"].exists`,
        // which stopped matching anything when the player's dismiss became a chevron —
        // so the player sheet stayed up for the rest of the test and the two screens
        // below were photographed through its backdrop. An optional dismissal cannot
        // fail, which is precisely how it hid.
        dismissFullPlayer(in: app)

        // 4. History — the cross-device record, which is the point of the scope control.
        app.tabBars.buttons["Library"].tap()
        let historyRow = app.buttons["History"]
        if historyRow.waitForExistence(timeout: 15) {
            historyRow.tap()
            let header = app.staticTexts["Across every device, from your server"]
            if !header.waitForExistence(timeout: 45) {
                // Say what was actually on screen. Guessing at a failure twice is how an
                // afternoon goes missing.
                print("HISTORY SCREEN TEXTS: " + app.staticTexts.allElementsBoundByIndex
                    .map { $0.label }.filter { !$0.isEmpty }.prefix(14).joined(separator: " | "))
                print("HISTORY BUTTONS: " + app.buttons.allElementsBoundByIndex
                    .map { $0.label }.filter { !$0.isEmpty }.prefix(14).joined(separator: " | "))
            }
            XCTAssertTrue(header.exists,
                "Recent must default to the server's record, which counts every device")
            capture("history-all-devices")

            // And the local log must still be reachable — it is the offline path.
            if app.buttons["This iPhone"].exists {
                app.buttons["This iPhone"].tap()
                XCTAssertTrue(app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS 'on this iPhone'")).firstMatch
                    .waitForExistence(timeout: 15),
                    "the on-device log must stay available and be labelled as such")
                capture("history-this-device")
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // 5. Search results — the shared SongRow, most crowded case.
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["SearchField"].exists
            ? app.textFields["SearchField"] : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("love")
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 20)
        capture("search-songrow-durations")
    }
}
