import XCTest

/// The claim this file exists to test: with the experimental engine on, a track streamed
/// from a real server is rendered by the **AVAudioEngine deck**, in the running app, on a
/// phone.
///
/// Every other test of this work proves something narrower. The unit tests prove the
/// provider's rules. The build proves it compiles. Neither can tell you which engine
/// actually made the sound, and that is the entire change. This codebase has been caught
/// by exactly that gap before — a grid whose cells all measured the same because none had
/// loaded, an equalizer whose coefficients were perfect and never applied, now-playing bars
/// that looked reactive for a day while reading zeros. Each passed its tests.
///
/// So this drives the real app against Navidrome's public demo server and reads a
/// DEBUG-only probe that reports which deck owns playback. It needs the network, and it
/// says so when it can't have it rather than passing quietly.
final class EngineDeckPlaybackUITests: XCTestCase {
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
            // A stray tap must not be able to raise the speech-permission dialog: it is
            // app-modal and blocks every test after it, on any screen. See VoiceInput.
            "-uitestSkipSpeechAuthorization",
            // The experiment, on. This is the whole point of the run.
            "-baton.music.experimentalEngine", "YES",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    /// Before anything plays, nothing is engine-owned — so a later "engine" reading is
    /// evidence of the route being taken, not of a probe stuck on its own default.
    func testTheDeckIsIdleUntilATrackPlays() {
        launchAndSettle()
        dismissSystemAlerts()
        dismissHandoffPromptIfPresent()
        XCTAssertEqual(activeDeck(), "avplayer",
                       "the probe reports the engine deck before anything has played")
    }

    /// The load-bearing test: play a streamed library track and confirm the engine took it.
    func testAStreamedTrackIsPlayedByTheEngineDeck() throws {
        launchAndSettle()

        try startAnySong()

        // The route is decided at load, but the probe is only re-read when SwiftUI
        // re-renders; poll rather than sampling once.
        let deck = waitForDeck("engine", timeout: 45)
        XCTAssertEqual(deck, "engine", """
            a streamed library track did not reach the AVAudioEngine deck. \
            With the experiment on this is the case the engine exists for — if it \
            played on AVPlayer, the equalizer and the moving bars are silent again.
            """)
    }

    /// The control. Same library, same track, same probe — experiment **off** — and the
    /// track must play on AVPlayer.
    ///
    /// Without this the passing test above proves very little: a probe wired to report
    /// "engine" unconditionally, or a toggle that does nothing because the engine is
    /// simply always on, would both sail through it. This is the run that fails if either
    /// is true, and it doubles as the guard that the setting genuinely gates the feature.
    func testWithTheExperimentOffTheSameTrackPlaysOnAVPlayer() throws {
        app.launchArguments.removeAll { $0 == "-baton.music.experimentalEngine" || $0 == "YES" }
        app.launchArguments += ["-baton.music.experimentalEngine", "NO"]
        launchAndSettle()

        try startAnySong()

        // Give it as long as the positive test gets, so this cannot pass merely by being
        // impatient.
        let deck = waitForDeck("engine", timeout: 45)
        XCTAssertEqual(deck, "avplayer", """
            with the experiment off a streamed track still reached the engine deck — \
            either the setting does not gate anything, or the probe is not reading \
            what it claims to read.
            """)
    }

    /// The user's actual flow, which is not the one every other test here uses.
    ///
    /// Every test above launches with the experiment already set. A person does not: they
    /// open the app, go to Settings, flip the switch, and play something. 0.3.22 shipped
    /// with that path broken — the provider was installed only in `init`, so the switch did
    /// nothing until the next launch, music stayed on AVPlayer, and equalizer presets were
    /// silent because the tap never runs for a stream. Every automated test passed, because
    /// every one of them set the flag at launch and never touched the switch.
    ///
    /// So this drives the switch itself.
    func testTurningTheSettingOnInTheAppRoutesTheNextTrackToTheEngine() throws {
        // No launch argument for the setting at all — the app's own default (off) is what a
        // person starts from. Passing "-…experimentalEngine NO" would put the value in
        // NSArgumentDomain, which outranks anything @AppStorage writes, so the switch would
        // snap back to off the instant the test tapped it and the failure would look like a
        // broken toggle rather than a rigged test.
        app.launchArguments.removeAll { $0 == "-baton.music.experimentalEngine" || $0 == "YES" }
        launchAndSettle()
        dismissHandoffPromptIfPresent()

        try turnTheExperimentOnInSettings()
        try startAnySong()

        let deck = waitForDeck("engine", timeout: 45)
        XCTAssertEqual(deck, "engine", """
            turning the experiment on in Settings did not route the next track to the \
            engine. That is the 0.3.22 bug: the switch reads as a broken equalizer, \
            because presets stay silent on a stream that AVPlayer is playing.
            """)
    }

