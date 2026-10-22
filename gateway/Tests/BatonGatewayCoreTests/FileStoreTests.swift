import Foundation
import XCTest
@testable import BatonGatewayCore

/// The gateway's file store.
///
/// **These are the gateway's first tests.** Nothing in `scripts/test.sh` built this target
/// before, which is the same gap the Watch app has twice fallen through in this repo: it
/// silently stopped compiling and nobody noticed, because nothing built it. Adding streaming
/// file storage to a component no automated check even compiles would have been worse.
///
/// What is asserted here is the part that fails quietly: an id off the wire becoming a file
/// path, a disk filling up, and a half-written blob being served as though it were whole.
final class FileStoreTests: XCTestCase {

    private var dir: URL!
    private var store: FileStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-filestore-\(UUID().uuidString)")
        // Small limits, so the eviction and refusal paths are testable without writing
        // hundreds of megabytes to someone's disk on every run.
        store = FileStore(directory: dir, maximumFileBytes: 4096,
                          maximumTotalBytes: 10_000, maximumAge: 3600)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A file already on disk, as the transport will hand it over once it streams uploads.
    private func staged(_ bytes: Int, name: String = "clip") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("staged-\(UUID().uuidString)")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func id() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    // MARK: - Round trip

    func testACommittedFileCanBeFoundAgainWithItsMetadata() throws {
        let fileID = id()
        let meta = try store.commit(staged: try staged(1024), id: fileID, name: "Reading.m4a",
                                    contentType: "audio/mp4", sha256: "abc123", origin: "Mac")

        XCTAssertEqual(meta.size, 1024)
        XCTAssertEqual(store.metadata(id: fileID)?.name, "Reading.m4a")
        XCTAssertEqual(store.metadata(id: fileID)?.sha256, "abc123", "the receiver needs this to verify")
        XCTAssertNotNil(store.blobURL(id: fileID))
        XCTAssertEqual(store.list().count, 1)
    }

    /// The staged file is *moved*, not copied. A rename within a filesystem is atomic, so a
    /// reader sees the whole file or no file, and a gateway killed mid-publish cannot leave a
    /// partial blob that a later GET serves happily.
    func testCommittingConsumesTheStagedFile() throws {
        let source = try staged(512)
        try store.commit(staged: source, id: id(), name: "a", contentType: "audio/mp4",
                         sha256: nil, origin: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "the staged upload was copied rather than moved, so two copies exist")
    }

