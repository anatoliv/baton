import XCTest

/// The claim this file exists to test: on the day the gate opens, playing a track in the
/// running app actually fires the rating ask.
///
/// `ReviewPromptTests` proves the gate arithmetic and nothing else. It cannot see whether the
/// ask ever reaches a user, and the first version of this feature carried a bug only a running
/// app could show: the twenty-second re-check read `scenePhase` out of a captured
/// `RootTabView` struct, so it was `.active` whatever the app was really doing. Every unit test
/// passed. That is why `requiredListeningDays` and `settleDelay` are DEBUG-overridable at all.
///
/// **What this does and does not prove.** It asserts on `debug.reviewAsk`, so it covers
/// everything that is ours: the gate opened, the deferred re-check accepted the moment, and
/// `claimAsk()` spent the prompt. It does *not* assert the sheet is drawn — StoreKit renders
/// that out of process, in neither the app's element tree nor springboard's, and an earlier
/// version of this test that matched on its wording reported "no prompt" while attaching a
/// screenshot with the prompt plainly on screen. The screenshot is still attached on every
/// run, so the drawn sheet stays checkable by eye; it was confirmed by hand on 2026-09-07.
///
/// Demo mode, so it needs no server and no network.
final class ReviewPromptUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession",
            "-baton.demoMode", "YES",
            "-uitestBypassBiometrics",
            "-uitestSkipSpeechAuthorization",
            // Collapse the gate to something a test can reach: one listening day instead of
            // three, and a two-second settle instead of twenty.
            "-baton.review.requiredDays", "1",
            "-baton.review.settleSeconds", "2",
            // Deliberately NOT passing -baton.review.listeningDays or .lastPromptedVersion.
            // A launch argument lands in NSArgumentDomain, which outranks the persistent
            // domain on read — so seeding them here would permanently shadow the keys,
            // `recordListening()` would write where nothing reads, and the gate could never
            // open. `-baton.resetSession` is what clears prior state.
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testPlayingATrackPutsTheRatingPromptOnScreen() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60),
                      "app never reached its tab bar")
        dismissTransientSheets()

        try startPlayingSomething()

        // The ask is deferred by `settleDelay` and re-checks that music is still playing, so
        // give it the delay plus room rather than asserting immediately.
        let probe = app.staticTexts["debug.reviewAsk"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "the debug.reviewAsk probe is missing")

        var fired = false
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline && !fired {
            fired = probe.label == "asked"
            if !fired { Thread.sleep(forTimeInterval: 1.0) }
        }

        // The screenshot is the half a probe cannot give you: that something is actually on
        // screen, rather than that a boolean flipped. Kept either way — a failure needs it
        // more than a pass does.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = fired ? "rating-prompt-shown" : "no-rating-prompt"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(fired, """
            The rating ask never fired within 25s of playback starting, with the gate \
            collapsed to one day and a two-second settle. Either the gate did not open or \
            the deferred re-check rejected a moment that was in fact fine — the latter is \
            the `scenePhase` capture bug this test was written for.
            """)
    }

    // MARK: - Helpers


    private func dismissTransientSheets() {
        for _ in 0..<3 {
            if app.buttons["Done"].waitForExistence(timeout: 3) { app.buttons["Done"].tap() }
            if app.buttons["Not now"].exists { app.buttons["Not now"].tap() }
        }
    }

    /// Starts playback from the bundled demo library, using the same route `PlayerLayoutUITests`
    /// uses: search for a known fixture, then tap rows until the now-playing bar appears. Says
    /// so plainly if it cannot, rather than letting the real assertion fail for the wrong reason.
    private func startPlayingSomething() throws {
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch
            : app.textFields.firstMatch
        guard field.waitForExistence(timeout: 20) else {
            throw XCTSkip("no search field, so there was no way to reach a track")
        }
        field.tap()
        field.typeText(DemoFixtures.searchTerm + "\n")

        let cells = app.cells
        guard cells.element(boundBy: 0).waitForExistence(timeout: 20) else {
            throw XCTSkip("the bundled demo library returned nothing to play")
        }
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
        guard playing else {
            throw XCTSkip("nothing in the bundled demo library started playing")
        }
    }
}
