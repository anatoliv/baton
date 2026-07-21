import XCTest
@testable import Baton

/// W-49 unit sweep: FilterHistory's dedup / recency / cap / remove logic, exercised against an
/// injected store so the developer's real filter history is never touched.
final class FilterHistoryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FilterHistory.defaults = UserDefaults(suiteName: "filterhist-\(UUID().uuidString)")!
    }
    override func tearDown() {
        FilterHistory.defaults = .standard
        super.tearDown()
    }

    func testAddPutsMostRecentFirstAndTrimsEmpty() {
        FilterHistory.add("jazz", to: "albums")
        FilterHistory.add("  ", to: "albums") // whitespace → ignored
        FilterHistory.add("rock", to: "albums")
        XCTAssertEqual(FilterHistory.items("albums"), ["rock", "jazz"])
    }

    func testAddDedupesCaseInsensitivelyAndMovesToFront() {
        FilterHistory.add("Jazz", to: "albums")
        FilterHistory.add("Rock", to: "albums")
        FilterHistory.add("jazz", to: "albums") // same term, different case → moved to front, not dup
        XCTAssertEqual(FilterHistory.items("albums"), ["jazz", "Rock"])
    }

    func testHistoryIsCappedAtMaxSize() {
        FilterHistory.defaults.set(3, forKey: FilterHistory.sizeKey)
        for term in ["a", "b", "c", "d", "e"] { FilterHistory.add(term, to: "search") }
        XCTAssertEqual(FilterHistory.items("search"), ["e", "d", "c"], "keeps the 3 most recent")
    }

    func testKeysAreIndependent() {
        FilterHistory.add("alpha", to: "albums")
        FilterHistory.add("beta", to: "artists")
        XCTAssertEqual(FilterHistory.items("albums"), ["alpha"])
        XCTAssertEqual(FilterHistory.items("artists"), ["beta"])
    }

    func testRemoveAndClear() {
        for term in ["x", "y", "z"] { FilterHistory.add(term, to: "liked") }
        FilterHistory.remove("y", from: "liked")
        XCTAssertEqual(FilterHistory.items("liked"), ["z", "x"])
        FilterHistory.clear("liked")
        XCTAssertEqual(FilterHistory.items("liked"), [])
    }

    func testMaxSizeClampsBadDefaults() {
        FilterHistory.defaults.set(9999, forKey: FilterHistory.sizeKey)
        XCTAssertEqual(FilterHistory.maxSize, 100)
        FilterHistory.defaults.set(0, forKey: FilterHistory.sizeKey)
        XCTAssertEqual(FilterHistory.maxSize, 1)
    }
}
