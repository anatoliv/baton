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
}
