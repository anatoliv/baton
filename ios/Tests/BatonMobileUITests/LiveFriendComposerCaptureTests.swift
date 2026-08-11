import XCTest

/// The Friend composer, photographed over a real conversation.
///
/// This exists because the composer is the one screen in the app that **no simulator run
/// could ever render**: demo mode hides the Friend tab, and the tab only appears once a
/// connection test has actually passed against a model provider. So two consecutive fixes
/// to it — the "pill in a pill" capsule among them — shipped without anyone, human or
/// test, having seen the thing they changed. A fix nobody can look at is a guess.
///
/// It needs a real model provider, and that is the *only* thing it needs. The tab is
/// gated on `agentConfig.isReady` alone (`RootTabView.swift`) — not on the library — so
/// demo mode reaches it perfectly well, and this runs without anyone's server credentials:
///
///     TEST_RUNNER_BATON_AGENT_KEY=… TEST_RUNNER_BATON_AGENT_MODEL=chat \
///     TEST_RUNNER_BATON_AGENT_BASE_URL=http://…/v1 \
///       xcodebuild test -only-testing:BatonMobileUITests/LiveFriendComposerCaptureTests …
///
/// Supplying `BATON_SERVER_URL`/`USERNAME`/`SECRET` as well signs into that library
/// instead, which is worth doing when the conversation's answers matter; for photographing
/// the composer they do not. The LAN provider in `~/.baton-live-agent.json` is the
/// intended model.
///
/// The skip is deliberate rather than lenient — per this repo's standing rule, an
/// environment that cannot give a measurement is *not measurable*, which is not the same
/// as broken.
final class LiveFriendComposerCaptureTests: XCTestCase {
    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var serverURL: String { env("BATON_SERVER_URL") }
    private var username: String { env("BATON_USERNAME") }
    private var secret: String { env("BATON_SECRET") }
    private var agentKey: String { env("BATON_AGENT_KEY") }
    private var agentModel: String { env("BATON_AGENT_MODEL") }
    private var agentBaseURL: String { env("BATON_AGENT_BASE_URL") }

