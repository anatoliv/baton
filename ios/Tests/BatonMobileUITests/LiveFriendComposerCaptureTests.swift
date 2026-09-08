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

    /// The one message this test sends. Named because three separate checks have to agree
    /// on it — what is typed, whether the composer still holds it, and which bubble is our
    /// own — and they used to agree by three copies of the same string literal.
    private static let question = "What genres am I in the mood for?"

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
        // Hittable, not merely existing. The root tab bar stays in the accessibility
        // hierarchy underneath a sheet, so `exists` is satisfied by a tab nobody can see
        // and the tap lands on the modal instead — which is exactly how this test used to
        // fail one step later, on the composer.
        XCTAssertTrue(waitFor(timeout: 20) { friendTab.isHittable },
                      "the Friend tab must be on screen, not just in the hierarchy")
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
        composer.typeText(Self.question)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "tapping the composer must raise the keyboard")
        XCTAssertTrue(composer.isHittable, "the composer must stay reachable above the keyboard")
        capture("composer-keyboard-up")

        // Everything on screen before the send, so "a reply arrived" can mean a label that
        // was not there before. The check this replaces counted static texts and passed at
        // `> 1` — and the greeting is two of them, before a word is sent, with two hidden
        // `debug.*` probes underneath. It returned true on its first poll on 2026-09-07 and
        // the test went green having photographed an unsent message sitting in the composer.
        let before = visibleLabels()

        // Send, and wait for the model to actually answer. A composer that looks right and
        // cannot send is the same class of defect as the mix card nothing could tap — so
        // the send is checked as its own claim, before anything is read into an answer.
        // Everything after an unsent message would be a photograph of a conversation that
        // never happened, which is what shipped in the screenshots of 2026-09-07.
        guard let send = composerSendButton() else {
            return XCTFail("the composer must offer a Send button above the keyboard — \(describeSendControls())")
        }
        send.tap()

        // The transcript, not the composer, is the signal. A sent message becomes a bubble
        // of its own, and `Text(message.text)` gives that bubble the message as its label —
        // so this is the app saying it took the message, rather than the test inferring it
        // from a field that has more than one way to change.
        XCTAssertTrue(app.staticTexts[Self.question].waitForExistence(timeout: 15),
                      "Send did not put the message into the transcript, so it was never sent — \(describeSendControls())")

        if !waitForReply(after: before, timeout: 180) {
            capture("composer-no-reply")
            XCTFail("the model never answered — check the provider is awake before believing this")
        }
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

    /// Every static text on screen, by label.
    private func visibleLabels() -> Set<String> {
        Set(app.staticTexts.allElementsBoundByIndex.filter { $0.exists }.map { $0.label })
    }

    /// A reply has landed when text appears that **was not on screen before the send** and
    /// is not our own message echoed back into a bubble.
    ///
    /// Difference from a count, which is what this used to be: a count cannot tell a reply
    /// from the greeting, the screen title, or the two hidden `debug.*` probes this build
    /// carries, and so was satisfied before the message was even sent.
    private func waitForReply(after before: Set<String>, timeout: TimeInterval) -> Bool {
        waitFor(timeout: timeout) {
            guard !self.app.staticTexts["Thinking…"].exists else { return false }
            return self.visibleLabels().contains {
                !$0.isEmpty && !before.contains($0) && $0 != Self.question && $0 != "Thinking…"
            }
        }
    }

    /// The composer's own Send button — the one **above** the keyboard.
    ///
    /// The history, because it is why this is not `app.buttons["Send"].firstMatch`: the
    /// field **used to** carry `.submitLabel(.send)`, which made the keyboard's return key
    /// a second button labelled "Send", and that is the one `firstMatch` picked on both
    /// runs on 2026-09-07. Tapping it did not submit — a `TextField(axis: .vertical)`
    /// treats return as a newline — so the message stayed in the composer with a second
    /// line under it, and the test called that a conversation.
    ///
    /// **Both modifiers are gone.** TBX-5158 removed `.submitLabel(.send)` and the dead
    /// `.onSubmit(sendDraft)` from the field for exactly that reason, and gave the
    /// composer's own button the identifier `FriendComposerSend`. Only one control on this
    /// screen is named Send today. Do not put either modifier back — `MusicFriendView.swift`
    /// carries the argument at the field itself, and this test is what caught it.
    ///
    /// Picking by position is therefore belt and braces now rather than the workaround it
    /// was, and a rewrite should ask for `FriendComposerSend` by identifier instead. It is
    /// left as it is on purpose: this test runs only when a live model provider is supplied,
    /// so a change here would go unrun, and this file has already sat broken for an unknown
    /// period because nothing ran it.
    ///
    /// The rule the geometry encodes: the keyboard covers the bottom of the screen, and the
    /// composer sits above it.
    private func composerSendButton() -> XCUIElement? {
        let keyboardTop = app.keyboards.firstMatch.exists
            ? app.keyboards.firstMatch.frame.minY
            : CGFloat.greatestFiniteMagnitude
        return app.buttons
            .matching(NSPredicate(format: "label ==[c] %@", "Send"))
            .allElementsBoundByIndex
            .first { $0.exists && $0.isHittable && $0.frame.maxY <= keyboardTop }
    }

    /// What the "Send" label actually matches, for a failure message that says something.
    /// Since TBX-5158 the composer's own button should be the only candidate; before it, the
    /// keyboard's return key was a second. So more than one match printed here is the tell
    /// that the field has grown a `.submitLabel` again.
    private func describeSendControls() -> String {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@", "Send"))
            .allElementsBoundByIndex
            .filter { $0.exists }
            .map { "type=\($0.elementType.rawValue) frame=\($0.frame) enabled=\($0.isEnabled) hittable=\($0.isHittable)" }
        return matches.isEmpty ? "nothing on screen is labelled Send" : matches.joined(separator: " | ")
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
        //
        // `exists` is the right check *here*, unlike everywhere else: the tab bar is still
        // behind the Settings sheet at this point, so nothing about it can be hittable yet.
        // The hittable check belongs after `dismissSettings()`, and that is where it is.
        try XCTSkipUnless(
            waitFor(timeout: 180) { self.app.tabBars.buttons["Friend"].exists },
            """
            the model provider never passed Baton's connection test, so the Friend tab \
            never appeared. It needs a model that reliably emits a tool call for \
            "pause the music" — check that before reading anything into this skip.
            """
        )

        try dismissSettings()
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


    /// Pops the pushed Music Friend detail, closes the Settings sheet, and **proves** the
    /// root is reachable before returning.
    ///
    /// The version this replaced did nothing at all, twice over, and said nothing about it.
    /// `app.navigationBars.buttons["Done"]` matched no element — the Settings sheet draws
    /// its own large header rather than a `UINavigationBar` — and the loop guard
    /// `!app.tabBars.firstMatch.exists` was false on entry, because the root tab bar stays
    /// in the accessibility hierarchy the whole time a sheet covers it, so the loop body
    /// never ran once. The test then tapped "Friend" through the modal and failed twenty
    /// seconds later on the composer, pointing at the wrong screen entirely.
    ///
    /// So the signal for "am I back at the root" is deliberately **not** the existence of
    /// anything: it is the *absence* of the `Music Friend` navigation bar together with the
    /// Home tab being **hittable**, which a covering sheet makes false. And when that
    /// signal does not arrive this throws, with a screenshot of wherever it got stuck.
    /// This is `tapRow`'s rule, which the same file already argues for and this function
    /// used not to apply: a precondition that quietly does nothing is worse than one that
    /// fails.
    private func dismissSettings() throws {
        let detailBar = app.navigationBars["Music Friend"]
        let home = app.tabBars.buttons["Home"]

        // 1. Pop the pushed detail, if we are on it.
        if detailBar.exists {
            let back = detailBar.buttons.firstMatch
            guard back.exists else {
                capture("dismiss-failed-no-way-out-of-the-detail")
                throw DismissalFailure("the Music Friend detail is up and its navigation bar offers no button to leave it")
            }
            back.tap()
            guard waitFor(timeout: 10, until: { !detailBar.exists }) else {
                capture("dismiss-failed-detail-would-not-pop")
                throw DismissalFailure("tapping Back left the Music Friend navigation bar on screen")
            }
        }

        // 2. Close the sheet. Unscoped, for the reason above. A miss here is not fatal on
        //    its own — there is no Done to find when the sheet was never up — so the root
        //    check below is what decides, and it cannot be satisfied by a sheet still up.
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }

        // 3. The check that makes the two steps above mean something.
        guard waitFor(timeout: 20, until: { !detailBar.exists && home.isHittable }) else {
            capture("dismiss-failed-never-reached-the-root")
            throw DismissalFailure("""
                Settings never closed: after Back and Done, \
                Music Friend navigation bar present=\(detailBar.exists), \
                Home tab hittable=\(home.isHittable). Anything read off the tab bar from \
                here would be a photograph of the sheet.
                """)
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

/// Thrown when the walk cannot get back to the root tab bar.
///
/// A thrown error rather than an `XCTFail` and a return: the caller's next act is to read
/// the tab bar, and a failure recorded but not propagated would still let it do that and
/// photograph a sheet. Both `LocalizedError` and `CustomStringConvertible`, because those
/// are two different printings and XCTest reaches for the second: a bare `Error` reports as
/// "the operation couldn't be completed", and a `LocalizedError` alone came out of a real
/// run as `DismissalFailure(reason: "…")` — readable by luck rather than by design.
private struct DismissalFailure: LocalizedError, CustomStringConvertible {
    let description: String
    init(_ reason: String) { description = "could not get back to the root from Settings — \(reason)" }
    var errorDescription: String? { description }
}

private extension XCUIApplication {
    /// A tap in the transcript, which is Music Friend's own dismiss-the-keyboard gesture.
    func tapCoordinateInTranscript() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    }
}
