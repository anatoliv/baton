import BatonDocuments
import XCTest

/// Every voice on the phone, against `FakeHomeServer` listing the 68 voices the
/// Baton server's Kokoro offers: the import screen keeps the three suggestions on top and opens
/// All voices, grouped and searchable; the chosen voice is the one sent. Change Voice on a book
/// uses the same picker. A server that does not list its voices leaves the suggested voice and
/// says why.
///
/// Demo mode, no network beyond loopback. Environment, never launch arguments.
final class NarratorAllVoicesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!

    /// The 68 voices the Kokoro on the Baton server listed on 2026-10-16.
    static let serverVoices: [String] = """
    af_alloy af_aoede af_bella af_heart af_jadzia af_jessica af_kore af_nicole af_nova af_river af_sarah af_sky \
    af_v0 af_v0bella af_v0irulan af_v0nicole af_v0sarah af_v0sky am_adam am_echo am_eric am_fenrir am_liam \
    am_michael am_onyx am_puck am_santa am_v0adam am_v0gurney am_v0michael bf_alice bf_emma bf_isabella bf_lily \
    bf_v0emma bf_v0isabella bm_daniel bm_fable bm_george bm_lewis bm_v0george bm_v0lewis ef_dora em_alex em_santa \
    ff_siwis hf_alpha hf_beta hm_omega hm_psi if_sara im_nicola jf_alpha jf_gongitsune jf_nezumi jf_tebukuro \
    jm_kumo pf_dora pm_alex pm_santa zf_xiaobei zf_xiaoni zf_xiaoxiao zf_xiaoyi zm_yunjian zm_yunxi zm_yunxia zm_yunyang
    """.split(separator: " ").map { "kokoro:\($0)" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCTAssertEqual(Self.serverVoices.count, 68)
        server = try FakeHomeServer()
        server.setVoices(Self.serverVoices)
        app = XCUIApplication.batonUnderTest()
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

        Chapter 2 The Door

        The door opened onto a second room, the same as the first.
        """
    }

    override func tearDown() {
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    @MainActor
    func testAllVoicesAreGroupedSearchableAndTheChosenOneIsSent() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["Two Rooms"].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")
        let heart = app.buttons["narrator-kokoro:af_heart"].firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 20), "no suggested voices\n\(app.debugDescription)")
        XCTAssertEqual(heart.label, "Heart, American, female", "the suggested voice is named in words")
        XCTAssertEqual(suggestedIDs(), ["narrator-kokoro:af_heart", "narrator-kokoro:am_adam", "narrator-kokoro:bf_emma"])
        XCTAssertTrue(heart.isSelected)

        let all = app.buttons["all-voices"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), "no All voices")
        XCTAssertEqual(all.label, "All voices (68)")
        all.tap()
        let alloy = app.buttons["voice-kokoro:af_alloy"].firstMatch
        reveal(alloy)
        XCTAssertTrue(alloy.waitForExistence(timeout: 10), "All voices did not open\n\(app.debugDescription)")
        XCTAssertEqual(alloy.label, "Alloy, American, female")
        attach("1-import-all-voices-open")

        let search = app.textFields["voice-search"].firstMatch
        var downs = 0
        while !(search.exists && search.isHittable) && downs < 6 { app.swipeDown(); downs += 1 }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no search field")
        search.tap()
        search.typeText("british male")
        let george = app.buttons["voice-kokoro:bm_george"].firstMatch
        reveal(george)
        XCTAssertTrue(george.waitForExistence(timeout: 5), "George is not found by \"british male\"")
        XCTAssertFalse(app.buttons["voice-kokoro:bf_emma"].exists, "a female voice matched \"male\"")
        XCTAssertFalse(app.buttons["voice-kokoro:af_alloy"].exists, "an American voice matched \"british\"")
        let found = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voice-'")).allElementsBoundByIndex.map { $0.identifier }
        // By name, so each earlier-model voice follows its namesake: George, George (v0), Lewis, Lewis (v0).
        // The list builds only the rows on screen, and the keyboard covers the last of them.
        let expected = ["voice-kokoro:bm_daniel", "voice-kokoro:bm_fable", "voice-kokoro:bm_george", "voice-kokoro:bm_v0george",
                        "voice-kokoro:bm_lewis", "voice-kokoro:bm_v0lewis"]
        XCTAssertGreaterThanOrEqual(found.count, 4, "too few British male voices on screen: \(found)")
        XCTAssertEqual(found, Array(expected.prefix(found.count)), "only British male voices, by name")
        george.tap()
        XCTAssertTrue(waitFor(5) { george.isSelected }, "tapping George did not choose him")
        attach("2-import-search-british-male")

        // The choice stays on top with All voices closed. All voices sits above the search
        // field, and the list builds only the rows on screen: after George was revealed it can
        // be scrolled out of the tree, so scroll back up to it first.
        let closeAll = app.buttons["all-voices"].firstMatch
        var back = 0
        while !(closeAll.exists && closeAll.isHittable) && back < 6 { app.swipeDown(); back += 1 }
        XCTAssertTrue(closeAll.waitForExistence(timeout: 5), "All voices cannot be scrolled back to")
        closeAll.tap()
        let chosenOnTop = app.buttons["narrator-kokoro:bm_george"].firstMatch
        var ups = 0
        while !chosenOnTop.exists && ups < 6 { app.swipeDown(); ups += 1 }
        XCTAssertTrue(chosenOnTop.waitForExistence(timeout: 5) && chosenOnTop.isSelected, "the chosen voice left the top")
        XCTAssertTrue(heart.exists && !heart.isSelected, "Heart is no longer chosen")

        make()
        let id = try XCTUnwrap(server.bookIDs.first)
        XCTAssertEqual(server.narrator(ofBook: id), "kokoro:bm_george", "the book should carry the chosen narrator")
    }

    @MainActor
    func testAServerWithNoVoiceListLeavesTheSuggestedVoiceAndSaysWhy() throws {
        server.setVoices(nil)
        app.launch()
        XCTAssertTrue(app.staticTexts["Two Rooms"].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")
        let why = app.staticTexts["Only the suggested voices are here, because your Baton server is older than the voice list."].firstMatch
        XCTAssertTrue(why.waitForExistence(timeout: 20), "the picker does not say why there is no list\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["all-voices"].exists)
        XCTAssertEqual(suggestedIDs().count, 1, "the default voice alone")
        attach("3-import-no-voice-list")
    }

    @MainActor
    func testChangeVoiceOffersEveryVoice() throws {
        server.setReadyOnSubmit(2)
        app.launch()
        XCTAssertTrue(app.staticTexts["Two Rooms"].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")
        XCTAssertTrue(app.buttons["narrator-kokoro:af_heart"].firstMatch.waitForExistence(timeout: 20))
        make()
        BooksScreen.open(app)
        let row = BooksScreen.row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the book row is not in Books")
        row.press(forDuration: 1.2)
        let change = app.buttons["Change Voice…"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10), "the book's menu has no Change Voice…")
        change.tap()

        XCTAssertTrue(app.staticTexts["Now read by Heart, American, female."].firstMatch.waitForExistence(timeout: 20),
                      "the screen names the voice it has in words")
        let now = app.buttons["narrator-kokoro:af_heart"].firstMatch
        XCTAssertTrue(now.waitForExistence(timeout: 10))
        XCTAssertEqual(now.label, "Heart, American, female, now")
        let all = app.buttons["all-voices"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertEqual(all.label, "All voices (68)")
        attach("4-change-voice-suggested")
        all.tap()
        let search = app.textFields["voice-search"].firstMatch
        reveal(search)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("spanish")
        let dora = app.buttons["voice-kokoro:ef_dora"].firstMatch
        reveal(dora)
        XCTAssertTrue(dora.waitForExistence(timeout: 5), "Dora is not found by \"spanish\"")
        XCTAssertTrue(app.buttons["voice-kokoro:em_alex"].exists)
        XCTAssertFalse(app.buttons["voice-kokoro:pf_dora"].exists, "a Brazilian Portuguese voice matched \"spanish\"")
        dora.tap()
        XCTAssertTrue(waitFor(5) { dora.isSelected }, "tapping Dora did not choose her")
        attach("5-change-voice-search-spanish")
        let before = server.bookIDs.count
        app.buttons["make-again"].firstMatch.tap()
        XCTAssertTrue(waitFor(15) { self.server.narrators.contains("kokoro:ef_dora") },
                      "Make Again did not send Dora (\(before) books before)")
    }

    // MARK: - Helpers

    @MainActor
    private func suggestedIDs() -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'narrator-'")).allElementsBoundByIndex.map { $0.identifier }
    }

    /// Scroll the list until `element` is on screen: a List only builds the rows it shows.
    @MainActor
    private func reveal(_ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 8 {
            app.swipeUp()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            swipes += 1
        }
    }

    @MainActor
    private func make() {
        let make = app.buttons["make-audiobook"].firstMatch
        var tries = 0
        while !(make.exists && make.isHittable) && tries < 12 {
            app.swipeUp()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
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
        XCTAssertTrue(waitFor(10) { self.server.requests("PUT").count >= 1 }, "Make Audiobook sent nothing")
        app.tap()
        removeUIInterruptionMonitor(monitor)
        ImportScreen.waitToClose(app)
    }

    @MainActor
    private func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        return condition()
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
