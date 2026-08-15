import XCTest

/// App Store screenshots, captured against the demo server so every screen has a real
/// library behind it. Not part of the gate: each test skips unless `BATON_SCREENSHOTS`
/// is set in the environment, because a marketing capture that depends on a third-party
/// server has no business failing a merge.
///
/// Run explicitly, per device the store wants (6.9" iPhone and 13" iPad):
///
///   BATON_SCREENSHOTS=1 xcodebuild test -project BatonMobile.xcodeproj \
///     -scheme BatonMobile -destination "platform=iOS Simulator,name=iPhone 17 Pro Max" \
///     -only-testing:BatonMobileUITests/StoreScreenshotUITests
///
/// The screenshots come out as attachments in the result bundle; the launch tooling
/// exports them with `xcresulttool`.
final class StoreScreenshotUITests: XCTestCase {
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
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    private func skipUnlessEnabled() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BATON_SCREENSHOTS"] == nil,
                      "store screenshots run on demand, not in the gate")
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

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 20) {
        XCTAssertTrue(element.waitForExistence(timeout: 40), "expected \(element)")
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable, Date() < deadline { usleep(300_000) }
        XCTAssertTrue(element.isHittable, "\(element) never became tappable")
    }

    /// Two launches: the first browses every screen we intend to capture, so the
    /// artwork cache fills; the second (no reset, same server) captures against warm
    /// caches. The first attempt skipped this and produced a store page of grey
    /// placeholder tiles — a screenshot of loading, not of the app.
    func testCaptureStoreScreenshots() throws {
        try skipUnlessEnabled()
        try Self.skipUnlessDemoServerIsUp()
        app.launch()

        // Warm pass: visit Home, Albums, one album. Give artwork time to land.
        XCTAssertTrue(app.buttons["Albums"].firstMatch.waitForExistence(timeout: 40))
        sleep(10)
        app.buttons["Albums"].firstMatch.tap()
        let album = app.scrollViews.buttons.firstMatch
        waitHittable(album)
        sleep(8)
        // Scroll through the grid so covers below the fold load too — the iPad shows
        // five rows where the phone shows two, and the first capture had a third of
        // them still grey.
        app.swipeUp(); sleep(4)
        app.swipeUp(); sleep(4)
        app.swipeDown(); app.swipeDown(); sleep(4)
        album.tap()
        waitHittable(app.buttons["Play"].firstMatch)
        sleep(5)

        // Capture pass: same server, warm caches, nothing reset.
        app.terminate()
        app.launchArguments = ["-uitestBypassBiometrics"]
        app.launch()

        // The public demo server is shared, so another Baton's saved queue can raise
        // the "Continue where you left off?" handoff dialog over the first screen.
        if app.buttons["Not now"].waitForExistence(timeout: 6) {
            app.buttons["Not now"].tap()
        }

        XCTAssertTrue(app.buttons["Albums"].firstMatch.waitForExistence(timeout: 40))
        app.buttons["Albums"].firstMatch.tap()
        waitHittable(album)
        sleep(6)
        snap("02-albums")

        album.tap()
        let play = app.buttons["Play"].firstMatch
        waitHittable(play)
        sleep(4)
        snap("03-album")
        play.tap()
        sleep(2)

        // Full-screen player, via the bar's stable identifier.
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "expected the now-playing bar")
        bar.tap()
        let player = app.descendants(matching: .any).matching(identifier: "FullPlayerContent").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 15), "expected the full player")
        sleep(6) // artwork + palette settle
        snap("04-now-playing")

        // Close the player. Home comes last: by now the walk has warmed every cover
        // the screen shows, including the recently-played tiles our playback created.
        app.buttons["Minimize player"].firstMatch.tap()
        let home = app.buttons["Home"].firstMatch
        waitHittable(home)
        home.tap()
        sleep(8)
        snap("01-home")

        let search = app.buttons["Search"].firstMatch
        waitHittable(search)
        search.tap()
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            field.typeText("the")
            sleep(6)
            snap("05-search")
        }
    }
}
