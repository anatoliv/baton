import XCTest
import BatonSubsonicKit
import BatonSubsonicModels
@testable import BatonMobile

/// The rail is a map of the list, so its letters have to run in the same order as the rows.
/// Three shipped bugs came from that going unchecked, and none of them was catchable by the
/// existing suite: the rail is gated at 30 items and the demo library has fewer, so every
/// rail screen renders railless in CI.
final class AlphabetIndexOrderingTests: XCTestCase {

    // MARK: - The server's index letters must survive decoding

    /// `getArtists` returns `{"index": [{"name": "A", "artist": [...]}]}` and the `name`
    /// was never decoded — the client rebuilt its own letters instead, which is the whole
    /// reason the rail disagreed with the rows on a mixed-script library.
    func testArtistsWireKeepsTheServersIndexLetters() throws {
        let json = """
        {"index": [
          {"name": "A", "artist": [{"id": "1", "name": "ABBA"}]},
          {"name": "Б", "artist": [{"id": "2", "name": "Браво"}]}
        ]}
        """.data(using: .utf8)!

        let wire = try JSONDecoder().decode(ArtistsWire.self, from: json)
        let indexed = wire.indexed()

        XCTAssertEqual(indexed.buckets.map(\.letter), ["A", "Б"],
                       "the server's own letters, not letters re-derived from names")
        XCTAssertEqual(indexed.items.map(\.id), ["1", "2"],
                       "flattening must preserve the server's order")
    }

    /// A letter that scrolls nowhere is a dead target, and servers do report empty buckets.
    func testEmptyServerBucketsAreNotOfferedAsTargets() {
        let list = ServerIndexedList<NavidromeArtist>(buckets: [
            .init(letter: "A", items: [NavidromeArtist(id: "1", name: "ABBA")]),
            .init(letter: "B", items: []),
            .init(letter: "C", items: [NavidromeArtist(id: "2", name: "Cher")]),
        ])

        XCTAssertEqual(list.indexTargets.map(\.letter), ["A", "C"])
        XCTAssertEqual(list.indexTargets.map(\.firstID), ["1", "2"])
    }

    // MARK: - The ordering claim

    /// Genres drew `E, R, H, A, C, P` over a list ordered by song count. A caller that
    /// cannot say its list is alphabetical must not be able to get a rail.
    func testAListNobodyVouchedForGetsNoRail() {
        let items = (0..<50).map { (id: "\($0)", name: "Item \($0)") }

        XCTAssertTrue(AlphabetIndex.Ordered.clientSorted(items, isAlphabetical: false).entries.isEmpty,
                      "an index over a non-alphabetical list is worse than no index")
        XCTAssertFalse(AlphabetIndex.Ordered.clientSorted(items, isAlphabetical: true).entries.isEmpty)
    }

    /// The invariant the three bugs all violated: walking the rail top to bottom must walk
    /// the list top to bottom. If letter *n* points further down the list than letter
    /// *n+1*, tapping it jumps backwards.
    func testRailTargetsNeverRunBackwardsThroughTheList() {
        let names = ["01 Intro", "ABBA", "Édith Piaf", "Zebra", "Браво", "東京"]
        let items = names.enumerated().map { (id: "\($0.offset)", name: $0.element) }

        let ordered = AlphabetIndex.Ordered.clientSorted(items, isAlphabetical: true, minimum: 0)
        let positions = ordered.entries.compactMap { entry in
            items.firstIndex { $0.id == entry.firstID }
        }

        XCTAssertEqual(positions, positions.sorted(),
                       "rail letter \(ordered.entries.map(\.letter)) points backwards into the list")
    }

    /// The server route carries the same invariant for free, which is the point of it.
    func testServerIndexTargetsFollowTheServersOwnOrder() {
        let list = ServerIndexedList<NavidromeArtist>(buckets: [
            .init(letter: "#", items: [NavidromeArtist(id: "0", name: "01")]),
            .init(letter: "A", items: [NavidromeArtist(id: "1", name: "ABBA")]),
            .init(letter: "Б", items: [NavidromeArtist(id: "2", name: "Браво")]),
        ])
        let ordered = AlphabetIndex.Ordered.server(list, minimum: 0)

        XCTAssertEqual(ordered.entries.map(\.letter), ["#", "A", "Б"])
        XCTAssertEqual(ordered.entries.map(\.firstID), ["0", "1", "2"])
    }

    // MARK: - The gate that hid all of it

    func testTheItemFloorIsHonouredAndOverridable() {
        let items = (0..<10).map { (id: "\($0)", name: "\(UnicodeScalar(65 + $0)!)") }

        XCTAssertTrue(AlphabetIndex.Ordered.clientSorted(items, isAlphabetical: true, minimum: 30).entries.isEmpty,
                      "ten items is below the floor")
        XCTAssertFalse(AlphabetIndex.Ordered.clientSorted(items, isAlphabetical: true, minimum: 3).entries.isEmpty,
                       "-baton.railMinimum is what lets a test see this feature at all")
    }
}

extension AlphabetIndexOrderingTests {
    /// Navidrome returns `X-Z` and a literal `[Unknown]`; a word wraps and clips in a
    /// 22pt column, so only labels short enough to fit are drawn as themselves.
    func testMultiCharacterServerBucketsStayInsideTheRail() {
        XCTAssertEqual(AlphabetIndex.Entry(letter: "A", firstID: "1").displayLetter, "A")
        XCTAssertEqual(AlphabetIndex.Entry(letter: "X-Z", firstID: "1").displayLetter, "X-Z",
                       "a range carries information and fits")
        XCTAssertEqual(AlphabetIndex.Entry(letter: "[Unknown]", firstID: "1").displayLetter, "?")
    }
}
