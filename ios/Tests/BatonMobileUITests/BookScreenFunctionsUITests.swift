import XCTest

/// Every control on the iPhone's open book, against `FakeHomeServer`: Play, then
/// Pause and Resume on the same button while the book is in the player, the chapter row in the
/// player toggling it, "% heard" following the playhead, the two buttons one line each and the
/// same size at the default and accessibility text sizes, and, while the home server makes the
/// book again in another voice, Change Voice…, Stop Making Again, Remove Download and getting it
/// back, Keep on This iPhone, the sleep timer, the mini player and Back.
///
/// The owner's report: "Resume" while the book played, text only beside an iconed "Read Along"
/// that wrapped onto two lines, static dots for the playing chapter, and the header and the
/// "Making again…" line under the navigation bar when scrolled. Screenshots of each step are
/// attached to the result (`BookScreen-*`), at the same scroll positions.
///
/// Demo mode, no network beyond loopback, preference sync off. Environment, never launch
/// arguments, except Apple's text size flag.
final class BookScreenFunctionsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        // Narrated chapters only for the test about them: they are seconds long, and the walk
        // through every control would outlive the book. The tones are two minutes each, so
        // chapter 1 is still playing when the walk ends: with 30-second chapters chapter 2
        // started as the sleep timer's menu opened, the menu stayed up and ignored the tap on
        // "15 minutes", and the run failed on a toolbar button the open menu hid
        //
        server = try FakeHomeServer(speech: name.contains("RealSpeech"), chapterSeconds: 120)
        server.setReadyOnSubmit(3)
        server.setVoices(["kokoro:af_heart", "kokoro:am_adam", "kokoro:bf_emma"])
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = server.baseURL
        app.launchEnvironment["uitestGatewayToken"] = "uitest-fake-home-server"
        app.launchEnvironment["uitestImportText"] = """
        The Machine Stops
        by E. M. Forster

        Chapter 1 The Air-Ship

        Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee.

        It is lighted neither by window nor by lamp, yet it is filled with a soft radiance.

        Chapter 2 The Mending Apparatus

        By her side, on the little reading-desk, was a survival from the ages of litter.

        Chapter 3 The Homeless

        The light at the top was grey, and the hills were bare.
        """
    }

    override func tearDown() {
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    /// Play, Pause, Resume, the chapter row, "% heard", then every control while the book is
    /// made again in another voice.
    func testTheOpenBooksControlsWhilePlayingAndWhileItIsMadeAgain() throws {
        app.launch()
        openTheBook()
        let main = BooksScreen.playButton(app)
        let readAlong = app.buttons["book-read-along"].firstMatch
        XCTAssertEqual(main.label, "Play", "a book never heard offers Play")
        assertButtonsMatch(main, readAlong, "at the default text size")
        attach("BookScreen-01-play")

        // Play: the button becomes Pause, and "% heard" follows the playhead.
        main.tap()
        XCTAssertTrue(waitFor(10) { main.label == "Pause" }, "while the book plays the button is Pause, got \(main.label)")
        XCTAssertTrue(waitFor(10) { self.heard() != nil }, "\"% heard\" should follow the playhead while it plays")
        let firstHeard = heard()
        assertButtonsMatch(main, readAlong, "while it plays")
        let chapterOne = chapterRow("The Air-Ship")
        XCTAssertEqual(chapterOne.value as? String, "Now playing", "the chapter in the player says so")
        attach("BookScreen-02-playing-pause")

        // Pause, then Resume, from the same button.
        main.tap()
        XCTAssertTrue(waitFor(5) { main.label == "Resume" }, "paused, the button is Resume, got \(main.label)")
        XCTAssertTrue(waitFor(5) { chapterOne.value as? String == "Paused" }, "the chapter row says paused")
        attach("BookScreen-03-paused-resume")
        main.tap()
        XCTAssertTrue(waitFor(5) { main.label == "Pause" }, "Resume carries on; got \(main.label)")
        XCTAssertTrue(waitFor(12) { self.heard() != firstHeard }, "\"% heard\" moved on from \(firstHeard ?? "nothing")")

        // The chapter in the player toggles it rather than starting it again.
        chapterOne.tap()
        XCTAssertTrue(waitFor(5) { main.label == "Resume" }, "a tap on the playing chapter pauses it; got \(main.label)")
        chapterOne.tap()
        XCTAssertTrue(waitFor(5) { main.label == "Pause" }, "a second tap carries on; got \(main.label)")

        // Scrolled: the header and the status line stay clear of the navigation bar.
        app.swipeUp()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        attach("BookScreen-04-scrolled-playing")
        app.swipeDown()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))

        // Change Voice…: the home server makes it again in Adam's voice, and holds it there.
        server.setReadyOnSubmit(0)
        revealAbovePlayer(app.buttons["Change Voice…"].firstMatch).tap()
        let adam = app.buttons["narrator-kokoro:am_adam"].firstMatch
        XCTAssertTrue(adam.waitForExistence(timeout: 15), "Change Voice offers Adam\n\(app.debugDescription)")
        adam.tap()
        app.buttons["make-again"].firstMatch.tap()
        // The line is in the header: back to the top, where a small screen's lazy list has it.
        let remaking = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Making again'")).firstMatch
        for _ in 0..<4 where !remaking.exists {
            app.swipeDown()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        }
        XCTAssertTrue(remaking.waitForExistence(timeout: 20), "the book says it is being made again")
        app.swipeDown()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        attach("BookScreen-05-remaking-top")
        app.swipeUp()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        attach("BookScreen-06-remaking-scrolled")
        app.swipeDown()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))

        // Every control still works while it is made again.
        XCTAssertEqual(main.label, "Pause", "still playing in the old voice")
        main.tap()
        XCTAssertTrue(waitFor(5) { main.label == "Resume" }, "Pause works while the book is made again")
        main.tap()
        XCTAssertTrue(waitFor(5) { main.label == "Pause" }, "Resume works while the book is made again")

        // The switch itself, at the row's trailing edge: a tap in the middle of the row is on
        // its label, which a SwiftUI Toggle in a List does not take.
        // Scrolled until the switch sits above the floating mini player, as a person would: below
        // it, a tap lands on the mini player (its close button stopped the book in one run).
        let keep = revealAbovePlayer(app.switches.matching(NSPredicate(format: "label == 'Keep on This iPhone'")).firstMatch)
        let keptBefore = keep.value as? String
        let knob = keep.switches.firstMatch.exists ? keep.switches.firstMatch : keep
        report("Keep on This iPhone: row \(keep.frame), knob \(knob.frame), hittable \(knob.isHittable), value \(keptBefore ?? "?")")
        attach("BookScreen-06a-keep-before")
        knob.tap()
        let toggled = waitFor(3) { (keep.value as? String) != keptBefore }
        attach("BookScreen-06b-keep-after")
        XCTAssertTrue(toggled, "Keep on This iPhone toggles (\(keptBefore ?? "?") -> \(keep.value as? String ?? "?"))")
        knob.tap()
        XCTAssertTrue(waitFor(3) { (keep.value as? String) == keptBefore }, "and back")

        let sleep = app.buttons["books-sleep-timer"].firstMatch
        XCTAssertTrue(sleep.waitForExistence(timeout: 5), "the sleep timer is in the bar while something plays")
        sleep.tap()
        XCTAssertTrue(app.buttons["End of chapter"].firstMatch.waitForExistence(timeout: 5), "the sleep timer offers End of chapter")
        // A fixed time rather than End of chapter: the narrated chapters here are seconds long,
        // so the chapter could end, and the timer with it, before Cancel is looked for.
        let minutes = app.buttons["15 minutes"].firstMatch
        XCTAssertTrue(minutes.exists, "the sleep timer offers 15 minutes")
        minutes.tap()
        sleep.tap()
        let cancelSleep = app.buttons["Cancel sleep timer"].firstMatch
        XCTAssertTrue(cancelSleep.waitForExistence(timeout: 5), "an armed timer can be cancelled")
        cancelSleep.tap()

        // Going back to the old voice resubmits it; the home server has it made already.
        server.setReadyOnSubmit(3)
        let stop = revealAbovePlayer(app.buttons["Stop Making Again"].firstMatch)
        stop.tap()
        for _ in 0..<4 { app.swipeDown(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4)) }
        XCTAssertTrue(waitFor(15) { !remaking.exists }, "Stop Making Again ends the voice change")
        XCTAssertEqual(main.label, "Pause", "and the book plays on")
        attach("BookScreen-07-stopped-remaking")

        // The mini player opens the full player, while the book plays. (Remove Download, next,
        // takes the book's chapters out of the player, and the mini player with them.)
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the mini player is there while a chapter is in the player")
        tapMiniBar(in: app)   // not bar.tap(): the first match can be the bar's Pause
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "FullPlayerContent").firstMatch
            .waitForExistence(timeout: 10), "the mini player opens the full player")
        attach("BookScreen-08b-full-player")
        app.swipeDown(velocity: .fast)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))

        // Remove Download, then get the book back; the player stops with it.
        main.tap()
        XCTAssertTrue(waitFor(5) { main.label == "Resume" })
        revealAbovePlayer(app.buttons["Remove Download"].firstMatch).tap()
        let back = app.buttons.matching(NSPredicate(format: "label == 'Download Again' OR label == 'Render Again'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "a removed book offers to come back")
        attach("BookScreen-08-removed")
        back.tap()
        XCTAssertTrue(waitFor(30) { self.app.staticTexts["On this phone"].exists }, "the book is back on this phone")

        // Back returns to the list.
        let navBack = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(navBack.waitForExistence(timeout: 5))
        navBack.tap()
        XCTAssertTrue(BooksScreen.row(app).waitForExistence(timeout: 10), "Back returns to the Books list")
        attach("BookScreen-09-list")
    }

    /// Owner report, 2026-10-17: "after changing the voice, the old voices stays active until
    /// application is restarted". A book playing when the home server has made
    /// it again goes on in the new voice, at the same place, without a relaunch: here the new
    /// voice's chapters are a minute long against the old two, so the full player's length says
    /// which audio the player holds.
    func testABookPlayingWhenItsNewVoiceLandsIsHeardInIt() throws {
        try server.setChapterSeconds(60, forNarrator: "kokoro:am_adam")
        app.launch()
        openTheBook()
        let main = BooksScreen.playButton(app)
        main.tap()
        XCTAssertTrue(waitFor(10) { main.label == "Pause" }, "the book plays, got \(main.label)")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 6))

        openFullPlayer(in: app)
        let content = app.descendants(matching: .any).matching(identifier: "FullPlayerContent").firstMatch
        let elapsed = app.staticTexts["player-elapsed"].firstMatch
        XCTAssertTrue(content.buttons["2:00"].firstMatch.waitForExistence(timeout: 10),
                      "chapter 1 in the old voice is two minutes long\n\(app.debugDescription)")
        report("before the change: \(elapsed.label) of 2:00 at \(Date())")
        attach("VoiceLive-01-old-voice")
        dismissFullPlayer(in: app)

        // Change Voice…: the home server has it made at once (`setReadyOnSubmit(3)`).
        revealAbovePlayer(app.buttons["Change Voice…"].firstMatch).tap()
        let adam = app.buttons["narrator-kokoro:am_adam"].firstMatch
        XCTAssertTrue(adam.waitForExistence(timeout: 15), "Change Voice offers Adam")
        adam.tap()
        app.buttons["make-again"].firstMatch.tap()
        report("Make Again pressed at \(Date())")

        openFullPlayer(in: app)
        XCTAssertTrue(content.buttons["1:00"].firstMatch.waitForExistence(timeout: 60),
                      "the playing chapter is the new voice's one-minute audio, without a relaunch\n\(app.debugDescription)")
        report("after the change: \(elapsed.label) of 1:00 at \(Date())")
        attach("VoiceLive-02-new-voice")
        let first = elapsed.label
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
        XCTAssertNotEqual(elapsed.label, first, "and it plays on")
        dismissFullPlayer(in: app)
        XCTAssertEqual(server.narrators.sorted(), ["kokoro:am_adam"], "the home server holds the book in its new voice only")
    }

    /// The two buttons at larger text sizes: one line each and the same size side by side while
    /// that fits, else stacked at full width, never wrapped.
    func testTheButtonsAtLargerTextSizes() throws {
        for size in ["UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityL"] {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
            app.launch()
            openTheBook()
            let main = BooksScreen.playButton(app)
            let readAlong = app.buttons["book-read-along"].firstMatch
            main.tap()
            XCTAssertTrue(waitFor(10) { main.label == "Pause" }, "Pause at \(size)")
            assertButtonsMatch(main, readAlong, "at \(size)")
            attach("BookScreen-10-\(size)")
            main.tap()
            app.terminate()
        }
    }

    /// With real narrated chapters (the runner given `BATON_UITEST_SPEECH_DIR`): the playing
    /// chapter's bars while speech plays, and Read Along's lit sentence against the chapter's own
    /// timing, sampled every tenth of a second from the moment Play was pressed.
    @MainActor
    func testTheBarsAndReadAlongWithRealSpeech() throws {
        guard let folder = ProcessInfo.processInfo.environment["BATON_UITEST_SPEECH_DIR"], !folder.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_BATON_UITEST_SPEECH_DIR to a folder of chapter-N.m4a and chapter-N.timing.json")
        }
        let timing = try JSONDecoder().decode(Timing.self, from: Data(contentsOf: URL(fileURLWithPath: folder)
            .appendingPathComponent("chapter-1.timing.json")))
        app.launchEnvironment["uitestImportText"] = """
        Probe Machine
        by Nobody in Particular

        Chapter 1 The Cell

        Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee.

        Chapter 2 The Tube

        The airship rose from the tube without a sound.

        Chapter 3 The Surface

        The light at the top was grey, and the hills were bare.
        """
        app.launch()
        makeAudiobook(title: "Probe Machine")
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '3 chapters'")).firstMatch
            .waitForExistence(timeout: 40), "all three chapters should come down")
        BooksScreen.openBook(app)
        let main = BooksScreen.playButton(app)
        main.tap()
        XCTAssertTrue(waitFor(10) { main.label == "Pause" }, "the book plays")
        // The bars over a second and a half of speech.
        for i in 1...4 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            attach("BookScreen-11-speech-bars-\(i)")
        }
        app.buttons["book-read-along"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "ReadAlong").firstMatch
            .waitForExistence(timeout: 10), "Read Along opens")
        // The panel's own playhead (DEBUG accessibility value) and the lit sentence, read in one
        // query each step: XCUITest takes most of a second per query, so lags measured against
        // the wall clock were mostly the test's own. Against the playhead the panel was given,
        // a sentence is lit late only by the panel's own lag.
        let panel = app.descendants(matching: .any).matching(identifier: "ReadAlong").firstMatch
        let sentences = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'readalong-sentence-'"))
        XCTAssertTrue(sentences.firstMatch.waitForExistence(timeout: 10), "Read Along shows sentences")
        func sample() -> (playhead: Double, lit: Int?)? {
            let snapshot = try? panel.snapshot()
            guard let value = snapshot?.value as? String, value.hasPrefix("playhead "),
                  let playhead = Double(value.dropFirst("playhead ".count)) else { return nil }
            func find(_ node: XCUIElementSnapshot) -> Int? {
                if node.isSelected, node.identifier.hasPrefix("readalong-sentence-") {
                    return Int(node.identifier.dropFirst("readalong-sentence-".count))
                }
                for child in node.children { if let found = find(child) { return found } }
                return nil
            }
            return (playhead, snapshot.flatMap(find))
        }
        let from = 1
        app.buttons["readalong-sentence-\(from)"].firstMatch.tap()
        var samples: [(playhead: Double, lit: Int?)] = []
        let end = Date(timeIntervalSinceNow: 14)
        while Date() < end {
            if let s = sample() { samples.append(s) }
        }
        attach("BookScreen-12-speech-read-along")
        // A sample is wrong when the lit sentence is not the one whose span holds the playhead.
        // As the panel counts it: a sentence starts 5 ms early (`ReadAlong.startTolerance`), for
        // the player's 1/600 s clock.
        func expected(_ t: Double) -> Int { max(timing.segments.lastIndex { $0.start <= t + 0.005 } ?? 0, 0) }
        let wrong = samples.filter { $0.lit != expected($0.playhead) }
        let line = samples.prefix(40).map { String(format: "%.2f→%@", $0.playhead, $0.lit.map(String.init) ?? "-") }
            .joined(separator: " ")
        report("read-along on the phone after a tap on sentence \(from) (starts \(String(format: "%.2f", timing.segments[from].start)) s): "
            + "first playhead \(samples.first.map { String(format: "%.2f", $0.playhead) } ?? "-") s; \(samples.count) samples, "
            + "\(wrong.count) with another sentence lit than the playhead's: \(line)")
        let first = try XCTUnwrap(samples.first, "the panel reported no playhead")
        XCTAssertEqual(first.playhead, timing.segments[from].start, accuracy: 0.6,
                       "the tap seeks to the sentence's start: \(line)")
        XCTAssertGreaterThan(samples.last?.playhead ?? 0, timing.segments[from + 1].start, "it played on: \(line)")
        XCTAssertLessThanOrEqual(wrong.count, 1, "the lit sentence is the one at the playhead: \(line)")
    }

    private struct Timing: Decodable {
        struct Segment: Decodable { var start: Double }
        var segments: [Segment]
    }

    // MARK: - Steps

    private func openTheBook() {
        makeAudiobook()
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '3 chapters'")).firstMatch
            .waitForExistence(timeout: 40), "all three chapters should come down")
        BooksScreen.openBook(app)
        XCTAssertTrue(chapterRow("The Air-Ship").waitForExistence(timeout: 10), "the open book lists chapter 1")
    }

    /// Library, then Books; at the larger text sizes on a small phone, Books is below the fold.
    private func openBooks() {
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
    }

    private func chapterRow(_ title: String) -> XCUIElement {
        app.buttons.containing(.staticText, identifier: title).firstMatch
    }

    private func heard() -> String? {
        let text = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '% heard'")).firstMatch
        return text.exists ? text.label : nil
    }

    /// The two buttons the same height and width side by side, or each the full width stacked;
    /// one line each: as tall as each other, and no taller than one line of the label's text.
    private func assertButtonsMatch(_ main: XCUIElement, _ readAlong: XCUIElement, _ when: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let a = main.frame, b = readAlong.frame
        XCTAssertEqual(a.height, b.height, accuracy: 1, "the buttons are the same height \(when): \(a) \(b)", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 1, "the buttons are the same width \(when): \(a) \(b)", file: file, line: line)
        let sideBySide = abs(a.minY - b.minY) < 1
        let window = app.windows.firstMatch.frame
        if !sideBySide {
            XCTAssertGreaterThan(a.width, window.width * 0.7, "stacked, each button is full width \(when)", file: file, line: line)
        }
        report("buttons \(when): \(sideBySide ? "side by side" : "stacked"), \(Int(a.width))×\(Int(a.height)) and \(Int(b.width))×\(Int(b.height)) in a \(Int(window.width)) pt window")
    }

    /// Scroll in small steps until `element` sits between the navigation bar and the floating
    /// mini player, as a person would: below the player a tap lands on the player (its close
    /// button stopped the book in one run), and a full swipe on a small phone carried the row
    /// past the top.
    private func revealAbovePlayer(_ element: XCUIElement) -> XCUIElement {
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        let window = app.windows.firstMatch.frame
        func step(_ points: CGFloat) {   // positive scrolls the content up
            let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -points)))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        for _ in 0..<14 {
            let bottom = bar.exists ? bar.frame.minY - 4 : window.maxY - 40
            let top = window.minY + 140
            if element.exists, element.frame.minY.isFinite {
                if element.frame.maxY > bottom { step(120); continue }
                if element.frame.minY < top { step(-120); continue }
                break
            }
            step(160)
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) can be scrolled into view")
        if bar.exists {
            XCTAssertLessThan(element.frame.maxY, bar.frame.minY, "\(element) can be scrolled clear of the mini player")
        }
        return element
    }

    private func reveal(_ element: XCUIElement) -> XCUIElement {
        var tries = 0
        while !(element.exists && element.isHittable) && tries < 6 {
            app.swipeUp()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            tries += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "not found: \(element)")
        return element
    }

    private func makeAudiobook(title: String = "The Machine Stops") {
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")
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
        XCTAssertTrue(waitFor(10) { !self.server.requests("PUT").isEmpty }, "Make Audiobook sent nothing")
        app.tap()
        ImportScreen.waitToClose(app)
        removeUIInterruptionMonitor(monitor)
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
