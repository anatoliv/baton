import XCTest
@testable import Baton

/// Pins the pure attribute-filter logic behind the Search / Liked screens' funnel
/// (`MusicCollectionView.RatingFilter`). The like/rating *application* is a SwiftUI view
/// concern, but the accept predicate is pure and worth locking so a future refactor of
/// the rating semantics can't silently change what a "★3+" or "Unrated" filter shows.
final class SearchFilterTests: XCTestCase {
    private typealias Filter = MusicCollectionView.RatingFilter

    func testAnyAcceptsEverything() {
        for r in 0...5 { XCTAssertTrue(Filter.any.accepts(r)) }
        XCTAssertFalse(Filter.any.isActive)
    }

    func testUnratedAcceptsOnlyZero() {
        XCTAssertTrue(Filter.unrated.accepts(0))
        for r in 1...5 { XCTAssertFalse(Filter.unrated.accepts(r)) }
        XCTAssertTrue(Filter.unrated.isActive)
    }

    func testAtLeastIsAFloor() {
        let three = Filter.atLeast(3)
        XCTAssertFalse(three.accepts(0))
        XCTAssertFalse(three.accepts(2))
        XCTAssertTrue(three.accepts(3))
        XCTAssertTrue(three.accepts(5))
        XCTAssertTrue(three.isActive)
    }

    func testFiveStarAcceptsOnlyFive() {
        let five = Filter.atLeast(5)
        for r in 0...4 { XCTAssertFalse(five.accepts(r)) }
        XCTAssertTrue(five.accepts(5))
    }
}
