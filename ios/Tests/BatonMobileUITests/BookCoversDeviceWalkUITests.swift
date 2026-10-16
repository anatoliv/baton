import XCTest

/// The rest of book covers on the phone, against a throwaway loopback home server:
/// the book row's long-press Cover items, Choose Image… from a picture in Files, the lock
/// screen's Now Playing artwork, and, because the player now prefers a track's own picture,
/// a podcast episode's artwork in the player.
///
/// Opt-in: each test skips unless the runner has what it needs. `BATON_LIVE_GATEWAY_URL` and
/// `BATON_LIVE_GATEWAY_TOKEN` name a home server that lists a book; `BATON_LIVE_COVER_FILE` is
/// the name of a picture already in the simulator's Files ("On My iPhone");
/// `BATON_LIVE_PODCAST_FEED` is an RSS feed whose episode has its own picture. Everything reaches
/// the app by its launch environment, never argv.
final class BookCoversDeviceWalkUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    func testTheRowsCoverItemsChooseImageFromFilesAndTheLockScreen() throws {
        guard let url = env["BATON_LIVE_GATEWAY_URL"], let token = env["BATON_LIVE_GATEWAY_TOKEN"], !token.isEmpty,
              let file = env["BATON_LIVE_COVER_FILE"], !file.isEmpty else {
            throw XCTSkip("set BATON_LIVE_GATEWAY_URL, BATON_LIVE_GATEWAY_TOKEN and BATON_LIVE_COVER_FILE")
        }
        app.launchEnvironment["uitestGatewayURL"] = url
        app.launchEnvironment["uitestGatewayToken"] = token
        let monitor = allowNotifications()
        defer { removeUIInterruptionMonitor(monitor) }
        app.launch()
        BooksScreen.open(app)
        let row = BooksScreen.row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 90), "the home server's book was not adopted")
        pause(4)
        attach("c01-books-list")

        // The row's long-press menu carries the same cover items as the open book.
        row.press(forDuration: 1.2)
        let make = app.buttons["Make a Cover"].firstMatch
        XCTAssertTrue(make.waitForExistence(timeout: 5), "no Make a Cover in the row's long-press menu")
        XCTAssertTrue(app.buttons["Find Cover…"].firstMatch.exists, "no Find Cover… in the row's long-press menu")
        XCTAssertTrue(app.buttons["Choose Image…"].firstMatch.exists, "no Choose Image… in the row's long-press menu")
        attach("c02-row-long-press-cover-items")
        make.tap()
        pause(3)
        attach("c03-row-made-cover")

        // Choose Image… from the row: the system's file picker, a picture in Files.
        row.press(forDuration: 1.2)
        let choose = app.buttons["Choose Image…"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
        pause(3)
        attach("c04-file-picker")
        let picked = pickFromFiles(named: file)
        attach("c05-file-picked")
        XCTAssertTrue(picked, "could not pick \(file) in the file picker\n\(app.debugDescription)")
        pause(4)
        attach("c06-row-chosen-cover")

        // The lock screen's Now Playing shows the cover while a chapter plays.
        BooksScreen.playBook(app)
        pause(4)
        attach("c07-playing")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        pause(3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap(); pause(3) }
        attach("c08-lock-screen-now-playing")
        // Wake the screen without unlocking, which shows the Now Playing card.
        XCUIDevice.shared.press(.home)
        pause(2)
        attach("c09-lock-screen-awake")
        // Unlock, then Control Center: its Now Playing module draws from MPNowPlayingInfoCenter.
        XCUIDevice.shared.press(.home)
        pause(2)
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.6)))
        pause(3)
        attach("c10-control-center-now-playing")
    }

    func testAPodcastEpisodeShowsItsOwnPictureInThePlayer() throws {
        guard let feed = env["BATON_LIVE_PODCAST_FEED"], !feed.isEmpty else {
            throw XCTSkip("set BATON_LIVE_PODCAST_FEED to an RSS feed whose episode has its own picture")
        }
        app.launch()
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        let podcasts = app.cells.containing(.staticText, identifier: "Podcasts").firstMatch
        var tries = 0
        while !podcasts.exists && tries < 5 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(podcasts.waitForExistence(timeout: 10), "no Podcasts in Library")
        podcasts.tap()
        let add = app.buttons["Add podcast feed"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let alert = app.alerts["Add podcast feed"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no Add podcast feed alert")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(feed)
        attach("p00-feed-typed")
        // A plain tap on an alert button over the keyboard did not land on this runtime (the
        // alert stayed up and the feed was never asked for), so the button is pressed by its
        // centre, and Return is the fallback.
        alert.buttons["Subscribe"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if !waitUntilGone(alert, timeout: 5) { field.typeText("\n") }
        XCTAssertTrue(waitUntilGone(alert, timeout: 10), "the alert stayed up after Subscribe")
        // The show is a card in the grid or a row in the list; either way its label says its title.
        let show = labelled("Cover Probe Radio")
        XCTAssertTrue(show.waitForExistence(timeout: 30), "the feed's show did not appear\n\(app.debugDescription)")
        pause(2)
        attach("p01-podcast-subscribed")
        show.tap()
        let episode = labelled("An Episode With Its Own Picture")
        XCTAssertTrue(episode.waitForExistence(timeout: 15), "the episode is not listed\n\(app.debugDescription)")
        episode.tap()
        pause(5)
        attach("p02-podcast-playing-mini-player")
        // The mini player, to open the full one: the last element carrying the episode's title.
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "An Episode With Its Own Picture"))
        if all.count > 1 { all.element(boundBy: all.count - 1).tap() }
        pause(3)
        attach("p03-podcast-full-player")
    }

    // MARK: - Helpers

    /// The system file picker, wherever it opens: Browse, On My iPhone, then the file.
    private func pickFromFiles(named name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        func fileElement() -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", stem)).firstMatch
        }
        if fileElement().waitForExistence(timeout: 4) { fileElement().tap(); return true }
        for label in ["Browse", "Locations"] where app.buttons[label].firstMatch.exists {
            app.buttons[label].firstMatch.tap()
            pause(1)
        }
        let onMyPhone = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
        if onMyPhone.waitForExistence(timeout: 6) { onMyPhone.tap(); pause(2) }
        attach("c04b-file-picker-on-my-iphone")
        guard fileElement().waitForExistence(timeout: 8) else { return false }
        fileElement().tap()
        // Some pickers ask to confirm with Open.
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 2) { open.tap() }
        return true
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func labelled(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND (elementType == %d OR elementType == %d OR elementType == %d)",
                                                             text, XCUIElement.ElementType.button.rawValue,
                                                             XCUIElement.ElementType.staticText.rawValue,
                                                             XCUIElement.ElementType.cell.rawValue)).firstMatch
    }

    private func allowNotifications() -> NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Allow", "Don’t Allow", "Don't Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
    }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
