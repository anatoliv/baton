import Foundation
import XCTest

/// Release smoke walk for the sharing features merged on 2026-10-16: a received
/// song, a mixtape composed and received, and the dormant reaction-push opt-in. Opt-in only,
/// against loopback stand-ins: a throwaway Navidrome and the `baton-share-fixture` service.
/// Never an owner account, a real share service, Apple push or a person.
///
/// Environment (passed to the runner as TEST_RUNNER_*): BATON_SHARED_SMOKE=1, SMOKE_SHARE_BASE
/// (the fixture, http://127.0.0.1:port), SMOKE_DEAD_BASE (a loopback port nothing listens on),
/// SMOKE_SONG_LINK (a baton://share link seeded into the fixture) and SMOKE_NAV_URL,
/// SMOKE_NAV_USER, SMOKE_NAV_SECRET for the throwaway Navidrome, whose liked songs include
/// "Smoke Track 1" and "Smoke Track 2".
@MainActor
final class SharedFeaturesSmokeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["BATON_SHARED_SMOKE"] == "1", "requires the loopback sharing stand-ins")
        let smokeApp = XCUIApplication()
        app = smokeApp
        addTeardownBlock { @MainActor [smokeApp] in
            XCTContext.runActivity(named: "smoke-final") { activity in
                let pixels = XCTAttachment(screenshot: smokeApp.screenshot())
                pixels.name = "smoke-final"
                pixels.lifetime = .keepAlways
                activity.add(pixels)
            }
            smokeApp.terminate()
        }
        // Never let a test instance write to the owner's synced preferences.
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["baton.defaultsSuite"] = "io.tonebox.tests.smoke." + UUID().uuidString
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["uitestSkipSpeechAuthorization"] = "1"
        for (key, source) in [("uitestServer", "SMOKE_NAV_URL"), ("uitestUser", "SMOKE_NAV_USER"), ("uitestSecret", "SMOKE_NAV_SECRET")] {
            app.launchEnvironment[key] = try XCTUnwrap(environment[source])
        }
    }

    private func launch(shareBase key: String) throws {
        app.launchEnvironment["baton.share.baseURL"] = try XCTUnwrap(environment[key])
        app.launch()
        if app.navigationBars["What's New"].waitForExistence(timeout: 5) { app.buttons["Done"].tap() }
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 30))
    }

    private func capture(_ name: String) {
        let pixels = XCTAttachment(screenshot: app.screenshot())
        pixels.name = "smoke-" + name
        pixels.lifetime = .keepAlways
        add(pixels)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func songLink() throws -> URL { try XCTUnwrap(URL(string: try XCTUnwrap(environment["SMOKE_SONG_LINK"]))) }

    /// Liked → Select → two songs → Share Mixtape, as a listener would.
    private func openComposer() {
        app.tabBars.buttons["Library"].tap()
        app.buttons["Liked"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Smoke Track 1"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["Select"].tap()
        app.staticTexts["Smoke Track 1"].firstMatch.tap()
        app.staticTexts["Smoke Track 2"].firstMatch.tap()
        app.buttons["Share Mixtape"].tap()
        XCTAssertTrue(app.navigationBars["Share Mixtape"].waitForExistence(timeout: 10))
    }

    func testReceivedSongOpensAndPlays() throws {
        try launch(shareBase: "SMOKE_SHARE_BASE")
        app.open(try songLink())
        XCTAssertTrue(element("incomingShare.sheet").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Incoming Fixture A"].waitForExistence(timeout: 20))
        capture("song-opened")
        let play = element("incomingShare.play")
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        sleep(4)
        capture("song-playing")
        XCTAssertFalse(element("incomingShare.failure").exists, "a playable song must not show a failure")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testReceivedSongSaysSoWhenTheServiceIsUnreachable() throws {
        try launch(shareBase: "SMOKE_DEAD_BASE")
        app.open(try songLink())
        XCTAssertTrue(element("incomingShare.sheet").waitForExistence(timeout: 20))
        let failure = element("incomingShare.failure")
        XCTAssertTrue(failure.waitForExistence(timeout: 30), "an unreachable service must be said plainly, not spin")
        XCTAssertEqual(failure.label, "The song could not be reached. Check your connection and try again.")
        capture("song-unreachable")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testMixtapeComposedAndReceived() throws {
        try launch(shareBase: "SMOKE_SHARE_BASE")
        openComposer()
        let create = app.buttons["mixtape-create-link"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: create)
        waitForExpectations(timeout: 20)
        create.tap()
        let result = element("mixtape.result-link")
        XCTAssertTrue(result.waitForExistence(timeout: 90), "the mixtape must upload to the loopback service")
        capture("mixtape-created")
        // The fixture hands back an http://127.0.0.1 link; Baton opens the same id and key
        // through its own scheme.
        let link = try XCTUnwrap(URLComponents(string: result.label))
        let id = try XCTUnwrap(link.path.split(separator: "/").last)
        let key = try XCTUnwrap(link.fragment)
        app.navigationBars["Share Mixtape"].buttons["Done"].tap()
        app.open(try XCTUnwrap(URL(string: "baton://mixtape/\(id)#\(key)")))
        XCTAssertTrue(element("incomingMixtape.sheet").waitForExistence(timeout: 20))
        XCTAssertTrue(element("incomingMixtape.title").waitForExistence(timeout: 30))
        XCTAssertFalse(element("incomingMixtape.failure").exists)
        capture("mixtape-received")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testMixtapeComposerSaysSoWhenTheServiceIsUnreachable() throws {
        try launch(shareBase: "SMOKE_DEAD_BASE")
        openComposer()
        // Create Link stays disabled, and the form's last section says why.
        sleep(3)
        XCTAssertFalse(app.buttons["mixtape-create-link"].isEnabled, "Create Link must not offer an upload that cannot work")
        let unavailable = app.staticTexts["Mixtape sharing is unavailable until the service supports it."]
        for _ in 0..<8 where !unavailable.exists { app.swipeUp() }
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        capture("mixtape-unreachable")
        app.navigationBars["Share Mixtape"].buttons["Cancel"].tap()
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testReactionNotificationsStayDormant() throws {
        try launch(shareBase: "SMOKE_SHARE_BASE")
        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].tap()
        // The row's label carries its value too ("Shared Links, None").
        let links = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Shared Links'")).firstMatch
        for _ in 0..<12 where !links.exists { app.swipeUp() }
        XCTAssertTrue(links.waitForExistence(timeout: 10))
        links.tap()
        XCTAssertTrue(app.navigationBars["Shared Links"].waitForExistence(timeout: 10))
        sleep(2)
        // No shipping build supplies the reviewed APNs activation, so the opt-in never appears
        // and nothing registers with Apple.
        XCTAssertFalse(app.switches["Notify me about reactions"].exists)
        XCTAssertFalse(app.staticTexts["Notify me about reactions"].exists)
        capture("shared-links")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
