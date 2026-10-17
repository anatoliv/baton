import XCTest

/// A book plays through its chapters even when only chapter 1 was on the phone at Play
/// (TBX-10991, "If clip contains multiple chapters play all continuous").
///
/// On `FakeHomeServer`'s three-chapter book, with only chapter 1 ready when Play is pressed:
/// chapter 2 is made while chapter 1 plays (it has to join the playing queue), and chapter 3 only
/// once chapter 2 has ended (the player has to wait for it at the boundary, then play it). The
/// book then stops at the end of chapter 3 and stays stopped.
///
/// Before the fix the queue was fixed at Play with the chapters already here, so the book stopped
/// at the end of chapter 1. Every chapter change is printed with the wall clock as a
/// `TBX-10991 timeline` line, which is the evidence of where it went and when.
///
/// Demo mode, no network beyond loopback. Environment, never launch arguments.
final class BookContinuousChaptersUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!
    private var started = Date()
    private var timeline: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        server = try FakeHomeServer()
        app = XCUIApplication.batonUnderTest()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = server.baseURL
        app.launchEnvironment["uitestGatewayToken"] = "uitest-fake-home-server"
        // A new document every run: the book's id is its text's digest, and a book the
        // simulator already holds would resume where an earlier run left it.
        app.launchEnvironment["uitestImportText"] = """
        Three Rooms
        by Nobody in Particular

        Chapter 1 The Cell

        A small room, like the cell of a bee. The air was fresh, though there was no window. \(UUID().uuidString)

        Chapter 2 The Surface

        The light at the top was grey, and the hills were bare.

        Chapter 3 The Return

        She went back down the stair, and the room was as she had left it.
        """
    }

    override func tearDown() {
        if !timeline.isEmpty {
            let note = XCTAttachment(string: timeline.joined(separator: "\n"))
            note.name = "timeline"
            note.lifetime = .keepAlways
            add(note)
        }
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    func testOnlyChapterOneHereAtPlayStillPlaysTheWholeBook() throws {
        server.setReadyOnSubmit(1)
        app.launch()
        makeAudiobook()
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '1 of 3 chapters'")).firstMatch
            .waitForExistence(timeout: 30), "chapter 1 should come down, and only chapter 1")
        playBookAndOpenPlayer()
        started = Date()
        XCTAssertTrue(title(containing: "The Cell").waitForExistence(timeout: 15), "the book should start at chapter 1")
        note("Play pressed: chapter 1 (The Cell) playing; chapters 2 and 3 not on the phone")
        attach("1-chapter-1-playing-only-chapter-1-here")

        // Chapter 2 is made while chapter 1 plays.
        server.setReady(2)
        note("home server: chapter 2 ready")
        XCTAssertTrue(app.descendants(matching: .any)["0:30"].firstMatch.waitForExistence(timeout: 10),
                      "chapter 1's length never showed")
        // Give the phone time to bring chapter 2 down before chapter 1 ends.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 8))
        seek(toFraction: 0.9)
        note("seek near the end of chapter 1, elapsed \(elapsedLabel)")
        let reachedTwo = title(containing: "The Surface").waitForExistence(timeout: 20)
        note(reachedTwo ? "chapter 2 (The Surface) playing, elapsed \(elapsedLabel)"
                        : "after chapter 1 ended: still \(currentTitle), Play shown \(app.buttons["Play"].firstMatch.exists)")
        attach("2-after-chapter-1-ended")
        XCTAssertTrue(reachedTwo, "chapter 1 should end into chapter 2, which arrived while it played")
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5), "chapter 2 should be playing")

        // Chapter 3 is not made until chapter 2 has ended: the player waits for it.
        XCTAssertTrue(app.descendants(matching: .any)["0:30"].firstMatch.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        seek(toFraction: 0.9)
        note("seek near the end of chapter 2, elapsed \(elapsedLabel); chapter 3 not made yet")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 6))
        note("chapter 2 ended 3 s ago or so: showing \(currentTitle), elapsed \(elapsedLabel)")
        attach("3-waiting-for-chapter-3")
        XCTAssertFalse(title(containing: "The Return").exists, "chapter 3 cannot be playing before it is made")
        let waitingNote = app.staticTexts["player-continuation-note"].firstMatch
        XCTAssertTrue(waitingNote.waitForExistence(timeout: 5), "the player should say it is waiting")
        note("the player says: \(waitingNote.label)")
        XCTAssertEqual(waitingNote.label, "Waiting for chapter 3")
        server.setReady(3)
        note("home server: chapter 3 ready")
        let reachedThree = title(containing: "The Return").waitForExistence(timeout: 30)
        note(reachedThree ? "chapter 3 (The Return) playing, elapsed \(elapsedLabel)" : "chapter 3 never played: \(currentTitle)")
        attach("4-chapter-3-playing")
        XCTAssertTrue(reachedThree, "the player should play chapter 3 once it arrives")
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 10), "chapter 3 should be playing")

        // The end of chapter 3 is the end of the book: stop, and stay stopped.
        XCTAssertTrue(app.descendants(matching: .any)["0:30"].firstMatch.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        seek(toFraction: 0.9)
        note("seek near the end of chapter 3, elapsed \(elapsedLabel)")
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 15), "the book should stop after chapter 3")
        note("stopped on \(currentTitle)")
        let replayed = waitFor(8) { self.app.buttons["Pause"].firstMatch.exists }
        note(replayed ? "chapter 3 started again" : "still stopped 8 s later on \(currentTitle)")
        attach("5-stopped-after-chapter-3")
        XCTAssertFalse(replayed, "the last chapter started again after its end")
    }

    // MARK: - Timeline

    private var elapsedLabel: String { app.staticTexts["player-elapsed"].firstMatch.label }

    private var currentTitle: String {
        for name in ["The Cell", "The Surface", "The Return"] where title(containing: name).exists { return name }
        return "no chapter title"
    }

    private func note(_ line: String) {
        let stamp = String(format: "%6.1f s", Date().timeIntervalSince(started))
        let entry = "TBX-10991 timeline \(stamp)  \(line)"
        print(entry)
        timeline.append(entry)
    }

    // MARK: - Steps (as BookLastChapterUITests)

    private func title(containing text: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// A tap on the waveform scrubber, drawn just above the elapsed time.
    private func seek(toFraction fraction: CGFloat) {
        let elapsed = app.staticTexts["player-elapsed"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5), "no scrubber on the player")
        let frame = elapsed.frame
        let window = app.windows.firstMatch.frame
        let x = frame.minX + fraction * (window.width - 2 * frame.minX)
        let y = frame.minY - 24
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
    }

    private func playBookAndOpenPlayer() {
        // A book's row opens the book; its Play starts it, and the list is shown again so only
        // the player names a chapter.
        BooksScreen.playBookAndLeave(app)
        let title = app.staticTexts.matching(identifier: PlayerControls.miniBar).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "Play started nothing")
        title.tap()
        XCTAssertTrue(app.buttons[PlayerControls.dismissFullPlayer].waitForExistence(timeout: 15),
                      "tapping the mini player must open the full player")
    }

    private func makeAudiobook() {
        if !app.staticTexts["Three Rooms"].firstMatch.waitForExistence(timeout: 30) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(app.staticTexts["Three Rooms"].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")
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
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(waitFor(30) {
            for name in ["Don’t Allow", "Don't Allow"] where springboard.buttons[name].exists {
                springboard.buttons[name].tap()
            }
            return !self.app.buttons["make-audiobook"].exists
        }, "the import screen should close")
        removeUIInterruptionMonitor(monitor)
    }

    /// Books has its own Library section since TBX-11018; the route is `BooksScreen`.
    private func openBooks() {
        BooksScreen.open(app)
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
