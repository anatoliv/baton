import XCTest
@testable import Baton

/// Covers the status-menu header clipping (`BatonMenuBarText`). NSMenu ignores SwiftUI layout on
/// menu items, so a long title has to be clipped in code or it stretches the whole menu to
/// full-screen width — this pins that logic. (menu-bar review)
final class MenuBarTextTests: XCTestCase {
    func testShortTitlePassesThrough() {
        XCTAssertEqual(BatonMenuBarText.title("So What"), "So What")
    }

    func testLongTitleIsMiddleTruncatedToCap() {
        let long = "Arabic Deep House ✨ Golden Tides Chill Flow | Oud, Violin & Handpan Relax Mix (No Vocal)"
        let clipped = BatonMenuBarText.title(long)
        XCTAssertEqual(clipped.count, BatonMenuBarText.titleMax)          // exactly the cap
        XCTAssertTrue(clipped.contains("…"))                             // middle ellipsis
        XCTAssertTrue(clipped.hasPrefix("Arabic Deep House"))            // start kept
        XCTAssertTrue(clipped.hasSuffix("(No Vocal)"))                   // end kept
    }

    func testTitleTrimsWhitespace() {
        XCTAssertEqual(BatonMenuBarText.title("   Padded   "), "Padded")
    }

    func testArtistUnknownIsDropped() {
        XCTAssertNil(BatonMenuBarText.artist("Unknown"))
        XCTAssertNil(BatonMenuBarText.artist("  unknown  "))            // case- + space-insensitive
        XCTAssertNil(BatonMenuBarText.artist(""))
        XCTAssertNil(BatonMenuBarText.artist(nil))
    }

    func testRealArtistIsKeptAndClipped() {
        XCTAssertEqual(BatonMenuBarText.artist("Miles Davis"), "Miles Davis")
        let long = String(repeating: "A", count: 60)
        let clipped = BatonMenuBarText.artist(long)!
        XCTAssertEqual(clipped.count, BatonMenuBarText.artistMax)
        XCTAssertTrue(clipped.contains("…"))
    }
}
