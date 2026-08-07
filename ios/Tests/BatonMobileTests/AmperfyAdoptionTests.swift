import BatonPlaybackKit
import BatonSubsonicModels
import XCTest
@testable import BatonMobile

/// The A–Z rail's index. Letters come from the data, not a fixed alphabet.
final class AlphabetIndexTests: XCTestCase {
    func testLettersComeFromTheDataInOrder() {
        let entries = AlphabetIndex.entries(from: [
            ("1", "Abbey Road"), ("2", "Aja"), ("3", "Blue"), ("4", "Kind of Blue"),
        ])
        XCTAssertEqual(entries.map(\.letter), ["A", "B", "K"])
        XCTAssertEqual(entries.first?.firstID, "1", "the target is the FIRST item under the letter")
    }

    func testDigitsAndPunctuationPoolUnderHash() {
        XCTAssertEqual(AlphabetIndex.bucket(for: "1989"), "#")
        XCTAssertEqual(AlphabetIndex.bucket(for: "…And Justice for All"), "#")
    }

    /// "Édith" files under E — the rail must agree with the sort about where she lives.
    func testDiacriticsFoldToTheirBaseLetter() {
        XCTAssertEqual(AlphabetIndex.bucket(for: "Édith Piaf"), "E")
        XCTAssertEqual(AlphabetIndex.bucket(for: "Ólafur Arnalds"), "O")
    }

    func testEmptyNamesDoNotCrashTheBucketing() {
        XCTAssertEqual(AlphabetIndex.bucket(for: ""), "#")
        XCTAssertEqual(AlphabetIndex.bucket(for: "   "), "#")
    }
}

/// Search's memory: entities, capped, promoted on re-open.
@MainActor
final class SearchRecentsTests: XCTestCase {
    private func makeStore() -> (SearchRecents, UserDefaults) {
        let defaults = UserDefaults(suiteName: "recents.\(UUID().uuidString)")!
        return (SearchRecents(defaults: defaults), defaults)
    }

    func testOpeningAnAlbumRecordsIt() {
        let (store, _) = makeStore()
        store.record(album: NavidromeAlbum(id: "a1", name: "Aja", artist: "Steely Dan"))

        XCTAssertEqual(store.entries.first?.title, "Aja")
        XCTAssertEqual(store.entries.first?.kind, .album)
    }

    /// Re-opening promotes rather than duplicates — the list is "what I come back to".
    func testReopeningPromotesInsteadOfDuplicating() {
        let (store, _) = makeStore()
        store.record(album: NavidromeAlbum(id: "a1", name: "Aja"))
        store.record(album: NavidromeAlbum(id: "a2", name: "Blue"))
        store.record(album: NavidromeAlbum(id: "a1", name: "Aja"))

        XCTAssertEqual(store.entries.map(\.id), ["a1", "a2"])
    }

    func testTheListIsCapped() {
        let (store, _) = makeStore()
        for index in 0 ..< 20 {
            store.record(album: NavidromeAlbum(id: "a\(index)", name: "Album \(index)"))
        }
        XCTAssertEqual(store.entries.count, SearchRecents.cap)
        XCTAssertEqual(store.entries.first?.id, "a19", "newest first")
    }

    func testRecentsSurviveARelaunch() {
        let defaults = UserDefaults(suiteName: "recents.persist.\(UUID().uuidString)")!
        SearchRecents(defaults: defaults).record(artist: NavidromeArtist(id: "ar1", name: "Dido", albumCount: 3))

        let reloaded = SearchRecents(defaults: defaults)

        XCTAssertEqual(reloaded.entries.first?.title, "Dido")
        XCTAssertEqual(reloaded.entries.first?.subtitle, "3 albums")
    }

    /// The stored entry must rebuild something the detail screens can open.
    func testEntriesRebuildNavigableEntities() {
        let (store, _) = makeStore()
        store.record(album: NavidromeAlbum(id: "a1", name: "Aja", artist: "Steely Dan"))

        let album = store.album(for: store.entries[0])

        XCTAssertEqual(album?.id, "a1")
        XCTAssertNil(store.artist(for: store.entries[0]), "an album entry must not pose as an artist")
    }
}

/// The Library's editable layout.
@MainActor
final class LibraryLayoutTests: XCTestCase {
    private func makeLayout() -> (LibraryLayout, UserDefaults) {
        let defaults = UserDefaults(suiteName: "layout.\(UUID().uuidString)")!
        return (LibraryLayout(defaults: defaults), defaults)
    }

    func testTheDefaultShowsEverythingInDeclaredOrder() {
        let (layout, _) = makeLayout()
        XCTAssertEqual(layout.visible, LibrarySection.allCases)
    }

