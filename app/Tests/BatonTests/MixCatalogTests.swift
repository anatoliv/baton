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
