import XCTest
@testable import Baton

/// `MusicMixCatalog` classification rules — pure, no model or network.
///
/// Two real problems on a YouTube-sourced library motivated these:
///
///  * Every file is genre-tagged "Music" or "People & Blogs", so the per-genre "Daily Mix"
///    cards offered the entire 6,149-track library under one meaningless heading.
///  * A nightly generator writes real playlists (Focus · Deep, Fresh, Daily Jams), which
///    were invisible among 300+ hand-sorted playlists in the sidebar.
final class MixCatalogTests: XCTestCase {
    // MARK: - Genres that are not distinctions

    func testYouTubeCategoryTagsAreNotOfferedAsGenres() {
        XCTAssertFalse(MusicMixCatalog.isUsefulGenre(name: "Music", songCount: 5800, librarySongCount: 6149))
        XCTAssertFalse(MusicMixCatalog.isUsefulGenre(name: "People & Blogs", songCount: 300, librarySongCount: 6149))
        XCTAssertFalse(MusicMixCatalog.isUsefulGenre(name: "  entertainment ", songCount: 40, librarySongCount: 6149))
    }

    func testAGenreCoveringMostOfTheLibraryIsNotAGenre() {
        // Even under an unrecognised name: if it covers half the library it distinguishes nothing.
        XCTAssertFalse(MusicMixCatalog.isUsefulGenre(name: "Assorted", songCount: 3100, librarySongCount: 6149))
    }

    func testRealGenresSurvive() {
        XCTAssertTrue(MusicMixCatalog.isUsefulGenre(name: "Trance", songCount: 800, librarySongCount: 6149))
        XCTAssertTrue(MusicMixCatalog.isUsefulGenre(name: "Jazz", songCount: 22, librarySongCount: 6149))
    }

    func testEmptyGenresAreDropped() {
        XCTAssertFalse(MusicMixCatalog.isUsefulGenre(name: "Ambient", songCount: 0, librarySongCount: 6149))
    }

    func testAnUnknownLibrarySizeDoesNotSuppressEverything() {
        // Before genres load, total is 0 — a real genre must still be offered.
        XCTAssertTrue(MusicMixCatalog.isUsefulGenre(name: "Techno", songCount: 66, librarySongCount: 0))
    }

    // MARK: - Which playlists are generated

    func testGeneratedPlaylistsAreRecognised() {
        for name in ["Daily Jams", "Daily Discovery", "Deep Cuts", "Fresh",
                     "Focus · Deep", "Focus · Momentum", "Focus · Lift"] {
            XCTAssertTrue(MusicMixCatalog.isServerGenerated(name), "\(name) is generated")
        }
    }

    func testNewFocusContextsAppearWithoutACodeChange() {
        XCTAssertTrue(MusicMixCatalog.isServerGenerated("Focus · Reading"))
    }

    func testHandCuratedPlaylistsStayInTheSidebar() {
        // Pulling someone's curated list out of the place they expect it is worse than
        // leaving a generated one there, so the match must stay conservative.
        for name in ["02 - Classic Trance", "09 - Chillout (Pt 7)", "Liked Songs",
                     "DJ Hurley", "Skip", "Delete", "Focus"] {
            XCTAssertFalse(MusicMixCatalog.isServerGenerated(name), "\(name) is hand-made")
        }
    }

    func testMatchingIsExactNotSubstring() {
        XCTAssertFalse(MusicMixCatalog.isServerGenerated("My Daily Jams"))
        XCTAssertFalse(MusicMixCatalog.isServerGenerated("Fresh Additions"))
    }
}

/// `MixMeshBackdrop` — the procedural card artwork.
///
/// Replaced a mosaic of the tracks' own cover art, which looked like clutter on a
/// YouTube-sourced library (16:9 thumbnails with text, faces and channel watermarks) and
/// cost a library query per card just to draw a backdrop.
@MainActor
final class MixMeshBackdropTests: XCTestCase {
    func testTheSameMixAlwaysLooksTheSame() {
        // The point of seeding: a card must keep its face between launches so it becomes
        // recognisable. Swift seeds String.hashValue per process, which is exactly why the
        // PRNG here does not use it — this test would fail if someone swapped it back.
        XCTAssertEqual(MixMeshBackdrop.rng("focusdeep", salt: 3),
                       MixMeshBackdrop.rng("focusdeep", salt: 3))
        XCTAssertEqual(MixMeshBackdrop.points(seed: "server-abc"),
                       MixMeshBackdrop.points(seed: "server-abc"))
    }

    func testDifferentMixesLookDifferent() {
        XCTAssertNotEqual(MixMeshBackdrop.points(seed: "focusdeep"),
                          MixMeshBackdrop.points(seed: "focuslift"))
        XCTAssertNotEqual(MixMeshBackdrop.rng("a", salt: 1), MixMeshBackdrop.rng("b", salt: 1))
    }

    func testMeshIsTheSizeMeshGradientExpects() {
        // A mismatch between point count and width*height is a runtime crash, not a warning.
        XCTAssertEqual(MixMeshBackdrop.points(seed: "x").count, 9)
        XCTAssertEqual(MixMeshBackdrop.colors(seed: "x", tint: .blue).count, 9)
    }

    func testEdgesArePinnedSoTheCardIsAlwaysFilled() {
        // Only the centre point may drift; a floating edge would leave a pale corner exactly
        // where the title and play button sit.
        let pts = MixMeshBackdrop.points(seed: "anything")
        XCTAssertEqual(pts[0], SIMD2<Float>(0, 0))
        XCTAssertEqual(pts[2], SIMD2<Float>(1, 0))
        XCTAssertEqual(pts[6], SIMD2<Float>(0, 1))
        XCTAssertEqual(pts[8], SIMD2<Float>(1, 1))
    }

    func testInteriorPointStaysWellInsideTheCard() {
        for seed in ["a", "focusdeep", "server-xyz", "", "🎧"] {
            let centre = MixMeshBackdrop.points(seed: seed)[4]
            XCTAssertGreaterThanOrEqual(centre.x, 0.15, "seed \(seed)")
            XCTAssertLessThanOrEqual(centre.x, 0.85, "seed \(seed)")
            XCTAssertGreaterThanOrEqual(centre.y, 0.15, "seed \(seed)")
            XCTAssertLessThanOrEqual(centre.y, 0.85, "seed \(seed)")
        }
    }

    func testRandomnessIsInRange() {
        for salt in 0 ..< 40 {
            let v = MixMeshBackdrop.rng("seed", salt: salt)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 1)
        }
    }
}
