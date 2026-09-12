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
}
