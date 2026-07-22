import XCTest
@testable import Baton

/// `Image(systemName:)` renders an empty view for a name that doesn't exist — no error, no
/// placeholder, nothing. Action icons are the one SF Symbol name a user types by hand, so a typo
/// used to mean an invisible icon with no clue why. These cover the validity/fallback logic that
/// turns that into something visible.
final class SymbolCatalogTests: XCTestCase {
    func testRecognisesRealSymbols() {
        XCTAssertTrue(SFSymbolCatalog.isValid("doc.text"))
        XCTAssertTrue(SFSymbolCatalog.isValid("bolt.horizontal.circle"))
        // Leading/trailing space is a typing artefact, not a different symbol.
        XCTAssertTrue(SFSymbolCatalog.isValid("  paperplane  "))
    }

    func testRejectsNamesThatWouldRenderNothing() {
        XCTAssertFalse(SFSymbolCatalog.isValid(""))
        XCTAssertFalse(SFSymbolCatalog.isValid("   "))
        XCTAssertFalse(SFSymbolCatalog.isValid("doc.txt"))          // plausible typo
        XCTAssertFalse(SFSymbolCatalog.isValid("not.a.real.symbol"))
    }

    /// Anywhere an action's icon is drawn must fall back rather than render blank.
    func testResolvedAlwaysYieldsADrawableName() {
        XCTAssertEqual(SFSymbolCatalog.resolved("doc.text"), "doc.text")
        XCTAssertEqual(SFSymbolCatalog.resolved("  doc.text "), "doc.text")
        XCTAssertEqual(SFSymbolCatalog.resolved(""), SFSymbolCatalog.fallback)
        XCTAssertEqual(SFSymbolCatalog.resolved("bogus.symbol"), SFSymbolCatalog.fallback)
        XCTAssertTrue(SFSymbolCatalog.isValid(SFSymbolCatalog.resolved("bogus.symbol")),
                      "the fallback itself must be drawable")
    }

    /// A curated entry that doesn't exist on this OS would be an invisible tile in the picker —
    /// the exact bug this feature exists to prevent.
    func testEveryCuratedSymbolActuallyExists() {
        for group in SFSymbolCatalog.groups {
            XCTAssertFalse(group.symbols.isEmpty, "\(group.title) is empty")
            for name in group.symbols {
                XCTAssertTrue(SFSymbolCatalog.isValid(name),
                              "curated symbol “\(name)” in \(group.title) does not exist")
            }
        }
    }

    func testSearchMatchesNameOrGroupTitle() {
        let byName = SFSymbolCatalog.search("paperplane").flatMap(\.symbols)
        XCTAssertTrue(byName.contains("paperplane"))
        XCTAssertFalse(byName.contains("music.note"), "unrelated symbols must be filtered out")

        // A group title matches even when no symbol name contains the word.
        let byGroup = SFSymbolCatalog.search("media").flatMap(\.symbols)
        XCTAssertTrue(byGroup.contains("waveform"))

        XCTAssertTrue(SFSymbolCatalog.search("zzzznope").isEmpty)
        XCTAssertEqual(SFSymbolCatalog.search("").count, SFSymbolCatalog.groups.count,
                       "an empty query shows everything")
    }
}
