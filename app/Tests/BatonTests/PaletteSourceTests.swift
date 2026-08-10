import XCTest
@testable import Baton

/// Every surface must extract its palette from the *same* image.
///
/// The mini player fed the extractor its 120px display thumbnail while the purpose-built
/// `paletteCoverURL` — computed three lines above, at `ArtworkColorExtractor.coverSize` —
/// went unused. So the mini player and the main window derived different accents for the
/// same track, and the app quietly disagreed with itself about what colour a song was.
///
/// A source scan rather than a behavioural test: the bug is which *URL* is handed over, and
/// that is a fact about the call site, not about anything observable at runtime without two
/// windows and a careful eye.
final class PaletteSourceTests: XCTestCase {
    /// The repo root, found rather than counted.
    ///
    /// The first version walked up a fixed number of directories and was simply wrong —
    /// off by one for the app tree and by two for `Shared/`. Counting `..` is a fact about
    /// where a file happens to sit today; searching for a landmark survives the file being
    /// moved, which is exactly what this plan has been doing to files all week.
    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 8 {
            dir.deleteLastPathComponent()
            let marker = dir.appending(path: "Shared/ArtworkPalette.swift")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
        }
        throw XCTSkip("repo root not found from \(#filePath) — running from a copied tree?")
    }

    private func source(_ file: String) throws -> String {
        let url = try repoRoot().appending(path: "app/Sources/Baton/Shell/Music/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheMiniPlayerExtractsFromTheCanonicalCoverSize() throws {
        let text = try source("MiniPlayerWindowView.swift")
        XCTAssertFalse(text.contains("paletteLoader.update(url: artworkURL)"),
                       "the mini player is deriving its accent from the 120px display thumb again")
        XCTAssertTrue(text.contains("paletteLoader.update(url: paletteCoverURL)"),
                      "expected the palette to come from paletteCoverURL")
    }

    /// The loader's cache used to be an unbounded dictionary — one palette per track, kept
    /// for the life of the process, across a 2,600-album library.
    func testThePaletteCacheIsBounded() throws {
        let text = try String(contentsOf: try repoRoot().appending(path: "Shared/ArtworkPalette.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("cacheLimit"),
                      "ArtworkPaletteLoader's cache must stay bounded")
    }
}
