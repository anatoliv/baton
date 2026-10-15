import XCTest

/// The phone's book rows and how chapters are collected (M5.3), against `FakeHomeServer` in this
/// runner: the app is told its address through `uitestGatewayURL` (DEBUG only), and every
/// request it makes is recorded with its time, so "collected on open", "every five seconds while
/// a book is being made", "on becoming active" and "Stop Making This Book deletes it on the home
/// server" are read from what the app actually asked, not from its own log.
///
/// Demo mode, no network beyond loopback. Environment, never launch arguments.
final class BookRowsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: FakeHomeServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        server = try FakeHomeServer()
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
        server?.stop()
        server = nil
        app = nil
        super.tearDown()
    }

    // MARK: - A book being made

    func testABookBeingMadeIsWatchedCollectedOnReturnPlayedAndStopped() throws {
        app.launch()
        makeAudiobook()

        // Collected on open: opening Clippings asks the home server about the book.
        let opened = Date()
        openClippings()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'of 2 chapters ready'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the book row did not appear")
        XCTAssertTrue(waitFor(10) { !self.server.statusReads(since: opened).isEmpty }, "opening Clippings asked nothing")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Making chapter 1 of 2'")).firstMatch
            .waitForExistence(timeout: 10), "the row should say chapter 1 is being made")

        // The five-second watch: while the screen shows a book still being made, the app asks
        // again every five seconds or so, on its own. Measured after the opening collection has
        // settled, since a look on open can fall within a second of a watch tick.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        let watchStart = Date()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 16))
        let reads = server.statusReads(since: watchStart).map(\.at)
        let gaps = zip(reads.dropFirst(), reads).map { $0.timeIntervalSince($1) }
        report("watch: \(reads.count) status reads in 16 s, gaps \(gaps.map { String(format: "%.1f", $0) })")
        XCTAssertGreaterThanOrEqual(reads.count, 2, "the screen should keep asking while the book is being made")
        XCTAssertLessThanOrEqual(reads.count, 5, "asking far more often than every five seconds")
        XCTAssertTrue(gaps.contains { (4.0...7.0).contains($0) }, "no two reads about five seconds apart: \(gaps)")

        // Off screen the watch stops, so a later read can only be the app becoming active.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
        let quietStart = Date()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 8))
        XCTAssertEqual(server.statusReads(since: quietStart).count, 0, "the watch should stop when Clippings closes")

        // Collected on becoming active: chapter 1 is ready while the app is away, and comes down
        // the moment it is back, with Clippings not on screen.
        server.setReady(1)
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
        let back = Date()
        app.activate()
        XCTAssertTrue(waitFor(10) { !self.server.statusReads(since: back).isEmpty }, "becoming active asked nothing")
        XCTAssertTrue(waitFor(10) { self.server.requests("GET", since: back).contains { $0.path.hasSuffix("/chapters/1") } },
                      "chapter 1 was not collected on becoming active")
        report("active: first read \(String(format: "%.1f", server.statusReads(since: back)[0].at.timeIntervalSince(back))) s after activation")

        openClippings()
        let oneReady = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '1 of 2 chapters ready'")).firstMatch
        XCTAssertTrue(oneReady.waitForExistence(timeout: 15), "the row should count chapter 1 as ready")
        attach("book-row-one-ready")

        // Expanding the book lists its chapters; playing from chapter 1 starts the player.
        expand("Two Rooms")
        let chapter = app.buttons.containing(NSPredicate(format: "label CONTAINS 'The Cell'")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10), "expanding the book shows no chapter 1\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'The Surface'")).firstMatch.exists,
                      "chapter 2 should be listed while it is being made")
        attach("book-expanded")
        // The middle of the row, where nothing is written: the whole row plays, not only its words.
        app.cells.containing(.staticText, identifier: "The Cell").firstMatch.tap()
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "playing from chapter 1 started nothing")
        attach("playing-chapter-1")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'The Cell'")).firstMatch.exists)

        // Stop Making This Book: the home server is told to delete it.
        let id = try XCTUnwrap(server.bookIDs.first)
        let menuAt = Date()
        longPressBook("Two Rooms")
        let stop = app.buttons["Stop Making This Book"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "a book being made offers Stop Making This Book")
        XCTAssertFalse(app.buttons["Delete Book…"].exists, "Delete Book… is for a book that is no longer being made")
        stop.tap()
        XCTAssertTrue(waitFor(10) { self.server.requests("DELETE", since: menuAt).contains { $0.path == "/v1/books/\(id)" } },
                      "Stop Making This Book did not delete the book on the home server")
        let making = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Making chapter'")).firstMatch
        XCTAssertTrue(waitFor(10) { !making.exists }, "the row should no longer say the book is being made")
        attach("book-stopped")
    }

    // MARK: - A finished book

    /// Delete Book… asks first, then Delete Everywhere has the home server stop keeping it.
    func testAFinishedBookCanBeDeletedEverywhere() throws {
        let (id, menuAt) = try openDeleteQuestionOnAFinishedBook()
        app.buttons["Delete Everywhere"].firstMatch.tap()
        XCTAssertTrue(waitFor(10) { self.server.requests("DELETE", since: menuAt).contains { $0.path == "/v1/books/\(id)" } },
                      "Delete Everywhere should have the home server stop keeping the book")
        XCTAssertTrue(waitFor(10) { !self.app.staticTexts["Two Rooms"].exists }, "the deleted book is still listed")
        attach("book-deleted-everywhere")
    }

    /// Remove from this iPhone: the book leaves this phone's list and, as the question says, the
    /// home server stops keeping it too.
    func testAFinishedBookCanBeRemovedFromThisPhone() throws {
        let (id, menuAt) = try openDeleteQuestionOnAFinishedBook()
        app.buttons["Remove from this iPhone"].firstMatch.tap()
        XCTAssertTrue(waitFor(10) { self.server.requests("DELETE", since: menuAt).contains { $0.path == "/v1/books/\(id)" } },
                      "Remove from this iPhone should have the home server stop keeping the book")
        XCTAssertTrue(waitFor(10) { !self.app.staticTexts["Two Rooms"].exists }, "the removed book is still listed")
        attach("book-removed-from-phone")
    }

    /// Make a book whose chapters are all ready, open Clippings, and press Delete Book….
    private func openDeleteQuestionOnAFinishedBook() throws -> (id: String, menuAt: Date) {
        server.setReadyOnSubmit(2)
        app.launch()
        makeAudiobook()
        openClippings()

        let done = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "both chapters should come down")
        let id = try XCTUnwrap(server.bookIDs.first)

        let menuAt = Date()
        longPressBook("Two Rooms")
        let delete = app.buttons["Delete Book…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "a finished book offers Delete Book…")
        XCTAssertFalse(app.buttons["Stop Making This Book"].exists, "nothing is being made any more")
        delete.tap()

        // The question first: nothing is removed by the menu item alone.
        XCTAssertTrue(app.buttons["Remove from this iPhone"].firstMatch.waitForExistence(timeout: 5),
                      "Delete Book… should ask before removing anything")
        XCTAssertTrue(app.buttons["Delete Everywhere"].firstMatch.exists)
        attach("delete-book-question")
        XCTAssertTrue(server.requests("DELETE", since: menuAt).isEmpty, "asked, not yet answered: nothing deleted")
        return (id, menuAt)
    }

    // MARK: - Steps

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
        // The notification question comes after the book is on its way; this answers it.
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Don’t Allow", "Don't Allow", "Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        make.tap()
        XCTAssertTrue(waitFor(10) { self.server.requests("PUT").count == 1 }, "Make Audiobook sent nothing")
        app.tap()
        XCTAssertTrue(waitFor(20) { !self.app.buttons["make-audiobook"].exists }, "the import screen should close")
        removeUIInterruptionMonitor(monitor)
    }

    private func openClippings() {
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20), "no Library tab")
        library.tap()
        let entry = app.cells.containing(.staticText, identifier: "Clippings").firstMatch
        if entry.waitForExistence(timeout: 10) { entry.tap() } else {
            let fallback = app.buttons["Clippings"].firstMatch
            XCTAssertTrue(fallback.waitForExistence(timeout: 10), "no route to Clippings")
            fallback.tap()
        }
    }

    /// The book's row is a disclosure group: its chevron opens the chapters, its label plays.
    private func expand(_ title: String) {
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "no row for \(title)")
        let chevron = cell.buttons.allElementsBoundByIndex.first { !$0.identifier.hasPrefix("book-") }
        if let chevron, chevron.exists { chevron.tap() } else {
            // SwiftUI puts the disclosure indicator at the row's trailing edge.
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
    }

    private func longPressBook(_ title: String) {
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "no row for \(title)")
        cell.press(forDuration: 1.2)
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
