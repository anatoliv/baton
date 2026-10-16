import Foundation
import XCTest
@testable import BatonPlaybackKit

/// Covers settled with the home server while the listener keeps choosing (TBX-11064 acceptance
/// review): a cover chosen during an upload still goes up, a pick made during a download is kept,
/// and a sync asked for while one runs makes the running one go round again.
@MainActor
final class BookCoverSyncTests: XCTestCase {
    private var dir: URL!
    private let document = String(repeating: "ab", count: 32)
    private let job = String(repeating: "cd", count: 32)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-cover-sync-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func jpeg(_ tag: UInt8) -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0, tag, tag, tag]) }
    private func sha(_ data: Data) -> String { BookCoverStore.sha256(data) }

    /// A home server that keeps one job's cover, counts revisions, and lets a test act in the
    /// middle of a call.
    private final class FakeServer {
        var cover: Data?
        var revision = 0
        var uploads: [Data] = []
        var fetches = 0
        var relists = 0
        /// Runs inside the next upload or fetch, before it answers: the listener choosing.
        var duringUpload: (() throws -> Void)?
        var duringFetch: (() throws -> Void)?
        /// The upload really waits, so another task gets the main actor meanwhile.
        var slowUpload = false
        let stampDate = Date(timeIntervalSince1970: 2_000_000_000)   // the same second, every time

        var stamp: BookCoverStore.ServerCover? {
            revision == 0 ? nil : .init(sha256: cover.map(BookCoverStore.sha256), changedAt: stampDate, revision: revision)
        }

        func remote(job: String, document: String) -> BookCoverSync.Remote {
            BookCoverSync.Remote(
                upload: { [unowned self] _, image in
                    try self.duringUpload?()
                    self.duringUpload = nil
                    if self.slowUpload { try await Task.sleep(for: .milliseconds(150)) }
                    self.uploads.append(image)
                    self.cover = image
                    self.revision += 1
                    return self.stamp!
                },
                remove: { [unowned self] _ in
                    self.cover = nil
                    self.revision += 1
                    return self.stamp!
                },
                fetch: { [unowned self] _ in
                    self.fetches += 1
                    try self.duringFetch?()
                    self.duringFetch = nil
                    return self.cover
                },
                relist: { [unowned self] in
                    self.relists += 1
                    return [BookCoverSync.Book(documentID: document, jobID: job, server: self.stamp)]
                })
        }
    }

    private func engine(_ store: BookCoverStore) -> BookCoverSync {
        BookCoverSync(store: store, sanitize: { $0 })
    }

    /// The reviewer's repro, as it was: cover A uploading, cover B chosen meanwhile. B is still
    /// owed to the home server after A's answer, and the next pass sends it.
    func testACoverChosenDuringAnUploadIsSentAfterIt() async throws {
        let store = BookCoverStore(directory: dir)
        let server = FakeServer()
        try store.set(jpeg(1), documentID: document, source: .made)
        server.duringUpload = { try store.set(self.jpeg(2), documentID: self.document, source: .file) }

        await engine(store).sync([.init(documentID: document, jobID: job, server: nil)],
                                 remote: server.remote(job: job, document: document))

        XCTAssertEqual(server.uploads, [jpeg(1), jpeg(2)], "A, then B on the pass after")
        XCTAssertEqual(server.cover, jpeg(2), "the home server ends with the cover chosen last")
        XCTAssertGreaterThanOrEqual(server.relists, 1)
        let entry = try XCTUnwrap(store.entry(document))
        XCTAssertEqual(entry.sha256, sha(jpeg(2)))
        XCTAssertFalse(entry.needsPush, "settled only once B is there")
        XCTAssertEqual(entry.serverRevision, 2)
    }

    /// The same at the store: what was pushed is recorded, not what the entry holds after.
    func testMarkingSyncedAfterAPushKeepsALaterChangeOwed() throws {
        let store = BookCoverStore(directory: dir)
        try store.set(jpeg(1), documentID: document, source: .made)
        try store.set(jpeg(2), documentID: document, source: .file)
        let stamp = BookCoverStore.ServerCover(sha256: sha(jpeg(1)), changedAt: Date(timeIntervalSince1970: 2_000_000_000), revision: 1)
        store.markSynced(documentID: document, jobID: job, serverChangedAt: stamp.changedAt, serverRevision: 1,
                         pushed: .cover(sha(jpeg(1))))
        XCTAssertEqual(store.entry(document)?.needsPush, true)
        XCTAssertEqual(BookCoverStore.decide(local: store.entry(document), jobID: job, server: stamp), .push)
        // A removal sent while a cover was chosen: still owed too.
        store.markSynced(documentID: document, jobID: job, serverChangedAt: stamp.changedAt, serverRevision: 2, pushed: .removal)
        XCTAssertEqual(store.entry(document)?.needsPush, true)
        store.markSynced(documentID: document, jobID: job, serverChangedAt: stamp.changedAt, serverRevision: 3,
                         pushed: .cover(sha(jpeg(2))))
        XCTAssertEqual(store.entry(document)?.needsPush, false)
    }

    /// Another device's cover is coming down; the listener picks one here meanwhile. The pick is
    /// kept, not overwritten by the download, and goes up on the next pass.
    func testAPickMadeDuringADownloadIsKeptAndSent() async throws {
        let store = BookCoverStore(directory: dir)
        let server = FakeServer()
        server.cover = jpeg(9)
        server.revision = 4
        server.duringFetch = { try store.set(self.jpeg(3), documentID: self.document, source: .openLibrary) }

        await engine(store).sync([.init(documentID: document, jobID: job, server: server.stamp)],
                                 remote: server.remote(job: job, document: document))

        XCTAssertEqual(server.fetches, 1)
        let entry = try XCTUnwrap(store.entry(document))
        XCTAssertEqual(entry.sha256, sha(jpeg(3)), "the pick made here wins")
        XCTAssertEqual(entry.source, .openLibrary)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.url(for: document))), jpeg(3))
        XCTAssertEqual(server.uploads, [jpeg(3)], "and goes to the home server")
        XCTAssertFalse(entry.needsPush)
    }

    /// Without a change meanwhile, a download is applied as before.
    func testADownloadWithNothingChangedHereIsApplied() async throws {
        let store = BookCoverStore(directory: dir)
        let server = FakeServer()
        server.cover = jpeg(9)
        server.revision = 1
        await engine(store).sync([.init(documentID: document, jobID: job, server: server.stamp)],
                                 remote: server.remote(job: job, document: document))
        XCTAssertEqual(store.entry(document)?.sha256, sha(jpeg(9)))
        XCTAssertEqual(store.entry(document)?.source, .homeServer)
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertEqual(server.relists, 0, "nothing left over, no second pass")
    }

    /// A sync asked for while one is running does not run beside it: the running one goes round
    /// again over a fresh listing, which is how a cover chosen meanwhile gets sent.
    func testASyncAskedForDuringOneMakesItGoRoundAgain() async throws {
        let store = BookCoverStore(directory: dir)
        let server = FakeServer()
        let engine = engine(store)
        try store.set(jpeg(1), documentID: document, source: .made)
        var second: Task<Void, Never>?
        var secondFoundOneRunning = false
        server.slowUpload = true
        server.duringUpload = {
            try store.set(self.jpeg(5), documentID: self.document, source: .file)
            // The change's own sync, while this one waits on the upload.
            second = Task { @MainActor in
                secondFoundOneRunning = engine.isSyncing
                await engine.sync([.init(documentID: self.document, jobID: self.job, server: nil)],
                                  remote: server.remote(job: self.job, document: self.document))
            }
        }
        await engine.sync([.init(documentID: document, jobID: job, server: nil)],
                          remote: server.remote(job: job, document: document))
        await second?.value
        XCTAssertTrue(secondFoundOneRunning, "the second sync was asked for while the first ran")
        XCTAssertEqual(server.uploads, [jpeg(1), jpeg(5)], "one upload at a time, the newest last")
        XCTAssertEqual(store.entry(document)?.needsPush, false)
        XCTAssertFalse(engine.isSyncing)
    }

    /// Two changes in the same second are told apart by revision; a home server from before
    /// revisions is still compared by its `changedAt`.
    func testTwoChangesInOneSecondAreToldApartByRevision() throws {
        let store = BookCoverStore(directory: dir)
        let second = Date(timeIntervalSince1970: 2_000_000_000)
        try store.set(jpeg(1), documentID: document, source: .homeServer, push: false, syncedJobID: job,
                      serverChangedAt: second, serverRevision: 1)
        let next = BookCoverStore.ServerCover(sha256: sha(jpeg(2)), changedAt: second, revision: 2)
        XCTAssertEqual(BookCoverStore.decide(local: store.entry(document), jobID: job, server: next), .pull)
        let same = BookCoverStore.ServerCover(sha256: sha(jpeg(1)), changedAt: second, revision: 1)
        XCTAssertEqual(BookCoverStore.decide(local: store.entry(document), jobID: job, server: same), .nothing)
        let older = BookCoverStore.ServerCover(sha256: sha(jpeg(2)), changedAt: second)
        XCTAssertEqual(BookCoverStore.decide(local: store.entry(document), jobID: job, server: older), .nothing,
                       "without revisions the second is all there is")
    }

    /// A book gone for good takes its picture and record with it, and tells the player.
    func testForgettingABookRemovesItsPictureAndRecord() throws {
        let store = BookCoverStore(directory: dir)
        var told: [String] = []
        store.onChange = { told.append($0) }
        try store.set(jpeg(1), documentID: document, source: .made)
        let file = try XCTUnwrap(store.url(for: document))
        store.forget(documentID: document)
        XCTAssertNil(store.entry(document))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(BookCoverStore.artworkURL(documentID: document))
        XCTAssertEqual(told, [document, document])
        XCTAssertNil(BookCoverStore(directory: dir).entry(document), "gone after a relaunch too")
    }
}
