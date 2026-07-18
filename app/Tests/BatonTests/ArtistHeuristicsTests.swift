import XCTest
@testable import Baton

/// Coverage for the artist-library cleanup heuristics: auto-import (junk) detection
/// and duplicate-grouping normalization.
final class ArtistHeuristicsTests: XCTestCase {
    func testAutoImportFlagsQuotedAndNumericAndUserNames() {
        XCTAssertTrue(ArtistHeuristics.isAutoImport("\" Hey Ya! \""))
        XCTAssertTrue(ArtistHeuristics.isAutoImport("“Rabbit”"))
        XCTAssertTrue(ArtistHeuristics.isAutoImport("026_Bobina And Betsie Larkin"))
        XCTAssertTrue(ArtistHeuristics.isAutoImport("040_Scooter"))
        XCTAssertTrue(ArtistHeuristics.isAutoImport("10-Faithless"))
        XCTAssertTrue(ArtistHeuristics.isAutoImport("01, E+E"))
        XCTAssertTrue(ArtistHeuristics.isAutoImport("User 959578140"))
    }

    func testAutoImportLeavesRealArtists() {
        XCTAssertFalse(ArtistHeuristics.isAutoImport("Tiësto"))
        XCTAssertFalse(ArtistHeuristics.isAutoImport("Culture Beat"))
        XCTAssertFalse(ArtistHeuristics.isAutoImport("Aly & Fila"))
        XCTAssertFalse(ArtistHeuristics.isAutoImport("2 Brothers on the 4th Floor")) // digit but not a prefix-id
    }

    func testAutoImportAlbumFlagsJunkKeepsRealAlbums() {
        // Junk: generic YT name, bare numeric names, or an auto-import artist.
        XCTAssertTrue(ArtistHeuristics.isAutoImportAlbum(name: "YT Mix", artist: "Mike Shiver vs. Fandy"))
        XCTAssertTrue(ArtistHeuristics.isAutoImportAlbum(name: "01", artist: "Foreigner"))
        XCTAssertTrue(ArtistHeuristics.isAutoImportAlbum(name: "026", artist: nil))
        XCTAssertTrue(ArtistHeuristics.isAutoImportAlbum(name: "Some Album", artist: "\"I Want to Know What Love Is\""))
        // Real albums are kept.
        XCTAssertFalse(ArtistHeuristics.isAutoImportAlbum(name: "Discovery", artist: "Daft Punk"))
        XCTAssertFalse(ArtistHeuristics.isAutoImportAlbum(name: "4", artist: "Foreigner")) // single digit real album
        XCTAssertFalse(ArtistHeuristics.isAutoImportAlbum(name: "1989", artist: "Taylor Swift"))
    }

    func testNormalizedKeyCollapsesDiacriticsCasePunctuation() {
        let key = ArtistHeuristics.normalizedKey("Tiësto")
        XCTAssertEqual(ArtistHeuristics.normalizedKey("Tiesto"), key)
        XCTAssertEqual(ArtistHeuristics.normalizedKey("TIESTO"), key)
        XCTAssertEqual(ArtistHeuristics.normalizedKey("Ti-esto"), key)
    }

    func testNormalizedKeyStripsLeadingNumericPrefix() {
        XCTAssertEqual(ArtistHeuristics.normalizedKey("040_Scooter"), ArtistHeuristics.normalizedKey("Scooter"))
    }

    func testDistinctArtistsGetDistinctKeys() {
        XCTAssertNotEqual(
            ArtistHeuristics.normalizedKey("Armin van Buuren"),
            ArtistHeuristics.normalizedKey("Above & Beyond")
        )
    }
}
