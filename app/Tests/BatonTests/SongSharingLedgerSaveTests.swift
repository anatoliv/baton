import BatonShareKit
import XCTest
@testable import Baton

/// C-8: a finished book upload removed its staging folder, the only other copy
/// of the link's key, after a ledger save whose failure was swallowed. The upload now removes it
/// only when `addSaved` says the record reached disk; these pin that answer.
@MainActor
final class SongSharingLedgerSaveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-ledger-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func record() -> ShareLedger.Record {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return ShareLedger.Record(id: "abcdefghijklmnopqrstuv", link: "https://batonmusic.app/b/abcdefghijklmnopqrstuv#key",
                                  songID: "", title: "Book", artist: "Author", isPrivate: true, createdAt: start,
                                  expiresAt: start + 604_800, summary: nil, kind: .book)
    }

    func testASavedRecordSaysSoAndIsOnDisk() throws {
        let url = root.appendingPathComponent("SongShares.json")
        XCTAssertTrue(SongSharing(ledgerURL: url, base: ShareLink.defaultBase).addSaved(record()))
        XCTAssertEqual(ShareLedger.load(from: url).records.map(\.id), ["abcdefghijklmnopqrstuv"])
    }

    func testAFailedSaveSaysSo() throws {
        // The ledger's folder is a file, so nothing can be written there.
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)
        let sharing = SongSharing(ledgerURL: blocker.appendingPathComponent("SongShares.json"), base: ShareLink.defaultBase)
        XCTAssertFalse(sharing.addSaved(record()), "a ledger that never reached disk must not release the staging folder")
    }
}
