import XCTest

/// Read Along on the phone, against `FakeHomeServer`: a book made on the home server
/// comes down with chapter 1's timing, and the full player's Read Along lights the sentence being
/// heard, follows it, and seeks to a tapped sentence. Chapter 2 has no timing (the server answers
/// 404, as for a chapter made before timing was kept), so its text shows without a highlight.
///
/// Demo mode, no network beyond loopback, preference sync off. Environment, never launch
/// arguments.
final class ReadAlongUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        server = try FakeHomeServer()
        server.setReadyOnSubmit(2)
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

        Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee.

        It is lighted neither by window nor by lamp, yet it is filled with a soft radiance.

        There are no apertures for ventilation, yet the air is fresh and moving all the time.

        There are no musical instruments, and yet the room is throbbing with melodious sounds.

        An armchair is in the centre, and by its side a reading desk, which is all the furniture.

        In the armchair there sits a swaddled lump of flesh, a woman about five feet high.

        Chapter 2 The Surface

        The light at the top was grey, and the hills were bare. He waited a long while for the wind to drop before he climbed.
        """
    }

    override func tearDown() {
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    func testReadAlongFollowsTheSentenceSeeksOnTapAndShowsAnOlderChapterPlain() throws {
        app.launch()
        makeAudiobook()
        openBooks()
        let done = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "both chapters should come down")
        XCTAssertTrue(waitFor(10) { self.server.requests("GET").contains { $0.path.hasSuffix("/chapters/1/timing") } },
                      "chapter 1's timing was not asked for when it came down")

        // Play chapter 1 and open the full player.
        openBook("Two Rooms")
        let chapterOne = app.cells.containing(.staticText, identifier: "The Cell").firstMatch
        XCTAssertTrue(chapterOne.waitForExistence(timeout: 10), "opening the book shows no chapter 1")
        chapterOne.tap()
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "playing chapter 1 started nothing")
        tapMiniBar(in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "FullPlayerContent").firstMatch
            .waitForExistence(timeout: 10), "the full player did not open")
        XCTAssertFalse(app.buttons["Transcript"].exists, "a book chapter offers Read Along in place of Transcript")

        // Read Along: a sentence is lit, and it moves on as the chapter plays.
        let readAlong = app.buttons["Read Along"].firstMatch
        XCTAssertTrue(readAlong.waitForExistence(timeout: 10), "the full player offers no Read Along for a book")
        readAlong.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "ReadAlong").firstMatch
            .waitForExistence(timeout: 10), "Read Along did not open")
        let sentences = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'readalong-sentence-'"))
        XCTAssertTrue(sentences.firstMatch.waitForExistence(timeout: 10), "no sentences shown")
        let count = sentences.count
        XCTAssertGreaterThanOrEqual(count, 6, "chapter 1 should show its heading and six sentences, got \(count)")
        XCTAssertTrue(waitFor(10) { self.litSentence() != nil }, "no sentence is lit while the chapter plays")
        let firstLit = try XCTUnwrap(litSentence())
        XCTAssertTrue(waitFor(15) { (self.litSentence() ?? -1) > firstLit }, "the highlight did not move on from \(firstLit)")
        attach("read-along-following")

        // Tap a sentence further on: the player seeks there, so it is lit at once rather than
        // after the 20-odd seconds it would take to get there by playing.
        let target = count - 2
        XCTAssertGreaterThan(target, (litSentence() ?? 0) + 1, "the target must be ahead of the playhead")
        let tapped = Date()
        app.buttons["readalong-sentence-\(target)"].tap()
        XCTAssertTrue(waitFor(4) { self.litSentence() == target },
                      "tapping sentence \(target) did not seek there (lit: \(String(describing: litSentence())))")
        report("tap-to-seek: sentence \(target) lit \(String(format: "%.1f", Date().timeIntervalSince(tapped))) s after the tap; \(count) sentences")
        attach("read-along-after-tap")

        // Chapter 2 has no timing: its text shows, plainly, with nothing lit.
        app.buttons["Done"].firstMatch.tap()
        let next = app.buttons.matching(identifier: "Next track").allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(next, "no reachable Next track in the full player").tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'The Surface'")).firstMatch
            .waitForExistence(timeout: 15), "chapter 2 did not start")
        XCTAssertTrue(readAlong.waitForExistence(timeout: 10))
        readAlong.tap()
        let untimed = app.descendants(matching: .any).matching(identifier: "ReadAlongUntimed").firstMatch
        XCTAssertTrue(untimed.waitForExistence(timeout: 10), "a chapter without timing should say why nothing is lit")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'The light at the top was grey'")).firstMatch.exists,
                      "chapter 2's words should show")
        XCTAssertNil(litSentence(), "nothing is lit without timing")
        attach("read-along-untimed")

        // The sleep timer is here too, without going back to the player.
        let sleep = app.buttons["readalong-sleep-timer"].firstMatch
        XCTAssertTrue(sleep.waitForExistence(timeout: 5), "Read Along offers the sleep timer while a book plays")
        XCTAssertEqual(sleep.value as? String, "Off")
        sleep.tap()
        XCTAssertTrue(app.buttons["End of chapter"].firstMatch.waitForExistence(timeout: 5), "the sleep timer offers End of chapter")
        app.buttons["15 minutes"].firstMatch.tap()
        XCTAssertTrue(waitFor(3) { (sleep.value as? String) == "Stops in 15 minutes" },
                      "15 minutes arms the timer (value: \(String(describing: sleep.value)))")
        attach("read-along-sleep-armed")
        sleep.tap()
        let cancel = app.buttons["Cancel sleep timer"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "an armed timer can be cancelled from Read Along")
        cancel.tap()
        XCTAssertTrue(waitFor(3) { (sleep.value as? String) == "Off" }, "Cancel turns the timer off")
    }

    /// Jump to current after the reader has scrolled away: it brings back the sentence
    /// being heard, lit, every time. Paragraphs here run to several spoken chunks each, as a real
    /// book's do; the short sentences of the test above are one chunk to a paragraph, which is
    /// what hid this. The panel numbered its paragraphs and its sentences from 0 alike, so asking
    /// to scroll to sentence 6 could land on paragraph 6, a page further on, with nothing lit.
    func testJumpToCurrentAfterScrollingAwayShowsTheLitSentence() throws {
        app.launchEnvironment["uitestImportText"] = Self.longParagraphBook
        app.launch()
        makeAudiobook()
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch
            .waitForExistence(timeout: 30), "both chapters should come down")
        openBook("Two Rooms")
        let chapterOne = app.cells.containing(.staticText, identifier: "The Cell").firstMatch
        XCTAssertTrue(chapterOne.waitForExistence(timeout: 10), "opening the book shows no chapter 1")
        chapterOne.tap()
        let bar = app.descendants(matching: .any).matching(identifier: PlayerControls.miniBar).firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "playing chapter 1 started nothing")
        XCTAssertTrue(openFullPlayer(in: app))

        // Paused while the test finds a sentence to seek to; tapping it plays on from there.
        let pause = app.buttons.matching(NSPredicate(format: "label == 'Pause' AND identifier != %@", PlayerControls.miniBar))
            .allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(pause, "the full player offers no Pause").tap()
        app.buttons["Read Along"].firstMatch.tap()
        let panel = app.descendants(matching: .any).matching(identifier: "ReadAlong").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Read Along did not open")
        let sentences = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'readalong-sentence-'"))
        XCTAssertTrue(sentences.firstMatch.waitForExistence(timeout: 10), "no sentences shown")
        XCTAssertGreaterThanOrEqual(sentences.count, 30, "each paragraph should be several chunks, got \(sentences.count)")

        // Seek to a sentence early in the chapter, where its number is also a paragraph's.
        let opened = "lit \(litSentence().map(String.init) ?? "none") on opening; \(sentenceFrames(0 ... 12))"
        var target: Int?
        for _ in 0 ..< 12 where target == nil {
            target = (5 ... 9).first { app.buttons["readalong-sentence-\($0)"].isHittable }
            guard target == nil else { break }
            if app.buttons["readalong-sentence-7"].frame.maxY < panel.frame.minY { panel.swipeDown() } else { panel.swipeUp() }
        }
        let lit = try XCTUnwrap(target, "no sentence between 5 and 9 on screen to seek to; \(sentenceFrames(0 ... 12)) panel \(panel.frame)")
        report("Read Along on opening, paused: \(opened); panel \(panel.frame)")
        app.buttons["readalong-sentence-\(lit)"].tap()
        // It plays on from there, so by the first look the next chunk may already be lit.
        XCTAssertTrue(waitFor(5) { self.litSentence().map { (lit ... lit + 1).contains($0) } ?? false },
                      "tapping sentence \(lit) did not light it (lit: \(self.litSentence().map(String.init) ?? "none"))")

        // Scroll away and jump back, twice: the second time after the first jump, as the
        // owner reported it. Swipes go on into the chapter, then a little back. Tapping a
        // sentence seeks there and plays on, so the lit sentence moves while the test swipes
        // (about a second a chunk here): what Jump to current must show is whichever sentence
        // is lit when it is pressed, which is what a listener sees (review of an internal task).
        for (round, swipes) in [[true, true, true], [true, true, true, true, false]].enumerated() {
            for up in swipes { if up { panel.swipeUp() } else { panel.swipeDown() } }
            let jump = app.buttons["Jump to current"].firstMatch
            XCTAssertTrue(jump.waitForExistence(timeout: 5), "scrolling away offers no Jump to current (round \(round))")
            let away = try XCTUnwrap(litSentence(), "no sentence lit before the jump (round \(round))")
            XCTAssertFalse(app.buttons["readalong-sentence-\(away)"].isHittable,
                           "the lit sentence \(away) should be off screen after scrolling away (round \(round))")
            jump.tap()
            var shown: Int?
            XCTAssertTrue(waitFor(4) {
                guard let now = self.litSentence(), self.app.buttons["readalong-sentence-\(now)"].isHittable else { return false }
                shown = now
                return true
            }, "Jump to current did not bring the lit sentence back on screen (round \(round)); lit \(self.litSentence().map(String.init) ?? "none") before the jump \(away); \(sentenceFrames(0 ... 40))")
            report("round \(round): lit \(away) when Jump to current was pressed, lit \(shown.map(String.init) ?? "none") on screen after")
            XCTAssertTrue(waitFor(3) { !jump.exists }, "following should resume after the jump (round \(round))")
            attach("jump-to-current-\(round)")
        }
    }

    /// Chapter 1 in long paragraphs, each four or more spoken chunks (`DocumentSpeech.packTarget`
    /// is 280 characters), so sentence numbers and paragraph numbers part company at once.
    private static let longParagraphBook: String = {
        let sentence = "The machine hummed on through the long evening while she read the old letters again by the light of the screen"
        let paragraphs = (1 ... 10).map { p in
            (1 ... 8).map { s in "Paragraph \(p) line \(s). \(sentence)." }.joined(separator: " ")
        }
        return """
        Two Rooms
        by Nobody in Particular

        Chapter 1 The Cell

        \(paragraphs.joined(separator: "\n\n"))

        Chapter 2 The Surface

        The light at the top was grey, and the hills were bare. He waited a long while for the wind to drop before he climbed.
        """
    }()

    // MARK: - Steps

    /// Where sentences are, for a failure message: id, frame, and whether a tap can reach it.
    private func sentenceFrames(_ ids: ClosedRange<Int>) -> String {
        ids.map { id in
            let element = app.buttons["readalong-sentence-\(id)"]
            guard element.exists else { return "\(id): none" }
            return "\(id): y \(Int(element.frame.minY))...\(Int(element.frame.maxY))\(element.isHittable ? " hittable" : "")"
        }.joined(separator: "; ")
    }

    /// The index of the lit sentence, read from the selected trait.
    private func litSentence() -> Int? {
        let lit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'readalong-sentence-' AND selected == true"))
            .firstMatch
        guard lit.exists else { return nil }
        return Int(lit.identifier.replacingOccurrences(of: "readalong-sentence-", with: ""))
    }

    private func makeAudiobook() {
        XCTAssertTrue(app.staticTexts["Two Rooms"].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")
        let make = app.buttons["make-audiobook"].firstMatch
        var tries = 0
        while !make.exists && tries < 6 {
            app.swipeUp()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            tries += 1
        }
        XCTAssertTrue(make.waitForExistence(timeout: 20), "Make Audiobook was not offered: the fake home server did not answer")
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Don’t Allow", "Don't Allow", "Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        make.tap()
        XCTAssertTrue(waitFor(10) { self.server.requests("PUT").count == 1 }, "Make Audiobook sent nothing")
        app.tap()
        ImportScreen.waitToClose(app)
        removeUIInterruptionMonitor(monitor)
    }

    /// Books has its own Library section since an internal task; the route is `BooksScreen`.
    private func openBooks() {
        BooksScreen.open(app)
    }

    /// A book's row opens the book, which lists its chapters.
    private func openBook(_ title: String) {
        XCTAssertTrue(app.cells.containing(.staticText, identifier: title).firstMatch.waitForExistence(timeout: 10),
                      "no row for \(title)")
        BooksScreen.openBook(app)
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

    private func report(_ text: String) {
        let note = XCTAttachment(string: text)
        note.name = "measured"
        note.lifetime = .keepAlways
        add(note)
    }
}
