import XCTest
import BatonSubsonicKit
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

/// The whole hand-over across a quit (TBX-10889 audit): a share claimed out of the App Group
/// inbox and offered to the model is still pending in the next process's model, and is let go
/// only when the person closes an import screen that actually appeared. The model uses the real
/// `PendingImportStore.shared`, so each test starts and ends with it empty.
@MainActor
final class PendingImportRelaunchTests: XCTestCase {
    private var work: URL!
    private var inbox: PendingShareInbox!
    private var storedDocumentsSwitch: Any?

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("baton-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        inbox = PendingShareInbox(root: work.appendingPathComponent("PendingImports", isDirectory: true))
        storedDocumentsSwitch = BatonStorage.defaults.object(forKey: MobileDocuments.enabledKey)
        BatonStorage.defaults.removeObject(forKey: MobileDocuments.enabledKey)
        PendingImportStore.shared.clear()
    }

    override func tearDownWithError() throws {
        PendingImportStore.shared.clear()
        if let storedDocumentsSwitch {
            BatonStorage.defaults.set(storedDocumentsSwitch, forKey: MobileDocuments.enabledKey)
        }
        try? FileManager.default.removeItem(at: work)
    }

    func testAClaimedShareSurvivesARelaunchUntilItsImportScreenIsClosed() throws {
        try inbox.writeText("Pages From Elsewhere\n\nChapter 1 The Window\n\nWords.", originalName: "Shared.txt")

        // The activation pickup in BatonMobileApp: claim out of the inbox, offer to the model.
        let claimed = try XCTUnwrap(MobileDocuments.claimSharedImport(from: inbox))
        XCTAssertNil(MobileDocuments.claimSharedImport(from: inbox), "the inbox hands a share over once")
        var model: MobileModel? = MobileModel()
        model?.offerImport(claimed)
        let pending = try XCTUnwrap(model?.pendingDocumentImport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))

        // Force-quit before the import screen appeared: the model goes, a new process starts.
        model = nil
        let relaunched = MobileModel()
        XCTAssertEqual(relaunched.pendingDocumentImport?.standardizedFileURL, pending.standardizedFileURL,
                       "the claimed share is still pending after a relaunch")
        XCTAssertTrue(try String(contentsOf: pending, encoding: .utf8).contains("The Window"))

        // A sheet handed the import that was taken back before it appeared keeps it pending.
        var presentation = ImportPresentation()
        let now = Date()
        func situation(_ seconds: TimeInterval) -> ImportPresentation.Situation {
            .init(pending: relaunched.pendingDocumentImport, isActive: true, waitsForGate: false,
                  otherPresentationUp: false, now: now.addingTimeInterval(seconds))
        }
        XCTAssertEqual(presentation.step(situation(0)), .show(pending))
        XCTAssertEqual(presentation.closed(pending: relaunched.pendingDocumentImport, whatsNewWanted: false), .keepImport)
        XCTAssertNotNil(PendingImportStore(directory: PendingImportStore.shared.directory).restore(),
                        "not seen yet, so still kept on disk")

        // The screen appears, and the person closes it: only now is the document let go.
        presentation.appeared(pending)
        XCTAssertEqual(presentation.closed(pending: relaunched.pendingDocumentImport, whatsNewWanted: false), .endImport)
        relaunched.pendingDocumentImport = nil // what RootTabView does on .endImport
        XCTAssertNil(PendingImportStore(directory: PendingImportStore.shared.directory).restore())
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertNil(MobileModel().pendingDocumentImport, "nothing comes back on the launch after")
    }
}
