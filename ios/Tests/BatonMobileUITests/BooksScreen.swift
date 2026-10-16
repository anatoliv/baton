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
