import XCTest

/// Three defects that only exist while the app is running, and that every unit test in the
/// repo was happy to ignore.
///
/// - Starting playback threw the user back to the Home tab and popped every navigation
///   stack, because the now-playing accessory swapped one modifier chain for another and
///   SwiftUI rebuilt the whole `TabView`. It fired on the first play of every session.
/// - Home was one shelf over a screen of black until the app was relaunched, because its
///   shelves were fetched behind the setup cover before there was a library to fetch from.
///   That is the first screen a new buyer and an App Review tester see.
/// - The "Engine cost" section sat inside another section's `footer:` closure, where
///   SwiftUI silently drops it, so a shipped measurement had never once been on screen.
///
/// Demo mode throughout: no server, no network, no third party.
final class SessionNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // TBX-5336: launchEnvironment, not launchArguments — see CLAUDE.md's UI-test section.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["uitestSkipSpeechAuthorization"] = "1"
    }

    override func tearDown() { app = nil; super.tearDown() }

    // MARK: - F5: Home after "Try the demo", with no relaunch

    /// Enters the demo the way a first-time user does — through the setup cover — and asks
    /// for a shelf that only exists once the library has been fetched.
    ///
    /// On the old code `Recently Added` was absent here and present after a relaunch, from
    /// exactly the same data.
    func testHomeFillsInAfterEnteringTheDemoWithoutARelaunch() throws {
        app.launch()

        // The demo entry sits below the fold on a phone-sized setup screen.
        let tryTheDemo = app.buttons["Try the demo"]
        _ = app.staticTexts["Connect to Navidrome"].waitForExistence(timeout: 60)
        var offered = tryTheDemo.exists && tryTheDemo.isHittable
        for _ in 0 ..< 8 where !offered {
            app.swipeUp()
            offered = tryTheDemo.exists && tryTheDemo.isHittable
        }
        guard offered else {
            throw XCTSkip("the setup cover did not offer the demo, so there was nothing to enter")
        }
        tryTheDemo.tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30),
                      "entering the demo never reached the tabs")
        dismissTransientSheets()

        // The shelf that comes from the fetch, not from the mixes built out of what is
        // already in memory.
        let shelf = app.staticTexts["Recently Added"]
        var found = shelf.waitForExistence(timeout: 30)
        for _ in 0 ..< 6 where !found {
            app.swipeUp()
            found = shelf.exists
        }
        snap("home-after-try-the-demo")
        XCTAssertTrue(found, """
            Home never showed the Recently Added shelf after entering the demo. Its shelves \
            were fetched behind the setup cover, before there was a library, and nothing \
            refetched them until the next launch.
            """)
    }

    // MARK: - F1: playing something must not move the screen

    /// Two levels deep — Library, then Liked — then play, then assert the screen has not
    /// moved. On the old code the Liked screen was gone and the Home tab was selected.
    func testPlayingATrackLeavesTheScreenWhereItWas() throws {
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60),
                      "app never reached its tab bar")
        dismissTransientSheets()

        app.buttons["Library"].firstMatch.tap()
        let liked = app.buttons["Liked"].firstMatch.exists
            ? app.buttons["Liked"].firstMatch
            : app.staticTexts["Liked"].firstMatch
        guard liked.waitForExistence(timeout: 20), liked.isHittable else {
            throw XCTSkip("no Liked row in Library, so there was no second level to stand on")
        }
        liked.tap()

        let likedTitle = app.staticTexts["Liked"]
        guard likedTitle.waitForExistence(timeout: 20) else {
            throw XCTSkip("the Liked screen never came up")
        }

        // Liked opens on whichever segment was last used, and the demo library only has
        // liked *songs*. The segmented control is itself the first cell in the list, so a
        // blind tap on row zero changes the segment instead of playing anything.
        let songs = app.buttons["Songs"]
        if songs.waitForExistence(timeout: 10), songs.isHittable { songs.tap() }

        snap("liked-before-play")

        let cells = app.cells
        guard cells.element(boundBy: 1).waitForExistence(timeout: 20) else {
            throw XCTSkip("Liked is empty in the demo library, so nothing could be started here")
        }
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        var playing = false
        for index in 1 ..< min(cells.count, 5) where !playing {
            let cell = cells.element(boundBy: index)
            guard cell.exists, cell.isHittable else { continue }
            cell.tap()
            playing = bar.waitForExistence(timeout: 12)
        }
        if !playing {
            snap("liked-nothing-played")
            print("WS6 element tree after tapping Liked rows:\n\(app.debugDescription)")
            throw XCTSkip("nothing started playing, so there is nothing to assert")
        }

        snap("liked-after-play")
        XCTAssertTrue(likedTitle.exists, """
            playing a track threw the app back to Home and discarded the navigation stack. \
            The now-playing accessory used to return a different modifier chain once \
            something was playing, which rebuilds the TabView and resets both.
            """)
    }

    // MARK: - F9: the Engine cost section is on screen at all

    func testSettingsShowsTheEngineCostSection() throws {
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60),
                      "app never reached its tab bar")
        dismissTransientSheets()

        app.buttons["Home"].firstMatch.tap()
        let settings = app.buttons["Settings"].firstMatch
        guard settings.waitForExistence(timeout: 20) else {
            throw XCTSkip("no Settings button in Home's header")
        }
        settings.tap()

        let header = app.staticTexts["Engine cost"]
        var found = header.waitForExistence(timeout: 5)
        for _ in 0 ..< 12 where !found {
            app.swipeUp()
            found = header.exists
        }
        snap("settings-engine-cost")
        XCTAssertTrue(found, """
            the Engine cost section is not in Settings. It used to sit inside the Advanced \
            section's footer: closure, where SwiftUI drops a Section silently, so \
            EngineCPUCostRow shipped as dead code.
            """)
    }

    // MARK: - Helpers

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dismissTransientSheets() {
        for _ in 0 ..< 3 {
            if app.buttons["Done"].waitForExistence(timeout: 3) { app.buttons["Done"].tap() }
            if app.buttons["Not now"].exists { app.buttons["Not now"].tap() }
        }
    }
}
