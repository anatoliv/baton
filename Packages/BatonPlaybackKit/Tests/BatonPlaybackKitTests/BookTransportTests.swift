import XCTest
@testable import BatonPlaybackKit

/// The open book's main button and progress, the same on the Mac and the iPhone.
/// The owner's report: "play/resume never changes and it does not work properly", with the Mac
/// showing "Resume" and "0% heard" while chapter 1 of The Machine Stops played.
final class BookTransportTests: XCTestCase {
    // MARK: - The main button

    /// The book in the player and playing: Pause, which only pauses the player.
    func testTheBookPlayingOffersPause() {
        let action = BookTransport.action(isLoaded: true, isPlaying: true, finished: false, hasPosition: true)
        XCTAssertEqual(action, .pause)
        XCTAssertEqual(action.title, "Pause")
        XCTAssertEqual(action.symbol, "pause.fill")
        XCTAssertTrue(action.togglesPlayer)
    }

    /// The book in the player and paused: Resume, which carries on from the playhead rather than
    /// queuing the book again from its saved place.
    func testTheBookPausedInThePlayerResumesThePlayer() {
        let action = BookTransport.action(isLoaded: true, isPlaying: false, finished: false, hasPosition: true)
        XCTAssertEqual(action, .resumePlayer)
        XCTAssertEqual(action.title, "Resume")
        XCTAssertEqual(action.symbol, "play.fill")
        XCTAssertTrue(action.togglesPlayer)
    }

    /// A book in the player is toggled whatever its ledger says: finished, or never saved yet.
    func testTheBookInThePlayerIsToggledEvenWhenFinishedOrUnsaved() {
        XCTAssertEqual(BookTransport.action(isLoaded: true, isPlaying: true, finished: true, hasPosition: false), .pause)
        XCTAssertEqual(BookTransport.action(isLoaded: true, isPlaying: false, finished: true, hasPosition: true), .resumePlayer)
    }

    /// Not in the player: Resume from the saved place when there is one and the book is not
    /// finished, which keeps the place pull and "Previously…".
    func testAnotherBookWithAPlaceResumesFromIt() {
        let action = BookTransport.action(isLoaded: false, isPlaying: true, finished: false, hasPosition: true)
        XCTAssertEqual(action, .resumeFromPlace)
        XCTAssertEqual(action.title, "Resume")
        XCTAssertFalse(action.togglesPlayer)
    }

    /// Not in the player, never heard or finished: Play, from the start.
    func testAnotherBookNeverHeardOrFinishedPlays() {
        XCTAssertEqual(BookTransport.action(isLoaded: false, isPlaying: false, finished: false, hasPosition: false), .play)
        XCTAssertEqual(BookTransport.action(isLoaded: false, isPlaying: false, finished: true, hasPosition: true), .play)
        XCTAssertEqual(BookTransport.Action.play.title, "Play")
        XCTAssertFalse(BookTransport.Action.play.togglesPlayer)
    }

    /// From the shared collection rule: playing is Pause, paused there is Resume
    /// (the player's), and not in the player (including a book that ran to its end) goes back to
    /// the book's own place: Resume from it, or Play for a finished book.
    func testTheButtonFollowsTheSharedCollectionRule() {
        XCTAssertEqual(BookTransport.action(.playing, finished: false, hasPosition: true), .pause)
        XCTAssertEqual(BookTransport.action(.paused, finished: true, hasPosition: true), .resumePlayer)
        XCTAssertEqual(BookTransport.action(.idle, finished: false, hasPosition: true), .resumeFromPlace)
        XCTAssertEqual(BookTransport.action(.idle, finished: true, hasPosition: true), .play)
        XCTAssertEqual(BookTransport.action(.idle, finished: false, hasPosition: false), .play)
    }

