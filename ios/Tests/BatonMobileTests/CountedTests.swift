import XCTest
@testable import BatonMobile

/// The counted-noun phrases in every root header.
///
/// Five screens now build their subtitle from this, and the first version of those lines
/// shipped "1 albums · 1 artists" onto the Search tab. Small, and exactly the kind of
/// thing that makes an app look like nobody ever opened it.
final class CountedTests: XCTestCase {
    func testOneIsSingular() {
        XCTAssertEqual(Counted.phrase(1, "album"), "1 album")
        XCTAssertEqual(Counted.phrase(1, "artist"), "1 artist")
    }

    func testOtherCountsArePlural() {
        XCTAssertEqual(Counted.phrase(0, "album"), "0 albums")
        XCTAssertEqual(Counted.phrase(2, "album"), "2 albums")
        XCTAssertEqual(Counted.phrase(142, "playlist"), "142 playlists")
    }

    /// Not every counted word takes an "s". "2 likeds" is what the default rule produces
    /// for Library's line, so words like that must be able to say so.
    func testAWordThatDoesNotTakeAnSCanSaySo() {
        XCTAssertEqual(Counted.phrase(2, "liked", plural: "liked"), "2 liked")
        XCTAssertEqual(Counted.phrase(1, "liked", plural: "liked"), "1 liked")
    }

    // MARK: - Assembling the line

    func testEmptyPartsProduceNoLineAtAll() {
        XCTAssertNil(Counted.line([]))
        XCTAssertNil(Counted.line([nil, nil]),
                     "a header reading '0 playlists · 0 downloaded' is worse than no header line")
    }

    func testPresentPartsAreJoinedWithTheSeparator() {
        XCTAssertEqual(Counted.line(["1 album", "1 artist"]), "1 album · 1 artist")
    }

    func testAbsentPartsDoNotLeaveDanglingSeparators() {
        XCTAssertEqual(Counted.line([nil, "3 playlists", nil]), "3 playlists")
        XCTAssertEqual(Counted.line(["2 liked", nil, "4 artists"]), "2 liked · 4 artists")
    }
}
