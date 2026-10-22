import AVFoundation
import BatonDocuments
import BatonPlaybackKit
import BatonShareKit
import Foundation
import XCTest
@testable import Baton

/// A Mac book as Share… sees it: only chapters whose
/// audio is here, in order, with the sizes the planner checks against the service's caps.
@MainActor
final class BookShareDraftTests: XCTestCase {
    private var root: URL!
    private var clippings: ClippingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-book-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                  defaults: ThrowawayDefaults.make("book-share"))
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
    private func landChapter(_ index: Int, seconds: Double = 60) throws -> ClippingStore.Item {
        try clippings.adopt(try tone(seconds: seconds), title: "Chapter \(index + 1)", durationSeconds: seconds,
                            chapter: .init(documentID: "doc", documentTitle: "The Machine Stops",
                                           author: "E. M. Forster", chapterIndex: index,
                                           chapterTitle: "Chapter \(index + 1)"))
    }

    private func book() throws -> BookShelf.Book {
        let books = BookShelf.entries(items: clippings.items, jobs: [], ledger: clippings.ledger)
            .compactMap { if case let .book(book) = $0 { book } else { nil } }
        return try XCTUnwrap(books.first)
    }

    func testTheDraftHoldsTheChaptersHereInOrder() throws {
        try landChapter(1, seconds: 2)
        try landChapter(0, seconds: 3)
        let draft = BookShareDraft(try book(), covers: nil)
        XCTAssertEqual(draft.title, "The Machine Stops")
        XCTAssertEqual(draft.author, "E. M. Forster")
        XCTAssertEqual(draft.chapterCount, 2)
        XCTAssertEqual(draft.chapters.map(\.index), [0, 1])
        XCTAssertEqual(draft.chapters.map(\.durationSeconds), [3, 2])
        XCTAssertTrue(draft.chapters.allSatisfy { $0.bytes > 0 }, "sizes come from the files")
        XCTAssertEqual(draft.chapters[0].songID, draft.chapters[0].url.absoluteString,
                       "the id the player and the upload ticket know the chapter by")
        XCTAssertEqual(ShareBookPlan.defaultRange(draft.chapters.map(\.plan)), 0 ... 1)
    }

    func testAChapterWhoseAudioHasGoneIsLeftOutAndStillCounted() throws {
        try landChapter(0)
        let gone = try landChapter(1)
        try landChapter(2)
        try FileManager.default.removeItem(at: gone.url)
        let draft = BookShareDraft(try book(), covers: nil)
        XCTAssertEqual(draft.chapterCount, 3, "a link of some chapters still says which")
        XCTAssertEqual(draft.chapters.map(\.index), [0, 2])
        XCTAssertEqual(ShareBookPlan.check(draft.chapters.map(\.plan)), .failure(.missingChapter(2)),
                       "the run across the gap is refused rather than mislabelled")
        XCTAssertEqual(ShareBookPlan.defaultRange(draft.chapters.map(\.plan)), 0 ... 0)
    }

    // MARK: - Whole-book links (Phase 2)

    func testAWholeBookLinkNeedsEveryChapterHereAndNamesTheOneThatIsNot() throws {
        let limits = ShareBookLimits(limits: .standard)
        try landChapter(0)
        let gone = try landChapter(1)
        try landChapter(2)
        guard case let .success(whole) = BookShareDraft(try book(), covers: nil).wholeBookCheck(limits) else {
            return XCTFail("every chapter is here")
        }
        XCTAssertEqual(whole.chapters, 3)
        try FileManager.default.removeItem(at: gone.url)
        let draft = BookShareDraft(try book(), covers: nil)
        XCTAssertEqual(draft.wholeBookCheck(limits), .failure(.missingChapters([2])))
        XCTAssertFalse(ShareBookPlan.prefersWholeBook(draft.chapters.map(\.plan), chapterCount: draft.chapterCount,
                                                      limits: .standard, bookLimits: limits),
                       "a book missing a chapter opens on the chapters it can send")
    }

    func testTheWholeBookIsChosenFirstOnlyWhenItDoesNotFitPhaseOne() throws {
        let limits = ShareBookLimits(limits: .standard)
        for index in 0 ..< 13 { try landChapter(index, seconds: 1) }
        let draft = BookShareDraft(try book(), covers: nil)
        XCTAssertTrue(ShareBookPlan.prefersWholeBook(draft.chapters.map(\.plan), chapterCount: 13, limits: .standard, bookLimits: limits),
                      "thirteen chapters do not fit one mixtape")
        XCTAssertFalse(ShareBookPlan.prefersWholeBook(draft.chapters.map(\.plan), chapterCount: 13, limits: .standard, bookLimits: nil),
                       "without the service's advertisement nothing new is offered")
        XCTAssertFalse(ShareBookPlan.prefersWholeBook(Array(draft.chapters.prefix(4)).map(\.plan), chapterCount: 4,
                                                      limits: .standard, bookLimits: limits))
    }

    func testReadAlongTimingIsAskedForByChapterAndMappedToTheBookFormat() async throws {
        try landChapter(0)
        let second = try landChapter(1)
        let asked = AskedItems()
        let draft = BookShareDraft(try book(), covers: nil, timing: { item in
            asked.urls.append(item.url)
            return ReadAlongTiming(segments: [.init(text: "The Machine Stops.", paragraph: -1, start: 0, end: 1.2),
                                              .init(text: "Imagine, if you can, a small room.", paragraph: 0, start: 1.6, end: 4)])
        })
        let timing = await draft.timing?(1)
        XCTAssertEqual(asked.urls, [second.url])
        let text = try XCTUnwrap(BookShareDraft.readAlongText(timing))
        XCTAssertEqual(text.segments.map(\.text), ["The Machine Stops.", "Imagine, if you can, a small room."])
        XCTAssertEqual(text.segments.map(\.paragraph), [-1, 0])
        XCTAssertEqual(text.segments.last?.end, 4)
        let missing = await draft.timing?(7)
        XCTAssertNil(missing, "a chapter that is not here has no timing to ask for")
    }

    /// A seal killed midway leaves a ticketless folder of ciphertext no retry can use (review,
    /// An internal task): it is swept after an hour, and nothing else is.
    func testOnlyOldTicketlessStagingFoldersAreSwept() throws {
        let staging = root.appendingPathComponent("PendingBookShares")
        let manager = FileManager.default
        let now = Date()
        func folder(_ name: String, ticket: Bool = false, age: TimeInterval, in parent: URL? = nil) throws -> URL {
            let url = (parent ?? staging).appendingPathComponent(name)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            let sealed = url.appendingPathComponent("\(UUID().uuidString).sealed")
            try Data(repeating: 1, count: 64).write(to: sealed)
            if ticket { try Data("{}".utf8).write(to: url.appendingPathComponent(PreparedBookShare.ticketName)) }
            for item in [sealed, url] + (ticket ? [url.appendingPathComponent(PreparedBookShare.ticketName)] : []) {
                try manager.setAttributes([.modificationDate: now - age], ofItemAtPath: item.path)
            }
            return url
        }
        let orphan = try folder(UUID().uuidString, age: 7200)
        let recent = try folder(UUID().uuidString, age: 600)
        let ticketed = try folder(UUID().uuidString, ticket: true, age: 86400)
        let active = try folder(UUID().uuidString, age: 7200)
        let named = try folder("not-a-uuid", age: 7200)
        let outside = try folder(UUID().uuidString, age: 7200, in: root.appendingPathComponent("Elsewhere"))
        // A folder whose own date is old but which was written to a minute ago is still in use.
        let busy = try folder(UUID().uuidString, age: 7200)
        try Data([2]).write(to: busy.appendingPathComponent("\(UUID().uuidString).sealed"))
        XCTAssertEqual(SongSharing.orphanedBookStaging(in: staging, active: active, now: now).map(\.standardizedFileURL),
                       [orphan.standardizedFileURL])
        XCTAssertEqual(SongSharing.orphanedBookStaging(in: staging, active: nil, now: now).map(\.lastPathComponent).sorted(),
                       [orphan, active].map(\.lastPathComponent).sorted(), "the sealing folder is spared only while it seals")
        XCTAssertEqual(SongSharing.orphanedBookStaging(in: root.appendingPathComponent("missing"), active: nil, now: now), [])
        for kept in [recent, ticketed, named, outside, busy] { XCTAssertTrue(manager.fileExists(atPath: kept.path)) }
    }

    func testABookLinkGoesToTheBrowserNotTheApp() {
        let id = "AwMDAwMDAwMDAwMDAwMDAw"
        let book = URL(string: "https://batonmusic.app/b/\(id)#BAQEBAQEBAQEBAQEBAQEBA")!
        XCTAssertNil(BatonDeepLink(url: book))
        XCTAssertTrue(BatonDeepLink.isBrowserOnlyShare(book))
        XCTAssertEqual(BatonDeepLink(url: URL(string: "https://batonmusic.app/m/\(id)")!), .mixtape(id: id, key: nil))
    }
}

@MainActor private final class AskedItems { var urls = [URL]() }
