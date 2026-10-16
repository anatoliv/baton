import XCTest
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
@testable import BatonMobile

/// A book on the phone resumes where the listener was, on whichever device: Play with
/// no chapter chosen starts at the synced chapter and offset, a playing chapter writes its
/// position to the shared ledger, and the end of the last chapter finishes the book here and on
/// the home server. Against the in-process `HomeServerBooksPhoneTests.FakeGateway`, whose
/// chapters are 60 seconds long.
@MainActor
final class BookPlaybackPhoneTests: XCTestCase {
    private var root: URL!
    private var fake: HomeServerBooksPhoneTests.FakeGateway!
    private var clippings: ClippingStore!
    private var library: HomeServerBooks!
    private var documentID: String!
    private var jobID: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-phone-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fake = HomeServerBooksPhoneTests.FakeGateway()
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                  defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-resume"))!)
        let fake = fake!
        library = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                                  gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
        let url = root.appendingPathComponent("three-rooms.md")
        try "# Three Rooms\n\n## The Cell\n\nA small room.\n\n## The Surface\n\nThe light was grey.\n\n## The Hills\n\nBare hills."
            .write(to: url, atomically: true, encoding: .utf8)
        let prepared = DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
        documentID = prepared.documentID
        jobID = try await library.submit(prepared)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func collect(_ ready: Int) async {
        fake.setReady(jobID, ready)
        await library.collect()
    }

    private func shelf() -> MobileBookShelf.Book {
        MobileBookShelf.books(items: clippings.items, records: library.records, summaries: library.summaries,
                              ledger: clippings.ledger)[0]
    }

    private func chapter(_ index: Int) throws -> NavidromeSong {
        try XCTUnwrap(clippings.item(documentID: documentID, chapterIndex: index)).asSong
    }

    // MARK: - The resume choice

    func testPlayWithNoChapterChosenStartsAtTheSyncedChapterAndOffset() async throws {
        await collect(3)
        // Never heard: from the first chapter.
        XCTAssertEqual(MobileBookShelf.queue(for: shelf()).startIndex, 0)

        // The Mac was 42 s into chapter 2 (these chapters are 60 s), as a ledger merge brings it.
        var ledger = clippings.ledger
        ledger.setPosition(documentID: documentID, chapterIndex: 1, seconds: 42)
        clippings.ledger = ledger

        let (songs, start) = MobileBookShelf.queue(for: shelf())
        XCTAssertEqual(songs.count, 3, "the whole book is the queue")
        XCTAssertEqual(start, 1, "Play starts at the synced chapter 2")
        XCTAssertEqual(BookPlayback.resumeOffset(for: songs[1], clippings: clippings), 42)
        XCTAssertNil(BookPlayback.resumeOffset(for: songs[0], clippings: clippings), "another chapter starts at 0")
        XCTAssertNil(BookPlayback.resumeOffset(for: songs[2], clippings: clippings))

        // A chosen chapter is still that chapter.
        XCTAssertEqual(MobileBookShelf.queue(for: shelf(), fromChapter: 0).startIndex, 0)
        XCTAssertEqual(MobileBookShelf.queue(for: shelf(), fromChapter: 2).startIndex, 2)

        // Finished: from the start, with no offset.
        ledger.setFinished(true, documentID: documentID)
        clippings.ledger = ledger
        XCTAssertEqual(MobileBookShelf.queue(for: shelf()).startIndex, 0)
        XCTAssertNil(BookPlayback.resumeOffset(for: songs[1], clippings: clippings))
    }

    func testASyncedChapterWhoseAudioIsNotHereStartsFromTheBeginning() async throws {
        await collect(1)
        var ledger = clippings.ledger
        ledger.setPosition(documentID: documentID, chapterIndex: 2, seconds: 30)
        clippings.ledger = ledger
        XCTAssertEqual(MobileBookShelf.queue(for: shelf()).startIndex, 0)
    }

    // MARK: - Continuous play

    /// Only chapter 1 on the phone at Play: the queue is chapter 1, the rest are coming, and the
    /// continuation brings them down from the home server and hands them over in reading order.
    func testOnlyChapterOneHereQueuesItAndTheRestComeDownInOrder() async throws {
        await collect(1)
        let (songs, start) = MobileBookShelf.queue(for: shelf())
        XCTAssertEqual(songs.map(\.id), [try chapter(0).id])
        XCTAssertEqual(start, 0)
        XCTAssertEqual(MobileBookShelf.continuationChapters(of: shelf(), problem: nil, canGetBack: false),
                       [.here, .coming, .coming])

        let library = library!
        let continuation = BookContinuation(clippings: clippings, chapters: { [unowned self] _ in
            MobileBookShelf.continuationChapters(of: self.shelf(), problem: library.problem, canGetBack: false)
        }, fetch: { _, _ in await library.collect() }, pollInterval: .milliseconds(20))
        XCTAssertTrue(continuation.continues(after: try chapter(0)))
        fake.setReady(jobID, 3)
        let next = await continuation.continuation(after: try chapter(0))
        XCTAssertEqual(next, .more([try chapter(1), try chapter(2)]), "chapters 2 and 3 should come down, in order")
        XCTAssertFalse(continuation.continues(after: try chapter(2)), "nothing follows the last chapter")
    }

