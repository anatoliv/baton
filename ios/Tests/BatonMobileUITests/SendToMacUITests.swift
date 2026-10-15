import XCTest

/// "Send to my Mac" on the phone's import screen, against `FakeHomeServer` on
/// 127.0.0.1: the home server answers that it cannot make books, so the screen offers Send to my
/// Mac instead of Make Audiobook, and tapping it puts the document and its record in the
/// gateway's file store. The Mac's half is `DocumentInboxTests`; the two halves meet over the
/// real gateway in `PendingImportRelayTests.testAgainstARealGateway`.
///
/// Environment, never launch arguments.
final class SendToMacUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try FakeHomeServer()
        server.setBooksOff(reason: "no voice server is set up")
        app = XCUIApplication()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = server.baseURL
        app.launchEnvironment["uitestGatewayToken"] = "uitest-fake-home-server"
        app.launchEnvironment["uitestImportText"] = """
        Two Rooms
        by Nobody in Particular

        Chapter 1 The Cell

        A small room, like the cell of a bee. The air was fresh, though there was no window.

        Chapter 2 The Surface

        The light at the top was grey, and the hills were bare.
        """
    }

    override func tearDown() {
        app = nil
        server.stop()
        server = nil
        super.tearDown()
    }

    func testAHomeServerWithoutBooksOffersSendToMyMacAndParksTheDocument() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["Two Rooms"].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")

        let send = app.buttons["send-to-mac"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 15), "a home server that cannot make books should offer Send to my Mac")
        XCTAssertFalse(app.buttons["make-audiobook"].exists, "nothing would make the book")
        XCTAssertFalse(app.buttons["airdrop-to-mac"].exists, "AirDrop is for when there is no home server")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "no voice server is set up")).firstMatch.exists,
                      "the screen says why, in the home server's words")
        attach("send-to-mac-offered")

        let before = Date()
        send.tap()
        let sent = app.staticTexts["Sent to your Mac"].firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "the screen should say it was sent")
        attach("send-to-mac-sent")

        let puts = server.requests("PUT", since: before).map(\.path)
        XCTAssertEqual(puts.count, 2, "the document, then its record: \(puts)")
        XCTAssertTrue(puts.first?.hasSuffix("-d0c") ?? false, "the document goes first")
        let recordID = try XCTUnwrap(puts.last.map { String($0.dropFirst("/v1/files/".count)) })
        let record = try XCTUnwrap(server.storedFile(recordID))
        XCTAssertEqual(record.contentType, "application/vnd.baton.pending-import+json", "marked as a pending import")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: record.body) as? [String: Any])
        XCTAssertEqual(fields["title"] as? String, "Two Rooms")
        XCTAssertEqual(fields["documentID"] as? String, "\(recordID)-d0c")
        XCTAssertNotNil(fields["filename"] as? String)
        XCTAssertFalse((fields["fromDevice"] as? String ?? "").isEmpty, "the sending device is named")
        let document = try XCTUnwrap(server.storedFile("\(recordID)-d0c"))
        XCTAssertTrue(String(decoding: document.body, as: UTF8.self).contains("like the cell of a bee"), "the original words travel")

        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Two Rooms"].firstMatch.waitForExistence(timeout: 3), "Done closes the import screen")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
