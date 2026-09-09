import XCTest
@testable import Baton

/// : versioned, corruption-safe persistence. A corrupt file must be preserved (never
/// silently wiped), legacy unversioned files must migrate, and version bumps must migrate.
final class VersionedStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }
    private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func testRoundTrip() {
        let store = VersionedStore<[String]>(fileURL: file("s.json"))
        XCTAssertTrue(store.save(["a", "b"]))
        XCTAssertEqual(store.load(), ["a", "b"])
    }

    func testAbsentFileLoadsNil() {
        XCTAssertNil(VersionedStore<[String]>(fileURL: file("missing.json")).load())
    }

    func testCorruptFileIsPreservedNotWiped() throws {
        let url = file("s.json")
        try Data("this is not json { ".utf8).write(to: url)
        let store = VersionedStore<[String]>(fileURL: url)
        XCTAssertNil(store.load(), "corrupt file loads as nil (caller starts empty)")
        // The original bytes must survive alongside as a .corrupt-* file.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.contains("s.json.corrupt-") }, "corrupt file preserved: \(siblings)")
    }

    func testLegacyUnversionedFileMigrates() throws {
        let url = file("s.json")
        // An older build wrote the raw payload (no envelope).
        try JSONEncoder().encode(["x", "y"]).write(to: url)
        XCTAssertEqual(VersionedStore<[String]>(fileURL: url).load(), ["x", "y"])
    }

    func testVersionBumpTriggersMigration() {
        let url = file("s.json")
        VersionedStore<[String]>(fileURL: url, currentVersion: 1).save(["old"])
        let v2 = VersionedStore<[String]>(fileURL: url, currentVersion: 2) { payload, from in
            from < 2 ? payload + ["migrated"] : payload
        }
        XCTAssertEqual(v2.load(), ["old", "migrated"])
    }

    func testBackupKeptWhenEnabled() throws {
        let url = file("s.json")
        let store = VersionedStore<[String]>(fileURL: url, keepBackup: true)
        store.save(["v1"])
        store.save(["v2"]) // second save copies the prior file to .bak
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

    // MARK: - A file from a newer build (S-F14)

    /// The hole this closes. `load` had no `env.version > currentVersion` branch, so a file
    /// written by a newer build went to the identity migration, was adopted as current, and the
    /// next `save` re-stamped it as this build's version — destroying the number a future
    /// migration keys on, and silently downgrading whatever the newer build had added.
    ///
    /// `testVersionBumpTriggersMigration` above looks like it covers this and does not: it is
    /// backward only. Forward and backward are opposite requirements, and the test for one
    /// passes happily while the other is broken.
    func testAFileFromANewerBuildIsNotAdoptedAsCurrent() {
        let url = file("s.json")
        VersionedStore<[String]>(fileURL: url, currentVersion: 3).save(["written by v3"])

        let older = VersionedStore<[String]>(fileURL: url, currentVersion: 1)
        let result = older.loadWithOutcome()

        XCTAssertEqual(result.payload, ["written by v3"], "reading it is fine; rewriting it is not")
        XCTAssertEqual(result.outcome, .newerThanThisBuild(found: 3))
    }

    /// And the half that actually loses data: the older build must refuse the write rather than
    /// re-stamp the file as its own version.
    func testAnOlderBuildRefusesToWriteOverANewerFile() {
        let url = file("s.json")
        VersionedStore<[String]>(fileURL: url, currentVersion: 3).save(["written by v3"])

        let older = VersionedStore<[String]>(fileURL: url, currentVersion: 1)
        XCTAssertFalse(older.save(["downgraded"]), "a refused write must report itself as one")

        XCTAssertEqual(VersionedStore<[String]>(fileURL: url, currentVersion: 3).load(),
                       ["written by v3"],
                       "the newer build's file was overwritten by a build that cannot read it")
    }

    /// A file from an *older* build is still migrated and still writable: the guard has to be
    /// one-directional, or every version bump would break the upgrade path it exists to protect.
    func testAnOlderFileIsStillWritable() {
        let url = file("s.json")
        VersionedStore<[String]>(fileURL: url, currentVersion: 1).save(["old"])
        XCTAssertTrue(VersionedStore<[String]>(fileURL: url, currentVersion: 2).save(["new"]))
    }

    // MARK: - Backed by UserDefaults (S-F14, the play queue)

    /// The play queue lives in one `UserDefaults` key rather than a file, and had every problem
    /// this type was written for: a truncated blob read as "no queue", and the next
    /// `persistQueue()` wrote an empty one over it, so a long set vanished at launch.
    func testADefaultsBackedStoreRoundTripsAndPreservesCorruptBytes() throws {
        let suiteName = "io.tonebox.tests.vstore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let store = VersionedStore<[String]>(backing: .defaults(defaults, key: "queue"),
                                             keepBackup: true)
        XCTAssertTrue(store.save(["a", "b"]))
        XCTAssertEqual(store.load(), ["a", "b"])

        defaults.set(Data("truncat".utf8), forKey: "queue")
        XCTAssertNil(store.load())
        let preserved = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("queue.corrupt-") }
        XCTAssertEqual(preserved.count, 1,
                       "the unreadable queue was discarded rather than kept for recovery")
    }

    /// The forward guard has to work over defaults too, or the queue keeps the hole the files
    /// no longer have.
    func testADefaultsBackedStoreAlsoRefusesToDowngrade() throws {
        let suiteName = "io.tonebox.tests.vstore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        VersionedStore<[String]>(backing: .defaults(defaults, key: "queue"),
                                 currentVersion: 3).save(["written by v3"])
        let older = VersionedStore<[String]>(backing: .defaults(defaults, key: "queue"),
                                             currentVersion: 1)
        XCTAssertFalse(older.save(["downgraded"]))
    }
}