    /// A home server that is not answering stops the book at the next chapter not here, with
    /// the reason, rather than waiting for ever.
    func testAChapterThatCannotComeIsUnavailableWithItsReason() async throws {
        await collect(1)
        XCTAssertEqual(MobileBookShelf.continuationChapters(of: shelf(), problem: "the home server is not answering",
                                                            canGetBack: false),
                       [.here, .unavailable("the home server is not answering"), .unavailable("the home server is not answering")])
    }

    // MARK: - The position writes

    func testAPlayingChapterWritesItsPositionToTheSharedLedger() async throws {
        await collect(3)
        let at = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(MobileBookShelf.recordProgress(try chapter(1), time: 25, duration: 60,
                                                    clippings: clippings, homeServer: library, now: at))
        let record = try XCTUnwrap(clippings.ledger.document(documentID))
        XCTAssertEqual(record.chapterIndex, 1)
        XCTAssertEqual(record.seconds, 25)
        XCTAssertEqual(record.positionAt, at)
        XCTAssertFalse(record.finished)
        XCTAssertEqual(shelf().position?.chapterIndex, 1)

        // The written position is what the next Play resumes from.
        XCTAssertEqual(MobileBookShelf.queue(for: shelf()).startIndex, 1)
        XCTAssertEqual(BookPlayback.resumeOffset(for: try chapter(1), clippings: clippings), 25)

        // A clipping that is not a chapter writes nothing.
        let other = NavidromeSong(id: "file:///nowhere.m4a", title: "x", artist: nil, album: nil, duration: 10, coverArtID: nil)
        XCTAssertNil(MobileBookShelf.recordProgress(other, time: 5, duration: 10, clippings: clippings, homeServer: library))
        XCTAssertEqual(clippings.ledger.document(documentID)?.seconds, 25)
    }

    // MARK: - The finished mark

    func testTheEndOfTheLastChapterFinishesTheBookHereAndOnTheHomeServer() async throws {
        await collect(3)
        // The end of a chapter that is not the last finishes nothing.
        XCTAssertNil(MobileBookShelf.recordProgress(try chapter(1), time: 60, duration: 60,
                                                    clippings: clippings, homeServer: library))
        XCTAssertEqual(clippings.ledger.document(documentID)?.finished, false)

        let finished = MobileBookShelf.recordProgress(try chapter(2), time: 60, duration: 60,
                                                      clippings: clippings, homeServer: library)
        XCTAssertEqual(finished, documentID)
        XCTAssertEqual(clippings.ledger.document(documentID)?.finished, true)
        XCTAssertTrue(shelf().finished)
        // Said once: a second end-of-track report does not finish it again.
        XCTAssertNil(MobileBookShelf.recordProgress(try chapter(2), time: 60, duration: 60,
                                                    clippings: clippings, homeServer: library))

        await MobileBookShelf.markFinished(documentID: documentID, homeServer: library)
        XCTAssertEqual(fake.seen.filter { $0 == "POST /v1/books/\(jobID!)/finished" }.count, 1,
                       "the home server should be told once: \(fake.seen)")
    }

    /// While the rest is still being made, the last chapter to have landed is not the end of the
    /// book: the count comes from the home server's job.
    func testTheEndOfTheLastLandedChapterIsNotTheEndWhileTheRestIsBeingMade() async throws {
        await collect(2)
        XCTAssertNil(MobileBookShelf.recordProgress(try chapter(1), time: 60, duration: 60,
                                                    clippings: clippings, homeServer: library))
        XCTAssertEqual(clippings.ledger.document(documentID)?.finished, false)
    }

    /// A finished book played again past its first minute resumes there on the next Play, and
    /// the home server is not asked to forget its finished mark.
    func testAReplayedBookResumesWhereTheReplayStopped() async throws {
        await collect(3)
        XCTAssertNotNil(MobileBookShelf.recordProgress(try chapter(2), time: 60, duration: 60,
                                                       clippings: clippings, homeServer: library))
        XCTAssertEqual(MobileBookShelf.queue(for: shelf()).startIndex, 0, "finished: Play starts over")

        _ = MobileBookShelf.recordProgress(try chapter(0), time: 55, duration: 60, clippings: clippings, homeServer: library)
        XCTAssertTrue(shelf().finished, "still within the first minute")
        _ = MobileBookShelf.recordProgress(try chapter(1), time: 20, duration: 60, clippings: clippings, homeServer: library)
        XCTAssertFalse(shelf().finished)
        XCTAssertEqual(MobileBookShelf.queue(for: shelf()).startIndex, 1)
        XCTAssertEqual(BookPlayback.resumeOffset(for: try chapter(1), clippings: clippings), 20)
        XCTAssertFalse(fake.seen.contains { $0.hasPrefix("DELETE") || $0.contains("unfinish") }, "\(fake.seen)")
    }
}

