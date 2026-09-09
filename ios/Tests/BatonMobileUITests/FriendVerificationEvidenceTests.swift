import XCTest

/// Evidence, from a running app, for the three claims that TBX-5123, TBX-5127 and
/// TBX-5131 have only ever had code review and unit tests behind them:
///
///  1. a passing connection test makes the **Friend tab appear by itself** — the thing
///     TBX-5131 fixed by making the verified fingerprint an observed stored property, and
///     whose own "done when" asks for a screenshot of the tab bar;
///  2. the Music Friend settings screen carries a **live status row**;
///  3. typing in the API key field **does not fire a request per keystroke** — the defect
///     TBX-5127's audit found and `239e777c` fixed.
///
/// The provider is a local stub that always answers "pause the music" with a `music_pause`
/// tool call, for two reasons. It makes the pass deterministic, so what is under
/// observation is the app's plumbing rather than a small LAN model's willingness to emit a
/// tool call (the existing `LiveFriendComposerCaptureTests` documents it refusing on two
/// runs out of three). And it counts requests exactly, which is the whole measurement in
/// item 3 and cannot be taken from a paid provider's word.
///
///     BATON_STUB_BASE_URL=http://127.0.0.1:8099/v1 \
///       xcodebuild test-without-building -only-testing:BatonMobileUITests/FriendVerificationEvidenceTests …
final class FriendVerificationEvidenceTests: XCTestCase {
    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var stubBaseURL: String { env("BATON_STUB_BASE_URL") }
    /// Deliberately 40 characters: the audit's own worked example was "pasting a
    /// 40-character API key fires up to 40 real requests".
    private let apiKey = "sk-0123456789abcdef0123456789abcdef01234"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(stubBaseURL.isEmpty, "no stub provider supplied")
        app = XCUIApplication()
        // TBX-5336: launchEnvironment, not launchArguments — see CLAUDE.md's UI-test section.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["baton.agent.route"] = "direct"
        app.launchEnvironment["baton.agent.provider"] = "openAICompatible"
        app.launchEnvironment["baton.agent.baseURL"] = stubBaseURL
        app.launchEnvironment["baton.agent.model"] = "chat"
    }

    override func tearDown() { app = nil; super.tearDown() }

    // MARK: - 1 + 2: the tab appears, and the row is live

    func testAPassingConnectionTestMakesTheFriendTabAppear() throws {
        app.launch()

        // The control half. Without it a screenshot of a tab bar *with* a Friend tab proves
        // nothing — the tab could have been there all along.
        let friendTab = app.tabBars.buttons["Friend"]
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "the app must reach its tab bar")
        XCTAssertFalse(friendTab.exists, "the Friend tab must be hidden before any test passes")
        capture("01-tabbar-before-no-friend-tab")

        openMusicFriendSettings()

        // The live status row (item 2), before anything is typed. `isConfigured` is false
        // while the key is empty, so this is the not-configured state.
        capture("02-friend-settings-before-key")

        mark("key-typing-start")
        typeAPIKey()
        mark("key-typing-end")

        capture("03-friend-settings-key-typed")

        let test = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Test connection'")).firstMatch
        XCTAssertTrue(test.waitForExistence(timeout: 10), "there must be a connection test")
        mark("manual-test-tap")
        test.tap()

        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'understood the test request'"))
            .firstMatch.waitForExistence(timeout: 60), "the stub provider must pass the connection test")
        capture("04-friend-settings-after-passing-test")

        // THE CLAIM. The tab bar is behind this pushed screen, so leave and photograph it.
        // No relaunch, no other navigation that could re-render it by luck: back out of the
        // detail screen, close Settings, look at the tab bar.
        dismissSettings()
        XCTAssertTrue(friendTab.waitForExistence(timeout: 20),
                      "the Friend tab must appear once the connection test has passed")
        // Hittable, not merely existing. Under a sheet the whole tab bar stays in the
        // hierarchy, so `exists` would have been satisfied by a tab nobody could see.
        let deadline = Date().addingTimeInterval(20)
        while !friendTab.isHittable, Date() < deadline { usleep(300_000) }
        XCTAssertTrue(friendTab.isHittable, "the Friend tab must be on screen, not just in the hierarchy")
        capture("05-tabbar-after-friend-tab-present")

        friendTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["FriendComposerField"].waitForExistence(timeout: 30),
                      "the Friend tab must actually open the friend")
        capture("06-friend-screen-open")
    }

    // MARK: - 3: no request per keystroke

    /// Opens the screen a second time on an already-verified configuration, which is the
    /// case the fix claims spends nothing at all.
    func testReopeningAVerifiedScreenSpendsNoRequest() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        openMusicFriendSettings()
        typeAPIKey()
        let test = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Test connection'")).firstMatch
        XCTAssertTrue(test.waitForExistence(timeout: 10))
        test.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'understood the test request'"))
            .firstMatch.waitForExistence(timeout: 60))
        dismissSettings()
        XCTAssertTrue(app.tabBars.buttons["Friend"].waitForExistence(timeout: 20))

        // Now re-enter the screen. Verified, so the guard `!config.isReady` should stop the
        // on-appear probe.
        mark("verified-revisit-start")
        openMusicFriendSettings()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Test connection'"))
            .firstMatch.waitForExistence(timeout: 20), "the friend screen must open again")
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 6)
        capture("07-friend-settings-revisited-verified")
        mark("verified-revisit-end")
    }

    // MARK: - Is the Keychain even working in this build?

    /// A control for the import result, not a claim about either card.
    ///
    /// The Mac-import walk found the friend's settings arriving while its API key read back
    /// "Not set", even though `applyImport` had counted the secret as applied. That is either
    /// an app defect or a property of an unsigned simulator build whose Keychain writes do
    /// not stick — and the two are indistinguishable from the import alone. This types a key
    /// in by hand, relaunches WITHOUT the session reset, and looks at the same row.
    func testTheKeychainSurvivesARelaunch() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        openMusicFriendSettings()
        typeAPIKey()
        capture("20-key-typed-before-relaunch")

        // Same launch environment minus the wipe, so the only thing that could carry the key
        // across is the Keychain.
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "baton.resetSession")
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        openMusicFriendSettings()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 4)
        let notSet = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "not set"))
            .allElementsBoundByIndex.contains { $0.exists }
        capture("21-after-relaunch-keyReadsNotSet-\(notSet)")
    }

    // MARK: - Helpers

    private func typeAPIKey() {
        tapRow(startingWith: "API key", describedAs: "the locked API key row")
        let keyField = app.secureTextFields.firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 15), "the API key field must unlock")
        keyField.tap()
        // Character by character on purpose. `typeText` with the whole string is one
        // keystroke as far as the field's binding is concerned in some paths; the bug
        // being measured is per-edit, so each character must be its own edit.
        for character in apiKey { keyField.typeText(String(character)) }
    }

    /// Leaves a dated marker in the stub provider's request log, so requests can be
    /// attributed to a phase of the test from outside the simulator.
    private func mark(_ name: String) {
        guard let url = URL(string: stubBaseURL.replacingOccurrences(of: "/v1", with: "") + "/__mark/" + name)
        else { return }
        let done = XCTestExpectation(description: "mark")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        _ = XCTWaiter.wait(for: [done], timeout: 10)
    }

    private func openMusicFriendSettings() {
        app.tabBars.buttons["Home"].tap()
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 20), "Home's header must offer Settings")
        gear.tap()
        XCTAssertTrue(app.staticTexts["Server"].waitForExistence(timeout: 20), "Settings must open")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Music Friend"))
            .allElementsBoundByIndex
            .first { $0.exists && $0.isHittable }
        XCTAssertNotNil(row, "Settings must offer Music Friend")
        row?.tap()
    }

    private func tapRow(startingWith prefix: String, describedAs description: String) {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
            .first { $0.exists && $0.isHittable }
        guard let match else { return XCTFail("could not find \(description)") }
        match.tap()
    }

    /// Back out of the Music Friend detail screen, then close the Settings sheet.
    ///
    /// Explicitly, not by looping on "is a tab bar visible". Settings is a sheet *over* the
    /// tab view, so the tab bar stays in the accessibility hierarchy underneath it the whole
    /// time — a loop guarded on its absence never runs, and a screenshot taken on the
    /// strength of `tabBars.buttons["Friend"].exists` photographs the sheet.
    private func dismissSettings() {
        let back = app.navigationBars["Music Friend"].buttons.firstMatch
        if back.exists { back.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2)
        // Any button labelled Done, not `navigationBars.buttons["Done"]`: the Settings sheet
        // draws its own large header rather than a navigation bar, so the scoped query
        // matched nothing and the sheet silently stayed up.
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2)
        capture("04b-after-dismissing-settings")
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
