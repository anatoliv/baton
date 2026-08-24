import XCTest

/// App Store screenshots, captured against a local library so every screen has real
/// content behind it. Not part of the gate: each test skips unless `BATON_SCREENSHOTS`
/// is set in the environment, because a marketing capture has no business failing a merge.
///
/// This used to point at `https://demo.navidrome.org`, and that is precisely what got
/// Baton 1.0 rejected under **App Store guideline 5.2.1**: the public demo server's
/// catalogue is real music with real cover art, so all ten store screenshots showed
/// album sleeves we had no licence to display. It now points at a Navidrome on
/// localhost serving a library we generated ourselves — invented artists, invented
/// albums, our own artwork. See `tools/storeart/` for how it is built.
///
///   python3 tools/storeart/build_library.py     # generate the library
///   ./tools/storeart/navidrome.sh up            # serve it on localhost:4533
///
/// Then run explicitly, per device the store wants (6.9" iPhone and 13" iPad):
///
///   BATON_SCREENSHOTS=1 xcodebuild test -project BatonMobile.xcodeproj \
///     -scheme BatonMobile -destination "platform=iOS Simulator,name=iPhone 17 Pro Max" \
///     -only-testing:BatonMobileUITests/StoreScreenshotUITests
///
/// The screenshots come out as attachments in the result bundle; the launch tooling
/// exports them with `xcresulttool`.
final class StoreScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Overridable so the library can be served from somewhere other than this machine,
    /// but the default is the local instance `tools/storeart/navidrome.sh` starts.
    private static func env(_ key: String, _ fallback: String) -> String {
        let value = ProcessInfo.processInfo.environment[key] ?? ""
        return value.isEmpty ? fallback : value
    }
    private static var server: String { env("STOREART_SERVER", "http://localhost:4533") }
    private static var user: String { env("STOREART_USER", "admin") }
    private static var secret: String { env("STOREART_PASS", "batonstoreart") }

    /// What the search screenshot types.
    ///
    /// Not "the", which is what the demo-server capture used. Against this library "the"
    /// matches artist *names* — The Threnody Club, The Cordwainers — so four of the five
    /// visible rows came back from one artist wearing one sleeve, and a column of four
    /// identical thumbnails reads as a rendering bug rather than a search result.
    /// "night" spans four artists and also matches an album, so the shot shows two
    /// populated sections and four different covers.
    private static var searchTerm: String { env("STOREART_SEARCH", "night") }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession",
            "-uitestServer", Self.server,
            "-uitestUser", Self.user, "-uitestSecret", Self.secret,
            "-uitestBypassBiometrics",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    private func skipUnlessEnabled() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BATON_SCREENSHOTS"] == nil,
                      "store screenshots run on demand, not in the gate")
    }

    /// Reachable is not the same as ready: a Navidrome that answers while still indexing
    /// produces a store page of empty tiles. Ask for an album rather than a ping, so the
    /// check fails when the library is there but empty.
    private nonisolated static func skipUnlessLibraryIsReady() throws {
        let url = URL(string: "\(server)/rest/getAlbumList2?type=alphabeticalByName"
                      + "&size=1&u=\(user)&p=\(secret)&v=1.16.1&c=storeart&f=json")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var albums = 0
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = root["subsonic-response"] as? [String: Any],
                  let list = response["albumList2"] as? [String: Any] else { return }
            albums = ((list["album"] as? [[String: Any]]) ?? []).count
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        try XCTSkipIf(albums == 0,
                      "no library at \(server) — run tools/storeart/navidrome.sh up")
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Fail loudly on the app's own error screen instead of timing out on some element
    /// that will never arrive. The first run against a local library spent forty seconds
    /// waiting for an album tile and then reported `expected "..." Button`, when the app
    /// had been plainly displaying "Couldn't load / The music server rejected your
    /// credentials" the whole time. The screen already knew; the test just wasn't reading it.
    private func failIfLibraryErrorShowing() {
        let error = app.staticTexts["Couldn't load"].firstMatch
        guard error.exists else { return }
        let detail = app.staticTexts.allElementsBoundByIndex
            .map { $0.label }
            .first { $0.count > 40 } ?? "no detail on screen"
        snap("99-error")
        XCTFail("the app is showing its load-failure screen: \(detail)")
    }

    /// The first tappable album tile on the Albums grid.
    ///
    /// Deliberately not `app.scrollViews.buttons.firstMatch`. The tab bar leaves Home's
    /// view in the accessibility hierarchy after switching tabs, so that query resolves
    /// to Home's "Most Played" mix card: an element that exists, is never hittable
    /// again, and fails twenty seconds later with a message naming a button nobody was
    /// looking for. Album tiles are labelled "<album>, by <artist>", which mix cards and
    /// tab items are not, and taking the first *hittable* match lands on the visible tab.
    private func firstAlbumTile() -> XCUIElement {
        let tiles = app.buttons.matching(NSPredicate(format: "label CONTAINS ', by '"))
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            for index in 0..<tiles.count {
                let tile = tiles.element(boundBy: index)
                if tile.exists, tile.isHittable { return tile }
            }
            failIfLibraryErrorShowing()
            usleep(500_000)
        }
        failIfLibraryErrorShowing()
        XCTFail("no tappable album tile appeared on the Albums grid")
        return tiles.firstMatch
    }

    /// True when the Albums grid is showing and at least one tile can be tapped.
    private var albumsGridIsShowing: Bool {
        let tiles = app.buttons.matching(NSPredicate(format: "label CONTAINS ', by '"))
        for index in 0..<min(tiles.count, 4) {
            let tile = tiles.element(boundBy: index)
            if tile.exists, tile.isHittable { return true }
        }
        return false
    }

    /// Return to the Albums grid from an album detail.
    ///
    /// Harder than it should be. The grid sets no `navigationTitle`, so the system back
    /// button is labelled "Back" rather than "Albums" and does not surface through
    /// `navigationBars`. `swipeRight()` is not the pop gesture either — it swipes across
    /// the middle of the screen, so the first version did nothing at all, silently, and
    /// left the run parked on the detail view until it timed out. Try each real option
    /// and confirm the grid actually came back rather than assuming it did.
    @discardableResult
    private func returnToAlbumsGrid() -> Bool {
        let attempts: [() -> Void] = [
            { let back = self.app.navigationBars.buttons.firstMatch
              if back.exists, back.isHittable { back.tap() } },
            { let back = self.app.buttons["Back"].firstMatch
              if back.exists, back.isHittable { back.tap() } },
            { self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05,
                       thenDragTo: self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))) },
            { let tab = self.app.buttons["Albums"].firstMatch
              if tab.exists, tab.isHittable { tab.tap() } },
        ]
        for attempt in attempts {
            attempt()
            sleep(2)
            if albumsGridIsShowing { return true }
        }
        return false
    }

    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 20) {
        if !element.waitForExistence(timeout: 40) { failIfLibraryErrorShowing() }
        XCTAssertTrue(element.waitForExistence(timeout: 1), "expected \(element)")
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
        try Self.skipUnlessLibraryIsReady()
        app.launch()

        // Warm pass: visit Home, Albums, one album. Give artwork time to land.
        XCTAssertTrue(app.buttons["Albums"].firstMatch.waitForExistence(timeout: 40))
        sleep(10)
        app.buttons["Albums"].firstMatch.tap()
        waitHittable(firstAlbumTile())
        sleep(8)
        // Scroll through the grid so covers below the fold load too — the iPad shows
        // five rows where the phone shows two, and the first capture had a third of
        // them still grey.
        app.swipeUp(); sleep(4)
        app.swipeUp(); sleep(4)
        app.swipeDown(); app.swipeDown(); sleep(4)
        // Home leads with "Recently Played" and a running play count, and both are fed by
        // *local* history — scrobbles seeded server-side never reach them. The capture
        // pass is not reset, so whatever is played here is what that shelf shows. Play a
        // few different albums so Home is a populated row rather than one lonely tile,
        // which is what the first good capture produced: "1 plays and counting".
        // Strictly best-effort: a thinner Recently Played shelf is a worse screenshot,
        // but a capture that dies here produces none at all. Every step is conditional
        // and the loop abandons itself the moment it cannot get back to the grid.
        for index in 0..<3 {
            let tiles = app.buttons.matching(NSPredicate(format: "label CONTAINS ', by '"))
            guard tiles.count > index else { break }
            let tile = tiles.element(boundBy: index)
            guard tile.exists, tile.isHittable else { continue }
            tile.tap()
            let play = app.buttons["Play"].firstMatch
            if play.waitForExistence(timeout: 20) {
                play.tap()
                sleep(4)
            }
            guard returnToAlbumsGrid() else {
                XCTContext.runActivity(named: "history walk gave up at \(index)") { _ in }
                break
            }
        }

        // Re-resolve after the scrolling and the history walk: the tile that was first
        // before all that is not necessarily the same element afterwards.
        firstAlbumTile().tap()
        waitHittable(app.buttons["Play"].firstMatch)
        sleep(5)

        // Capture pass: same server, warm caches, nothing reset.
        //
        // The credentials are passed again rather than left to the restored session. The
        // two passes exist to warm the artwork cache, not to exercise persistence, and a
        // run that relied on the restored session once came back with "The music server
        // rejected your credentials" on the capture pass alone — forty seconds of waiting
        // for an album tile that was never going to appear. Re-supplying them costs
        // nothing and takes that whole failure mode off the table. No `resetSession`
        // here, so the caches the warm pass filled survive.
        app.terminate()
        app.launchArguments = [
            "-uitestServer", Self.server,
            "-uitestUser", Self.user, "-uitestSecret", Self.secret,
            "-uitestBypassBiometrics",
        ]
        app.launch()

        // The warm pass leaves a saved queue behind, which raises the "Continue where
        // you left off?" handoff dialog over the first screen of the capture pass.
        if app.buttons["Not now"].waitForExistence(timeout: 6) {
            app.buttons["Not now"].tap()
        }

        XCTAssertTrue(app.buttons["Albums"].firstMatch.waitForExistence(timeout: 40))
        app.buttons["Albums"].firstMatch.tap()
        waitHittable(firstAlbumTile())
        sleep(6)
        snap("02-albums")

        firstAlbumTile().tap()
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
            field.typeText(Self.searchTerm)
            sleep(6)
            snap("05-search")
        }
    }
}
