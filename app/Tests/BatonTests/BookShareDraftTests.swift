import AVFoundation
import BatonPlaybackKit
import BatonShareKit
import Foundation
import XCTest
@testable import Baton

/// A Mac book as Share… sees it (TBX-1000000132, `specs/book-sharing.md`): only chapters whose
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
}
