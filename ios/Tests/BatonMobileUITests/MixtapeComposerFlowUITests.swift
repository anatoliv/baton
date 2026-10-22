import BatonShareKit
import Foundation
import XCTest

/// Real app selection and upload against fresh local Navidrome/service fixtures.
/// No demo rows, owner's library, clipboard writes or fake playback-success path.
@MainActor
final class MixtapeComposerFlowUITests: XCTestCase {
    private let titles = ["Mixtape Fixture A", "Mixtape Fixture B", "Mixtape Fixture C"]
    private var app: XCUIApplication!
    private var base: URL!
    private var controlToken = ""
    private var initialLaunchPID: Int?
    private func launch() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MIXTAPE_COMPOSER_FLOW_TESTS"] == "1", "Requires the owned loopback composer harness")
        base = try XCTUnwrap(URL(string: try XCTUnwrap(env["MIXTAPE_COMPOSER_BASE"])))
        controlToken = try XCTUnwrap(env["MIXTAPE_COMPOSER_CONTROL_TOKEN"])
        app = XCUIApplication.batonUnderTest()
        let nonce = UUID().uuidString
        app.launchEnvironment["baton.launchProbe"] = nonce
        app.launchEnvironment["baton.defaultsSuite"] = "io.tonebox.tests.mixtape." + UUID().uuidString
        app.launchEnvironment["baton.share.baseURL"] = base.absoluteString
        for (key, fixture) in [("uitestServer", "MIXTAPE_COMPOSER_NAV_URL"),
                               ("uitestUser", "MIXTAPE_COMPOSER_NAV_USER"),
                               ("uitestSecret", "MIXTAPE_COMPOSER_NAV_SECRET")] {
            app.launchEnvironment[key] = try XCTUnwrap(env[fixture])
        }
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["uitestSkipSpeechAuthorization"] = "1"
        app.launch()
        let probe = app.staticTexts["debug.launchEnvironmentProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15)); XCTAssertEqual(probe.label, nonce)
        if env["MIXTAPE_UI_WALKS"] == "1" {
            let identity = app.staticTexts["debug.launchProcessID"]
            XCTAssertTrue(identity.waitForExistence(timeout: 5))
            initialLaunchPID = try XCTUnwrap(Int(identity.label))
            XCTAssertGreaterThan(try XCTUnwrap(initialLaunchPID), 0)
        }
        if app.navigationBars["What's New"].waitForExistence(timeout: 5) { app.buttons["Done"].tap() }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 30))
    }
    private func control(_ body: [String: Bool]? = nil) async throws -> [String: Int] {
        var request = URLRequest(url: base.appendingPathComponent("_baton_mixtape_fixture"))
        request.timeoutInterval = 5
        request.setValue("Bearer " + controlToken, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try ["creates", "tracks", "finalizes"].reduce(into: [:]) { result, key in
            result[key] = try XCTUnwrap(object[key] as? Int)
        }
    }
    private func selectAllIntoDraft() {
        app.tabBars.buttons["Library"].tap()
        app.buttons["Liked"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Liked"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[titles[0]].firstMatch.waitForExistence(timeout: 30))
        app.buttons["Sort"].tap()
        app.buttons["Title"].tap()
        app.buttons["Select"].tap()
        for title in titles { app.staticTexts[title].firstMatch.tap() }
        app.buttons["Share…"].tap()
        XCTAssertTrue(app.navigationBars["Share Songs"].waitForExistence(timeout: 10))
        for (index, title) in titles.enumerated() {
            XCTAssertTrue(track(index).label.hasPrefix("\(index + 1). \(title)"))
            XCTAssertEqual(track(index).value as? String, "1", "every track starts switched on")
        }
    }
    /// The composer's per-track switch, by position. Its label starts "<n>. <title>" (then the
    /// artist and duration), and <n> follows the position after a move.
    private var resultLink: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "collection-share-result-link").firstMatch
    }
    private func track(_ index: Int) -> XCUIElement { app.switches["collection-share-track-\(index)"] }
    /// Replaces the suggested title, whatever the composer suggested for these fixtures.
    private func retitle(_ field: XCUIElement) {
        let suggested = (field.value as? String) ?? ""
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: suggested.count) + "Ordered Fixture\n")
    }
    private func draft() {
        selectAllIntoDraft()
        app.buttons["Move Mixtape Fixture C up"].tap()
        app.buttons["Move Mixtape Fixture C up"].tap()
        // The composer has no Remove: a track leaves by switching it off. A tap on the row's
        // middle lands on its title and leaves the switch on, so tap the switch itself, as the
        // other phone UI tests do.
        let knob = track(2).switches.firstMatch
        (knob.exists ? knob : track(2)).tap()
        XCTAssertTrue(track(0).label.hasPrefix("1. Mixtape Fixture C"))
        XCTAssertTrue(track(1).label.hasPrefix("2. Mixtape Fixture A"))
        XCTAssertTrue(track(2).label.hasPrefix("3. Mixtape Fixture B"))
        XCTAssertEqual(track(2).value as? String, "0")
        // Both privacy switches start off for a mixtape route; the Form builds its lower sections
        // lazily, so each is scrolled into view before it is read.
        let preview = app.switches["collection-share-public-preview"]
        reveal(preview, swipingUp: true)
        XCTAssertEqual(preview.value as? String, "0")
        let preservation = app.switches["collection-share-review-preservation"]
        reveal(preservation, swipingUp: true)
        XCTAssertEqual(preservation.value as? String, "0")
        let disclosure = app.descendants(matching: .any).matching(identifier: "collection-share-disclosure").firstMatch
        reveal(disclosure, swipingUp: true)
        let field = app.textFields["collection-share-title"]
        reveal(field, swipingUp: false)
        retitle(field)
    }
    private func reveal(_ element: XCUIElement, swipingUp: Bool, existenceTimeout: TimeInterval = 5) {
        // Grouped Form sections are lazy. Exercise the same bounded scrolling a
        // person uses to read the disclosure, rather than asserting offscreen content.
        for _ in 0..<3 {
            if element.exists && element.isHittable { break }
            if swipingUp { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: existenceTimeout))
        XCTAssertTrue(element.isHittable)
    }
    private func createdManifest(expectedTitles: [String]? = nil) async throws -> ShareMixtapeManifest {
        let link = resultLink
        XCTAssertTrue(link.waitForExistence(timeout: 90), "The real ordered upload did not finish")
        // Never include the fragment in assertion messages, screenshots or receipts.
        let parts = try XCTUnwrap(URLComponents(string: link.label))
        XCTAssertTrue(parts.scheme == "http" && parts.host == "127.0.0.1" && parts.port == base.port)
        XCTAssertTrue(parts.path.hasPrefix("/m/") && parts.query == nil)
        let id = String(parts.path.dropFirst(3)), key = parts.fragment.flatMap(Base64URL.decode)
        XCTAssertTrue(ShareLink.isValidID(id)); XCTAssertTrue(key?.count == 16)
        let receiver = try ShareMixtapeReceiver(base: base)
        let details = try await receiver.details(.init(id: id, key: key, kind: .mixtape))
        XCTAssertEqual(details.manifest.title, "Ordered Fixture")
        XCTAssertEqual(details.manifest.tracks.map(\.metadata.title), expectedTitles ?? [titles[2], titles[0]])
        XCTAssertNil(details.share.preview)
        return details.manifest
    }
    func testSelectionOrderingRemovalAndPrivateConsentCreateOneContainer() async throws {
        try launch(); defer { app.terminate() }
        let before = try await control(["release": true])
        draft()
        let editing = try await control(); XCTAssertEqual(editing["creates"], before["creates"])
        app.buttons["collection-share-create-link"].tap()
        _ = try await createdManifest()
        let after = try await control()
        XCTAssertEqual(after["creates"], (before["creates"] ?? 0) + 1)
        XCTAssertEqual(after["tracks"], (before["tracks"] ?? 0) + 2)
        XCTAssertEqual(after["finalizes"], (before["finalizes"] ?? 0) + 1)
    }
    func testInterruptedUploadFreezesDraftAndExplicitRetryKeepsOneContainer() async throws {
        try launch(); defer { app.terminate() }
        let before = try await control(["loseFinalization": true])
        draft(); app.buttons["collection-share-create-link"].tap()
        let retry = app.buttons["collection-share-create-link"]
        let interrupted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "collection-share-failure", "Upload interrupted.")).firstMatch
        reveal(interrupted, swipingUp: true, existenceTimeout: 90)
        XCTAssertEqual(retry.label, "Retry Upload")
        XCTAssertFalse(app.textFields["collection-share-title"].isEnabled)
        let move = app.buttons["Move Mixtape Fixture C down"]
        reveal(move, swipingUp: false)
        XCTAssertFalse(move.isEnabled)
        let toggle = track(1)
        reveal(toggle, swipingUp: true)
        XCTAssertFalse(toggle.isEnabled)
        let pending = try await control(); XCTAssertEqual(pending["creates"], (before["creates"] ?? 0) + 1)
        _ = try await control(["release": true])
        reveal(retry, swipingUp: false)
        retry.tap(); _ = try await createdManifest()
        let after = try await control(); XCTAssertEqual(after["creates"], (before["creates"] ?? 0) + 1)
        XCTAssertEqual(after["finalizes"], pending["finalizes"])
    }
    func testExactlyTwentyMinutesCreatesOneOrderedContainer() async throws {
        try launch(); defer { app.terminate() }
        let before = try await control(["release": true])
        selectAllIntoDraft()
        let editing = try await control(); XCTAssertEqual(editing["creates"], before["creates"])
        retitle(app.textFields["collection-share-title"])
        app.buttons["collection-share-create-link"].tap()
        let manifest = try await createdManifest(expectedTitles: titles)
        XCTAssertEqual(manifest.tracks.map(\.metadata.durationSeconds), [400, 400, 400])
        let after = try await control()
        XCTAssertEqual(after["creates"], (before["creates"] ?? 0) + 1)
        XCTAssertEqual(after["tracks"], (before["tracks"] ?? 0) + 3)
        XCTAssertEqual(after["finalizes"], (before["finalizes"] ?? 0) + 1)
    }

    // These two selectors require a separately qualified UI controller. The
    // composer-only caller must not admit them using its narrower fixture.
    private func uiControl(_ command: String, link: String? = nil, initialPID: Int? = nil) async throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MIXTAPE_UI_WALKS"] == "1", "Requires the dedicated owned mixtape UI controller")
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(env["MIXTAPE_UI_CONTROL_URL"])))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertTrue(parts.scheme == "http" && parts.host == "127.0.0.1" && parts.port != nil &&
            parts.path == "/mixtape-ui" && parts.query == nil && parts.fragment == nil && parts.user == nil)
        var request = URLRequest(url: url); request.timeoutInterval = 15; request.httpMethod = "POST"
        request.setValue("Bearer " + (try XCTUnwrap(env["MIXTAPE_UI_CONTROL_TOKEN"])), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["command": command]
        if let link { body["url"] = link }
        if let initialPID { body["pid"] = initialPID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(receipt["accepted"] as? Bool, true)
        return receipt
    }
    private func bindLaunchedApp() async throws {
        let initialPID = try XCTUnwrap(initialLaunchPID)
        let bound = try await uiControl("bindLaunch", initialPID: initialPID)
        XCTAssertEqual(bound["pid"] as? Int, initialPID)
    }
    private func uiCreated(preservation: Bool = false) async throws -> ShareInvitation {
        _ = try await uiControl("stats") // Refuse/skip before creating when the required seam is absent.
        draft()
        if preservation {
            let consent = app.switches["collection-share-review-preservation"]
            reveal(consent, swipingUp: true)
            // Tap the switch itself; a tap on the row's middle lands on its label (as for track(2)).
            let knob = consent.switches.firstMatch
            (knob.exists ? knob : consent).tap()
            XCTAssertEqual(consent.value as? String, "1")
        }
        app.buttons["collection-share-create-link"].tap(); _ = try await createdManifest()
        let parts = try XCTUnwrap(URLComponents(string: resultLink.label))
        let key = try XCTUnwrap(parts.fragment.flatMap(Base64URL.decode))
        let invitation = ShareInvitation(id: String(parts.path.dropFirst(3)), key: key, kind: .mixtape)
        _ = try await uiControl("register", link: invitation.url(base: base).absoluteString)
        // Never capture or attach the composer result: it displays the fragment.
        app.navigationBars["Share Songs"].buttons["Done"].tap()
        return invitation
    }
    private func uiDeliver(_ command: String) async throws {
        let receipt = try await uiControl(command)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for application in [springboard, app!] {
            let prompt = application.alerts.containing(.staticText, identifier: "Open in “Baton”?").firstMatch
            if prompt.waitForExistence(timeout: 2), prompt.buttons["Open"].isHittable {
                prompt.buttons["Open"].tap(); break
            }
        }
        let verified = try await uiControl("verify")
        XCTAssertEqual(verified["pid"] as? Int, receipt["pid"] as? Int,
            "OS delivery and consent must preserve the isolated original app")
    }
    private var mixtapeSheet: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "incomingMixtape.sheet").firstMatch
    }
    private func uiReady() {
        XCTAssertTrue(mixtapeSheet.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["incomingMixtape.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["incomingMixtape.play"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["incomingMixtape.title"].label, "Ordered Fixture")
        XCTAssertTrue(app.buttons["incomingMixtape.track.0"].label.contains("1. Mixtape Fixture C"))
        XCTAssertTrue(app.buttons["incomingMixtape.track.1"].label.contains("2. Mixtape Fixture A"))
        XCTAssertEqual(app.buttons["incomingMixtape.play"].label, "Play")
        XCTAssertEqual(app.buttons["incomingMixtape.browser"].label, "Open in browser")
    }
    private func uiCapture(_ name: String) {
        let pixels = XCTAttachment(screenshot: app.screenshot()); pixels.name = name
        pixels.lifetime = .keepAlways; add(pixels)
    }
    private func uiClose() {
        app.navigationBars["Shared mixtape"].buttons["Done"].tap()
        XCTAssertTrue(mixtapeSheet.waitForNonExistence(timeout: 10))
    }
    private func uiFailure(_ text: String) {
        let failure = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "incomingMixtape.failure", text)).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["incomingMixtape.title"].exists)
        XCTAssertFalse(app.buttons["incomingMixtape.play"].exists)
    }
    private func sharedLinks() {
        app.tabBars.buttons["Home"].tap(); app.buttons["Settings"].tap()
        let links = app.buttons["Shared Links"].firstMatch
        for _ in 0..<12 where !links.isHittable { app.swipeUp() }
        XCTAssertTrue(links.isHittable); links.tap()
        XCTAssertTrue(app.navigationBars["Shared Links"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Ordered Fixture"].firstMatch.waitForExistence(timeout: 15))
    }
    private func containerAction(_ title: String) -> XCUIElement {
        app.staticTexts["Ordered Fixture"].firstMatch.press(forDuration: 1)
        let action = app.buttons[title].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5)); return action
    }
    func testMixtapeRecipientOrderedControlsBackgroundAndAccessibleFailures() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIXTAPE_UI_WALKS"] == "1", "Requires the dedicated owned mixtape UI controller")
        _ = try await uiControl("beginLaunch")
        try launch(); defer { app.terminate() }
        try await bindLaunchedApp()
        _ = try await uiCreated(); try await uiDeliver("ready"); uiReady()
        XCTAssertFalse(app.buttons["incomingMixtape.previous"].isEnabled)
        XCTAssertTrue(app.buttons["incomingMixtape.next"].isEnabled)
        app.buttons["incomingMixtape.next"].tap()
        XCTAssertTrue(app.buttons["incomingMixtape.previous"].isEnabled)
        XCTAssertFalse(app.buttons["incomingMixtape.next"].isEnabled)
        app.buttons["incomingMixtape.previous"].tap()
        app.buttons["incomingMixtape.track.1"].tap()
        XCTAssertFalse(app.buttons["incomingMixtape.next"].isEnabled)
        app.buttons["incomingMixtape.track.0"].tap()
        app.buttons["incomingMixtape.play"].tap()
        let advancing = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label MATCHES %@",
            "incomingMixtape.clock", "[1-9][0-9]* / [0-9]+ seconds")).firstMatch
        XCTAssertTrue(advancing.waitForExistence(timeout: 15), "The real AV playback clock must move")
        XCTAssertEqual(app.buttons["incomingMixtape.play"].label, "Pause")
        app.buttons["incomingMixtape.play"].tap()
        let stopped = app.staticTexts["incomingMixtape.clock"].label
        try await Task.sleep(for: .seconds(1)); XCTAssertEqual(app.staticTexts["incomingMixtape.clock"].label, stopped)
        XCTAssertEqual(app.sliders["incomingMixtape.seek"].label, "Track position")
        app.sliders["incomingMixtape.seek"].adjust(toNormalizedSliderPosition: 0.25)
        uiCapture("mixtape-real-controls-accessible")
        app.buttons["incomingMixtape.play"].tap()
        XCUIDevice.shared.press(.home); app.activate(); uiReady()
        XCTAssertFalse(app.staticTexts["incomingMixtape.clock"].exists,
            "Backgrounding must evict the plaintext track before a new explicit Play")
        try await uiDeliver("wrong")
        uiFailure("This mixtape could not be opened. Ask your friend to share it again.")
        uiCapture("mixtape-authentication-failure-clears-content")
        try await uiDeliver("incomplete")
        uiFailure("This mixtape link is incomplete. Ask your friend to send the full link again.")
        try await uiDeliver("unknown")
        uiFailure("This mixtape link could not be found.")
        try await uiDeliver("pending")
        XCTAssertTrue(app.staticTexts["This mixtape is still arriving."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertFalse(app.buttons["incomingMixtape.play"].exists)
        uiCapture("mixtape-pending-accessible"); uiClose()
    }
    func testMixtapeSharedLinksRefreshExtendReviewRevokeAndForget() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIXTAPE_UI_WALKS"] == "1", "Requires the dedicated owned mixtape UI controller")
        _ = try await uiControl("beginLaunch")
        try launch(); defer { app.terminate() }
        try await bindLaunchedApp()
        let before = try await uiControl("stats")
        let invitation = try await uiCreated(preservation: true)
        let receiver = try ShareMixtapeReceiver(base: base)
        let initial = try await receiver.details(invitation)
        try await uiDeliver("ready"); uiReady(); app.buttons["incomingMixtape.play"].tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 25),
            "Finishing a real short fixture track must unlock the actual reaction UI")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["incomingMixtape.sent"].waitForExistence(timeout: 15))
        uiClose(); sharedLinks()
        XCTAssertTrue(app.staticTexts["2 tracks · Sessions 1 · Played 1"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["❤️ Someone"].waitForExistence(timeout: 15))
        let counters = try await uiControl("stats")
        XCTAssertEqual(counters["playsStarted"] as? Int, (before["playsStarted"] as? Int).map { $0 + 1 })
        XCTAssertEqual(counters["reactions"] as? Int, (before["reactions"] as? Int).map { $0 + 1 })
        containerAction("Extend 7 Days").tap()
        var extended = initial
        for _ in 0..<10 {
            extended = try await receiver.details(invitation)
            if extended.share.expiresAt != initial.share.expiresAt { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertEqual(try XCTUnwrap(ShareDate.date(extended.share.expiresAt)).timeIntervalSince(
            try XCTUnwrap(ShareDate.date(initial.share.expiresAt))), 7 * 86400, accuracy: 2)
        _ = try await uiControl("hold"); app.swipeDown()
        XCTAssertTrue(app.staticTexts["Disabled for review"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Review deadline:")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Paused link lifetime:")).firstMatch.exists)
        XCTAssertFalse(containerAction("Extend 7 Days").isEnabled)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).tap()
        uiCapture("mixtape-held-owner-container")
        do { _ = try await receiver.details(invitation); XCTFail("Held container must deny recipient details") }
        catch let failure as ShareMixtapeReceiver.Failure { XCTAssertEqual(failure, .expired) }
        try await uiDeliver("ready")
        uiFailure("This mixtape link has ended. Ask your friend to share it again."); uiClose()
        containerAction("Revoke").tap()
        let confirmation = app.buttons["Revoke"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
        XCTAssertTrue(app.staticTexts["Revoked"].waitForExistence(timeout: 15))
        do { _ = try await receiver.details(invitation); XCTFail("Revoked container must remain unavailable") }
        catch let failure as ShareMixtapeReceiver.Failure { XCTAssertEqual(failure, .expired) }
        uiCapture("mixtape-revoked-owner-container")
        containerAction("Remove from List").tap()
        XCTAssertTrue(app.staticTexts["Ordered Fixture"].firstMatch.waitForNonExistence(timeout: 10))
    }
}