    /// Re-uploading the same id replaces it. Uploads get retried, and a retry must not fail or
    /// leave the first attempt's bytes behind under the same name.
    func testReUploadingAnIDReplacesIt() throws {
        let fileID = id()
        try store.commit(staged: try staged(100), id: fileID, name: "first",
                         contentType: "audio/mp4", sha256: nil, origin: nil)
        try store.commit(staged: try staged(200), id: fileID, name: "second",
                         contentType: "audio/mp4", sha256: nil, origin: nil)
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.metadata(id: fileID)?.size, 200)
        XCTAssertEqual(store.metadata(id: fileID)?.name, "second")
    }

    // MARK: - Ids are hostile input

    /// This service answers every device on the network, and an id off the wire becomes a file
    /// name. A separator or a `..` would be a write outside the store.
    func testTraversalAndOtherHostileIDsAreRefused() {
        for bad in ["../etc/passwd", "a/b", "..", "a b", "a;rm -rf /", "", String(repeating: "a", count: 200)] {
            XCTAssertNil(FileStore.sanitize(bad), "accepted a hostile id: \(bad)")
        }
    }

    func testAHostileIDIsRefusedAtCommitAndTakesTheStagedFileWithIt() throws {
        let source = try staged(64)
        XCTAssertThrowsError(try store.commit(staged: source, id: "../escape", name: "x",
                                              contentType: "audio/mp4", sha256: nil, origin: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "a refused upload left its staged file behind to accumulate")
        XCTAssertTrue(store.list().isEmpty)
    }

    func testDigestsAndUUIDsAreBothAcceptedAndNormalised() {
        XCTAssertEqual(FileStore.sanitize("ABCDEF0123"), "abcdef0123")
        XCTAssertNotNil(FileStore.sanitize(UUID().uuidString))
        XCTAssertNotNil(FileStore.sanitize(String(repeating: "a", count: 64)), "a SHA-256 digest")
    }

    // MARK: - Bounded, in all three directions

    func testAFileOverThePerFileCapIsRefusedRatherThanTruncated() throws {
        let source = try staged(store.maximumFileBytes + 1)
        XCTAssertThrowsError(try store.commit(staged: source, id: id(), name: "huge",
                                              contentType: "audio/mp4", sha256: nil, origin: nil)) { error in
            XCTAssertEqual(error as? FileStore.StoreError, .tooLarge(limit: store.maximumFileBytes))
        }
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    /// A file nobody collected is dropped. Without this the store only ever grows, and the total
    /// cap would eventually evict things people *were* waiting for.
    func testFilesPastTheAgeLimitArePruned() throws {
        let old = id(), fresh = id()
        let now = Date()
        try store.commit(staged: try staged(10), id: old, name: "old", contentType: "audio/mp4",
                         sha256: nil, origin: nil,
                         now: now.addingTimeInterval(-store.maximumAge - 3600))
        try store.commit(staged: try staged(10), id: fresh, name: "fresh", contentType: "audio/mp4",
                         sha256: nil, origin: nil, now: now)

        store.prune(now: now)
        XCTAssertNil(store.metadata(id: old), "an expired file survived")
        XCTAssertNotNil(store.metadata(id: fresh))
    }

    /// Oldest first, so the thing most recently sent is the thing most likely to still be there.
    func testTheTotalCapEvictsTheOldestFirst() throws {
        let each = store.maximumTotalBytes / 4 + 1
        let now = Date()
        var ids: [String] = []
        for i in 0..<4 {
            let fileID = id()
            ids.append(fileID)
            try store.commit(staged: try staged(each), id: fileID, name: "f\(i)",
                             contentType: "audio/mp4", sha256: nil, origin: nil,
                             now: now.addingTimeInterval(Double(i)))
        }
        let total = store.list().reduce(0) { $0 + $1.size }
        XCTAssertLessThanOrEqual(total, store.maximumTotalBytes, "the store grew past its own cap")
        XCTAssertNil(store.metadata(id: ids[0]), "the oldest should have gone first")
        XCTAssertNotNil(store.metadata(id: ids[3]), "the newest should have survived")
    }

    // MARK: - "Send to my Mac" pending imports

    /// What the phone's relay stores: the document first, then its record, then a Mac's claim.
    /// Ids as `PendingImportRelay` makes them: a lowercase UUID, `-d0c`, `-<mac>`.
    @discardableResult
    private func pendingImport(document bytes: Int, at time: Date) throws -> String {
        let record = UUID().uuidString.lowercased()
        try store.commit(staged: try staged(bytes), id: "\(record)-d0c", name: "Two Rooms.md",
                         contentType: "text/markdown", sha256: nil, origin: "iPhone", now: time)
        try store.commit(staged: try staged(200), id: record, name: "pending-import.json",
                         contentType: FileStore.pendingImportContentType, sha256: nil, origin: "iPhone",
                         now: time.addingTimeInterval(1))
        try store.commit(staged: try staged(2), id: "\(record)-\(UUID().uuidString.lowercased())", name: "claim",
                         contentType: "application/vnd.baton.pending-import-claim", sha256: nil, origin: "Mac",
                         now: time.addingTimeInterval(2))
        return record
    }

    private func pendingFiles(_ record: String) -> [String] {
        store.list().map(\.id).filter { $0 == record || $0.hasPrefix("\(record)-") }
    }

    /// The document was stored first, so plain oldest-first eviction took it and left its record:
    /// the Mac then claimed a record whose document was gone, every minute, for two weeks.
    func testCapEvictionTakesAPendingImportsRecordDocumentAndClaimTogether() throws {
        let now = Date()
        let first = try pendingImport(document: 4000, at: now)
        let second = try pendingImport(document: 4000, at: now.addingTimeInterval(10))
        let third = try pendingImport(document: 4000, at: now.addingTimeInterval(20))

        XCTAssertLessThanOrEqual(store.list().reduce(0) { $0 + $1.size }, store.maximumTotalBytes)
        XCTAssertEqual(pendingFiles(first), [], "the oldest import goes whole, record and claim included")
        XCTAssertEqual(pendingFiles(second).count, 3)
        XCTAssertEqual(pendingFiles(third).count, 3)
    }

    /// Under cap pressure everything else goes before a document someone sent to their Mac.
    func testUnderCapPressureOtherFilesGoBeforeAPendingImport() throws {
        let now = Date()
        let sent = try pendingImport(document: 4000, at: now)
        let clip1 = id(), clip2 = id()
        try store.commit(staged: try staged(3000), id: clip1, name: "c1", contentType: "audio/mp4",
                         sha256: nil, origin: nil, now: now.addingTimeInterval(10))
        try store.commit(staged: try staged(3000), id: clip2, name: "c2", contentType: "audio/mp4",
                         sha256: nil, origin: nil, now: now.addingTimeInterval(20))

        XCTAssertLessThanOrEqual(store.list().reduce(0) { $0 + $1.size }, store.maximumTotalBytes)
        XCTAssertEqual(pendingFiles(sent).count, 3, "the pending import survived")
        XCTAssertNil(store.metadata(id: clip1), "the oldest other file went instead")
        XCTAssertNotNil(store.metadata(id: clip2))
    }

    /// Pending imports go last under the cap, but not after the file an upload has just written:
    /// that file was answered 201 and evicted in the same commit, so the other device's GET
    /// found nothing (TBX-1000000493 review).
    func testTheFileJustCommittedSurvivesPendingImportsFillingTheCap() throws {
        let now = Date()
        try pendingImport(document: 4000, at: now)
        try pendingImport(document: 4000, at: now.addingTimeInterval(10))
        let clip = id()
        try store.commit(staged: try staged(3000), id: clip, name: "a reading", contentType: "audio/mp4",
                         sha256: nil, origin: nil, now: now.addingTimeInterval(20))

        XCTAssertNotNil(store.metadata(id: clip), "the upload's own file was evicted by its own commit")
        XCTAssertLessThanOrEqual(store.list().reduce(0) { $0 + $1.size }, store.maximumTotalBytes)
    }

    /// The age limit still applies to pending imports, and takes the whole import at once rather
    /// than the document a second before its record.
    func testTheAgeLimitTakesAPendingImportWhole() throws {
        let now = Date()
        let sent = try pendingImport(document: 100, at: now.addingTimeInterval(-store.maximumAge - 1))
        store.prune(now: now)
        XCTAssertEqual(pendingFiles(sent), [], "record or claim outlived its document")
    }

    /// Only the relay's record type groups files: an ordinary file whose id happens to start
    /// like another's is evicted on its own.
    func testOrdinaryFilesAreNotGrouped() throws {
        let now = Date()
        let a = id()
        try store.commit(staged: try staged(4000), id: a, name: "a", contentType: "audio/mp4",
                         sha256: nil, origin: nil, now: now)
        try store.commit(staged: try staged(10), id: "\(a)-1", name: "a1", contentType: "audio/mp4",
                         sha256: nil, origin: nil, now: now.addingTimeInterval(30))
        try store.commit(staged: try staged(4000), id: id(), name: "b", contentType: "audio/mp4",
                         sha256: nil, origin: nil, now: now.addingTimeInterval(10))
        try store.commit(staged: try staged(4000), id: id(), name: "c", contentType: "audio/mp4",
                         sha256: nil, origin: nil, now: now.addingTimeInterval(20))
        XCTAssertNil(store.metadata(id: a))
        XCTAssertNotNil(store.metadata(id: "\(a)-1"), "an unrelated newer file stayed")
    }

    // MARK: - Listing

    func testListIsNewestFirstAndSurvivesAStrayFileInTheDirectory() throws {
        let now = Date()
        for i in 0..<3 {
            try store.commit(staged: try staged(10), id: id(), name: "f\(i)",
                             contentType: "audio/mp4", sha256: nil, origin: nil,
                             now: now.addingTimeInterval(Double(i)))
        }
        // Something that is not ours, and a sidecar that is not valid JSON. Neither may take the
        // listing down: this directory is on someone's home server and will collect debris.
        try Data("hello".utf8).write(to: dir.appendingPathComponent("README.txt"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("deadbeef.json"))

        let listed = store.list()
        XCTAssertEqual(listed.count, 3)
        XCTAssertEqual(listed.map(\.name), ["f2", "f1", "f0"])
    }

    func testRemovingTakesBothTheBlobAndItsMetadata() throws {
        let fileID = id()
        try store.commit(staged: try staged(10), id: fileID, name: "x", contentType: "audio/mp4",
                         sha256: nil, origin: nil)
        store.remove(id: fileID)
        XCTAssertNil(store.metadata(id: fileID))
        XCTAssertNil(store.blobURL(id: fileID))
        XCTAssertTrue(store.list().isEmpty)
    }

    // MARK: - TBX-5325: a stored name is bounded on its own, not just by the header cap

    /// `name` comes straight off `X-Baton-Name`, whose only limit is the transport's 32 KB
    /// header cap — so an uncapped name would put up to 32 KB in every sidecar file and every
    /// `list()` response, forever, for a field that exists to be shown on screen.
    func testAnOversizedNameIsTruncatedRatherThanStoredWhole() throws {
        let fileID = id()
        let longName = String(repeating: "n", count: 5_000)
        let meta = try store.commit(staged: try staged(10), id: fileID, name: longName,
                                    contentType: "audio/mp4", sha256: nil, origin: nil)

        XCTAssertEqual(meta.name.count, FileStore.maximumNameLength,
                       "the name handed back must already be the bounded one")
        XCTAssertEqual(store.metadata(id: fileID)?.name.count, FileStore.maximumNameLength,
                       "and so must what comes back off disk")
    }

    /// An ordinary file name is untouched — this is a ceiling, not a rewrite.
    func testAnOrdinaryNameIsUnaffected() throws {
        let meta = try store.commit(staged: try staged(10), id: id(), name: "Reading.m4a",
                                    contentType: "audio/mp4", sha256: nil, origin: nil)
        XCTAssertEqual(meta.name, "Reading.m4a")
    }
}
