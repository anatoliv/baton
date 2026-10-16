import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// A book plays through all its chapters, in order, even when only the first was on this device
/// at Play (TBX-10991, "If clip contains multiple chapters play all continuous").
///
/// Found on the iPhone: Play queued only the chapters already here, so a book whose later chapters
/// were still being made or brought down stopped at the end of the last one present. Each chapter
/// here is a real 20 s file in a real `ClippingStore`, played by the real controller; the ends are
/// simulated. Where each chapter stands is the test's to say, as each app's shelf says it.
@MainActor
final class BookContinuousPlayTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.bookcontinuous"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()
    private var dir: URL!
    private var clippings: ClippingStore!
    /// Where each of the book's three chapters stands, as the app would report it.
    private var states: [BookContinuation.Chapter] = [.here, .coming, .coming]
    private var fetched: [Int] = []
    private var controllers: [StreamingPlaybackController] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbx-10991-\(UUID().uuidString)")
        clippings = ClippingStore(directory: dir, defaults: suite)
    }

    override func tearDown() async throws {
        for c in controllers { c.stop() }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    /// A chapter of "Three Rooms" landing in Clippings, as a download or the renderer brings it.
    @discardableResult
    private func land(_ index: Int, document: String = "doc-three-rooms") throws -> ClippingStore.Item {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ch-\(UUID().uuidString).wav")
        try EngineTestSignals.sineWAV(frequency: 220 * Double(index + 1), seconds: 20).write(to: url)
        let item = try clippings.adopt(url, title: "Chapter \(index + 1)", durationSeconds: 20,
                                       chapter: .init(documentID: document, documentTitle: "Three Rooms", author: nil,
                                                      chapterIndex: index, chapterTitle: "Chapter \(index + 1)"))
        if document == "doc-three-rooms" {
            while states.count <= index { states.append(.coming) }
            states[index] = .here
        }
        return item
    }

    private func reading(_ title: String, at seconds: TimeInterval) throws -> ClippingStore.Item {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString).wav")
        try EngineTestSignals.sineWAV(frequency: 330, seconds: 2).write(to: url)
        return try clippings.adopt(url, title: title, durationSeconds: 2, now: Date(timeIntervalSince1970: seconds))
    }

    private func makeController(onFetch: ((Int) throws -> Void)? = nil) -> StreamingPlaybackController {
        let c = StreamingPlaybackController(streamURLProvider: { URL(string: $0)! }, defaults: suite,
                                            systemNowPlaying: false)
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.continuationSource = BookContinuation(clippings: clippings, chapters: { [unowned self] _ in self.states },
                                                fetch: { [unowned self] _, index in
                                                    self.fetched.append(index)
                                                    try? onFetch?(index)
                                                }, pollInterval: .milliseconds(50))
        controllers.append(c)
        return c
    }

    /// Play the book the way both apps' Play does.
    private func playBook(_ c: StreamingPlaybackController) {
        let (songs, start) = BookPlayback.queue(chapters: clippings.chapters(ofDocument: "doc-three-rooms"),
                                                position: nil, finished: false)
        c.play(songs, startAt: start)
    }

    private func titles(_ c: StreamingPlaybackController) -> [String] { c.queue.map(\.title) }

    private func endCurrent(_ c: StreamingPlaybackController) {
        c.seek(to: 19.6) // an end only counts at the end
        c.simulateTrackEndedForTesting()
    }

    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    // MARK: - The card's cases

    /// Chapters that land while chapter 1 plays join the queue behind it, in reading order: a
    /// chapter that lands before the one ahead of it waits for that one.
    func testAChapterArrivingMidPlaybackIsAppendedInOrder() async throws {
        try land(0)
        let c = makeController()
        playBook(c)
        XCTAssertEqual(titles(c), ["Chapter 1"], "precondition: only chapter 1 is here at Play")

        try land(2)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(titles(c), ["Chapter 1"], "chapter 3 must not join before chapter 2")

        try land(1)
        let joined = try await waitUntil { c.queue.count == 3 }
        XCTAssertTrue(joined, "the chapters that landed never joined the queue: \(titles(c))")
        XCTAssertEqual(titles(c), ["Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 1", "joining the queue does not interrupt the chapter playing")
        XCTAssertEqual(c.state, .playing)

        endCurrent(c)
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 2", "chapter 1 should end into chapter 2")
        endCurrent(c)
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 3", "chapter 2 should end into chapter 3")
    }

    /// The next chapter is asked for while the current one plays, not at the boundary, and is
    /// buffered behind it so the boundary has no gap.
    func testAMissingNextChapterIsFetchedAhead() async throws {
        try land(0)
        let c = makeController { [unowned self] index in try self.land(index) }
        playBook(c)
        let joined = try await waitUntil { c.queue.count >= 2 }
        XCTAssertTrue(joined, "chapter 2 was never fetched while chapter 1 played")
        XCTAssertEqual(fetched.first, 1, "the first chapter asked for is the one after the playing one")
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 1", "fetched ahead, while chapter 1 still plays")
        XCTAssertEqual(c.state, .playing)
        XCTAssertEqual(titles(c).prefix(2), ["Chapter 1", "Chapter 2"])
        XCTAssertEqual(c.gaplessPreloadIndexForTesting, 1, "chapter 2 should be buffered behind chapter 1")

        endCurrent(c)
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 2")
        XCTAssertEqual(c.gaplessAdvanceCountForTesting, 1, "the boundary into the fetched chapter should be gapless")
    }

    /// A tap on a reading plays the readings after it in the list, and none of the chapters of
    /// the books mixed in among them.
    func testAPlainClippingQueueExcludesBookChapters() throws {
        let first = try reading("Notes on a Garden", at: 400)
        try land(0, document: "doc-other")
        let second = try reading("The bit about notarization", at: 200)
        try land(1, document: "doc-other")
        let third = try reading("A recipe", at: 100)
        let list = clippings.items // newest first, as the list shows them
        XCTAssertEqual(list.filter(\.clipping.isBookChapter).count, 2, "precondition: chapters are in the list")

        let queue = ClippingQueue.readings(from: first, in: list)
        XCTAssertEqual(queue.map(\.title), [first, second, third].map(\.clipping.title))
        XCTAssertFalse(queue.contains { $0.genre == "Audiobook" }, "a book chapter was queued after a reading")
        XCTAssertEqual(ClippingQueue.readings(from: second, in: list).map(\.title), [second, third].map(\.clipping.title))
        XCTAssertEqual(ClippingQueue.readings(list).count, 3, "Play all plays the readings, not the books")
    }

    // MARK: - Around the edges

    /// The end of the queue with the next chapter still being made: wait for it, saying so, then
    /// play it when it lands.
    func testTheEndWaitsForAChapterStillBeingMadeThenPlaysIt() async throws {
        try land(0)
        let c = makeController()
        playBook(c)
        endCurrent(c)
        XCTAssertEqual(c.state, .loading, "the end of chapter 1 should wait for chapter 2, not stop")
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 1")
        XCTAssertEqual(c.toast?.text, "Waiting for chapter 2")
        XCTAssertEqual(c.continuationNote, "Waiting for chapter 2", "the player view says it is waiting")

        try land(1)
        let played = try await waitUntil { c.nowPlaying?.title == "Chapter 2" && c.state == .playing }
        XCTAssertTrue(played, "chapter 2 never played after landing: \(String(describing: c.nowPlaying?.title)) \(c.state)")
        XCTAssertNil(c.continuationNote, "the note goes once the chapter plays")
    }

    /// A chapter that joins while the book plays is still the book: the shared
    /// collection rule keeps the book's button at Pause and Resume in it, rather than
    /// Play, which queued the book again from its saved place.
    func testAChapterThatJoinsLaterIsStillTheBookInThePlayer() async throws {
        try land(0)
        let c = makeController()
        let source = BookTransport.source(documentID: "doc-three-rooms", title: "Three Rooms")
        let (songs, start) = BookPlayback.queue(chapters: clippings.chapters(ofDocument: "doc-three-rooms"),
                                                position: nil, finished: false)
        c.play(songs, startAt: start, source: source)
        XCTAssertEqual(c.collectionState(source), .playing)
        endCurrent(c)
        try land(1)
        let played = try await waitUntil { c.nowPlaying?.title == "Chapter 2" && c.state == .playing }
        XCTAssertTrue(played, "chapter 2 never played after landing")
        XCTAssertEqual(c.collectionState(source), .playing, "chapter 2 joined later, and it is still the book")
        c.pause()
        XCTAssertEqual(c.collectionState(source), .paused)
    }

    /// A chapter that cannot be made stops the book at that point with the reason: no skipping
    /// past it to a later chapter, no replay of the one before.
    func testAChapterThatCannotComeStopsTheBookThereWithTheReason() async throws {
        try land(0)
        try land(2)
        states[1] = .unavailable("it could not be made (the voice server failed)")
        let c = makeController()
        playBook(c)
        XCTAssertEqual(titles(c), ["Chapter 1"], "chapter 3 must not be queued past a missing chapter 2")
        _ = try await waitUntil { !c.isContinuingForTesting }
        endCurrent(c)
        XCTAssertEqual(c.state, .idle, "the book should stop at the end of chapter 1")
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 1")
        XCTAssertEqual(c.toast?.text, "Stopped before chapter 2: it could not be made (the voice server failed).")
        XCTAssertEqual(c.continuationNote, c.toast?.text, "the player view says why the book stopped")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.state, .idle, "nothing started again after the stop")
        XCTAssertEqual(titles(c), ["Chapter 1"])
    }

    /// The same, when the chapter fails while the player is already waiting for it.
    func testAChapterFailingWhileTheEndWaitsStopsThere() async throws {
        try land(0)
        let c = makeController()
        playBook(c)
        endCurrent(c)
        XCTAssertEqual(c.state, .loading)
        states[1] = .unavailable("the home server is not answering")
        let stopped = try await waitUntil { c.state == .idle }
        XCTAssertTrue(stopped, "the wait never ended")
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 1")
        XCTAssertEqual(c.toast?.text, "Stopped before chapter 2: the home server is not answering.")
    }

    /// The last chapter of the book is the end: nothing is asked for, and the book stops.
    func testTheLastChapterEndsTheBook() async throws {
        try land(0); try land(1); try land(2)
        let c = makeController()
        playBook(c)
        c.jump(to: 2)
        XCTAssertFalse(c.isContinuingForTesting, "nothing follows the last chapter")
        endCurrent(c)
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 3")
        XCTAssertTrue(fetched.isEmpty)
    }

    /// Play from a chosen chapter queues the chapters before it (for Previous) and the unbroken
    /// run after it; a gap ends the queue there rather than skipping ahead.
    func testPlayQueuesTheChaptersBeforeAndTheUnbrokenRunAfter() throws {
        let one = try land(0), three = try land(2), four = try land(3)
        let book = clippings.chapters(ofDocument: "doc-three-rooms")
        let fromStart = BookPlayback.queue(chapters: book, position: nil, finished: false)
        XCTAssertEqual(fromStart.songs.map(\.title), ["Chapter 1"])
        XCTAssertEqual(fromStart.startIndex, 0)
        let fromThree = BookPlayback.queue(chapters: book, position: nil, finished: false, fromChapter: 2)
        XCTAssertEqual(fromThree.songs.map(\.title), [one, three, four].map(\.clipping.title))
        XCTAssertEqual(fromThree.startIndex, 1)
        let synced = BookPlayback.queue(chapters: book, position: (2, 12), finished: false)
        XCTAssertEqual(synced.startIndex, 1, "the synced chapter is still where Play starts")
    }
}
