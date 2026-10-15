import XCTest
@testable import BatonMobile

/// When a document waiting for the import screen takes the screen.
///
/// The import screen used to be asked for the moment a document arrived. With the full player,
/// Settings or any other sheet up, UIKit dropped the request and the document looked lost. These
/// pin the rules that replaced it: close what is in the way, wait for what must not be closed,
/// keep asking until the screen has appeared, and never let the document go before the person
/// has seen it, including across a trip to the background.
final class ImportPresentationTests: XCTestCase {
    private let doc = URL(fileURLWithPath: "/tmp/imports/abcd-Pages.txt")
    private let later = URL(string: "https://example.com/article")!
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func at(_ seconds: TimeInterval, pending: URL?, active: Bool = true, gate: Bool = false,
                    other: Bool = false) -> ImportPresentation.Situation {
        .init(pending: pending, isActive: active, waitsForGate: gate, otherPresentationUp: other,
              now: start.addingTimeInterval(seconds))
    }

    func testNothingPendingIsIdle() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.step(at(0, pending: nil)), .idle)
        XCTAssertNil(presentation.launchContent(pending: nil, whatsNewWanted: false))
    }

    func testArrivingWhileIdleShowsAtOnceAndStopsWatchingOnceSeen() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.step(at(0, pending: doc)), .show(doc))
        XCTAssertEqual(presentation.launchContent(pending: doc, whatsNewWanted: false), .importDocument(doc))
        XCTAssertEqual(presentation.step(at(0.4, pending: doc)), .wait, "keeps watching until the screen appears")
        presentation.appeared(doc)
        XCTAssertEqual(presentation.step(at(0.8, pending: doc)), .idle)
        XCTAssertEqual(presentation.closed(pending: doc, whatsNewWanted: false), .endImport,
                       "closing the screen the person saw ends the import")
    }

    func testArrivingWhileASheetIsUpClosesItFirstThenShows() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.step(at(0, pending: doc, other: true)), .closeOthers)
        XCTAssertNil(presentation.launchContent(pending: doc, whatsNewWanted: false),
                     "not asked for while the player is up: UIKit would drop it")
        XCTAssertEqual(presentation.step(at(0.4, pending: doc, other: true)), .closeOthers, "still closing")
        XCTAssertEqual(presentation.step(at(0.8, pending: doc)), .show(doc))
        presentation.appeared(doc)
        XCTAssertEqual(presentation.step(at(1.2, pending: doc)), .idle)
    }

    func testWhatsNewWaitsAndItsMarkerIsLeftWhileADocumentIsPending() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.launchContent(pending: nil, whatsNewWanted: true), .whatsNew)
        // What's New is the launch sheet itself, not something in the way: the item swaps.
        XCTAssertEqual(presentation.step(at(0, pending: doc)), .show(doc))
        XCTAssertEqual(presentation.launchContent(pending: doc, whatsNewWanted: true), .importDocument(doc))
        // Waiting behind something else, the document holds What's New back too.
        var waiting = ImportPresentation()
        XCTAssertEqual(waiting.step(at(0, pending: doc, gate: true)), .wait)
        XCTAssertNil(waiting.launchContent(pending: doc, whatsNewWanted: true))
        XCTAssertEqual(waiting.closed(pending: doc, whatsNewWanted: true), .keepImport,
                       "What's New making way is not the person closing it: the marker stays")
        XCTAssertEqual(ImportPresentation().closed(pending: nil, whatsNewWanted: true), .markWhatsNewShown)
    }

    func testBackgroundedBeforeItShowsItShowsOnTheNextActivation() {
        var presentation = ImportPresentation()
        // Arrives while the app is not active (an "Open in" delivered before activation).
        XCTAssertEqual(presentation.step(at(0, pending: doc, active: false)), .wait)
        XCTAssertEqual(presentation.step(at(60, pending: doc, active: false)), .wait)
        XCTAssertEqual(presentation.step(at(120, pending: doc)), .show(doc))
    }

    func testASheetTakenAwayBeforeItAppearedIsAskedForAgainOnActivation() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.step(at(0, pending: doc)), .show(doc))
        // Gone to the background before the sheet reached the screen.
        XCTAssertEqual(presentation.step(at(0.2, pending: doc, active: false)), .wait)
        XCTAssertNil(presentation.launchContent(pending: doc, whatsNewWanted: false), "taken back")
        XCTAssertEqual(presentation.closed(pending: doc, whatsNewWanted: false), .keepImport,
                       "the echo of taking it back must not end the import")
        // Back, with the player opened in the meantime.
        XCTAssertEqual(presentation.step(at(30, pending: doc, other: true)), .closeOthers)
        XCTAssertEqual(presentation.step(at(30.4, pending: doc)), .show(doc))
    }

    func testAnImportOnScreenStaysThroughATripAway() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.step(at(0, pending: doc)), .show(doc))
        presentation.appeared(doc)
        XCTAssertEqual(presentation.step(at(5, pending: doc, active: false)), .idle)
        XCTAssertEqual(presentation.launchContent(pending: doc, whatsNewWanted: false), .importDocument(doc))
    }

    func testASheetUIKitDroppedIsAskedForAgainAfterTheGrace() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.step(at(0, pending: doc)), .show(doc))
        XCTAssertEqual(presentation.step(at(ImportPresentation.appearanceGrace - 0.5, pending: doc)), .wait)
        XCTAssertEqual(presentation.step(at(ImportPresentation.appearanceGrace + 0.5, pending: doc)), .wait,
                       "never appeared: taken back")
        XCTAssertNil(presentation.launchContent(pending: doc, whatsNewWanted: false))
        XCTAssertEqual(presentation.step(at(ImportPresentation.appearanceGrace + 1, pending: doc)), .show(doc))
    }

    func testSetupAndRootAlertsAreWaitedForNotClosed() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.step(at(0, pending: doc, gate: true, other: true)), .wait)
        XCTAssertEqual(presentation.step(at(10, pending: doc, gate: true, other: true)), .wait)
        XCTAssertEqual(presentation.step(at(11, pending: doc)), .show(doc))
    }

    func testANewerDocumentTakesOverTheScreen() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.step(at(0, pending: doc)), .show(doc))
        presentation.appeared(doc)
        XCTAssertEqual(presentation.step(at(5, pending: later)), .show(later))
        XCTAssertEqual(presentation.launchContent(pending: later, whatsNewWanted: false), .importDocument(later))
        XCTAssertEqual(presentation.closed(pending: later, whatsNewWanted: false), .keepImport,
                       "the newer one has not been seen yet")
        presentation.appeared(later)
        XCTAssertEqual(presentation.closed(pending: later, whatsNewWanted: false), .endImport)
    }

    func testClosingTheImportScreenClearsThePresentation() {
        var presentation = ImportPresentation()
        XCTAssertEqual(presentation.step(at(0, pending: doc)), .show(doc))
        presentation.appeared(doc)
        XCTAssertEqual(presentation.step(at(3, pending: nil)), .idle)
        XCTAssertNil(presentation.shown)
        XCTAssertEqual(presentation.launchContent(pending: nil, whatsNewWanted: true), .whatsNew,
                       "the notes may have their turn on a later launch path")
    }
}
