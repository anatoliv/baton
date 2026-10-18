import XCTest

/// The way to a book: Library, then **Books**, a section of its own next to
/// Clippings, then a book's row, which opens the book with its chapters, Play or Resume, Read
/// Along, Change Voice and the storage actions. Books were rows in Clippings before; every UI
/// test that reaches a book goes through here, so the route is written once.
enum BooksScreen {
    /// Library, then Books.
    static func open(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20), "no Library tab", file: file, line: line)
        library.tap()
        let entry = app.cells.containing(.staticText, identifier: "Books").firstMatch
        if entry.waitForExistence(timeout: 10) { entry.tap() } else {
            let fallback = app.buttons["Books"].firstMatch
            XCTAssertTrue(fallback.waitForExistence(timeout: 10), "no route to Books", file: file, line: line)
            fallback.tap()
        }
    }

    /// The first book's row in the list.
    static func row(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-' AND NOT identifier BEGINSWITH 'book-play' AND NOT identifier BEGINSWITH 'book-read-along'")).firstMatch
    }

    /// The open book's Play (or Resume) button.
    static func playButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["book-play"].firstMatch
    }

    /// Open the first book in the list.
    static func openBook(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = row(app)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the book row did not appear", file: file, line: line)
        row.tap()
        XCTAssertTrue(playButton(app).waitForExistence(timeout: 10), "opening the book shows no Play\n\(app.debugDescription)",
                      file: file, line: line)
    }

    /// Open the first book in the list and press Play (Resume, when there is a place).
    static func playBook(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openBook(app, file: file, line: line)
        playButton(app).tap()
    }

    /// Play the first book, then go back to the list, so the chapter titles on the open book's
    /// page are not on screen behind the player: a test that asks "which chapter is playing" by
    /// a title must find it in the player alone.
    static func playBookAndLeave(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        playBook(app, file: file, line: line)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button on the open book", file: file, line: line)
        back.tap()
        XCTAssertTrue(row(app).waitForExistence(timeout: 10), "not back on the Books list", file: file, line: line)
    }
}

/// The import screen after Make Audiobook. It closes only once the book is on
/// its way and the notification question, asked once per install, has been answered
/// (`DocumentImportScreen.submit` awaits `requestNotificationPermission` before `onDone`). The
/// suites answered that question through an interruption monitor, which fires only on the next
/// interaction: their one `app.tap()` came about 0.4 s after the alert on an idle iPhone 18 Pro
/// simulator (iOS 27.0), and when the alert came later the screen stayed up behind it. Then
/// "the import screen should close" failed, or Library was tapped under the sheet and "no route
/// to Books" did. This answers the alert on SpringBoard itself for as long as it waits.
enum ImportScreen {
    static func waitToClose(_ app: XCUIApplication, timeout: TimeInterval = 30,
                            file: StaticString = #filePath, line: UInt = #line) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let make = app.buttons["make-audiobook"].firstMatch
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            for name in ["Don’t Allow", "Don't Allow"] where springboard.buttons[name].exists {
                springboard.buttons[name].tap()
            }
            if !make.exists { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        // TBX-1000000071: one run stopped here with Make Audiobook disabled, the screen still
        // awaiting the book's PUT or the notification permission request, and only Baton's
        // hierarchy was kept, so which, and whether an alert was up, could not be told. Eight
        // later runs on fresh simulators closed in about 2 s, through the interruption monitor and
        // through a copy of this loop. Say what SpringBoard shows too, so a next occurrence names
        // its cause.
        XCTFail("""
            the import screen should close (Make Audiobook \(make.exists && make.isEnabled ? "enabled" : "disabled") \
            after \(Int(timeout)) s)
            BATON:
            \(app.debugDescription)
            SPRINGBOARD:
            \(springboard.debugDescription)
            """, file: file, line: line)
    }
}