    /// One source per book, by document id, of a kind every build can decode; another book,
    /// or a song of the same title, is not the same collection.
    func testABookPlaysUnderItsOwnSource() {
        let book = BookTransport.source(documentID: "doc-machine", title: "The Machine Stops")
        XCTAssertEqual(book.kind, .song)
        XCTAssertEqual(book.id, "doc-machine")
        XCTAssertTrue(book.isSameCollection(as: BookTransport.source(documentID: "doc-machine", title: "Renamed")))
        XCTAssertFalse(book.isSameCollection(as: BookTransport.source(documentID: "doc-other", title: "The Machine Stops")))
        XCTAssertFalse(book.isSameCollection(as: .init(label: "The Machine Stops", kind: .song, id: nil)))
    }

    // MARK: - A chapter row

    /// The chapter in the player toggles it; any other chapter plays the book from there.
    func testATapOnTheChapterInThePlayerTogglesIt() {
        XCTAssertEqual(BookTransport.chapterTap(isCurrentChapter: true, isPlaying: true), .pause)
        XCTAssertEqual(BookTransport.chapterTap(isCurrentChapter: true, isPlaying: false), .resumePlayer)
        XCTAssertNil(BookTransport.chapterTap(isCurrentChapter: false, isPlaying: true))
        XCTAssertNil(BookTransport.chapterTap(isCurrentChapter: false, isPlaying: false))
    }

    // MARK: - Progress

    private let chapters: [(index: Int, seconds: Double)] = [(0, 1500), (1, 1320), (2, 1260)]

    /// While a chapter is in the player the place is the playhead, not the saved place, which
    /// trails it (the owner's "0% heard" ten minutes into chapter 1).
    func testThePlaceIsThePlayheadWhileTheBookIsInThePlayer() {
        let place = BookTransport.place(loadedChapter: 0, playhead: 600, saved: (0, 3))
        XCTAssertEqual(place?.chapterIndex, 0)
        XCTAssertEqual(place?.seconds, 600)
        let fraction = BookTransport.fraction(chapters: chapters, place: place, finished: false, live: true)
        XCTAssertEqual(fraction, 600.0 / 4080, accuracy: 0.0001)
        XCTAssertEqual(BookTransport.heardText(fraction), "15% heard")
    }

    /// Not in the player: the saved place, and none for a book never heard.
    func testThePlaceIsTheSavedOneOtherwise() {
        let place = BookTransport.place(loadedChapter: nil, playhead: 600, saved: (1, 42))
        XCTAssertEqual(place?.chapterIndex, 1)
        XCTAssertEqual(place?.seconds, 42)
        XCTAssertEqual(BookTransport.fraction(chapters: chapters, place: place, finished: false), (1500.0 + 42) / 4080, accuracy: 0.0001)
        XCTAssertNil(BookTransport.place(loadedChapter: nil, playhead: 0, saved: nil))
        XCTAssertEqual(BookTransport.fraction(chapters: chapters, place: nil, finished: false), 0)
    }

    /// A finished book reads as all heard, until it is in the player again: then the playhead.
    func testAFinishedBookIsAllHeardUntilItIsHeardAgain() {
        XCTAssertEqual(BookTransport.fraction(chapters: chapters, place: (2, 1260), finished: true), 1)
        XCTAssertEqual(BookTransport.fraction(chapters: chapters, place: (0, 30), finished: true, live: true), 30.0 / 4080,
                       accuracy: 0.0001)
    }

    /// Never past 1, never below 0, and nothing without lengths.
    func testTheFractionIsBounded() {
        XCTAssertEqual(BookTransport.fraction(chapters: chapters, place: (2, 99_999), finished: false), 1)
        XCTAssertEqual(BookTransport.place(loadedChapter: 0, playhead: -2, saved: nil)?.seconds, 0)
        XCTAssertEqual(BookTransport.fraction(chapters: [], place: (0, 10), finished: false), 0)
    }

    /// Started but under one percent says so, rather than "0% heard" that reads as nothing.
    func testHeardTextUnderOnePercent() {
        XCTAssertEqual(BookTransport.heardText(0.001), "Under 1% heard")
        XCTAssertEqual(BookTransport.heardText(0.005), "1% heard")
        XCTAssertEqual(BookTransport.heardText(0.5), "50% heard")
        XCTAssertEqual(BookTransport.heardText(1), "100% heard")
    }
}