    /// Whether a real library was supplied. Without one the demo library stands in, which
    /// the composer does not care about.
    private var hasLiveServer: Bool { !serverURL.isEmpty && !secret.isEmpty }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(agentKey.isEmpty || agentBaseURL.isEmpty, "live model provider not provided")
        app = XCUIApplication()
        app.launchArguments += ["-baton.resetSession", "-uitestBypassBiometrics"]
        if !hasLiveServer { app.launchArguments += ["-baton.demoMode", "YES"] }
        // Everything `AgentConfig` keeps in UserDefaults is set here rather than typed
        // into the form. Typing it was three failed runs: the base URL field would not
        // clear — batched deletes get coalesced, per-character deletes did not register
        // at all, and each attempt left the previous value behind, so the address grew
        // "…/v1v1", "…/v1/v1v1", "…/v1/v1/v1v1" and the provider answered 404 every time.
        //
        // The settings form is not what this test is about. The API key still goes in by
        // hand below, because it lives in the Keychain and no launch argument can reach
        // it — and that one field is empty to begin with, which is exactly the case that
        // never needed clearing.
        app.launchArguments += [
            "-baton.agent.route", "direct",
            "-baton.agent.provider", "openAICompatible",
            "-baton.agent.baseURL", agentBaseURL,
        ]
        if !agentModel.isEmpty { app.launchArguments += ["-baton.agent.model", agentModel] }
        app.launch()
    }

    func testComposerOverARealConversation() throws {
        if hasLiveServer { signIn() }
        try configureFriend()

        let friendTab = app.tabBars.buttons["Friend"]
        XCTAssertTrue(friendTab.waitForExistence(timeout: 30),
                      "the Friend tab must appear once the connection test passes")
        friendTab.tap()

        // By identifier across any element type, not `app.textFields[…]`: the composer is a
        // `TextField(axis: .vertical)` so it can grow to four lines, and that reports as a
        // text *view*, not a text field.
        let composer = app.descendants(matching: .any)["FriendComposerField"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "the composer must be on screen")
        capture("composer-empty")

        // Keyboard up is the state both shipped bugs were in: the capsule sits directly
        // above it, and that is where a mismatched inset shows.
        composer.tap()
        composer.typeText("What genres am I in the mood for?")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "tapping the composer must raise the keyboard")
        XCTAssertTrue(composer.isHittable, "the composer must stay reachable above the keyboard")
        capture("composer-keyboard-up")

        // Send, and wait for the model to actually answer. A composer that looks right and
        // cannot send is the same class of defect as the mix card nothing could tap.
        app.buttons["Send"].firstMatch.tap()
        if !app.buttons["Send"].firstMatch.exists { composer.typeText("\n") }
        XCTAssertTrue(waitForReply(timeout: 180),
                      "the model never answered — check the provider is awake before believing this")
        capture("composer-after-reply")

        // And keyboard down, which is the other half of the accept criterion: the capsule
        // has to line up against the tab bar as well as against the keyboard.
        app.tapCoordinateInTranscript()
        capture("composer-keyboard-down")
    }

    /// Polls a condition rather than sleeping a fixed span, so a fast path finishes fast
    /// and a slow one still gets its full allowance.
    private func waitFor(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 2)
        }
        return condition()
    }

    /// A reply has landed when a bubble exists that isn't the message we sent and isn't
    /// the thinking row. Polls rather than sleeping, so a fast model finishes fast.
    private func waitForReply(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let thinking = app.staticTexts["Thinking…"].exists
            let bubbles = app.staticTexts.allElementsBoundByIndex.filter {
                $0.exists && !$0.label.isEmpty
                    && $0.label != "What genres am I in the mood for?"
                    && $0.label != "Thinking…"
                    && $0.label != "Music Friend"
            }
            if !thinking, bubbles.count > 1 { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 2)
        }
        return false
    }

    private func configureFriend() throws {
        openSettings()
        // By prefix, not by equality: the row is a navigation link with its current state
        // as the detail, so its accessibility label is "Music Friend, Off" — and it turns
        // into "Music Friend, On" the moment this test succeeds, which would break an
        // exact match in the one case that matters.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Music Friend"))
            .allElementsBoundByIndex
            .first { $0.exists && $0.isHittable }
        XCTAssertNotNil(row, "Settings must offer Music Friend")
        row?.tap()

        // Route, dialect, model and base URL all arrived as launch arguments; only the
        // Keychain-backed key has to be typed. It is behind the biometric gate, which the
        // DEBUG-only `-uitestBypassBiometrics` satisfies.
        tapRow(startingWith: "API key", describedAs: "the locked API key row")
        let keyField = app.secureTextFields.firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 15), "the API key field must unlock")
        keyField.tap()
        keyField.typeText(agentKey)

        // Confirm the seeded address really is what the app is about to call, so a wrong
        // one fails here and says so rather than surfacing as an opaque provider error.
        XCTAssertEqual(app.textFields["API base URL"].firstMatch.value as? String, agentBaseURL,
                       "the launch argument did not reach the base URL field")

        let test = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Test connection'"))
            .firstMatch
        XCTAssertTrue(test.waitForExistence(timeout: 10), "there must be a connection test")
        test.tap()

        // The test spends one real request against the provider, so give it room — a LAN
        // model that is still loading answers slowly rather than not at all. The Friend
        // tab appearing is the outcome that matters, and it is the app's own signal that
        // the test passed, so wait on that rather than on the wording of a badge.
        // Skip, don't fail, when the provider cannot pass the test.
        //
        // Baton's direct-route connection test asks the model to *pause the music* and
        // requires an actual tool call in reply — deliberately, so a pass means the next
        // real message works rather than merely that something answered. A small local
        // model may answer in a second and still decline to call the tool ("I can't
        // control music playback directly"), which is a fact about that model, not about
        // the composer this test photographs. Observed passing on one run and refusing on
        // the next two against the same host.
        //
        // Failing here would put a coin-flip red in the gate, and a gate that is red at
        // random stops being a gate. Same judgement as the conversation eval: an
        // environment that cannot give a measurement is not measurable, not broken.
        try XCTSkipUnless(
            waitFor(timeout: 180) { self.app.tabBars.buttons["Friend"].exists },
            """
            the model provider never passed Baton's connection test, so the Friend tab \
            never appeared. It needs a model that reliably emits a tool call for \
            "pause the music" — check that before reading anything into this skip.
            """
        )

        dismissSettings()
    }

    /// Taps the first hittable element whose label *starts with* `prefix`, and fails
    /// loudly when there is none.
    ///
    /// Both halves matter. Rows in this Form compose their labels out of their state —
    /// the picker is "Provider, Anthropic" and the locked key row is "API key, not set.
    /// Unlock to view or change." — so equality matches nothing. And the first version of
    /// this test wrapped each tap in `if exists`, which turned both misses into silence
    /// and then into a 15-second timeout on an unrelated field, blaming the biometric
    /// bypass for a query that never matched. A precondition that quietly does nothing is
    /// worse than one that fails.
    private func tapRow(startingWith prefix: String, describedAs description: String) {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
            .first { $0.exists && $0.isHittable }
        guard let match else { return XCTFail("could not find \(description)") }
        match.tap()
    }


    private func dismissSettings() {
        let done = app.navigationBars.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        while app.navigationBars.buttons.firstMatch.exists, !app.tabBars.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    private func openSettings() {
        app.tabBars.buttons["Home"].tap()
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "Home's header must offer Settings")
        gear.tap()
        XCTAssertTrue(app.staticTexts["Server"].waitForExistence(timeout: 20), "Settings must open")
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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

private extension XCUIApplication {
    /// A tap in the transcript, which is Music Friend's own dismiss-the-keyboard gesture.
    func tapCoordinateInTranscript() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    }
}
