import SwiftUI
import XCTest
@testable import Baton

/// `Shared/` is compiled into both apps and is not a package, so it has no test target of its
/// own and never can have one. This group is the answer: the Mac bundle is where the shared
/// pure logic is asserted, and the iPhone bundle carries only the files whose behaviour
/// genuinely differs by platform (S-F24).
///
/// The files covered here exist *because* the two apps drifted. A test that pins the shared
/// table is the only thing that makes the sharing worth anything: without one, the table can
/// be edited on one side of a merge and the drift is back, silently.
///
/// Covers, by file: `Shared/BrowseScreen.swift`, `Shared/SongAction.swift`,
/// `Shared/RadioStationInput.swift`, `Shared/AppearanceSetting.swift`,
/// `Shared/MixCardSpec.swift`, `Shared/BottomChrome.swift`, `Shared/AccessibleChrome.swift`.
/// Named as filenames on purpose: the audit that produced this group greps each
/// `Shared/*.swift` basename across the two test directories, so a file covered under a
/// different type name reads as uncovered unless it says so here.
///
/// **Named below but NOT asserted on here.** Naming them makes the basename grep find this
/// file rather than nothing, which is the point: an auditor lands on a stated reason instead
/// of an empty result. Do not read a grep hit on one of these as coverage.
/// `Shared/KeychainLockedBanner.swift`, `Shared/NowPlayingBars.swift` and
/// `Shared/MixBackdrop.swift` are SwiftUI views with no logic to assert away from a screen
/// (`MixMeshBackdrop`'s colour derivation is already covered by `MixCatalogTests`);
/// `Shared/ContentStateView.swift` is covered by `ContentDisplayStateTests`;
/// `Shared/ArtworkCache.swift` is in `SharedArtworkCacheTests`, which is the one file wired
/// into the iPhone bundle too.
final class SharedBrowseAndActionsTests: XCTestCase {
    // MARK: - BrowseScreen

    /// Twelve of these were spelled out by hand on the Mac. A typo compiles, runs, and gives
    /// that screen its own orphan key, so the setting appears to work and forgets itself on
    /// the next launch. Written as literals here rather than derived from `rawValue`, because
    /// a test that rebuilds the key the same way the code does would agree with a rename and
    /// a rename is a silent reset for everybody who had a preference stored.
    func testTheLayoutKeysAreTheOnesAlreadyOnDisk() {
        XCTAssertEqual(BrowseScreen.album.layoutKey, "tonebox.music.albumLayout")
        XCTAssertEqual(BrowseScreen.folder.layoutKey, "tonebox.music.folderLayout")
        XCTAssertEqual(BrowseScreen.clientPodcast.layoutKey, "tonebox.music.clientPodcastLayout")
        XCTAssertEqual(BrowseScreen.history.sortKey, "tonebox.music.historySort")
        XCTAssertEqual(BrowseScreen.liked.sortAscendingKey, "tonebox.music.likedSortAscending")
    }

    func testEveryBrowseScreenHasItsOwnThreeKeys() {
        var keys: Set<String> = []
        for screen in BrowseScreen.allCases {
            for key in [screen.layoutKey, screen.sortKey, screen.sortAscendingKey] {
                XCTAssertTrue(key.hasPrefix("tonebox.music."), key)
                XCTAssertTrue(keys.insert(key).inserted, "\(key) is claimed by two screens")
            }
        }
        XCTAssertEqual(keys.count, BrowseScreen.allCases.count * 3)
    }

    /// `sortKey` is a prefix of `sortAscendingKey`, which is fine for `UserDefaults` and would
    /// not be for anything doing prefix matching. Stated so a future change to either shape
    /// has to think about it.
    func testTheSortKeysAreDistinctEvenThoughOneIsAPrefixOfTheOther() {
        XCTAssertNotEqual(BrowseScreen.mix.sortKey, BrowseScreen.mix.sortAscendingKey)
        XCTAssertTrue(BrowseScreen.mix.sortAscendingKey.hasPrefix(BrowseScreen.mix.sortKey))
    }

    // MARK: - SongAction

    /// The order is the reading order both menus follow. Every case must appear in it exactly
    /// once, or one platform quietly loses an item, which is the drift this table exists to
    /// stop.
    func testTheOrderIsEveryCaseExactlyOnce() {
        XCTAssertEqual(Set(SongAction.order), Set(SongAction.allCases))
        XCTAssertEqual(SongAction.order.count, SongAction.allCases.count)
        XCTAssertEqual(Set(SongAction.order).count, SongAction.order.count, "no case is listed twice")
    }

