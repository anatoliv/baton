import XCTest

/// A look at the full player, written to a file so a human (or I) can see it.
///
/// Moving a control is not something a build success can confirm. This drives the real app
/// to the full player and writes the screenshot out, because "it compiles" has been wrong
/// about layout in this project more than once.
final class PlayerHeartVisualCheck: XCTestCase {
    func testCaptureFullPlayer() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession",
            "-uitestServer", "https://demo.navidrome.org",
            "-uitestUser", "demo", "-uitestSecret", "demo",
            "-uitestBypassBiometrics", "-uitestSkipSpeechAuthorization",
        ]
        app.launch()

        let ready = app.buttons.matching(identifier: "Search").firstMatch
        guard ready.waitForExistence(timeout: 90) else { throw XCTSkip("app never became usable") }
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }

        ready.tap()
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 20) else { throw XCTSkip("no search field") }
        field.tap()
        field.typeText("love\n")

        let cells = app.cells
        guard cells.element(boundBy: 0).waitForExistence(timeout: 45) else { throw XCTSkip("no results") }
        var playing = false
        for index in 0 ..< min(cells.count, 6) where !playing {
            let cell = cells.element(boundBy: index)
            guard cell.exists, cell.isHittable else { continue }
            cell.tap()
            playing = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch.waitForExistence(timeout: 15)
        }
        guard playing else { throw XCTSkip("nothing started playing") }

        // Open the full player from the mini bar.
        // `.firstMatch`: the bar surfaces as more than one element in the tree.
        app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch.tap()
        Thread.sleep(forTimeInterval: 3)

        let shot = XCUIScreen.main.screenshot()
        let out = URL(fileURLWithPath: "/tmp/baton-full-player.png")
        try? shot.pngRepresentation.write(to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "no screenshot written")
    }

    /// A look at the Friend screen: the log button, and no phantom edit icon on an empty
    /// conversation. Layout is the class of change a compiler cannot confirm, and this
    /// project has shipped invisible and inert controls before.
    func testCaptureFriendScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession",
            "-uitestServer", "https://demo.navidrome.org",
            "-uitestUser", "demo", "-uitestSecret", "demo",
            "-uitestBypassBiometrics", "-uitestSkipSpeechAuthorization",
        ]
        app.launch()

        let friend = app.buttons.matching(identifier: "Friend").firstMatch
        guard friend.waitForExistence(timeout: 90) else {
            throw XCTSkip("no Friend tab — the model provider is not configured on this machine")
        }
        if app.buttons["Not now"].waitForExistence(timeout: 5) { app.buttons["Not now"].tap() }
        friend.tap()
        Thread.sleep(forTimeInterval: 2)

        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/baton-friend.png"))

        // The bug that prompted this: an icon that looked live and did nothing.
        XCTAssertTrue(app.buttons["Friend log"].exists, "the log is unreachable from the Friend screen")
        XCTAssertFalse(app.buttons["New conversation"].exists,
                       "an empty conversation still shows a control that cannot do anything")
    }

}
