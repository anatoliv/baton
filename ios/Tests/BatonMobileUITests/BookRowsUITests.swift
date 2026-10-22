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

        // Collected on open: opening Books asks the home server about the book.
        let opened = Date()
        openBooks()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'of 2 chapters ready'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the book row did not appear")
        XCTAssertTrue(waitFor(10) { !self.server.statusReads(since: opened).isEmpty }, "opening Books asked nothing")
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
        XCTAssertEqual(server.statusReads(since: quietStart).count, 0, "the watch should stop when Books closes")

        // Collected on becoming active: chapter 1 is ready while the app is away, and comes down
        // the moment it is back, with Books not on screen.
        server.setReady(1)
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
        let back = Date()
        app.activate()
        XCTAssertTrue(waitFor(10) { !self.server.statusReads(since: back).isEmpty }, "becoming active asked nothing")
        XCTAssertTrue(waitFor(10) { self.server.requests("GET", since: back).contains { $0.path.hasSuffix("/chapters/1") } },
                      "chapter 1 was not collected on becoming active")
        report("active: first read \(String(format: "%.1f", server.statusReads(since: back)[0].at.timeIntervalSince(back))) s after activation")

        openBooks()
        let oneReady = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '1 of 2 chapters ready'")).firstMatch
        XCTAssertTrue(oneReady.waitForExistence(timeout: 15), "the row should count chapter 1 as ready")
        attach("book-row-one-ready")

        // Expanding the book lists its chapters; playing from chapter 1 starts the player.
        openBook("Two Rooms")
        let chapter = app.buttons.containing(NSPredicate(format: "label CONTAINS 'The Cell'")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10), "opening the book shows no chapter 1\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'The Surface'")).firstMatch.exists,
                      "chapter 2 should be listed while it is being made")
        attach("book-expanded")
        // The middle of the row, where nothing is written: the whole row plays, not only its words.
        app.cells.containing(.staticText, identifier: "The Cell").firstMatch.tap()
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "playing from chapter 1 started nothing")
        attach("playing-chapter-1")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'The Cell'")).firstMatch.exists)

        // Stop Making This Book, from the row's menu in the list: the home server is told to
        // delete it.
        let id = try XCTUnwrap(server.bookIDs.first)
        app.navigationBars.buttons.element(boundBy: 0).tap()
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

    // MARK: - Books and Clippings are two sections

    /// The book is in Books and not in Clippings; a kept reading is in Clippings and not in
    /// Books. The open book lists its chapters with Play and Read Along, and its storage.
    func testBooksHoldTheBookAndClippingsKeepTheReadings() throws {
        server.setReadyOnSubmit(2)
        app.launchEnvironment["baton.seedClipping"] = "1"
        app.launch()
        makeAudiobook()
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch
            .waitForExistence(timeout: 30), "both chapters should come down into Books")
        XCTAssertTrue(app.staticTexts["Two Rooms"].firstMatch.exists, "the book is listed in Books")
        XCTAssertFalse(app.staticTexts["Deploy products"].exists, "a kept reading is not a book")
        attach("books-list")

        BooksScreen.openBook(app)
        XCTAssertTrue(app.buttons["book-read-along"].firstMatch.exists, "the open book offers Read Along")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'The Cell'")).firstMatch.exists,
                      "the open book lists chapter 1")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'The Surface'")).firstMatch.exists,
                      "the open book lists chapter 2")
        attach("book-detail")

        // A chapter played from the open book: its row carries the playing bars.
        app.cells.containing(.staticText, identifier: "The Cell").firstMatch.tap()
        let bar = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "playing chapter 1 started nothing")
        XCTAssertTrue(waitFor(10) {
            self.app.buttons.containing(NSPredicate(format: "label CONTAINS 'The Cell' AND value == 'Now playing'")).firstMatch.exists
        }, "the playing chapter's row should say Now playing")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        attach("book-detail-chapter-playing")

        // Back to Library, then Clippings: the reading, and no book or chapter.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let entry = app.cells.containing(.staticText, identifier: "Clippings").firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "no Clippings row in Library")
        entry.tap()
        XCTAssertTrue(app.staticTexts["Deploy products"].firstMatch.waitForExistence(timeout: 20),
                      "the kept reading should be in Clippings")
        // Rows only: the mini player names the chapter playing and its book.
        XCTAssertFalse(app.cells.containing(.staticText, identifier: "Two Rooms").firstMatch.exists,
                       "the book should not be in Clippings")
        XCTAssertFalse(app.cells.containing(.staticText, identifier: "The Cell").firstMatch.exists,
                       "a book's chapter should not be in Clippings")
        attach("clippings-readings-only")
    }

    // MARK: - Resuming where the other device left off

    /// Play on a book with no chapter chosen resumes at the synced position (
    /// `specs/document-clippings.md`: chapter 2 at 10:00 on the Mac resumes there on the iPhone).
    /// The position is put in the shared ledger at launch through `uitestBookPosition`, where a
    /// `PreferenceSync` merge from the Mac would put it: chapter 2 (index 1), 15 seconds in.
    func testPlayResumesAtTheSyncedChapterAndOffset() throws {
        server.setReadyOnSubmit(2)
        app.launch()
        makeAudiobook()
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 chapters'")).firstMatch
            .waitForExistence(timeout: 30), "both chapters should come down")

        // Relaunch with the synced position, keeping what this phone holds.
        app.terminate()
        app.launchEnvironment["baton.resetSession"] = nil
        app.launchEnvironment["uitestImportText"] = nil
        app.launchEnvironment["uitestBookPosition"] = "1:15"
        app.launch()
        openBooks()
        let row = BooksScreen.row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the book row did not appear")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '% heard'")).firstMatch.exists,
                      "the synced position should show as heard")
        attach("book-with-synced-position")
        // The row opens the book; its Play (Resume, with a place) starts it. The open
        // book lists every chapter's title, so which one plays is read from the mini player.
        row.tap()
        XCTAssertTrue(BooksScreen.playButton(app).waitForExistence(timeout: 10), "opening the book shows no Play")
        BooksScreen.playButton(app).tap()

        let bar = app.descendants(matching: .any).matching(identifier: PlayerControls.miniBar).firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "Play started nothing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS 'The Surface'", PlayerControls.miniBar))
            .firstMatch.waitForExistence(timeout: 10), "Play should start at the synced chapter 2, The Surface")
        XCTAssertTrue(openFullPlayer(in: app))
        let elapsed = app.staticTexts["player-elapsed"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), "no elapsed time in the full player")
        // Resumed at 0:15 and playing; from the start it would read 0:00 to 0:05 here.
        let resumed = waitFor(10) {
            let parts = elapsed.label.split(separator: ":")
            guard parts.count == 2, parts[0] == "0", let s = Int(parts[1]) else { return false }
            return (14...24).contains(s)
        }
        report("elapsed after Play: \(elapsed.label)")
        attach("playing-chapter-2-resumed")
        XCTAssertTrue(resumed, "the player should be near 0:15 in chapter 2, not \(elapsed.label)")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'The Surface'")).firstMatch.exists)
    }

    // MARK: - Previously…

    /// Play on a book last heard two days ago offers "Previously…"; Hear Recap asks the music
    /// friend's model (here an OpenAI-shaped model on loopback, which counts as the person's
    /// network) with only the heard text, has the home server say it in a voice other than the
    /// narrator's, then plays the book from the synced chapter.
    func testPlayAfterADayAwayOffersPreviouslyThenPlays() throws {
        let one = (1...30).map { "Ada wound the great clock in the hall for the \($0) time that winter." }.joined(separator: " ")
        let twoHeard = (1...10).map { "A letter came that was not from Tobias, number \($0)." }.joined(separator: " ")
        let twoUnheard = (1...10).map { "Inside the case she found the little glass key, turn \($0)." }.joined(separator: " ")
        app.launchEnvironment["uitestImportText"] = """
        The Clock
        by Nobody in Particular

        Chapter 1 The House

        \(one)

        Chapter 2 The Letter

        \(twoHeard)

        \(twoUnheard)

        Chapter 3 The Return

        Tobias came home and would not say who sent the letter.
        """
        app.launchEnvironment["baton.agent.route"] = "direct"
        app.launchEnvironment["baton.agent.provider"] = "openAICompatible"
        app.launchEnvironment["baton.agent.baseURL"] = server.baseURL + "/v1"
        app.launchEnvironment["baton.agent.model"] = "fake-recap"
        app.launchEnvironment["uitestNoOnDeviceModel"] = "1"
        server.setReadyOnSubmit(3)
        app.launch()
        makeAudiobook(title: "The Clock")
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '3 chapters'")).firstMatch
            .waitForExistence(timeout: 30), "all three chapters should come down")

        // Relaunch with the synced position halfway into chapter 2, last heard 48 hours ago.
        app.terminate()
        app.launchEnvironment["baton.resetSession"] = nil
        app.launchEnvironment["uitestImportText"] = nil
        app.launchEnvironment["uitestBookPosition"] = "1:15:48"
        app.launch()
        openBooks()
        // A book's row opens the book; its Play starts it.
        BooksScreen.playBook(app)

        let hear = app.buttons["hear-recap"].firstMatch
        XCTAssertTrue(hear.waitForExistence(timeout: 10), "Play after two days should offer Previously…\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Previously…"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'It has been a while since you heard The Clock'"))
            .firstMatch.exists)
        XCTAssertTrue(app.buttons["Just Play"].firstMatch.exists)
        let bar = app.descendants(matching: .any).matching(identifier: PlayerControls.miniBar).firstMatch
        XCTAssertFalse(bar.exists, "nothing plays until the offer is answered")
        attach("previously-offer")

        let asked = Date()
        hear.tap()
        XCTAssertTrue(waitFor(20) { !self.server.requests("POST", since: asked).filter { $0.path == "/v1/chat/completions" }.isEmpty },
                      "Hear Recap asked no model")
        let prompt = try XCTUnwrap(server.bodies("/v1/chat/completions").last.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(prompt.contains("Ada wound the great clock"), "the heard chapter 1 is in the prompt")
        XCTAssertTrue(prompt.contains("number 10."), "the heard half of chapter 2 is in the prompt")
        XCTAssertFalse(prompt.contains("glass key"), "the unheard half of chapter 2 reached the model")
        XCTAssertFalse(prompt.contains("Tobias came home"), "chapter 3 reached the model")

        XCTAssertTrue(waitFor(20) { !self.server.bodies("/v1/speech/preview").isEmpty }, "the recap was not spoken by the home server")
        let speech = try XCTUnwrap(server.bodies("/v1/speech/preview").last
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let voice = try XCTUnwrap(speech["voice"] as? String)
        let narrator = try XCTUnwrap(server.narrators.first)
        report("narrator \(narrator), recap voice \(voice), recap: \(speech["text"] as? String ?? "")")
        XCTAssertNotEqual(voice, narrator, "the recap must not be in the narrator's voice")
        XCTAssertTrue((speech["text"] as? String)?.hasPrefix("Previously, Ada wound the great clock") == true)

        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the book did not play after the recap")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS 'The Letter'", PlayerControls.miniBar))
            .firstMatch.waitForExistence(timeout: 10), "the book should carry on at the synced chapter 2")
        attach("previously-then-playing")
    }

    /// A phone whose music friend is a cloud model reaches no model of its own. With a
    /// home server from before the book route (404), Hear Recap asks the Mac's question before any
    /// chapter goes to that provider, and Not Now plays the book with nothing sent. Once the home
    /// server answers the route, the recap is written there, from the heard text only.
    func testARecapThroughTheHomeServerAndTheCloudOnlyWhenAllowed() throws {
        let one = (1...30).map { "Ada wound the great clock in the hall for the \($0) time that winter." }.joined(separator: " ")
        let twoHeard = (1...10).map { "A letter came that was not from Tobias, number \($0)." }.joined(separator: " ")
        let twoUnheard = (1...10).map { "Inside the case she found the little glass key, turn \($0)." }.joined(separator: " ")
        app.launchEnvironment["uitestImportText"] = """
        The Clock
        by Nobody in Particular

        Chapter 1 The House

        \(one)

        Chapter 2 The Letter

        \(twoHeard)

        \(twoUnheard)

        Chapter 3 The Return

        Tobias came home and would not say who sent the letter.
        """
        // A hosted model the phone may not send chapters to unasked. The address is never reached.
        app.launchEnvironment["baton.agent.route"] = "direct"
        app.launchEnvironment["baton.agent.provider"] = "anthropic"
        app.launchEnvironment["baton.agent.baseURL"] = "https://api.anthropic.com"
        app.launchEnvironment["baton.agent.model"] = "claude-haiku-4-5-20251001"
        app.launchEnvironment["uitestAgentAPIKey"] = "uitest-not-a-real-key"
        app.launchEnvironment["uitestNoOnDeviceModel"] = "1"
        server.setReadyOnSubmit(3)
        app.launch()
        makeAudiobook(title: "The Clock")
        openBooks()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '3 chapters'")).firstMatch
            .waitForExistence(timeout: 30), "all three chapters should come down")

        // An older home server: the route is not there.
        let bar = app.descendants(matching: .any).matching(identifier: PlayerControls.miniBar).firstMatch
        relaunchTwoDaysLater()
        let older = Date()
        app.buttons["hear-recap"].firstMatch.tap()
        let ask = app.descendants(matching: .any)["recap-consent-ask"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 20), "the cloud question should be asked\n\(app.debugDescription)")
        XCTAssertEqual(ask.label, "Send the chapters you have heard to Anthropic to write a recap?")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Nothing on this iPhone, your network or the Baton server could write one.'"))
            .firstMatch.exists)
        XCTAssertFalse(server.requests("POST", since: older).filter { $0.path == "/v1/books/complete" }.isEmpty,
                       "the home server was tried first")
        XCTAssertFalse(bar.exists, "the book waits for the answer")
        attach("recap-consent-question")
        app.buttons["recap-consent-not-now"].firstMatch.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "Not Now plays the book as it is")

        // The home server now answers the route.
        server.setAnswersBookTasks(true)
        relaunchTwoDaysLater()
        let asked = Date()
        app.buttons["hear-recap"].firstMatch.tap()
        let writtenBy = app.staticTexts["recap-written-by"].firstMatch
        XCTAssertTrue(writtenBy.waitForExistence(timeout: 20), "no recap was written\n\(app.debugDescription)")
        XCTAssertEqual(writtenBy.label, "Written by your Baton server")
        attach("recap-through-home-server")
        XCTAssertFalse(app.descendants(matching: .any)["recap-consent-ask"].firstMatch.exists, "not asked: the home server wrote it")
        let prompt = try XCTUnwrap(server.bodies("/v1/books/complete").last
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["user"] as? String)
        XCTAssertTrue(prompt.contains("Ada wound the great clock"), "the heard chapter 1 is in the prompt")
        XCTAssertTrue(prompt.contains("number 10."), "the heard half of chapter 2 is in the prompt")
        XCTAssertFalse(prompt.contains("glass key"), "the unheard half of chapter 2 reached the home server")
        XCTAssertFalse(prompt.contains("Tobias came home"), "chapter 3 reached the home server")
        XCTAssertEqual(server.requests("POST", since: asked).filter { $0.path == "/v1/books/complete" }.count, 1)
        XCTAssertTrue(waitFor(20) { !self.server.bodies("/v1/speech/preview").isEmpty }, "the recap was not spoken")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the book did not play after the recap")
        report("route bodies \(server.bodies("/v1/books/complete").count), recap: \(server.bodies("/v1/speech/preview").last.flatMap { String(data: $0, encoding: .utf8) } ?? "")")
    }

    /// Relaunch with the synced position halfway into chapter 2, last heard 48 hours ago, and
    /// press Play on the book, which offers Previously….
    private func relaunchTwoDaysLater() {
        app.terminate()
        app.launchEnvironment["baton.resetSession"] = nil
        app.launchEnvironment["uitestImportText"] = nil
        app.launchEnvironment["uitestBookPosition"] = "1:15:48"
        app.launch()
        openBooks()
        // A book's row opens the book; its Play starts it.
        BooksScreen.playBook(app)
        XCTAssertTrue(app.buttons["hear-recap"].firstMatch.waitForExistence(timeout: 10), "Play after two days should offer Previously…")
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

    /// Remove from this iPhone: the book leaves this phone's list and the home server keeps its
    /// copy for the other devices. The phone hides it, so the next collection, which
    /// lists the home server's books, does not adopt it again.
    func testAFinishedBookCanBeRemovedFromThisPhone() throws {
        let (id, menuAt) = try openDeleteQuestionOnAFinishedBook()
        app.buttons["Remove from this iPhone"].firstMatch.tap()
        XCTAssertTrue(waitFor(10) { !self.app.staticTexts["Two Rooms"].exists }, "the removed book is still listed")
        attach("book-removed-from-phone")

        // A fresh collection: leaving and opening Books again lists the home server's books.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let reopened = Date()
        openBooks()
        XCTAssertTrue(waitFor(15) { self.server.requests("GET", since: reopened).contains { $0.path == "/v1/books" } },
                      "opening Books again did not list the home server's books")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
        XCTAssertFalse(app.staticTexts["Two Rooms"].exists, "the next listing adopted the removed book again")
        XCTAssertFalse(server.requests("DELETE", since: menuAt).contains { $0.path == "/v1/books/\(id)" },
                       "Remove from this iPhone should leave the home server's copy for the other devices")
        XCTAssertTrue(server.bookIDs.contains(id), "the home server should still keep the book")
        attach("book-removed-not-adopted-again")
    }

    /// Make a book whose chapters are all ready, open Books, and press Delete Book… in its row's menu.
    private func openDeleteQuestionOnAFinishedBook() throws -> (id: String, menuAt: Date) {
        server.setReadyOnSubmit(2)
        app.launch()
        makeAudiobook()
        openBooks()

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

    private func makeAudiobook(title: String = "Two Rooms") {
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 30), "the import screen did not open")
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
