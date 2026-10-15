import XCTest
@testable import BatonMobile

/// A document handed to the phone waits on disk for its import screen, so a
/// force-quit between the share and the screen closing does not lose it.
final class PendingImportStoreTests: XCTestCase {
    private var root: URL!
    private var store: PendingImportStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-pending-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PendingImportStore(directory: root.appendingPathComponent("PendingImport", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func stagedFile(_ name: String = "1a2b3c4d-Notes.txt", text: String = "Words to read aloud.") throws -> URL {
        let file = root.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testAKeptFileIsRestoredOnTheNextLaunchUntilCleared() throws {
        let staged = try stagedFile()
        let kept = store.keep(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "moved out of the temporary folder")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "Words to read aloud.")

        // A new launch: a fresh store over the same folder.
        let relaunched = PendingImportStore(directory: store.directory)
        XCTAssertEqual(relaunched.restore()?.standardizedFileURL, kept.standardizedFileURL)
        XCTAssertEqual(relaunched.restore()?.standardizedFileURL, kept.standardizedFileURL, "restoring does not consume it")

        relaunched.clear()
        XCTAssertNil(relaunched.restore())
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path))
    }

    func testAKeptLinkIsRestored() {
        let link = URL(string: "https://example.com/an-article")!
        XCTAssertEqual(store.keep(link), link)
        XCTAssertEqual(PendingImportStore(directory: store.directory).restore(), link)
    }

    func testANewDocumentReplacesTheOldOne() throws {
        let first = store.keep(try stagedFile("first.txt"))
        let second = store.keep(try stagedFile("second.txt", text: "Second."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(store.restore()?.lastPathComponent, "second.txt")
        XCTAssertEqual(store.keep(second), second, "offering the kept copy again keeps it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testAWeekOldDocumentIsDropped() throws {
        let now = Date()
        let kept = store.keep(try stagedFile(), now: now.addingTimeInterval(-PendingImportStore.maximumAge - 60))
        XCTAssertNil(store.restore(now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path), "the stale copy is removed")

        let fresh = store.keep(try stagedFile(), now: now.addingTimeInterval(-60))
        XCTAssertEqual(store.restore(now: now)?.standardizedFileURL, fresh.standardizedFileURL)
    }

    func testAMissingFileRestoresNothing() throws {
        let kept = store.keep(try stagedFile())
        try FileManager.default.removeItem(at: kept)
        XCTAssertNil(store.restore())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
}