    /// The labels the two apps disagreed about, pinned. The ban item read "Never Play in
    /// Radio" on the phone and "Ban from Radio" on the Mac.
    func testTheLabelsThatDriftedArePinned() {
        XCTAssertEqual(SongAction.banFromRadio.label, "Never Play in Radio")
        XCTAssertEqual(SongAction.addToPlaylist.label, "Add to Playlist")
        XCTAssertEqual(SongAction.goToAlbum.label, "Go to Album")
        XCTAssertEqual(SongAction.goToArtist.label, "Go to Artist")
    }

    /// An ellipsis is a promise that something opens. `sheetLabel` is how a platform that
    /// presents a sheet makes that promise, and a platform with a submenu must not.
    func testOnlyTheSheetFormCarriesAnEllipsis() {
        XCTAssertEqual(SongAction.addToPlaylist.sheetLabel, "Add to Playlist…")
        for action in SongAction.allCases where action != .findMoreLikeThis {
            XCTAssertFalse(action.label.hasSuffix("…"), "\(action) promises a sheet in its plain label")
        }
        XCTAssertEqual(SongAction.findMoreLikeThis.label, "Find More Like This…",
                       "this one is asked of the world rather than the library and always opens a sheet")
    }

    func testEveryActionHasANonEmptyLabelAndSymbol() {
        for action in SongAction.allCases {
            XCTAssertFalse(action.label.isEmpty, "\(action)")
            XCTAssertFalse(action.symbol.isEmpty, "\(action)")
        }
    }

    /// Two menu items drawn with the same glyph read as the same thing. Like and unlike are
    /// the exception nobody would confuse, and they already differ.
    func testNoTwoActionsShareASymbol() {
        var symbols: [String: SongAction] = [:]
        for action in SongAction.allCases {
            if let other = symbols[action.symbol] {
                XCTFail("\(action) and \(other) both draw \(action.symbol)")
            }
            symbols[action.symbol] = action
        }
    }

    // MARK: - RadioStationInput

    /// The phone checked only that the two fields were non-empty, so "my station" with a
    /// stream URL of "radio" saved happily and then failed silently at play time with nothing
    /// on screen to explain it.
    func testAStationNeedsANameAndAnAbsoluteHTTPStreamURL() {
        XCTAssertTrue(RadioStationInput.isValid(name: "BBC 6", streamURL: "http://stream.example/6"))
        XCTAssertTrue(RadioStationInput.isValid(name: "BBC 6", streamURL: "https://stream.example/6"))
        XCTAssertTrue(RadioStationInput.isValid(name: " BBC 6 ", streamURL: " http://stream.example/6 "),
                      "both fields are trimmed before they are judged")
    }

    /// http as well as https, deliberately: internet radio is overwhelmingly plain-HTTP
    /// Shoutcast/Icecast, which is why the app carries an ATS media exception at all.
    func testPlainHTTPIsAllowedAndOtherSchemesAreNot() {
        XCTAssertTrue(RadioStationInput.isValid(name: "x", streamURL: "http://a.example/s"))
        for scheme in ["ftp", "file", "javascript", "baton"] {
            XCTAssertFalse(RadioStationInput.isValid(name: "x", streamURL: "\(scheme)://a.example/s"), scheme)
        }
    }

    func testTheCasesThatUsedToSaveAndThenFailSilentlyAreRefused() {
        XCTAssertFalse(RadioStationInput.isValid(name: "my station", streamURL: "radio"),
                       "a relative string is not a stream")
        XCTAssertFalse(RadioStationInput.isValid(name: "", streamURL: "http://a.example/s"))
        XCTAssertFalse(RadioStationInput.isValid(name: "   ", streamURL: "http://a.example/s"))
        XCTAssertFalse(RadioStationInput.isValid(name: "x", streamURL: ""))
        XCTAssertFalse(RadioStationInput.isValid(name: "x", streamURL: "http:///no-host"))
    }

    // MARK: - AppearanceSetting

