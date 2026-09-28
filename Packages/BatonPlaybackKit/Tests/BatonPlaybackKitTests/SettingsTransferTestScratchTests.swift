import Foundation
import XCTest
@testable import BatonPlaybackKit

/// `SettingsTransfer.documentsDirectory` under XCTest must not leave anything in `$TMPDIR`.
///
/// Every call used to mint `$TMPDIR/io.tonebox.tests.documents.<UUID>`, and any test that
/// imported documents created it and walked away. 45 empty folders had piled up by 2026-09-24,
/// and 18 more within a day of clearing them.
final class SettingsTransferTestScratchTests: XCTestCase {
    /// Each call is still its own directory, so tests stay isolated, but all of them sit under
    /// one root named for this process, inside the temporary directory.
    func testEachCallIsDistinctAndUnderOneRootForThisProcess() throws {
        let first = try XCTUnwrap(SettingsTransfer.documentsDirectory())
        let second = try XCTUnwrap(SettingsTransfer.documentsDirectory())
        let root = SettingsTransfer.testDocumentsRoot

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(second.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(root.lastPathComponent, "io.tonebox.tests.documents.\(getpid())")
        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL,
                       URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL)
    }

    /// What `atexit` runs really removes the root, documents and all. The next write
    /// recreates it, so running this mid-suite costs later tests nothing.
    func testTheExitHookRemovesTheRootAndWhatWasWrittenInIt() throws {
        let directory = try XCTUnwrap(SettingsTransfer.documentsDirectory())
        let written = SettingsTransfer.writeDocuments(["remote-memory.json": Data("{}".utf8)], to: directory)
        XCTAssertEqual(written, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        SettingsTransfer.removeTestDocumentsRoot()

        XCTAssertFalse(FileManager.default.fileExists(atPath: SettingsTransfer.testDocumentsRoot.path))
    }

    /// A test process killed before `atexit` runs leaves its root behind. The next process
    /// removes roots whose pid has gone, and leaves a live process's root and anything not
    /// named for a pid alone.
    func testTheSweepRemovesOnlyRootsWhoseProcessHasGone() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // A pid far above the default ceiling, so no process can hold it.
        let gone = dir.appendingPathComponent("\(SettingsTransfer.testDocumentsPrefix)99999999")
        let live = dir.appendingPathComponent("\(SettingsTransfer.testDocumentsPrefix)\(getppid())")
        let mine = dir.appendingPathComponent("\(SettingsTransfer.testDocumentsPrefix)\(getpid())")
        let odd = dir.appendingPathComponent("\(SettingsTransfer.testDocumentsPrefix)not-a-pid")
        for url in [gone, live, mine, odd] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }

        SettingsTransfer.sweepStaleTestDocumentRoots(in: dir)

        XCTAssertFalse(fm.fileExists(atPath: gone.path), "a dead process's root should go")
        XCTAssertTrue(fm.fileExists(atPath: live.path), "a running process's root must stay")
        XCTAssertTrue(fm.fileExists(atPath: mine.path), "this process's own root must stay")
        XCTAssertTrue(fm.fileExists(atPath: odd.path), "a name that is not a pid must stay")
    }
}
