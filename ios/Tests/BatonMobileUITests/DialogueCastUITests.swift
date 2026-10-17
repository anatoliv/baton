import BatonDocuments
import XCTest

/// Voice the dialogue on the iPhone, against `FakeHomeServer`, whose book model
/// writes the cast list and places the lines without a speech tag:
///
/// - on the import screen: the switch, Check the Cast… (rename, a voice per character, Hear),
///   placing, and the book sent with its cast (each line's speaker and the plan's characters);
/// - with no model answering: said plainly, and the book read by one narrator;
/// - in Change Voice: a cast given to a book made without one (with Skip while lines are placed),
///   that cast edited, then turned off.
///
/// Demo mode, no network beyond loopback, preference sync off, Apple's on-device model left out.
final class DialogueCastUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!

    private static let sheet = """
    {"characters": [
      {"name": "Ada", "gender": "f", "age": "adult", "aliases": ["the clockmaker"]},
      {"name": "Tobias", "gender": "m", "age": "young", "aliases": ["her apprentice"]}
    ]}
    """

    /// Who speaks the two lines without a speech tag, as a model that read them says.
    private static let fill = ["c1q3": "Ada", "c1q4": "Tobias"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        server = try FakeHomeServer()
        server.setReadyOnSubmit(2)
        server.setVoices(["kokoro:af_heart", "kokoro:am_adam", "kokoro:bf_emma", "kokoro:bm_george", "kokoro:bf_isabella"])
        server.setAnswersBookTasks(true)
        server.setCastReplies(sheet: Self.sheet, fill: Self.fill)
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestNoOnDeviceModel"] = "1"
        app.launchEnvironment["uitestGatewayURL"] = server.baseURL
        app.launchEnvironment["uitestGatewayToken"] = "uitest-fake-home-server"
        app.launchEnvironment["uitestImportText"] = """
        The Clockmaker
        by A. Tester

        Chapter 1 The Hall

        \u{201C}Wind it slowly,\u{201D} said Ada.

        \u{201C}I always do,\u{201D} said Tobias.

        \u{201C}Then why does it run fast?\u{201D}

        \u{201C}Because the hall is cold.\u{201D}

        Chapter 2 The Letter

        A letter came in the spring. \u{201C}It is not from you,\u{201D} said Ada, and she put it away.
        """
    }

    override func tearDown() {
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    // MARK: - Import

    func testTheImportVoicesTheDialogueWithTheCheckedCast() throws {
        app.launch()
        waitForImport()
        setVoiceTheDialogue(true)
        let check = reveal(app.buttons["check-the-cast"].firstMatch, timeout: 30)
        XCTAssertEqual(check.label, "Check the Cast…")
        XCTAssertTrue(app.staticTexts["cast-summary"].firstMatch.label.hasPrefix("2 speakers proposed by your Baton server."),
                      "the model's cast, to be checked: \(app.staticTexts["cast-summary"].firstMatch.label)")
        XCTAssertFalse(app.buttons["make-audiobook"].firstMatch.isEnabled, "nothing is made before the cast is checked")
        attach("Cast-01-proposed")
        check.tap()

        // Rename Tobias, give Ada Emma's voice, and hear Ada.
        let tobiasName = app.textFields["Name of Tobias"].firstMatch
        XCTAssertTrue(tobiasName.waitForExistence(timeout: 10), "the editor lists Tobias\n\(app.debugDescription)")
        tobiasName.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        tobiasName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "Toby\n")
        XCTAssertTrue(app.textFields["Name of Toby"].waitForExistence(timeout: 5), "Tobias renamed Toby")
        app.buttons["cast-voice-Ada"].firstMatch.tap()
        let adaVoices = app.navigationBars["Voice for Ada"]
        XCTAssertTrue(adaVoices.waitForExistence(timeout: 10), "Ada's voices\n\(app.debugDescription)")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))   // the push settles
        let offered = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'narrator-kokoro:'")).allElementsBoundByIndex
        let pick = try XCTUnwrap(offered.first { $0.isHittable && !$0.isSelected }, "another voice for Ada")
        let adaVoice = String(pick.identifier.dropFirst("narrator-".count))
        pick.tap()
        // By identifier again: the chosen voice moves up among the suggested ones.
        let chosen = app.buttons.matching(identifier: "narrator-\(adaVoice)")
        XCTAssertTrue(waitFor(5) { chosen.allElementsBoundByIndex.contains { $0.isSelected } }, "\(adaVoice) chosen for Ada")
        attach("Cast-02-voice")
        adaVoices.buttons.firstMatch.tap()
        let previews = server.requests("POST").filter { $0.path == "/v1/speech/preview" }.count
        app.buttons["Hear Ada"].firstMatch.tap()
        XCTAssertTrue(waitFor(10) { self.server.requests("POST").filter { $0.path == "/v1/speech/preview" }.count > previews },
                      "Hear asks the Baton server for Ada's voice")
        attach("Cast-03-editor")
        // The model is asked with the cast as checked, so it names Toby.
        server.setCastReplies(sheet: Self.sheet, fill: ["c1q3": "Ada", "c1q4": "Toby"])
        app.buttons["use-this-cast"].firstMatch.tap()

        let placed = reveal(app.staticTexts["placed-line"].firstMatch, timeout: 30)
        XCTAssertTrue(placed.label.hasPrefix("Placed by your Baton server: 2 more lines, so 5 of 5 lines have a speaker."),
                      "what placing did: \(placed.label)")
        XCTAssertEqual(app.buttons["check-the-cast"].firstMatch.label, "Edit Cast…")
        attach("Cast-04-placed")

        let book = try makeAudiobook()
        XCTAssertEqual(Set(book.voices.characters.keys), ["Ada", "Toby"])
        XCTAssertEqual(book.voices.characters["Ada"], adaVoice)
        let speakers = book.chapters.flatMap(\.segments).filter { $0.kind == .quote }.map { $0.speaker ?? "narrator" }
        XCTAssertEqual(speakers, ["Ada", "Toby", "Ada", "Toby", "Ada"],
                       "the tagged lines by the rules, the two untagged by the model")
    }

    func testWithNoModelTheNarratorReadsEveryLine() throws {
        server.setAnswersBookTasks(false)
        app.launch()
        waitForImport()
        setVoiceTheDialogue(true)
        let why = reveal(app.staticTexts["cast-unavailable"].firstMatch, timeout: 30)
        XCTAssertEqual(why.label, "No model answered for the cast list, so the narrator reads every line.")
        attach("Cast-05-no-model")
        let book = try makeAudiobook()
        XCTAssertEqual(book.voices.characters, [:])
        XCTAssertFalse(book.chapters.flatMap(\.segments).contains { $0.speaker != nil }, "one narrator")
    }

    // MARK: - Change Voice

    func testChangeVoiceGivesEditsAndTakesAwayACast() throws {
        server.setCastReplies(sheet: Self.sheet, fill: Self.fill, fillDelay: 8)
        app.launch()
        waitForImport()
        setVoiceTheDialogue(false)
        let plain = try makeAudiobook()
        XCTAssertEqual(plain.voices.characters, [:])
        openTheBook()

        // A cast for a book made without one; Skip while the lines are placed.
        openChangeVoice()
        let toggle = app.switches["voice-the-dialogue"].firstMatch
        XCTAssertEqual(toggle.value as? String, "0", "the book has no cast")
        XCTAssertFalse(app.buttons["make-again"].firstMatch.isEnabled, "nothing changed yet")
        setVoiceTheDialogue(true)
        reveal(app.buttons["check-the-cast"].firstMatch, timeout: 30).tap()
        let use = app.buttons["use-this-cast"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        use.tap()
        let skip = reveal(app.buttons["skip-placing"].firstMatch, timeout: 10)
        XCTAssertFalse(app.buttons["make-again"].firstMatch.isEnabled, "Make Again waits while lines are placed")
        attach("Cast-06-placing")
        skip.tap()
        XCTAssertEqual(reveal(app.staticTexts["placed-line"].firstMatch, timeout: 5).label,
                       "Skipped: the narrator reads the lines without a speech tag.")
        var sent = try makeAgain()
        XCTAssertEqual(Set(sent.voices.characters.keys), ["Ada", "Tobias"])
        XCTAssertEqual(sent.chapters.flatMap(\.segments).filter { $0.kind == .quote }.map { $0.speaker ?? "narrator" },
                       ["Ada", "Tobias", "narrator", "narrator", "Ada"], "the rules' lines; the narrator reads the rest")
        XCTAssertEqual(sent.voices.narrator, plain.voices.narrator, "the same narrator")

        // That cast edited: Tobias gets George's voice.
        openChangeVoice()
        XCTAssertEqual(app.switches["voice-the-dialogue"].firstMatch.value as? String, "1", "the book has a cast now")
        reveal(app.buttons["check-the-cast"].firstMatch, timeout: 10).tap()
        app.buttons["cast-voice-Tobias"].firstMatch.tap()
        let tobiasVoices = app.navigationBars["Voice for Tobias"]
        XCTAssertTrue(tobiasVoices.waitForExistence(timeout: 10), "Tobias's voices")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))   // the push settles
        let other = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'narrator-kokoro:'")).allElementsBoundByIndex
            .first { $0.isHittable && !$0.isSelected }
        try XCTUnwrap(other, "another voice for Tobias").tap()
        tobiasVoices.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["use-this-cast"].firstMatch.waitForExistence(timeout: 5), "back in the editor")
        app.buttons["use-this-cast"].firstMatch.tap()
        let before = sent.voices.characters["Tobias"]
        attach("Cast-07-edited")
        sent = try makeAgain()
        XCTAssertNotEqual(sent.voices.characters["Tobias"], before, "Tobias has another voice")
        XCTAssertEqual(sent.voices.characters["Ada"], server.submittedBooks.dropLast().last?.voices.characters["Ada"])

        // Turned off: one narrator again.
        openChangeVoice()
        setVoiceTheDialogue(false)
        attach("Cast-08-off")
        sent = try makeAgain()
        XCTAssertEqual(sent.voices.characters, [:])
        XCTAssertFalse(sent.chapters.flatMap(\.segments).contains { $0.speaker != nil })
    }

    // MARK: - Steps

    private func waitForImport() {
        XCTAssertTrue(app.staticTexts["The Clockmaker"].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")
        XCTAssertTrue(app.buttons["narrator-kokoro:af_heart"].firstMatch.waitForExistence(timeout: 20), "the narrators")
    }

    private func setVoiceTheDialogue(_ on: Bool) {
        let toggle = reveal(app.switches["voice-the-dialogue"].firstMatch, timeout: 20)
        guard (toggle.value as? String == "1") != on else { return }
        // A SwiftUI switch takes the tap on its knob.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitFor(5) { (toggle.value as? String == "1") == on }, "Voice the dialogue did not turn \(on ? "on" : "off")")
    }

    /// Make Audiobook, and the book the home server was sent.
    private func makeAudiobook() throws -> PreparedBook {
        let make = reveal(app.buttons["make-audiobook"].firstMatch, timeout: 20)
        XCTAssertTrue(waitFor(10) { make.isEnabled }, "Make Audiobook stays held")
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Don’t Allow", "Don't Allow", "Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        let count = server.submittedBooks.count
        make.tap()
        XCTAssertTrue(waitFor(10) { self.server.submittedBooks.count > count }, "Make Audiobook sent nothing")
        app.tap()
        ImportScreen.waitToClose(app)
        removeUIInterruptionMonitor(monitor)
        return try XCTUnwrap(server.submittedBooks.last)
    }

    private func openTheBook() {
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20), "no Library tab")
        library.tap()
        let entry = app.cells.containing(.staticText, identifier: "Books").firstMatch
        var tries = 0
        while !(entry.exists && entry.isHittable) && tries < 6 {
            app.swipeUp()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            tries += 1
        }
        if entry.exists { entry.tap() } else { BooksScreen.open(app) }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch
            .waitForExistence(timeout: 40), "both chapters should come down")
        BooksScreen.openBook(app)
    }

    private func openChangeVoice() {
        reveal(app.buttons["Change Voice…"].firstMatch, timeout: 15).tap()
        XCTAssertTrue(app.buttons["make-again"].firstMatch.waitForExistence(timeout: 15), "Change Voice opened")
        XCTAssertTrue(app.switches["voice-the-dialogue"].firstMatch.waitForExistence(timeout: 15),
                      "Voice the dialogue in Change Voice\n\(app.debugDescription)")
    }

    /// Make Again, and the book the home server was sent.
    private func makeAgain() throws -> PreparedBook {
        let again = app.buttons["make-again"].firstMatch
        XCTAssertTrue(waitFor(10) { again.isEnabled }, "Make Again stays off")
        let count = server.submittedBooks.count
        again.tap()
        XCTAssertTrue(waitFor(15) { self.server.submittedBooks.count > count }, "Make Again sent nothing")
        XCTAssertTrue(waitFor(10) { !again.exists }, "Change Voice closes")
        return try XCTUnwrap(server.submittedBooks.last)
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, timeout: TimeInterval) -> XCUIElement {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var swipes = 0
        while Date() < deadline {
            if element.exists && element.isHittable { return element }
            if element.exists || swipes >= 6 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
                if element.exists && !element.isHittable && swipes < 10 { app.swipeUp(); swipes += 1 }
                continue
            }
            app.swipeUp()
            swipes += 1
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        XCTAssertTrue(element.exists && element.isHittable, "not found: \(element)\n\(app.debugDescription)")
        return element
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
