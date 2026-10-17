import Foundation
import XCTest

/// Runs against a private local Navidrome and share service, on a fresh simulator.
/// The fixture variables come from the test runner's private generated scheme, never argv.
@MainActor
final class SongSharingFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shareBase = ""
    private var adminToken = ""
    private var operatorToken = ""
    private let title = "iPhone Sharing Probe Song"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SONG_SHARING_FLOW_TESTS"] == "1", "requires isolated local song-sharing fixtures")
        shareBase = try XCTUnwrap(env["SONG_SHARING_SHARE_URL"])
        adminToken = try XCTUnwrap(env["SONG_SHARING_ADMIN_TOKEN"])
        operatorToken = env["SONG_SHARING_OPERATOR_TOKEN"] ?? ""
        app = XCUIApplication.batonUnderTest()
        app.terminate()
        let launchNonce = UUID().uuidString
        app.launchEnvironment["baton.launchProbe"] = launchNonce
        app.launchEnvironment["baton.defaultsSuite"] = "io.tonebox.tests.sharing." + UUID().uuidString
        app.launchEnvironment["baton.share.baseURL"] = shareBase
        app.launchEnvironment["uitestServer"] = try XCTUnwrap(env["SONG_SHARING_NAV_URL"])
        app.launchEnvironment["uitestUser"] = try XCTUnwrap(env["SONG_SHARING_NAV_USER"])
        app.launchEnvironment["uitestSecret"] = try XCTUnwrap(env["SONG_SHARING_NAV_SECRET"])
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["uitestSkipSpeechAuthorization"] = "1"
        app.launch()
        let launchProbe = app.staticTexts["debug.launchEnvironmentProbe"]
        XCTAssertTrue(launchProbe.waitForExistence(timeout: 15))
        XCTAssertEqual(launchProbe.label, launchNonce, "XCUITest did not deliver the isolated fixture environment to the app")
        if app.navigationBars["What's New"].waitForExistence(timeout: 5) {
            app.buttons["Done"].tap()
        }
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 30))
    }

    override func tearDown() {
        if let app {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "TBX-8679-final-state"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app?.terminate()
        super.tearDown()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TBX-8679-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        let draft = app.staticTexts["debug.shareDraft"]
        if draft.exists {
            let state = XCTAttachment(string: draft.label)
            state.name = "TBX-8679-" + name + "-state"
            state.lifetime = .keepAlways
            add(state)
        }
    }

    private func searchSong() {
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["SearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("iPhone Sharing\n")
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 30))
    }

    private func openRowComposer() {
        app.staticTexts[title].firstMatch.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Share…"].waitForExistence(timeout: 10))
        app.buttons["Share…"].tap()
        XCTAssertTrue(app.buttons["share-create-link"].waitForExistence(timeout: 10))
    }

    private func setFields(privatePreview: Bool) {
        let note = app.textFields["Add a note (optional)"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        let expectedNote = privatePreview ? "Private fixture note" : "Public fixture note"
        note.typeText(expectedNote)
        // SwiftUI's vertical TextField becomes a TextView after the first character.
        // Query its current value across both types instead of reusing its old placeholder.
        let enteredNote = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", expectedNote)).firstMatch
        XCTAssertTrue(enteredNote.exists)
        let from = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Your name")).firstMatch
        XCTAssertTrue(from.exists)
        from.tap()
        from.typeText("iPhone Probe\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Return must commit the single-line sender field and dismiss the keyboard")
        XCTAssertTrue(enteredNote.exists, "changing From must preserve the note")
        let toggle = app.switches["Show song details in link previews"]
        if privatePreview {
            let control = toggle.switches.firstMatch
            XCTAssertTrue(control.exists)
            control.tap()
        }
        XCTAssertEqual(toggle.value as? String, privatePreview ? "0" : "1")
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Link lasts")).firstMatch
        XCTAssertTrue(picker.exists)
        capture(privatePreview ? "private-before-expiry" : "public-before-expiry")
        // Hit the visible selected-value control, whose AX row also includes its label.
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let choice = app.buttons["1 day"]
        if !choice.waitForExistence(timeout: 5) { capture("expiry-control-did-not-open") }
        XCTAssertTrue(choice.exists)
        app.buttons["1 day"].tap()
        XCTAssertTrue(enteredNote.exists, "changing expiry must preserve the note")
        capture(privatePreview ? "private-composer" : "public-composer")
    }

    private func createLink() throws -> URL {
        app.buttons["share-create-link"].tap()
        let copy = app.buttons["Copy Link"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 90), "the actual fetch/encrypt/upload did not finish")
        let link = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", shareBase + "/s/")).firstMatch
        XCTAssertTrue(link.exists)
        let url = try XCTUnwrap(URL(string: link.label))
        XCTAssertNotNil(url.fragment, "a share needs its device-generated key in the fragment")
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
        capture("link-created-and-copied")
        return url
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         admin: Bool = false, operatorRequest: Bool = false) async throws -> (Data, Int) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: shareBase + path)))
        request.httpMethod = method
        request.timeoutInterval = 15
        if admin { request.setValue("Bearer " + adminToken, forHTTPHeaderField: "Authorization") }
        if operatorRequest { request.setValue("Bearer " + operatorToken, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
    }

    private func publicInfo(_ url: URL) async throws -> [String: Any] {
        let (data, status) = try await request("/v1/share/p/" + url.lastPathComponent)
        XCTAssertEqual(status, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertOneDayExpiry(_ info: [String: Any]) throws {
        let expiry = try XCTUnwrap(info["expiresAt"] as? String)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: expiry)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: expiry)
        }
        let remaining = try XCTUnwrap(date).timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 23 * 3600)
        XCTAssertLessThanOrEqual(remaining, 24 * 3600 + 60,
                                 "the selected one-day expiry must reach the actual service")
    }

    private func createdCount() async throws -> Int {
        let (data, status) = try await request("/v1/share/admin/stats", admin: true)
        XCTAssertEqual(status, 200)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((report["shares"] as? [String: Any])?["created"] as? Int)
    }

    private func finalizedCount() async throws -> Int {
        let (data, status) = try await request("/v1/share/admin/stats", admin: true)
        XCTAssertEqual(status, 200)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((report["shares"] as? [String: Any])?["finalized"] as? Int)
    }

    private func openSharedLinks() {
        app.buttons["Done"].firstMatch.tap()
        if app.buttons["Minimize player"].exists { app.buttons["Minimize player"].tap() }
        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let links = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shared Links")).firstMatch
        for _ in 0..<16 where !links.isHittable { app.swipeUp() }
        XCTAssertTrue(links.exists)
        links.tap()
        XCTAssertTrue(app.navigationBars["Shared Links"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    func testComposerCanCloseDuringPendingDurableUpload() async throws {
        let gate = try XCTUnwrap(ProcessInfo.processInfo.environment["SONG_SHARING_UPLOAD_GATE_URL"])
        XCTAssertEqual(gate, shareBase, "the pending-upload regression requires its private loopback gate")
        let releaseURL = try XCTUnwrap(URL(string: gate + "/_baton_probe_upload_gate"))
        addTeardownBlock {
            var release = URLRequest(url: releaseURL)
            release.httpMethod = "POST"
            release.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: release)
        }
        let before = try await createdCount()
        searchSong()
        openRowComposer()
        app.buttons["share-create-link"].tap()
        var entered = false
        for _ in 0..<100 {
            let (data, code) = try await request("/_baton_probe_upload_gate")
            XCTAssertEqual(code, 200)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if (state["enteredAudioPUTs"] as? Int ?? 0) == 1 { entered = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(entered, "the gate must observe this job's real file-upload request after durable create/task handoff")
        let pendingCreated = try await createdCount()
        XCTAssertEqual(pendingCreated, before + 1)
        let pendingFinalized = try await finalizedCount()
        XCTAssertEqual(pendingFinalized, 0, "the held synthetic share is still nonterminal at dismissal")
        XCTAssertFalse(app.buttons["share-create-link"].isEnabled)
        let cancel = app.buttons["Cancel"].firstMatch
        let done = app.buttons["Done"].firstMatch
        let close = done.exists ? done : cancel
        XCTAssertTrue(close.isEnabled, "durable background upload must allow leaving the composer")
        close.tap()
        XCTAssertTrue(app.buttons["share-create-link"].waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let links = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shared Links")).firstMatch
        for _ in 0..<16 where !links.isHittable { app.swipeUp() }
        XCTAssertTrue(links.isHittable)
        links.tap()
        XCTAssertTrue(app.navigationBars["Shared Links"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Uploading 1 shared song…"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[title].exists, "the held upload has not produced a ready ledger row")
        capture("dismissed-with-one-pending-upload")
        let (_, releaseStatus) = try await request("/_baton_probe_upload_gate", method: "POST")
        XCTAssertEqual(releaseStatus, 200)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts.matching(identifier: title).count, 1)
        XCTAssertTrue(app.staticTexts["Uploading 1 shared song…"].waitForNonExistence(timeout: 5))
        let completedCreated = try await createdCount()
        XCTAssertEqual(completedCreated, before + 1, "dismissing must not create a duplicate share")
        let completedFinalized = try await finalizedCount()
        XCTAssertEqual(completedFinalized, 1)
        capture("one-completed-link-after-dismissal")
    }

    func testClosedComposerShowsAccountedUploadFailure() async throws {
        let gate = try XCTUnwrap(ProcessInfo.processInfo.environment["SONG_SHARING_UPLOAD_GATE_URL"])
        XCTAssertEqual(gate, shareBase)
        let releaseURL = try XCTUnwrap(URL(string: gate + "/_baton_probe_upload_gate"))
        addTeardownBlock {
            var release = URLRequest(url: releaseURL)
            release.httpMethod = "POST"; release.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: release)
        }
        let (_, configured) = try await request("/_baton_probe_upload_gate", method: "POST",
            body: ["holdNextAudio": true, "corruptNextAudio": true])
        XCTAssertEqual(configured, 200)
        searchSong(); openRowComposer()
        app.buttons["share-create-link"].tap()
        var entered = false
        for _ in 0..<100 {
            let (data, _) = try await request("/_baton_probe_upload_gate")
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if (state["enteredAudioPUTs"] as? Int) == 1 { entered = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(entered)
        let created = try await createdCount()
        XCTAssertEqual(created, 1)
        let finalized = try await finalizedCount()
        XCTAssertEqual(finalized, 0)
        XCTAssertTrue(app.buttons["Done"].isEnabled)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["share-create-link"].waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap(); app.buttons["Settings"].firstMatch.tap()
        let links = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shared Links")).firstMatch
        for _ in 0..<16 where !links.isHittable { app.swipeUp() }
        XCTAssertTrue(links.isHittable); links.tap()
        XCTAssertTrue(app.staticTexts["Uploading 1 shared song…"].waitForExistence(timeout: 10))
        _ = try await request("/_baton_probe_upload_gate", method: "POST")
        XCTAssertTrue(app.staticTexts["1 song could not be shared"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Uploading 1 shared song…"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[title].exists)
        let afterCreated = try await createdCount(), afterFinalized = try await finalizedCount()
        XCTAssertEqual(afterCreated, 1); XCTAssertEqual(afterFinalized, 0)
        capture("closed-composer-durable-failure")
    }

    func testCancelDisclosureUploadsNothing() async throws {
        let before = try await createdCount()
        searchSong()
        openRowComposer()
        let disclosure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sharing uploads an encrypted copy")).firstMatch
        for _ in 0..<5 where !disclosure.isHittable { app.swipeUp() }
        XCTAssertTrue(disclosure.exists)
        capture("first-share-disclosure")
        app.buttons["Cancel"].tap()
        let after = try await createdCount()
        XCTAssertEqual(after, before, "opening and cancelling the composer must not create a share")
    }

    func testExplicitPreservationConsentReachesServiceAndOwnerNotice() async throws {
        try XCTSkipUnless(!operatorToken.isEmpty, "requires the isolated preservation fixture")
        searchSong()
        openRowComposer()
        let consent = app.switches["share-review-preservation"]
        for _ in 0..<5 where !consent.isHittable { app.swipeUp() }
        XCTAssertTrue(consent.exists)
        XCTAssertEqual(consent.value as? String, "0", "previous sharing never opts this share in")
        let disclosure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "If this link is disabled for review")).firstMatch
        XCTAssertTrue(disclosure.exists)
        consent.switches.firstMatch.tap()
        XCTAssertEqual(consent.value as? String, "1")
        capture("preservation-explicit-opt-in")
        let link = try createLink()
        let id = link.lastPathComponent
        let now = Int(Date().timeIntervalSince1970)
        let (body, status) = try await request("/v1/share/admin/enforcement/plan", method: "POST", body: [
            "operationID": UUID().uuidString.lowercased(), "action": "disable-share", "shareID": id,
            "caseReference": "synthetic_consent", "reasonCode": "review", "reviewUntil": now + 20 * 86400,
            "preservationDeadline": now + 22 * 86400], operatorRequest: true)
        XCTAssertEqual(status, 200)
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let affected = try XCTUnwrap(plan["affected"] as? [[String: Any]])
        let lifetime = try XCTUnwrap(affected.first?["remainingLifetimeSeconds"] as? Int)
        XCTAssertGreaterThan(lifetime, 6 * 86400)
        XCTAssertLessThanOrEqual(lifetime, 7 * 86400)
        let (_, applied) = try await request("/v1/share/admin/enforcement/apply", method: "POST", body: plan, operatorRequest: true)
        XCTAssertEqual(applied, 200)
        let (_, denied) = try await request("/v1/share/p/" + id + "/audio")
        XCTAssertEqual(denied, 410)
        openSharedLinks()
        let notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "seconds of link lifetime remain paused")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Disabled for review"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Expires in")).firstMatch.exists)
        capture("preservation-committed-owner-notice")
        app.staticTexts[title].press(forDuration: 1)
        XCTAssertTrue(app.buttons["Revoke"].firstMatch.exists)
    }

    func testPublicShareSendPickerAndManageLifecycle() async throws {
        searchSong()
        openRowComposer()
        setFields(privatePreview: false)
        let link = try createLink()
        var info = try await publicInfo(link)
        let preview = try XCTUnwrap(info["preview"] as? [String: Any])
        XCTAssertEqual(preview["title"] as? String, title)
        XCTAssertEqual(preview["note"] as? String, "Public fixture note")
        XCTAssertEqual(preview["from"] as? String, "iPhone Probe")
        try assertOneDayExpiry(info)
        app.buttons["share-send-link"].tap()
        let picker = app.otherElements["ShareSheet.RemoteContainerView"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "system share picker did not open")
        XCTAssertTrue(picker.cells["Copy"].exists)
        capture("system-share-picker-no-external-send")
        // Dismiss the observed compact system sheet without choosing a recipient.
        picker.swipeDown()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10))
        openSharedLinks()
        let id = link.lastPathComponent
        _ = try await request("/s/" + id)
        let (_, reactionStatus) = try await request("/v1/share/p/" + id + "/reactions", method: "POST",
                                                   body: ["emoji": "❤️", "name": "Fixture Friend", "reply": "Local reply"])
        XCTAssertEqual(reactionStatus, 204)
        let ledgers = app.collectionViews.containing(.staticText, identifier: title)
        XCTAssertEqual(ledgers.count, 1, "refresh must target the observed Shared Links list")
        let ledger = ledgers.element
        ledger.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: ledger.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertTrue(app.staticTexts["❤️ Fixture Friend: Local reply"].waitForExistence(timeout: 15))
        capture("refreshed-reaction")
        let oldExpiry = try XCTUnwrap(info["expiresAt"] as? String)
        app.staticTexts[title].press(forDuration: 1)
        app.buttons["Extend 7 Days"].tap()
        // Server truth verifies the visible action rather than trusting that a tap occurred.
        for _ in 0..<20 {
            info = try await publicInfo(link)
            if info["expiresAt"] as? String != oldExpiry { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertNotEqual(info["expiresAt"] as? String, oldExpiry)
        app.staticTexts[title].press(forDuration: 1)
        app.buttons["Revoke"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Revoke"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Revoke"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Revoked"].waitForExistence(timeout: 15))
        let (_, endedStatus) = try await request("/v1/share/p/" + id)
        XCTAssertEqual(endedStatus, 410)
        capture("revoked")
        app.staticTexts[title].press(forDuration: 1)
        app.buttons["Remove from List"].tap()
        XCTAssertTrue(app.staticTexts["No shared links yet"].waitForExistence(timeout: 10))
        capture("removed-from-list")
    }

    private func askFriend(_ text: String) {
        app.tabBars.buttons["Friend"].tap()
        let composer = app.descendants(matching: .any)["FriendComposerField"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(text)
        app.buttons["FriendComposerSend"].tap()
    }

    func testFriendRefusesBeforeConsentAndCreatesAfterManualShare() async throws {
        let env = ProcessInfo.processInfo.environment
        app.terminate()
        app.launchEnvironment["baton.agent.route"] = "direct"
        app.launchEnvironment["baton.agent.provider"] = "openai-compatible"
        app.launchEnvironment["baton.agent.model"] = "sharing-fixture"
        app.launchEnvironment["baton.agent.baseURL"] = try XCTUnwrap(env["SONG_SHARING_MODEL_URL"])
        app.launchEnvironment["uitestVerifiedAgent"] = "1"
        app.launch()
        let before = try await createdCount()
        askFriend("Share the fixture song with my friend")
        let refusal = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Share a song once from Baton itself first")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 30))
        let afterRefusal = try await createdCount()
        XCTAssertEqual(afterRefusal, before)
        capture("friend-refuses-before-manual-consent")
        // Tapping the transcript is the shipped keyboard dismissal affordance.
        refusal.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        searchSong()
        openRowComposer()
        let manual = try createLink()
        _ = try await publicInfo(manual)
        app.buttons["Done"].firstMatch.tap()
        askFriend("Share the fixture song again")
        let success = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "how_to_send")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 90), "the real local friend sharing tool did not return a link")
        // Admin windows exclude the current second; let the next query measure the new event.
        var after = afterRefusal
        for _ in 0..<20 {
            after = try await createdCount()
            if after >= before + 2 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(after, before + 2, "one manual share and one real friend dispatch must be created")
        capture("friend-shares-after-manual-consent")
    }

    func testQueueSharePreservesDraftAcrossNestedSheets() async throws {
        searchSong()
        app.staticTexts[title].firstMatch.tap()
        let bar = app.descendants(matching: .any)["NowPlayingBar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        tapMiniBar(in: app)
        XCTAssertTrue(app.buttons["Up Next"].waitForExistence(timeout: 10))
        app.buttons["Up Next"].tap()
        XCTAssertTrue(app.navigationBars["Up Next"].waitForExistence(timeout: 10))
        let queue = app.descendants(matching: .any)["QueueSheet"]
        let row = queue.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Share…"].waitForExistence(timeout: 10))
        app.buttons["Share…"].tap()
        setFields(privatePreview: false)
        let link = try createLink()
        let info = try await publicInfo(link)
        let preview = try XCTUnwrap(info["preview"] as? [String: Any])
        XCTAssertEqual(preview["title"] as? String, title)
        XCTAssertEqual(preview["note"] as? String, "Public fixture note")
        XCTAssertEqual(preview["from"] as? String, "iPhone Probe")
        try assertOneDayExpiry(info)
        capture("nested-queue-created-with-preserved-draft")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Up Next"].waitForExistence(timeout: 10),
                      "the composer must return to its actual nested queue host")
        app.navigationBars["Up Next"].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Minimize player"].waitForExistence(timeout: 10))
    }

    func testPrivateShareFromNowPlayingHidesPublicDetails() async throws {
        searchSong()
        app.staticTexts[title].firstMatch.tap()
        let bar = app.descendants(matching: .any)["NowPlayingBar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        tapMiniBar(in: app)
        XCTAssertTrue(app.buttons["Minimize player"].waitForExistence(timeout: 10))
        let heading = app.scrollViews["FullPlayerContent"].staticTexts[title].firstMatch
        XCTAssertTrue(heading.exists)
        heading.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Share…"].waitForExistence(timeout: 10))
        app.buttons["Share…"].tap()
        setFields(privatePreview: true)
        let link = try createLink()
        let info = try await publicInfo(link)
        XCTAssertNil(info["preview"], "private shares must not publish title, note or sender")
        XCTAssertNotNil(info["encryptedMeta"])
        try assertOneDayExpiry(info)
        openSharedLinks()
        XCTAssertTrue(app.images["Details hidden from previews"].exists)
        capture("private-link-in-ledger")
    }
}
