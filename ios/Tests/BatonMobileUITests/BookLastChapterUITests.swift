import XCTest

/// Next onto a book's last chapter, then let that chapter end: the book stops. It must not play
/// the last chapter a second time.
///
/// The TBX-10974 walk's own steps, on `FakeHomeServer`'s three-chapter book: chapter 2 reached by
/// a gapless boundary (so chapter 3 sits preloaded behind it), Next onto chapter 3, a scrubber
/// seek near its end straight away, and the end. Before the fix the seek dropped the skip blend,
/// chapter 2 played on under chapter 3's name, rolled into the stale preload of chapter 3, and
/// chapter 3 started again.
///
/// An XCUITest tap arrives after the 0.32 s blend has usually been promoted, so this walk passes
/// against the unfixed player too; `NextOntoLastItemTests` in BatonPlaybackKit reproduces the
/// race itself. This one guards the whole user path: the book stops on its last chapter.
///
/// Demo mode, no network beyond loopback. Environment, never launch arguments.
final class BookLastChapterUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!

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
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    func testNextOntoTheLastChapterThenItsEndStopsWithoutReplaying() throws {
        server.setReadyOnSubmit(3)
        app.launch()
        makeAudiobook()
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '3 chapters'")).firstMatch
            .waitForExistence(timeout: 30), "all three chapters should come down")
        playBookAndOpenPlayer()
        XCTAssertTrue(title(containing: "The Cell").waitForExistence(timeout: 15), "the book should start at chapter 1")

        // Chapter 1 to chapter 2 across a natural end: the gapless boundary preloads chapter 3.
        seek(toFraction: 0.9)
        XCTAssertTrue(title(containing: "The Surface").waitForExistence(timeout: 20), "chapter 1 should end into chapter 2")
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        attach("1-chapter-2-playing")

        // Next onto chapter 3, then the walk's race: a scrubber tap at once. The chapter's length
        // may not be known yet at that moment, so that tap can land near the start; the second
        // seek, once the length shows, takes the chapter close to its end.
        nextTrack()
        XCTAssertTrue(title(containing: "The Return").waitForExistence(timeout: 5), "Next should land on chapter 3")
        seek(toFraction: 0.9)
        XCTAssertTrue(app.descendants(matching: .any)["0:30"].firstMatch.waitForExistence(timeout: 10),
                      "the chapter's length never showed")
        seek(toFraction: 0.9)
        attach("2-chapter-3-after-next-and-seek")
        // The seek must have landed near the end, or the end below is not the one under test.
        let elapsed = app.staticTexts["player-elapsed"].firstMatch
        XCTAssertTrue(waitFor(5) { (elapsed.label.split(separator: ":").last.flatMap { Int($0) } ?? 0) >= 20 },
                      "the seek after Next did not land near the end: elapsed \(elapsed.label)")

        // The end of chapter 3 is the end of the book: the player stops, on chapter 3.
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 15),
                      "the book did not stop at the end of its last chapter\n\(app.debugDescription)")
        attach("3-after-the-end")
        // And stays stopped: a replay would bring Pause back with chapter 3 from the top.
        let replayed = waitFor(8) { self.app.buttons["Pause"].firstMatch.exists }
        attach("4-eight-seconds-later")
        XCTAssertFalse(replayed, "the last chapter started again after its end")
        XCTAssertTrue(title(containing: "The Return").exists, "the player should still show the last chapter")
    }

    /// After Next at 1.5×, the next chapter really runs at 1.5×: media time against the wall
    /// clock over about 15 s. The blend's incoming player used to start at 1× and
    /// keep it, while the player still said 1.5×.
    func testTheChapterAfterNextPlaysAtTheChosenSpeed() throws {
        server.setReadyOnSubmit(3)
        app.launch()
        makeAudiobook()
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '3 chapters'")).firstMatch
            .waitForExistence(timeout: 30), "all three chapters should come down")
        playBookAndOpenPlayer()
        // Paused while the speed is chosen, so chapter 1 cannot run out under the menu.
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 10))
        tapReachable("Pause")
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5), "Pause did not pause")
        XCTAssertTrue(title(containing: "The Cell").waitForExistence(timeout: 5), "the book should start at chapter 1")

        let speed = app.buttons["Playback speed"].firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        speed.tap()
        XCTAssertTrue(app.buttons["1.5×"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["1.5×"].firstMatch.tap()
        XCTAssertTrue(waitFor(5) { (speed.value as? String) == "1.5×" }, "the speed should show 1.5×")

        // Next on a *playing* chapter is the skip blend under test.
        tapReachable("Play")
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5), "Play did not resume")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        nextTrack()
        XCTAssertTrue(title(containing: "The Surface").waitForExistence(timeout: 5), "Next should land on chapter 2")
        attach("speed-1-chapter-2-after-next")

        // Every change of the elapsed label, stamped with the wall clock: the first and last
        // ticks bound the measurement to a quarter of a second either way.
        let elapsed = app.staticTexts["player-elapsed"].firstMatch
        func seconds(_ label: String) -> Int? {
            let parts = label.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
        }
        var ticks: [(wall: Date, media: Int)] = []
        var last: Int?
        let end = Date(timeIntervalSinceNow: 15)
        while Date() < end {
            if let now = seconds(elapsed.label), now != last {
                ticks.append((Date(), now)); last = now
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        attach("speed-2-chapter-2-after-15-seconds")
        XCTAssertTrue(title(containing: "The Surface").exists, "still on chapter 2")
        guard ticks.count >= 3, let first = ticks.dropFirst().first, let final = ticks.last else {
            return XCTFail("too few elapsed ticks: \(ticks.map(\.media))")
        }
        let wall = final.wall.timeIntervalSince(first.wall)
        let media = Double(final.media - first.media)
        let rate = media / wall
        let report = String(format: "TBX-10988 measurement: media %.0f s over wall %.2f s = %.3f× (ticks %@)",
                            media, wall, rate, ticks.map { String($0.media) }.joined(separator: ","))
        print(report)
        let note = XCTAttachment(string: report)
        note.name = "speed-measurement"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertEqual(rate, 1.5, accuracy: 0.08, report)
    }

    // MARK: - Steps

    private func title(containing text: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The full player's own Next, not the mini bar's behind the sheet.
    private func nextTrack() { tapReachable("Next track") }

    /// The full player's control with this label: the mini bar behind the sheet carries the same
    /// labels, and its buttons are in the tree but not on screen.
    private func tapReachable(_ label: String) {
        let buttons = app.buttons.matching(identifier: label)
        for index in 0 ..< buttons.count where buttons.element(boundBy: index).isHittable {
            buttons.element(boundBy: index).tap()
            return
        }
        XCTFail("no reachable \(label) button")
    }

    /// A tap on the waveform scrubber, drawn just above the elapsed time, the way the walk
    /// seeked. (The player's only slider is the volume.)
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
        // The launch-time import sheet is occasionally not presented on a cold simulator; one
        // relaunch with the same environment is the honest retry, not a longer wait.
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
