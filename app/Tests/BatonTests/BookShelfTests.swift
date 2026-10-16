import AVFoundation
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// Clippings with books in them (M3.5): one row per book, its chapters in order whatever has
/// landed so far, and the position the player resumes from.
@MainActor
final class BookShelfTests: XCTestCase {

    private var root: URL!
    private var clippings: ClippingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                  defaults: ThrowawayDefaults.make("shelf"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tone(seconds: Double) throws -> URL {
        let url = root.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(24_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    @discardableResult
    private func landChapter(_ index: Int, seconds: Double = 60, documentID: String = "doc") throws -> ClippingStore.Item {
        try clippings.adopt(try tone(seconds: seconds), title: "Chapter \(index + 1)", durationSeconds: seconds,
                            chapter: .init(documentID: documentID, documentTitle: "The Machine Stops",
                                           author: "E. M. Forster", chapterIndex: index,
                                           chapterTitle: "Chapter \(index + 1)"))
    }

    /// A render job for a three-chapter book, as `DocumentLibrary` would publish it.
    private func job(documentID: String = "doc", states: [BookJob.ChapterState], status: BookJob.Status,
                     pauseReason: String? = nil) throws -> DocumentLibrary.Job {
        let text = (1...states.count).map { "## Chapter \($0)\n\nSome words in chapter \($0)." }.joined(separator: "\n\n")
        let url = root.appendingPathComponent("\(UUID().uuidString).md")
        try "# The Machine Stops\n\n\(text)".write(to: url, atomically: true, encoding: .utf8)
        var book = DocumentSpeech.prepare(try DocumentImporter.importFile(at: url),
                                          voices: VoicePlan(narrator: "kokoro:bf_emma"))
        book.documentID = documentID
        var job = BookJob(id: "job-\(documentID)", book: book)
        job.chapters = states
        job.status = status
        job.pauseReason = pauseReason
        return DocumentLibrary.Job(job)
    }

    private func onlyBook(_ entries: [BookShelf.Entry]) throws -> BookShelf.Book {
        let books = entries.compactMap { if case let .book(book) = $0 { book } else { nil } }
        XCTAssertEqual(books.count, 1)
        return try XCTUnwrap(books.first)
    }

    func testChaptersOfOneBookAreOneRowAndReadingsStayFlat() throws {
        try landChapter(1)
        try landChapter(0)
        try clippings.adopt(try tone(seconds: 5), title: "A reading")
        let entries = BookShelf.entries(items: clippings.items, jobs: [], ledger: clippings.ledger)
        XCTAssertEqual(entries.count, 2, "one book and one reading")
        let book = try onlyBook(entries)
        XCTAssertEqual(book.title, "The Machine Stops")
        XCTAssertEqual(book.author, "E. M. Forster")
        XCTAssertEqual(book.chapters.map(\.index), [0, 1], "in reading order, not landing order")
        XCTAssertEqual(book.summaryText, "2 chapters · 2 m")
    }

    /// Just submitted: the book is there before any chapter is, with chapter 1's progress.
    func testABookIsShownWhileItRendersWithEachChaptersState() throws {
        let job = try job(states: [.rendering(done: 2, of: 5), .queued, .queued], status: .rendering)
        let book = try onlyBook(BookShelf.entries(items: [], jobs: [job], ledger: .init()))
        XCTAssertTrue(book.isRendering)
        XCTAssertEqual(book.chapters.map(\.state), [.rendering(0.4), .queued, .queued])
        XCTAssertEqual(book.summaryText, "0 of 3 chapters ready")
    }

    func testAPausedBookSaysWhy() throws {
        try landChapter(0)
        let job = try job(states: [.ready(file: "chapter-1.m4a", bytes: 1, seconds: 60, sha256: "x"),
                                   .rendering(done: 3, of: 3), .queued],
                          status: .paused, pauseReason: "kokoro did not answer: connection refused")
        let book = try onlyBook(BookShelf.entries(items: clippings.items, jobs: [job], ledger: .init()))
        XCTAssertEqual(book.pauseReason, "kokoro did not answer: connection refused")
        XCTAssertEqual(book.chapters.map(\.state), [.ready, .encoding, .queued])
        XCTAssertEqual(book.summaryText, "1 of 3 chapters ready · 1 m")
    }

    func testAChapterRemovedFromThisMacIsShownAsRemovedNotReady() throws {
        let job = try job(states: [.ready(file: "chapter-1.m4a", bytes: 1, seconds: 60, sha256: "x")], status: .ready)
        let book = try onlyBook(BookShelf.entries(items: [], jobs: [job], ledger: .init()))
        XCTAssertEqual(book.chapters.map(\.state), [.removed])
    }

    // MARK: - Continuous play

    /// A book still being made on this Mac: chapter 1 here is the queue, the chapter being made
    /// and the one waiting are coming, and a failed chapter is not, with its reason.
    func testABookStillBeingMadeQueuesWhatIsHereAndSaysWhatIsComing() throws {
        let one = try landChapter(0)
        let job = try job(states: [.ready(file: "chapter-1.m4a", bytes: 1, seconds: 60, sha256: "x"),
                                   .rendering(done: 1, of: 4), .queued], status: .rendering)
        let book = try onlyBook(BookShelf.entries(items: clippings.items, jobs: [job], ledger: clippings.ledger))
        let (songs, start) = BookPlayback.queue(for: book)
        XCTAssertEqual(songs.map(\.id), [one.asSong.id])
        XCTAssertEqual(start, 0)
        XCTAssertEqual(BookPlayback.continuationChapters(of: book, hasJob: true, canGetBack: false, homeServerProblem: nil),
                       [.here, .coming, .coming])
        XCTAssertNil(BookPlayback.continuationChapters(of: book, hasJob: false, canGetBack: false, homeServerProblem: nil),
                     "with no render job the chapters here are all there is")

        let failed = try self.job(states: [.ready(file: "chapter-1.m4a", bytes: 1, seconds: 60, sha256: "x"),
                                           .failed(reason: "the voice server failed"), .queued], status: .failed)
        let stopped = try onlyBook(BookShelf.entries(items: clippings.items, jobs: [failed], ledger: clippings.ledger))
        XCTAssertEqual(BookPlayback.continuationChapters(of: stopped, hasJob: true, canGetBack: false, homeServerProblem: nil)?[1],
                       .unavailable("it could not be made (the voice server failed)"))
    }

    /// Play from a chapter with a gap after it queues up to the gap, never past it.
    func testPlayNeverQueuesAChapterPastOneThatIsNotHere() throws {
        let one = try landChapter(0)
        try landChapter(2)
        let book = try onlyBook(BookShelf.entries(items: clippings.items, jobs: [], ledger: clippings.ledger))
        XCTAssertEqual(BookPlayback.queue(for: book).songs.map(\.id), [one.asSong.id])
        XCTAssertEqual(BookPlayback.queue(for: book, fromChapter: 2).startIndex, 1, "a chosen chapter still plays")
    }

    // MARK: - Resume

    func testPlayResumesAtTheSyncedChapterAndSecond() throws {
        try landChapter(0, seconds: 60)
        let second = try landChapter(1, seconds: 60)
        try landChapter(2, seconds: 60)
        var ledger = clippings.ledger
        ledger.setPosition(documentID: "doc", chapterIndex: 1, seconds: 42)
        clippings.ledger = ledger

        let book = try onlyBook(BookShelf.entries(items: clippings.items, jobs: [], ledger: clippings.ledger))
        let (songs, start) = BookPlayback.queue(for: book)
        XCTAssertEqual(songs.count, 3)
        XCTAssertEqual(start, 1)
        XCTAssertEqual(BookPlayback.resumeOffset(for: second.asSong, clippings: clippings), 42)
        XCTAssertNil(BookPlayback.resumeOffset(for: songs[0], clippings: clippings),
                     "only the chapter the position is in resumes")
        XCTAssertEqual(book.listenedFraction, (60 + 42) / 180, accuracy: 0.001)
    }

    func testAPositionInTheLastSecondsStartsTheChapterOver() throws {
        let item = try landChapter(0, seconds: 60)
        var ledger = clippings.ledger
        ledger.setPosition(documentID: "doc", chapterIndex: 0, seconds: 58)
        clippings.ledger = ledger
        XCTAssertNil(BookPlayback.resumeOffset(for: item.asSong, clippings: clippings))
    }

    func testPlayingRecordsThePosition() throws {
        let item = try landChapter(1)
        XCTAssertNil(BookPlayback.record(item.asSong, time: 30, duration: 60, chapterCount: 3, clippings: clippings))
        XCTAssertEqual(clippings.ledger.document("doc")?.chapterIndex, 1)
        XCTAssertEqual(clippings.ledger.document("doc")?.seconds, 30)
    }

    /// The end of the last chapter finishes the book. The end of the last chapter to have
    /// *landed*, while the rest still renders, does not.
    func testOnlyTheBooksLastChapterFinishesIt() throws {
        let second = try landChapter(1)
        XCTAssertNil(BookPlayback.record(second.asSong, time: 60, duration: 60, chapterCount: 3, clippings: clippings))
        XCTAssertNotEqual(clippings.ledger.document("doc")?.finished, true)

        let third = try landChapter(2)
        XCTAssertEqual(BookPlayback.record(third.asSong, time: 60, duration: 60, chapterCount: 3, clippings: clippings), "doc")
        XCTAssertEqual(clippings.ledger.document("doc")?.finished, true)
    }

    func testAFinishedBookPlaysFromTheStart() throws {
        try landChapter(0)
        try landChapter(1)
        var ledger = clippings.ledger
        ledger.setPosition(documentID: "doc", chapterIndex: 1, seconds: 59)
        ledger.setFinished(true, documentID: "doc")
        clippings.ledger = ledger
        let book = try onlyBook(BookShelf.entries(items: clippings.items, jobs: [], ledger: clippings.ledger))
        XCTAssertEqual(BookPlayback.queue(for: book).startIndex, 0)
        XCTAssertEqual(book.listenedFraction, 1)
    }

    /// A finished book played again past its first minute resumes there.
    func testAReplayedBookResumesWhereTheReplayStopped() throws {
        let first = try landChapter(0)
        let second = try landChapter(1)
        let third = try landChapter(2)
        XCTAssertEqual(BookPlayback.record(third.asSong, time: 60, duration: 60, chapterCount: 3, clippings: clippings), "doc")
        XCTAssertNil(BookPlayback.record(first.asSong, time: 55, duration: 60, chapterCount: 3, clippings: clippings))
        XCTAssertEqual(clippings.ledger.document("doc")?.finished, true, "still within the first minute")
        XCTAssertNil(BookPlayback.record(second.asSong, time: 20, duration: 60, chapterCount: 3, clippings: clippings))
        XCTAssertEqual(clippings.ledger.document("doc")?.finished, false)

        let book = try onlyBook(BookShelf.entries(items: clippings.items, jobs: [], ledger: clippings.ledger))
        XCTAssertEqual(BookPlayback.queue(for: book).startIndex, 1)
        XCTAssertEqual(BookPlayback.resumeOffset(for: second.asSong, clippings: clippings), 20)
    }

    func testAReadingIsNotABookToThePlayer() throws {
        let reading = try clippings.adopt(try tone(seconds: 5), title: "A reading")
        XCTAssertNil(BookPlayback.resumeOffset(for: reading.asSong, clippings: clippings))
        XCTAssertNil(BookPlayback.record(reading.asSong, time: 5, duration: 5, chapterCount: nil, clippings: clippings))
        XCTAssertEqual(clippings.ledger.documents, [])
    }

    // MARK: - Words on the import sheet and the row

    func testEveryImportWarningReadsWithoutDashes() {
        let kinds: [ImportWarning.Kind] = [.pagesWithoutText, .pagesRecognized, .noChapters, .metadataTitleIgnored,
                                           .protectedContent, .empty, .contentSkipped]
        for kind in kinds {
            let text = DocumentImportSheet.text(for: ImportWarning(kind, pages: [4, 5, 9], detail: "The-Machine-Stops.dvi"))
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), ": \(text)")
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertEqual(DocumentImportSheet.pageList([4]), "Page 4")
        XCTAssertEqual(DocumentImportSheet.pageList([4, 5, 9]), "Pages 4, 5 and 9")
        XCTAssertEqual(DocumentImportSheet.voiceLabel("kokoro:bf_emma"), "bf_emma on Kokoro")
    }

    func testThePausedLineSaysWhyAndThatItCarriesOn() throws {
        let job = try job(states: [.rendering(done: 1, of: 4), .queued], status: .paused,
                          pauseReason: "kokoro did not answer: connection refused")
        let book = try onlyBook(BookShelf.entries(items: [], jobs: [job], ledger: .init()))
        let line = try XCTUnwrap(MusicClippingsView.statusLine(book))
        XCTAssertTrue(line.isProblem)
        XCTAssertTrue(line.text.hasPrefix("Paused: kokoro did not answer"), line.text)
        XCTAssertFalse(line.text.contains("\u{2014}"))
    }

    func testTheRenderingLineNamesTheChapterBeingMade() throws {
        let job = try job(states: [.rendering(done: 1, of: 4), .queued], status: .rendering)
        let book = try onlyBook(BookShelf.entries(items: [], jobs: [job], ledger: .init()))
        XCTAssertEqual(MusicClippingsView.statusLine(book)?.text, "Making chapter 1 of 2, 25%")
    }
}

/// F1 and F3: Clippings without a music server, and the rail badge counting what the list shows.
@MainActor
final class ClippingsWithoutAServerTests: XCTestCase {

    func testTheSectionsShowWheneverThereIsSomethingOfflineToShow() {
        XCTAssertTrue(MusicView.showsSections(serverConfigured: true, hasClippings: false, documentsOn: false))
        XCTAssertTrue(MusicView.showsSections(serverConfigured: false, hasClippings: true, documentsOn: false),
                      "a kept reading plays from disk; hiding it behind 'connect a server' was the bug")
        XCTAssertTrue(MusicView.showsSections(serverConfigured: false, hasClippings: false, documentsOn: true))
        XCTAssertFalse(MusicView.showsSections(serverConfigured: false, hasClippings: false, documentsOn: false),
                       "a brand-new install with nothing still gets the single connect screen")
    }

    func testOnlyClippingsWorksWithoutAServer() {
        for tab in MusicView.MusicTab.allCases {
            XCTAssertEqual(MusicView.worksWithoutServer(tab), tab == .clippings, "\(tab)")
        }
    }

    func testTheBadgeCountsABookOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-badge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClippingStore(directory: root, defaults: ThrowawayDefaults.make("badge"))
        func file() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).m4a")
            try Data(repeating: 0x41, count: 64).write(to: url)
            return url
        }
        try store.adopt(try file(), title: "A reading", durationSeconds: 5)
        try store.adopt(try file(), title: "Another reading", durationSeconds: 5)
        for index in 0..<3 {
            try store.adopt(try file(), title: "Chapter \(index + 1)", durationSeconds: 60,
                            chapter: .init(documentID: "doc", documentTitle: "The Machine Stops", author: nil,
                                           chapterIndex: index, chapterTitle: "Chapter \(index + 1)"))
        }
        XCTAssertEqual(store.items.count, 5)
        XCTAssertEqual(BookShelf.entryCount(items: store.items), 3, "two readings and one book")
    }
}
