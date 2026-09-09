import Foundation
import XCTest
@testable import BatonGatewayCore

/// What "something like that" means when two conversations overlap (TBX-5308, S-F26).
///
/// The gateway held one `lastResults` field on one tool surface, so `music_similar_songs` seeded
/// from whatever the most recent search had been, whoever made it.
final class SearchSeedsTests: XCTestCase {

    func testTwoConversationsDoNotShareASeed() {
        let seeds = SearchSeedStore<[String]>()
        seeds.remember(["Debussy"], for: "morning")
        seeds.remember(["Autechre"], for: "evening")

        XCTAssertEqual(seeds.seed(for: "morning"), ["Debussy"],
                       "one conversation's search must not be reseeded by another's")
        XCTAssertEqual(seeds.seed(for: "evening"), ["Autechre"])
    }

    /// A client that sends no session id keeps the single-slot behaviour it had before, rather
    /// than losing its seed entirely.
    func testACallerWithNoSessionIdStillGetsItsOwnLastSearch() {
        let seeds = SearchSeedStore<[String]>()
        seeds.remember(["Debussy"], for: nil)
        seeds.remember(["Autechre"], for: "evening")

        XCTAssertEqual(seeds.seed(for: nil), ["Debussy"])
        XCTAssertEqual(seeds.seed(for: ""), ["Debussy"], "an empty id is no id")
    }

    func testAskingBeforeSearchingReturnsNothing() {
        XCTAssertNil(SearchSeedStore<[String]>().seed(for: "morning"))
    }

    /// A map keyed by session id with nothing evicting it is a slow leak in a process that runs
    /// for months. The bound is what makes this safe to leave alone.
    func testItIsBoundedAndDropsTheLeastRecentlyUsed() {
        let seeds = SearchSeedStore<[String]>(limit: 3)
        seeds.remember(["a"], for: "one")
        seeds.remember(["b"], for: "two")
        seeds.remember(["c"], for: "three")
        _ = seeds.seed(for: "one")            // used again, so "two" is now the oldest
        seeds.remember(["d"], for: "four")

        XCTAssertEqual(seeds.count, 3, "the store must stay bounded")
        XCTAssertNil(seeds.seed(for: "two"), "the least recently used goes first")
        XCTAssertEqual(seeds.seed(for: "one"), ["a"])
        XCTAssertEqual(seeds.seed(for: "four"), ["d"])
    }
}
