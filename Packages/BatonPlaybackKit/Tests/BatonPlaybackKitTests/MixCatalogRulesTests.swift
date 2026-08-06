import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// The shared mix rules — the decisions the Mac and the phone must agree on. The Mac has
/// its own suite over the same logic through `MusicMixCatalog`; this covers the shared
/// implementation both now forward to, including the ordering the Mac's tests don't reach.
final class MixCatalogRulesTests: XCTestCase {
    private func song(_ id: String, artist: String?) -> NavidromeSong {
        NavidromeSong(id: id, title: "Track \(id)", artist: artist)
    }

    // MARK: - Genre usefulness

    /// A genre covering most of the library isn't a distinction — a YouTube-sourced
    /// library tags nearly everything "Music", which produced a card offering the
    /// entire library under one meaningless heading.
    func testDominantGenreIsNotUseful() {
        XCTAssertFalse(MixCatalogRules.isUsefulGenre(name: "Assorted", songCount: 3100, librarySongCount: 6149))
    }

    func testUninformativeNamesAreRejectedRegardlessOfSize() {
        XCTAssertFalse(MixCatalogRules.isUsefulGenre(name: "Music", songCount: 12, librarySongCount: 6149))
        XCTAssertFalse(MixCatalogRules.isUsefulGenre(name: "  People & Blogs ", songCount: 12, librarySongCount: 6149))
    }

    func testDistinctiveGenresSurvive() {
        XCTAssertTrue(MixCatalogRules.isUsefulGenre(name: "Trance", songCount: 800, librarySongCount: 6149))
        XCTAssertTrue(MixCatalogRules.isUsefulGenre(name: "Jazz", songCount: 22, librarySongCount: 6149))
    }

    func testEmptyGenreIsNotOffered() {
        XCTAssertFalse(MixCatalogRules.isUsefulGenre(name: "Ambient", songCount: 0, librarySongCount: 6149))
    }

    // MARK: - Symbols

    func testRelatedGenresShareASymbolWithoutAnEntryEach() {
        XCTAssertEqual(MixCatalogRules.symbol(forGenre: "Hard Trance"),
                       MixCatalogRules.symbol(forGenre: "Vocal Trance"))
    }

    func testUnknownGenreGetsANeutralSymbolRatherThanAGuess() {
        XCTAssertEqual(MixCatalogRules.symbol(forGenre: "Zzyzx"), "music.note")
    }

    // MARK: - Server-generated names

    func testGeneratedPlaylistsAreRecognisedIncludingNewFocusContexts() {
        XCTAssertTrue(MixCatalogRules.isServerGenerated("Daily Jams"))
        XCTAssertTrue(MixCatalogRules.isServerGenerated("Focus · Reading"), "new focus contexts need no code change")
    }

    /// Guessing wrong pulls someone's hand-built playlist out of the list they expect it in.
    func testHandMadePlaylistsAreLeftAlone() {
        XCTAssertFalse(MixCatalogRules.isServerGenerated("My Daily Jams"))
        XCTAssertFalse(MixCatalogRules.isServerGenerated("Fresh Additions"))
    }

    // MARK: - Artist spreading

    func testAdjacentTracksAvoidRepeatingAnArtistWhenThePoolAllows() {
        let pool = [
            song("1", artist: "A"), song("2", artist: "A"), song("3", artist: "A"),
            song("4", artist: "B"), song("5", artist: "C"),
        ]

        let spread = MixCatalogRules.spreadArtists(pool)

        XCTAssertEqual(spread.count, pool.count, "spreading must not drop tracks")
        let artists = spread.map { $0.artist ?? "" }
        for (a, b) in zip(artists, artists.dropFirst()) where a == b {
            XCTFail("\(a) played twice in a row when it didn't have to")
        }
    }

    /// An artist owning more than half the pool has to repeat somewhere — the point is
    /// that it still emits everything rather than stalling.
    func testDominantArtistStillYieldsEveryTrack() {
        let pool = [
            song("1", artist: "A"), song("2", artist: "A"), song("3", artist: "A"),
            song("4", artist: "A"), song("5", artist: "B"),
        ]

        let spread = MixCatalogRules.spreadArtists(pool)

        XCTAssertEqual(Set(spread.map(\.id)), Set(pool.map(\.id)))
    }

    func testAlreadyDiverseListIsUnchanged() {
        let pool = [song("1", artist: "A"), song("2", artist: "B"), song("3", artist: "C")]
        XCTAssertEqual(MixCatalogRules.spreadArtists(pool).map(\.id), ["1", "2", "3"])
    }

    /// Songs with no artist are unrelated to each other, so grouping them would invent a
    /// clump that isn't there — each is its own bucket.
    func testUntaggedSongsAreNotTreatedAsOneArtist() {
        let pool = [
            song("1", artist: nil), song("2", artist: nil),
            song("3", artist: nil), song("4", artist: "A"),
        ]

        let spread = MixCatalogRules.spreadArtists(pool)

        XCTAssertEqual(spread.count, 4)
        XCTAssertEqual(Set(spread.map(\.id)), Set(["1", "2", "3", "4"]))
    }

    // MARK: - Forgotten favorites

    func testForgottenFavoritesExcludesWhatWasPlayedRecently() {
        let liked = [song("1", artist: "A"), song("2", artist: "B"), song("3", artist: "C")]

        let result = MixCatalogRules.forgottenFavorites(liked: liked, recentlyPlayedIDs: ["2"])

        XCTAssertEqual(Set(result.map(\.id)), Set(["1", "3"]))
    }

    func testForgottenFavoritesIsEmptyWhenEverythingIsFresh() {
        let liked = [song("1", artist: "A"), song("2", artist: "B")]
        XCTAssertTrue(MixCatalogRules.forgottenFavorites(liked: liked, recentlyPlayedIDs: ["1", "2"]).isEmpty)
    }
}
