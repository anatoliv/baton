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
}