    /// The merge rule that matters: a section this build knows and the saved layout
    /// doesn't gets appended VISIBLE — otherwise every new feature ships hidden from
    /// anyone who ever touched Edit.
    func testNewSectionsAppearForPeopleWithASavedLayout() {
        let saved = ["radio", "liked"]   // an old layout, from before Folders existed
        let resolved = LibraryLayout.resolve(saved: saved)

        XCTAssertEqual(resolved.prefix(2).map(\.rawValue), ["radio", "liked"])
        XCTAssertTrue(resolved.contains(.folders), "a new section must not be lost to an old layout")
    }

    func testUnknownSavedIDsAreDroppedNotFatal() {
        let resolved = LibraryLayout.resolve(saved: ["liked", "cassettes", "radio"])
        XCTAssertFalse(resolved.map(\.rawValue).contains("cassettes"))
        XCTAssertEqual(resolved.count, LibrarySection.allCases.count)
    }

    func testHidingPersistsAcrossRelaunch() {
        let defaults = UserDefaults(suiteName: "layout.persist.\(UUID().uuidString)")!
        LibraryLayout(defaults: defaults).setVisible(.radio, false)

        let reloaded = LibraryLayout(defaults: defaults)

        XCTAssertFalse(reloaded.isVisible(.radio))
        XCTAssertFalse(reloaded.visible.contains(.radio))
    }

    /// A Library with zero rows is a blank tab with no way to understand why.
    func testTheLastSectionCannotBeHidden() {
        let (layout, _) = makeLayout()
        for section in LibrarySection.allCases {
            layout.setVisible(section, false)
        }
        XCTAssertFalse(layout.visible.isEmpty, "at least one row must always survive")
    }
}

/// Playlist ordering and the row subtitle.
final class PlaylistSortTests: XCTestCase {
    private let playlists = [
        NavidromePlaylist(id: "1", name: "Zebra", songCount: 10, duration: 100),
        NavidromePlaylist(id: "2", name: "alpha", songCount: 95, duration: 25_020),
        NavidromePlaylist(id: "3", name: "Mid", songCount: 40, duration: 9_000),
    ]

    func testNameSortIsCaseInsensitive() {
        XCTAssertEqual(PlaylistSort.name.sorted(playlists).map(\.id), ["2", "3", "1"],
                       "\"alpha\" before \"Mid\" — case must not decide the order")
    }

    func testTracksAndDurationSortBiggestFirst() {
        XCTAssertEqual(PlaylistSort.tracks.sorted(playlists).first?.id, "2")
        XCTAssertEqual(PlaylistSort.duration.sorted(playlists).first?.id, "2")
    }

    func testSubtitleCarriesTheHours() {
        XCTAssertEqual(playlistSubtitle(playlists[1]), "95 songs · 6h 57m")
        XCTAssertEqual(playlistSubtitle(NavidromePlaylist(id: "4", name: "Short", songCount: 1, duration: 300)),
                       "1 song · 5m")
    }

    func testSubtitleWithoutADurationIsJustTheCount() {
        XCTAssertEqual(playlistSubtitle(NavidromePlaylist(id: "5", name: "N", songCount: 7)), "7 songs")
    }
}


/// Play time, in the two shapes lists need.
///
/// A track and a collection want different answers to "how long" — `4:21` reads as a
/// position on a clock, `6h 57m` reads as an evening. One format for both would make
/// track lists look like spreadsheets and album totals look like timestamps.
final class PlayTimeTests: XCTestCase {
    func testATrackReadsAsAClock() {
        XCTAssertEqual(PlayTime.track(261), "4:21")
        XCTAssertEqual(PlayTime.track(9), "0:09", "seconds stay two-digit")
    }

    /// Live sets and DJ mixes pass an hour, and "94:30" is not a time anyone reads.
    func testALongTrackGrowsAnHoursField() {
        XCTAssertEqual(PlayTime.track(3870), "1:04:30")
    }

    func testACollectionReadsAsAnEvening() {
        XCTAssertEqual(PlayTime.total(25_020), "6h 57m")
        XCTAssertEqual(PlayTime.total(2_940), "49m", "under an hour drops the hours field")
    }

    /// Missing and zero are the same thing to a reader — nothing to say. Returning nil
    /// rather than "0:00" is what keeps an empty column empty instead of noisy.
    func testNothingToShowReturnsNothing() {
        XCTAssertNil(PlayTime.track(nil))
        XCTAssertNil(PlayTime.track(0))
        XCTAssertNil(PlayTime.total(nil))
        XCTAssertNil(PlayTime.total(0))
    }

    /// Negative durations are nonsense a server can still send.
    func testNegativeDurationsAreRefused() {
        XCTAssertNil(PlayTime.track(-5))
        XCTAssertNil(PlayTime.total(-5))
    }
}
