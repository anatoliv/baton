import Foundation
import XCTest

/// Opt-in, fresh simulator + synthetic loopback fixtures. Never uses an owner account.
@MainActor
final class IncomingShareFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["INCOMING_SHARE_FLOW_TESTS"] == "1", "requires isolated incoming-sharing fixtures")
        let fixtureApp = XCUIApplication()
        app = fixtureApp
        // XCTest's synchronous tearDown override is nonisolated. Its SDK-provided
        // main-actor teardown block keeps screenshots and app cleanup on the UI actor.
        addTeardownBlock { @MainActor [fixtureApp] in
            XCTContext.runActivity(named: "incoming-final") { activity in
                let pixels = XCTAttachment(screenshot: fixtureApp.screenshot())
                pixels.name = "incoming-final"
                pixels.lifetime = .keepAlways
                activity.add(pixels)
            }
            fixtureApp.terminate()
        }
        // Never let a test instance write to the owner's synced preferences (main's rule since 2026-10-14).
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["baton.launchProbe"] = UUID().uuidString
        app.launchEnvironment["baton.defaultsSuite"] = "io.tonebox.tests.incoming." + UUID().uuidString
        app.launchEnvironment["baton.share.baseURL"] = try XCTUnwrap(environment["INCOMING_SHARE_BASE"])
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["uitestSkipSpeechAuthorization"] = "1"
    }
    private func capture(_ name: String) {
        let pixels = XCTAttachment(screenshot: app.screenshot()); pixels.name = "incoming-" + name
        pixels.lifetime = .keepAlways; add(pixels)
    }
    private func launch(connected: Bool = true) throws {
        if connected {
            for (key, fixture) in [("uitestServer","INCOMING_NAV_URL"),("uitestUser","INCOMING_NAV_USER"),("uitestSecret","INCOMING_NAV_SECRET")] {
                app.launchEnvironment[key] = try XCTUnwrap(environment[fixture])
            }
        }
        app.launch()
        if connected { XCTAssertTrue(app.staticTexts["debug.launchEnvironmentProbe"].waitForExistence(timeout: 20)) }
        else { XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20)) }
        if app.navigationBars["What's New"].waitForExistence(timeout: 3) { app.buttons["Done"].tap() }
        if connected {
            let home = app.tabBars.buttons["Home"]
            XCTAssertTrue(home.waitForExistence(timeout: 30))
            XCTAssertTrue(home.isHittable, "the connected library must be visible above setup")
            XCTAssertFalse(app.staticTexts["Connect to Navidrome"].exists)
            XCTAssertFalse(app.staticTexts["Baton can't read your saved passwords"].exists)
        }
    }
    private func deliver(_ command: String) async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: try XCTUnwrap(environment["INCOMING_CONTROL_URL"]))))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer " + (try XCTUnwrap(environment["INCOMING_CONTROL_TOKEN"])), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["command": command])
        let (bytes, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "OS delivery must preserve the running app process")
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(receipt["accepted"] as? Bool, true)
        // simctl openurl may ask for OS consent before delivering the URL. Only
        // approve this exact Baton prompt; preserve unrelated application alerts.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for application in [springboard, app!] {
            let prompt = application.alerts.containing(.staticText, identifier: "Open in “Baton”?").firstMatch
            if prompt.waitForExistence(timeout: 2), prompt.buttons["Open"].isHittable {
                prompt.buttons["Open"].tap()
                break
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["command": "verify"])
        let (confirmedBytes, confirmedResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((confirmedResponse as? HTTPURLResponse)?.statusCode, 200)
        let confirmed = try XCTUnwrap(JSONSerialization.jsonObject(with: confirmedBytes) as? [String: Any])
        XCTAssertEqual(confirmed["accepted"] as? Bool, true)
        XCTAssertEqual(confirmed["pid"] as? Int, receipt["pid"] as? Int,
            "accepting OS consent must preserve the original app process")
    }
    private func incoming(_ index: Int = 0) async throws {
        try await deliver(index == 0 ? "A" : "B")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "incomingShare.sheet").firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Incoming Fixture " + (index == 0 ? "A" : "B")].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Private note " + (index == 0 ? "A" : "B")].exists)
        capture("opened-\(index)")
    }
    private func closeIncoming() {
        app.navigationBars["Shared with you"].buttons["Done"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "incomingShare.sheet").firstMatch.waitForNonExistence(timeout: 10))
    }
    private func report() async throws -> [String: Any] {
        let base = try XCTUnwrap(environment["INCOMING_SHARE_BASE"])
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/v1/share/admin/stats")))
        request.timeoutInterval = 10
        request.setValue("Bearer " + (try XCTUnwrap(environment["INCOMING_SHARE_ADMIN"])), forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func settings() {
        app.tabBars.buttons["Home"].tap(); app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 10))
    }
    private func visibleButton(_ label: String) -> XCUIElement {
        let button = app.buttons[label].firstMatch
        for _ in 0..<12 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable); return button
    }
    func testSettingsNestedHelpAndAlertPreserveUnderlyingState() async throws {
        try launch(); settings(); try await incoming(); closeIncoming()
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.isHittable)
        visibleButton("Help & FAQ").tap()
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout: 10))
        try await incoming(); closeIncoming()
        XCTAssertTrue(app.navigationBars["Help"].exists)
        capture("underlying-help-preserved")
        app.navigationBars["Help"].buttons["Done"].tap()
        // A stable confirmation must remain until the person cancels it.
        for _ in 0..<12 where !app.buttons["Disconnect…"].firstMatch.isHittable { app.swipeDown() }
        visibleButton("Disconnect…").tap()
        let disconnect = app.buttons["Disconnect"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 10))
        try await deliver("A"); capture("alert-delays-incoming")
        XCTAssertTrue(disconnect.exists, "incoming delivery must preserve the confirmation")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "incomingShare.sheet").firstMatch.exists)
        // iOS may present this confirmation as a popover with implicit outside
        // cancellation. Its upper-left backdrop is outside the measured popover
        // and away from every destructive choice; never select Disconnect.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.20)).tap() }
        XCTAssertTrue(disconnect.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Incoming Fixture A"].waitForExistence(timeout: 15))
        closeIncoming(); XCTAssertTrue(app.staticTexts["Settings"].firstMatch.isHittable)
    }
    func testDraftSupersessionBackgroundAndPlaybackReaction() async throws {
        let before = try await report()
        try launch()
        app.tabBars.buttons["Search"].tap()
        let search = app.textFields["SearchField"]; XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Synthetic Incoming\n")
        let song = app.staticTexts["Synthetic Incoming Library Song"].firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 30)); song.press(forDuration: 1)
        app.buttons["Share…"].tap()
        XCTAssertTrue(app.buttons["share-create-link"].waitForExistence(timeout: 10))
        let note = app.textFields["Add a note (optional)"].firstMatch
        note.tap(); note.typeText("Unsent local draft")
        try await incoming(); try await incoming(1); try await incoming()
        // Same share ID with a different canonical key must replace decrypted private content.
        try await deliver("wrongA")
        XCTAssertTrue(app.staticTexts["incomingShare.failure"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Private note A"].exists)
        capture("changed-key-clears-private-content")
        try await incoming()
        let receiver = app.descendants(matching: .any).matching(identifier: "incomingShare.sheet").firstMatch
        XCTAssertTrue(receiver.exists)
        XCTAssertFalse(receiver.staticTexts["Incoming Fixture B"].exists,
            "superseded content must be absent from the receiver, independent of underlying catalog rows")
        let play = app.buttons["incomingShare.play"]
        play.tap()
        let running = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[1-9][0-9]* / [0-9]+ seconds")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 15), "actual decrypted native playback clock must advance")
        capture("native-clock-moving")
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertEqual(play.label, "Play", "backgrounding must stop incoming output")
        let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ / [0-9]+ seconds")).firstMatch
        let stoppedPosition = clock.label
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(clock.label, stoppedPosition, "incoming playback clock must stay stopped after background/foreground")
        capture("background-stopped-clock")
        play.tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 45), "30 actual listened seconds must unlock reaction")
        capture("thirty-seconds-listened")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["incomingShare.sent"].waitForExistence(timeout: 15))
        let after = try await report()
        let listeningBefore = try XCTUnwrap(before["listening"] as? [String: Any])
        let listeningAfter = try XCTUnwrap(after["listening"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(listeningAfter["playsStarted"] as? Int) - (try XCTUnwrap(listeningBefore["playsStarted"] as? Int)), 1)
        XCTAssertEqual(try XCTUnwrap(listeningAfter["listened30s"] as? Int) - (try XCTUnwrap(listeningBefore["listened30s"] as? Int)), 1)
        let engagementBefore = try XCTUnwrap(before["engagement"] as? [String: Any])
        let engagementAfter = try XCTUnwrap(after["engagement"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(engagementAfter["reactions"] as? Int) - (try XCTUnwrap(engagementBefore["reactions"] as? Int)), 1)
        let state = XCTAttachment(data: try JSONSerialization.data(withJSONObject: after, options: .prettyPrinted), uniformTypeIdentifier: "public.json")
        state.name = "incoming-service-listening-reaction-state"; state.lifetime = .keepAlways; add(state)
        closeIncoming()
        XCTAssertTrue(app.buttons["share-create-link"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "Unsent local draft")).firstMatch.exists)
        capture("unsent-draft-preserved")
        app.buttons["Cancel"].tap()
        try await incoming(); XCTAssertEqual(app.buttons["incomingShare.play"].label, "Play")
        closeIncoming()
    }
    func testFindMyLibraryPrefersRecordingAndKeepsTextCopiesAmbiguous() async throws {
        try launch()
        try await incoming(1)
        app.buttons["incomingShare.find"].tap()
        XCTAssertTrue(app.staticTexts["Choose your copy of this song:"].waitForExistence(timeout: 15))
        let copies = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play Incoming Fixture B from my library"))
        XCTAssertEqual(copies.count, 2, "both title/artist copies must be choices; never silently choose one")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fallback Copy One")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fallback Copy Two")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["NowPlayingBar"].exists, "Find must not start library playback")
        capture("title-artist-copies-remain-ambiguous")
        closeIncoming()
        try await incoming()
        app.buttons["incomingShare.play"].tap()
        let running = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[1-9][0-9]* / [0-9]+ seconds")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 15))
        app.buttons["incomingShare.find"].tap()
        let identity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play Identity Different Title from my library")).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 15), "recording identity must win even though displayed title differs")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play Incoming Fixture A from my library")).firstMatch.exists,
            "same-text song with a known different recording must not be chosen")
        XCTAssertFalse(app.descendants(matching: .any)["NowPlayingBar"].exists)
        capture("recording-identity-preferred-before-explicit-choice")
        identity.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "incomingShare.sheet").firstMatch.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["NowPlayingBar"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Identity Different Title"].firstMatch.exists)
        capture("explicit-library-handoff-selected-recording")
    }
    func testIncomingAboveSetupCoverPreservesTypedServer() async throws {
        try launch(connected: false)
        let server = app.textFields["https://music.example.com"]
        // The setup Form lazily exposes this field below its introductory sections.
        // Scroll before requiring existence, then require the actual source placeholder.
        for _ in 0..<8 where !server.exists || !server.isHittable { app.swipeUp() }
        XCTAssertTrue(server.exists)
        XCTAssertTrue(server.isHittable); server.tap(); server.typeText("http://127.0.0.1:1")
        try await incoming(); closeIncoming()
        XCTAssertEqual(server.value as? String, "http://127.0.0.1:1")
        capture("setup-draft-preserved")
    }
}
