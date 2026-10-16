import BatonDocuments
import XCTest

/// The import screen's narrator choice against `FakeHomeServer` listing Kokoro's
/// English voices on `/v1/voices`: Heart first and chosen, then the Mac's alternates, never
/// Aoede or Lewis; choosing Emma sends the book with Emma as its narrator.
///
/// Demo mode, no network beyond loopback. Environment, never launch arguments.
final class NarratorChoiceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        server = try FakeHomeServer()
        server.setVoices(VoiceCatalogue.kokoroEnglishVoices)
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
        """
    }

    override func tearDown() {
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    @MainActor
    func testTheHomeServersVoicesAreOfferedAndTheChosenOneIsSent() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["Two Rooms"].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")

        let heart = app.buttons["narrator-kokoro:af_heart"].firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 20), "no narrator choice from the home server's voices\n\(app.debugDescription)")
        let adam = app.buttons["narrator-kokoro:am_adam"].firstMatch
        let emma = app.buttons["narrator-kokoro:bf_emma"].firstMatch
        XCTAssertTrue(adam.exists && emma.exists, "the Mac's alternates (Adam, Emma) should follow Heart")
        let offered = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'narrator-'")).allElementsBoundByIndex
            .map { $0.identifier }
        XCTAssertEqual(offered, ["narrator-kokoro:af_heart", "narrator-kokoro:am_adam", "narrator-kokoro:bf_emma"])
        XCTAssertTrue(heart.isSelected, "Heart is the default for a book with no declared region")
        XCTAssertTrue(heart.frame.minY < adam.frame.minY && adam.frame.minY < emma.frame.minY, "not in the Mac's order")
        XCTAssertTrue(server.requests("GET").contains { $0.path == "/v1/voices" })

        emma.tap()
        XCTAssertTrue(waitFor(5) { emma.isSelected && !heart.isSelected }, "tapping Emma did not choose her")
        attach("narrator-choice")

        let make = app.buttons["make-audiobook"].firstMatch
        var tries = 0
        while !make.exists && tries < 6 {
            app.swipeUp()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            tries += 1
        }
        XCTAssertTrue(make.waitForExistence(timeout: 20), "Make Audiobook was not offered")
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Don’t Allow", "Don't Allow", "Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        make.tap()
        XCTAssertTrue(waitFor(10) { self.server.requests("PUT").count == 1 }, "Make Audiobook sent nothing")
        app.tap()
        removeUIInterruptionMonitor(monitor)
        let id = try XCTUnwrap(server.bookIDs.first)
        XCTAssertEqual(server.narrator(ofBook: id), "kokoro:bf_emma", "the book should carry the chosen narrator")
    }

    private func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        return condition()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