    /// `.system` must hand back nil, because passing `.light` for system would override the
    /// very thing it is deferring to.
    func testSystemDefersRatherThanForcingALightScheme() {
        XCTAssertNil(AppearanceSetting.system.colorScheme)
        XCTAssertEqual(AppearanceSetting.light.colorScheme, .light)
        XCTAssertEqual(AppearanceSetting.dark.colorScheme, .dark)
    }

    /// The raw values are what is stored, so they are the migration surface. The key is
    /// `baton.appearance` on both apps.
    func testTheStoredShapeIsFixed() {
        XCTAssertEqual(AppearanceSetting.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(AppearanceSetting.allCases.map(\.id), ["system", "light", "dark"])
        XCTAssertEqual(AppearanceSetting.key, "baton.appearance")
        XCTAssertEqual(AppearanceSetting.allCases.map(\.label), ["System", "Light", "Dark"])
    }

    /// Dark by default, so nobody's app changes: the artwork wash is built for a dark ground.
    /// An unreadable or absent stored value falls back to it rather than to `.system`.
    func testAnUnrecognisedStoredValueFallsBackToDark() {
        XCTAssertEqual(AppearanceSetting(rawValue: "sepia"), nil)
        XCTAssertEqual(AppearanceSetting(rawValue: "") ?? .dark, .dark)
    }

    // MARK: - MixCards

    func testTheSixAutoMixCardsAreDistinctAndComplete() {
        XCTAssertEqual(MixCards.auto.count, 6)
        XCTAssertEqual(Set(MixCards.auto.map(\.id)).count, 6, "two cards share an id")
        XCTAssertEqual(Set(MixCards.auto.map(\.title)).count, 6, "two cards read the same")
        XCTAssertEqual(Set(MixCards.auto.map(\.artwork)).count, 6, "two cards draw the same art")
        for card in MixCards.auto {
            XCTAssertFalse(card.subtitle.isEmpty, card.id)
            XCTAssertFalse(card.icon.isEmpty, card.id)
            XCTAssertTrue(card.artwork.hasPrefix("MixArt"), card.artwork)
        }
    }

    /// This copy is what people read, and it was written out twice before this table existed.
    func testTheCopyThatWasWrittenTwiceIsPinned() {
        XCTAssertEqual(MixCards.card("forgotten").title, "Forgotten Favorites")
        XCTAssertEqual(MixCards.card("mostPlayed").title, "Most Played")
        XCTAssertEqual(MixCards.card("recentlyAdded").title, "Just Added")
    }

    /// An id nothing recognises returns the first card rather than nil, so a shelf never
    /// draws a hole. Worth pinning: it means a typo in a caller shows as the wrong card, not
    /// as a crash, and somebody reading this should know which way it fails.
    func testAnUnknownIDFallsBackToTheFirstCard() {
        XCTAssertEqual(MixCards.card("no-such-mix").id, MixCards.auto[0].id)
    }

    func testTheServerArtworkMapNamesRealAssetsAndNoneTwice() {
        XCTAssertFalse(MixCards.serverArtwork.isEmpty)
        for (playlist, art) in MixCards.serverArtwork {
            XCTAssertTrue(art.hasPrefix("MixArt"), "\(playlist) -> \(art)")
        }
        XCTAssertEqual(Set(MixCards.serverArtwork.values).count, MixCards.serverArtwork.count,
                       "two server playlists share a backdrop")
    }

    // MARK: - BottomChrome

    /// The mini bar used a 10pt outer inset and the composer 12pt. Two points apart is worse
    /// than either: far enough to read as misaligned, close enough to look like a mistake.
    /// One constant so a third floating element cannot introduce a third inset.
    func testTheFloatingCapsuleGeometryIsOneSetOfNumbers() {
        XCTAssertEqual(BottomChrome.inset, 20)
        XCTAssertEqual(BottomChrome.gap, 4)
        XCTAssertEqual(BottomChrome.shadowRadius, 8)
        XCTAssertEqual(BottomChrome.shadowOpacity, 0.12, accuracy: 0.0001)
    }

    // MARK: - DifferentiateWithoutColor

    /// Selection, now-playing and liked are signalled with the accent colour. Turn colour off
    /// as a channel and several of them become indistinguishable from their neutral state.
    func testAMarkerAppearsOnlyWhenColourIsNotDoingTheJob() {
        XCTAssertNil(DifferentiateWithoutColor(isOn: false).selectionMarker)
        XCTAssertEqual(DifferentiateWithoutColor(isOn: true).selectionMarker, "chevron.right")
    }
}
