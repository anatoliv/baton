import Foundation
import XCTest
@testable import BatonPlaybackKit

/// A book's cover on this device: kept by document id under a name that changes with
/// the picture, carried to the player with the book's chapters, and settled with the home server
/// without comparing one device's clock with another's.
@MainActor
final class BookCoverStoreTests: XCTestCase {
    private var dir: URL!
    private let document = String(repeating: "ab", count: 32)
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x11, count: 500)
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x22, count: 500)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-covers-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testACoverIsKeptUnderANameThatChangesWithThePicture() throws {
        let store = BookCoverStore(directory: dir.appendingPathComponent("covers"))
        var told: [String] = []
        store.onChange = { told.append($0) }
        try store.set(jpeg, documentID: document, source: .made)
        let first = try XCTUnwrap(store.url(for: document))
        XCTAssertEqual(first.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: first), jpeg)
        XCTAssertEqual(store.entry(document)?.needsPush, true)
        XCTAssertEqual(store.source(of: document), .made)

        try store.set(png, documentID: document, source: .file)
        let second = try XCTUnwrap(store.url(for: document))
        XCTAssertNotEqual(first, second, "a new picture is a new URL, so no cache shows the old one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the old picture goes")
        XCTAssertEqual(second.pathExtension, "png")
        XCTAssertEqual(told, [document, document])

        // Read back by a new store, as after a relaunch.
        let again = BookCoverStore(directory: dir.appendingPathComponent("covers"))
        XCTAssertEqual(again.url(for: document), second)
        XCTAssertEqual(again.entry(document)?.source, .file)

        store.remove(documentID: document)
        XCTAssertNil(store.url(for: document))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(store.entry(document)?.needsPush, true, "the removal is kept until the home server has it")
        XCTAssertEqual(told.count, 3)
    }

    func testOnlyAPictureIsKeptAndOnlyUnderAnIdThatCanBeAFileName() {
        let store = BookCoverStore(directory: dir)
        XCTAssertThrowsError(try store.set(Data("<svg/>".utf8), documentID: document, source: .file)) {
            XCTAssertEqual($0 as? BookCoverStore.StoreError, .notAnImage)
        }
        XCTAssertThrowsError(try store.set(jpeg, documentID: "../../etc", source: .file)) {
            XCTAssertEqual($0 as? BookCoverStore.StoreError, .badID)
        }
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// The book's own cover (an EPUB's) never replaces one the listener chose, found or made.
    func testTheBooksOwnCoverOnlyFillsAnEmptyPlace() throws {
        let store = BookCoverStore(directory: dir)
        XCTAssertTrue(store.setIfAbsent(jpeg, documentID: document, source: .book))
        try store.set(png, documentID: document, source: .openLibrary)
        XCTAssertFalse(store.setIfAbsent(jpeg, documentID: document, source: .book))
        XCTAssertEqual(store.source(of: document), .openLibrary)
        store.remove(documentID: document)
        XCTAssertTrue(store.setIfAbsent(jpeg, documentID: document, source: .book), "importing the book again brings its own cover back")
        XCTAssertEqual(store.source(of: document), .book)
        // A book first seen in the home server's listing, with nothing set there, still keeps its own.
        store.markSynced(documentID: "cd", jobID: "job-1", serverChangedAt: nil)
        XCTAssertTrue(store.setIfAbsent(jpeg, documentID: "cd", source: .book))
    }

    /// A chapter handed to the player carries its book's cover as a direct picture, which every
    /// Now Playing surface and the lock screen read first.
    func testABookChapterCarriesItsCoverToThePlayer() throws {
        let clippings = ClippingStore(directory: dir.appendingPathComponent("clips"))
        let audio = dir.appendingPathComponent("a.m4a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 64).write(to: audio)
        let chapter = try clippings.adopt(audio, title: "Chapter 1", durationSeconds: 10,
                                          chapter: .init(documentID: document, documentTitle: "The Book", author: "A. Writer",
                                                         chapterIndex: 0, chapterTitle: "Chapter 1"))
        let reading = try clippings.adopt(try staged(), title: "A reading", durationSeconds: 5)
        let store = BookCoverStore(directory: dir.appendingPathComponent("covers"))
        store.remove(documentID: document)
        XCTAssertNil(chapter.asSong.artworkURL)
        try store.set(jpeg, documentID: document, source: .made)
        XCTAssertEqual(chapter.asSong.artworkURL, store.url(for: document))
        XCTAssertNil(chapter.asSong.coverArtID, "still no server cover-art lookup")
        XCTAssertNil(reading.asSong.artworkURL, "a reading has no book and no cover")
        store.remove(documentID: document)
        XCTAssertNil(chapter.asSong.artworkURL)
    }

    private func staged() throws -> URL {
        let url = dir.appendingPathComponent("r-\(UUID().uuidString).m4a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: url)
        return url
    }

    // MARK: - Settling with the home server

    private func entry(sha: String?, needsPush: Bool, job: String? = "job-1", at: Date? = Date(timeIntervalSince1970: 100))
        -> BookCoverStore.Entry {
        BookCoverStore.Entry(documentID: document, sha256: sha, fileName: sha.map { "\(document)-\($0.prefix(12)).jpg" },
                             source: sha == nil ? nil : .made, changedAt: Date(), needsPush: needsPush,
                             syncedJobID: job, serverChangedAt: at)
    }

    private func server(_ sha: String?, at seconds: TimeInterval) -> BookCoverStore.ServerCover {
        BookCoverStore.ServerCover(sha256: sha, changedAt: Date(timeIntervalSince1970: seconds))
    }

    func testAChangeMadeHereGoesUpUntilTheHomeServerHasIt() {
        let decide = BookCoverStore.decide
        XCTAssertEqual(decide(entry(sha: "aaa", needsPush: true), "job-1", nil), .push)
        XCTAssertEqual(decide(entry(sha: "aaa", needsPush: true), "job-1", server("bbb", at: 200)), .push,
                       "this device's newer change wins over what the home server had")
        XCTAssertEqual(decide(entry(sha: "aaa", needsPush: true), "job-1", server("aaa", at: 200)), .settled)
        XCTAssertEqual(decide(entry(sha: nil, needsPush: true), "job-1", server("bbb", at: 200)), .pushRemoval)
        XCTAssertEqual(decide(entry(sha: nil, needsPush: true), "job-1", server(nil, at: 200)), .settled)
        XCTAssertEqual(decide(entry(sha: nil, needsPush: true), "job-1", nil), .settled, "nothing there to remove")
    }

    func testAChangeMadeOnTheOtherDeviceComesDown() {
        let decide = BookCoverStore.decide
        XCTAssertEqual(decide(nil, "job-1", server("bbb", at: 200)), .pull, "a book this device has no cover for")
        XCTAssertEqual(decide(entry(sha: "aaa", needsPush: false), "job-1", server("bbb", at: 200)), .pull)
        XCTAssertEqual(decide(entry(sha: "aaa", needsPush: false), "job-1", server(nil, at: 200)), .removeLocal)
        XCTAssertEqual(decide(entry(sha: nil, needsPush: false), "job-1", server(nil, at: 200)), .settled)
        XCTAssertEqual(decide(nil, "job-1", nil), .nothing)
    }

    func testNothingHappensOnceBothSidesAgree() {
        let decide = BookCoverStore.decide
        // The stamp this device last saw on this job: nothing new, even when this device keeps
        // its own re-encoding of the picture (a different digest).
        XCTAssertEqual(decide(entry(sha: "local", needsPush: false, at: Date(timeIntervalSince1970: 200)), "job-1",
                              server("remote", at: 200)), .nothing)
        XCTAssertEqual(decide(entry(sha: "aaa", needsPush: false, at: Date(timeIntervalSince1970: 150)), "job-1",
                              server("aaa", at: 200)), .settled)
    }

    /// Made again in another voice, the book is a new job with no cover yet: it gets this
    /// device's. If the other device already gave it one, that one is taken.
    func testANewJobForTheSameBookCarriesTheCoverOver() {
        let decide = BookCoverStore.decide
        XCTAssertEqual(decide(entry(sha: "aaa", needsPush: false, job: "job-1"), "job-2", nil), .push)
        XCTAssertEqual(decide(entry(sha: "aaa", needsPush: false, job: "job-1", at: Date(timeIntervalSince1970: 200)), "job-2",
                              server("bbb", at: 200)), .pull, "the same stamp on another job is another change")
        XCTAssertEqual(decide(entry(sha: nil, needsPush: false, job: "job-1"), "job-2", nil), .nothing)
    }

    /// A cover fetched from the home server is not sent back, and remembers what it agreed with.
    func testACoverFromTheHomeServerIsNotSentBack() throws {
        let store = BookCoverStore(directory: dir)
        let stamp = Date(timeIntervalSince1970: 300)
        try store.set(jpeg, documentID: document, source: .homeServer, push: false, syncedJobID: "job-9", serverChangedAt: stamp)
        let kept = try XCTUnwrap(store.entry(document))
        XCTAssertFalse(kept.needsPush)
        XCTAssertEqual(BookCoverStore.decide(local: kept, jobID: "job-9", server: .init(sha256: "x", changedAt: stamp)), .nothing)
        store.markSynced(documentID: "cd", jobID: "job-3", serverChangedAt: nil)
        XCTAssertEqual(store.entry("cd")?.syncedJobID, "job-3")
        XCTAssertFalse(store.entry("cd")?.hasCover ?? true)
    }
}
