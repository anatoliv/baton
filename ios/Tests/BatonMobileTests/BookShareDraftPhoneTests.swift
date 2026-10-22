import XCTest
import BatonDocuments
import BatonPlaybackKit
import BatonShareKit
import BatonSubsonicKit
@testable import BatonMobile

/// An iPhone book as Share… sees it for a whole-book link (`specs/book-sharing.md`
/// Phase 2): every chapter must be on the phone, the one that is not is named, and each chapter's
/// read-along timing is found by its own index and carried in the book format's shape.
@MainActor
final class BookShareDraftPhoneTests: XCTestCase {
    private var root: URL!
    private var fake: HomeServerBooksPhoneTests.FakeGateway!
    private var clippings: ClippingStore!
    private var library: HomeServerBooks!
    private var jobID: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-phone-book-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fake = HomeServerBooksPhoneTests.FakeGateway()
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                  defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-book-share"))!)
        let fake = fake!
        library = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                                  gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
        let url = root.appendingPathComponent("three-rooms.md")
        try "# Three Rooms\n\n## The Cell\n\nA small room.\n\n## The Surface\n\nThe light was grey.\n\n## The Hills\n\nBare hills."
            .write(to: url, atomically: true, encoding: .utf8)
        let prepared = DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
        jobID = try await library.submit(prepared)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func draft(timing: (@MainActor (ClippingStore.Item) async -> ReadAlongTiming?)? = nil) -> BookShareDraft {
        let book = MobileBookShelf.books(items: clippings.items, records: library.records, summaries: library.summaries,
                                         ledger: clippings.ledger)[0]
        return BookShareDraft(book, covers: nil, timing: timing)
    }

    private let limits = ShareBookLimits(limits: .standard)

    func testAWholeBookLinkNamesTheChapterThatIsNotOnThePhone() async throws {
        fake.setReady(jobID, 2)
        await library.collect()
        let partial = draft()
        XCTAssertEqual(partial.chapterCount, 3)
        XCTAssertEqual(partial.wholeBookCheck(limits), .failure(.missingChapters([3])))
        XCTAssertTrue(ShareBookPlan.WholeBookRefusal.missingChapters([3]).message.hasPrefix("Chapter 3 isn't on this device."))

        fake.setReady(jobID, 3)
        await library.collect()
        let whole = draft()
        guard case let .success(book) = whole.wholeBookCheck(limits) else { return XCTFail("every chapter is here") }
        XCTAssertEqual(book.chapters, 3)
        XCTAssertFalse(ShareBookPlan.prefersWholeBook(whole.chapters.map(\.plan), chapterCount: whole.chapterCount,
                                                      limits: .standard, bookLimits: limits),
                       "three one-minute chapters fit a Phase 1 link, so the composer keeps it")
    }

    func testReadAlongTimingIsFoundByChapterAndCarriedInTheBookFormat() async throws {
        fake.setReady(jobID, 3)
        await library.collect()
        let asked = Asked()
        let shared = draft(timing: { item in
            asked.indices.append(item.clipping.chapterIndex)
            return ReadAlongTiming(segments: [.init(text: "The light was grey.", paragraph: 0, start: 0.4, end: 2.1)])
        })
        let timing = await shared.timing?(1)
        XCTAssertEqual(asked.indices, [1], "the chapter's own item is asked, by its index")
        let text = try XCTUnwrap(BookShareDraft.readAlongText(timing))
        XCTAssertEqual(text.schema, ShareBookText.schemaVersion)
        XCTAssertEqual(text.segments, [.init(text: "The light was grey.", paragraph: 0, start: 0.4, end: 2.1)])
        XCTAssertNil(BookShareDraft.readAlongText(nil))
        XCTAssertNil(BookShareDraft.readAlongText(ReadAlongTiming(segments: [])), "a chapter without timed text sends none")
        XCTAssertNil(draft().timing, "no timing source, no text")
    }
}

@MainActor private final class Asked { var indices = [Int?]() }
