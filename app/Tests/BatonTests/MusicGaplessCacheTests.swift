import XCTest
@testable import Baton

/// Disk behavior for the ephemeral gapless prefetch cache: store/lookup, LRU eviction past
/// the cap, and clear.
@MainActor
final class MusicGaplessCacheTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("gaplesscache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeTempFile(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: u.path, contents: Data([0x01, 0x02, 0x03]))
        return u
    }

    func testStoreAndLookup() {
        let cache = MusicGaplessCache(maxEntries: 6, directory: tempDir())
        XCTAssertNil(cache.localURL(for: "s1"))
        XCTAssertNotNil(cache.store(tempFile: makeTempFile("a"), songID: "s1"))
        XCTAssertNotNil(cache.localURL(for: "s1"))
    }

    func testEvictsOldestBeyondCap() {
        let dir = tempDir()
        let cache = MusicGaplessCache(maxEntries: 2, directory: dir)
        for i in 0 ..< 4 {
            _ = cache.store(tempFile: makeTempFile("f\(i)"), songID: "s\(i)")
        }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? 0
        XCTAssertLessThanOrEqual(remaining, 2, "cache exceeded its entry cap")
        XCTAssertNotNil(cache.localURL(for: "s3"), "the most-recently stored file must survive")
    }

    /// W-28 / AUDIO-18: the cache also evicts by byte budget, not just entry count.
    func testEvictsByByteBudget() {
        func sized(_ bytes: Int) -> URL {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sz-\(UUID().uuidString).bin")
            FileManager.default.createFile(atPath: u.path, contents: Data(repeating: 0, count: bytes))
            return u
        }
        let cache = MusicGaplessCache(maxEntries: 100, maxBytes: 100, directory: tempDir())
        _ = cache.store(tempFile: sized(80), songID: "old")
        _ = cache.store(tempFile: sized(80), songID: "new") // total 160 > 100 → evict "old"
        XCTAssertNil(cache.localURL(for: "old"), "byte budget should evict the older entry")
        XCTAssertNotNil(cache.localURL(for: "new"), "the just-stored entry is kept")
        XCTAssertLessThanOrEqual(cache.sizeBytes(), 100)
    }

    func testSizeBytesReflectsStoredFiles() {
        let cache = MusicGaplessCache(directory: tempDir())
        XCTAssertEqual(cache.sizeBytes(), 0)
        _ = cache.store(tempFile: makeTempFile("a"), songID: "s1")
        XCTAssertGreaterThan(cache.sizeBytes(), 0)
    }

    func testClearEmptiesCache() {
        let cache = MusicGaplessCache(directory: tempDir())
        _ = cache.store(tempFile: makeTempFile("a"), songID: "s1")
        cache.clear()
        XCTAssertNil(cache.localURL(for: "s1"))
    }
}