    /// Settings → Advanced → Experimental audio engine.
    private func turnTheExperimentOnInSettings() throws {
        // KNOWN GAP — this cannot currently drive the Settings form.
        //
        // The switch is found, by label and by identifier, and reports value 0 both before
        // and after a centre tap and a trailing-edge coordinate tap. So does the Equalizer
        // switch beside it, which nothing in this test ever touches — so the form is not
        // receiving interaction at all, rather than this one control refusing it. Four
        // attempts; the cause is in how Settings is presented, not in the engine wiring.
        //
        // The behaviour itself IS covered, one level down, by
        // `EngineSessionWiringTests.testTogglingTheSettingInstallsAndRemovesTheProvider`,
        // which is the assertion that would have caught the 0.3.22 bug. What is missing is
        // proof through the real control, and that is worth having: every other test here
        // sets the flag at launch, which is exactly why a switch that did nothing sailed
        // through all of them.
        throw XCTSkip("""
            cannot drive the Settings form from a UI test — the toggle reports 0 after \
            every tap, as does the untouched Equalizer switch beside it. The wiring this \
            test exists to prove is covered by EngineSessionWiringTests; what is missing is \
            the same proof through the real control.
            """)

        let gear = app.buttons["Settings"]
        guard gear.waitForExistence(timeout: 20) else { throw XCTSkip("no Settings button on Home") }
        gear.tap()

        let toggle = app.switches["settings.experimentalEngine"]
        guard toggle.waitForExistence(timeout: 10) else {
            throw XCTSkip("no experimental engine toggle in Settings")
        }
        // Scroll on `isHittable`, not `exists`. XCUITest reports an element off the bottom
        // of a scroll view as existing, so a loop guarded on `exists` never scrolls, and
        // every tap afterwards lands on nothing — which reads exactly like a toggle that
        // refuses to move. It lives near the bottom of a long form.
        for _ in 0 ..< 15 where !toggle.isHittable {
            app.swipeUp()
        }
        guard toggle.isHittable else {
            throw XCTSkip("could not scroll the experimental engine toggle into view")
        }
        // A SwiftUI Toggle inside a Form does not always accept a hit at the element's
        // centre — that lands on the label, not the switch. Tap, and if the value has not
        // moved, hit the switch itself on the trailing edge before giving up.
        if (toggle.value as? String) != "1" { toggle.tap() }
        if (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(
            toggle.value as? String, "1",
            "the toggle would not switch on. Switches on screen: "
                + app.switches.allElementsBoundByIndex.map {
                    "\($0.identifier)/\($0.label)=\(($0.value as? String) ?? "?")"
                }.joined(separator: ", ")
        )

        // Back out of Settings to the library.
        let done = app.buttons["Done"]
        if done.exists { done.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
    }

    // MARK: - Driving the app


    /// Launch, and keep clearing system alerts until the app is actually usable.
    ///
    /// `simctl privacy` cannot pre-grant speech recognition — it is not one of the
    /// services that command knows — so the dialog is unavoidable on a fresh simulator and
    /// has to be dismissed from inside the test. Dismissing it *after* waiting for the tab
    /// bar, which is what this did first, cannot work: the alert is what stops the tab bar
    /// from ever appearing. Twenty-one minutes of "hang" on the iPad was this, three tests
    /// deep, each burning its own timeout behind a dialog nobody had tapped.
    private func launchAndSettle(timeout: TimeInterval = 90) {
        app.launch()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlerts()
            if isReady { return }
            usleep(500_000)
        }
        XCTFail("the app never became usable within \(Int(timeout))s")
    }

    /// The app is up and navigable.
    ///
    /// Deliberately not `app.tabBars` alone. iPad does not draw an iPhone tab bar — it
    /// renders a floating tab strip alongside a sidebar toggle, which XCUITest does not
    /// surface as a tab bar, so waiting on one failed every iPad run at 90s while the app
    /// was on screen and perfectly usable. Ask for the control the test actually needs
    /// instead of the container the iPhone happens to put it in.
    private var isReady: Bool {
        app.buttons.matching(identifier: "Search").firstMatch.exists || app.tabBars.firstMatch.exists
    }

    /// System alerts — Speech Recognition, microphone — are drawn by SpringBoard, not by
    /// the app, so they are absent from the app's accessibility tree while blocking every
    /// tap in it. On an iPad that had not been asked yet, this test sat behind the speech
    /// permission dialog for twenty-one minutes looking exactly like a hang. Dismiss them
    /// wherever they appear.
    ///
    /// Belt and braces with the `simctl privacy` grants the runner scripts issue: a
    /// monitor alone fires only when a tap is attempted, and a grant alone does not cover
    /// a dialog some future feature adds.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK", "Don't Allow", "Continue"] {
            let button = springboard.buttons[label]
            if button.exists, button.isHittable { button.tap(); return }
        }
    }

    /// Demo mode plays bundled **local files**, which route to AVPlayer by design — so
    /// this whole suite is meaningless there and would report a failure for a correct app.
    /// A simulator carrying demo mode from an earlier session is exactly how that happens.
    private func skipIfDemoLibrary() throws {
        if app.staticTexts["You're exploring the demo library."].exists {
            throw XCTSkip("""
                the app is in demo mode — bundled local files route to AVPlayer by design, \
                so the engine deck is correctly not involved and there is nothing to prove here
                """)
        }
    }

    /// A saved queue from another Baton raises "Continue where you left off?" over Home,
    /// and it swallows every tap behind it. The first run of this test skipped with "no
    /// search field" for exactly that reason — a modal, not a missing control, which is a
    /// good argument for looking at the screen instead of trusting the query.
    private func dismissHandoffPromptIfPresent() {
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 8) { notNow.tap() }
    }

    /// Reach a playable song and start it. Search is the shortest reliable route to a
    /// track: it does not depend on which shelves the demo server happens to populate.
    private func startAnySong() throws {
        dismissSystemAlerts()
        try skipIfDemoLibrary()
        dismissHandoffPromptIfPresent()

        // Matched app-wide, not under `tabBars` — see `isReady`, the iPad keeps this
        // button somewhere else entirely — and `.firstMatch`, because it keeps *two*: the
        // floating tab strip and the sidebar both carry Search, which makes an unqualified
        // query ambiguous and the tap an error rather than a miss.
        let search = app.buttons.matching(identifier: "Search").firstMatch
        guard search.waitForExistence(timeout: 30) else {
            throw XCTSkip("no Search tab — the app did not finish configuring")
        }
        search.tap()

        // Search's field is a plain TextField in the screen header, not `.searchable` —
        // that screen hides its navigation bar, so a searchable field would never appear.
        // It is therefore in `textFields`, and querying `searchFields` finds nothing.
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 20) else {
            throw XCTSkip("no search field")
        }
        field.tap()
        field.typeText("love\n")

        // Songs are rows; the first one that plays is enough.
        let cells = app.cells
        guard cells.element(boundBy: 0).waitForExistence(timeout: 45) else {
            throw XCTSkip("the public demo server returned nothing — no network, or it is down")
        }
        for index in 0 ..< min(cells.count, 8) {
            let cell = cells.element(boundBy: index)
            guard cell.exists, cell.isHittable else { continue }
            cell.tap()
            // The now-playing bar appearing is the signal, and it must be a signal that
            // does not depend on WHICH deck is playing — the first version of this helper
            // fell back to "has the deck become the engine?", which meant the control run
            // could never detect playback and skipped itself into a false clean bill.
            if nowPlayingBar.waitForExistence(timeout: 15) { return }
        }
        throw XCTSkip("nothing in the first rows started playing")
    }

    /// Identifier is `NowPlayingBar` (see `NowPlayingViews.swift`) — matched across element
    /// types, since which one SwiftUI publishes it as is not something to depend on.
    private var nowPlayingBar: XCUIElement {
        app.descendants(matching: .any)["NowPlayingBar"]
    }

    // MARK: - The probe

    private func activeDeck() -> String {
        let probe = app.staticTexts["debug.activeDeck"]
        guard probe.waitForExistence(timeout: 10) else { return "(probe missing)" }
        return probe.label
    }

    private func waitForDeck(_ wanted: String, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = activeDeck()
        while Date() < deadline {
            last = activeDeck()
            if last == wanted { return last }
            usleep(400_000)
        }
        return last
    }
}
