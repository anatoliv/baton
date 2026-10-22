import XCTest
@testable import BatonSubsonicKit

final class VersionedStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("versioned-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func testCorruptFileIsPreservedAtomically() throws {
        let original = directory.appendingPathComponent("store.json")
        let damaged = Data("not json".utf8)
        try damaged.write(to: original)

        let result = VersionedStore<[String]>(fileURL: original).loadWithOutcome()

        XCTAssertNil(result.payload)
        XCTAssertEqual(result.outcome, .quarantined)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let rescueName = try XCTUnwrap(names.first { $0.hasPrefix("store.json.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(rescueName)), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path),
                       "once the rescue is durable, the unreadable file should be quarantined")
    }

    func testFailedRescueLeavesOriginalAndReportsFailure() throws {
        let original = directory.appendingPathComponent("store.json")
        let damaged = Data("not json".utf8)
        try damaged.write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)

        let result = VersionedStore<[String]>(fileURL: original).loadWithOutcome()

        XCTAssertNil(result.payload)
        XCTAssertEqual(result.outcome, .quarantineFailed)
        XCTAssertEqual(try Data(contentsOf: original), damaged,
                       "a failed rescue must not replace the only surviving copy")
        XCTAssertFalse(VersionedStore<[String]>(fileURL: original).save(["replacement"]),
                       "save must refuse while the unreadable bytes still cannot be rescued")
        XCTAssertEqual(try Data(contentsOf: original), damaged)
    }

    /// A newer build may have changed the payload's shape as well as its stamp. Its file must be
    /// left alone, not quarantined as corrupt and then replaced by this build's empty state.
    func testANewerBuildsUndecodablePayloadIsNotQuarantinedOrOverwritten() throws {
        let original = directory.appendingPathComponent("store.json")
        let newer = Data(#"{"version":4,"payload":{"reshaped":true}}"#.utf8)
        try newer.write(to: original)
        let store = VersionedStore<[String]>(fileURL: original, currentVersion: 3)

        let result = store.loadWithOutcome()

        XCTAssertNil(result.payload)
        XCTAssertEqual(result.outcome, .newerThanThisBuild(found: 4))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["store.json"], "a newer build's file was quarantined")
        XCTAssertFalse(store.save(["downgrade"]))
        XCTAssertEqual(try Data(contentsOf: original), newer)
    }

    /// A file that is there but cannot be read loaded as "nothing stored", and the next save
    /// replaced it unread (TBX-1000000506, C2-22).
    func testAFileThatCannotBeReadIsNeverWrittenOver() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("store.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = VersionedStore<[String]>(fileURL: url)
        XCTAssertTrue(store.save(["kept"]))
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try XCTSkipIf((try? Data(contentsOf: url)) != nil, "this user can read a mode-000 file")

        let result = store.loadWithOutcome()
        XCTAssertNil(result.payload)
        XCTAssertEqual(result.outcome, .unreadable, "an unreadable file read as a fresh install")
        XCTAssertFalse(store.save(["fresh"]), "the unread file was written over")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    /// The refusal must outlast the unreadable moment. An iPhone launched in the background
    /// before first unlock reads nothing and starts empty; once the device unlocks the file is
    /// readable again, and the next save would write that empty start over data nobody read
    /// (TBX-1000000506 review finding 1). A store that could not read its file writes again
    /// only after a load that did read it.
    func testAStoreThatNeverReadItsFileStillRefusesOnceTheFileIsReadable() throws {
        let url = directory.appendingPathComponent("latched.json")
        let store = VersionedStore<[String]>(fileURL: url)
        XCTAssertTrue(store.save(["kept"]))
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try XCTSkipIf((try? Data(contentsOf: url)) != nil, "this user can read a mode-000 file")
        XCTAssertEqual(store.loadWithOutcome().outcome, .unreadable)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertFalse(store.save([]), "the empty start state was written over the unread file")
        XCTAssertEqual(try Data(contentsOf: url), before)

        XCTAssertEqual(store.load(), ["kept"], "a load that reads the file")
        XCTAssertTrue(store.save(["kept", "more"]), "then writes as usual")
    }
}
