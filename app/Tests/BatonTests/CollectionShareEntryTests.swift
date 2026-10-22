import XCTest
@testable import Baton

/// What every Mac "Share…" on an album, a playlist or a song selection hands
/// `ShareCollectionSheet`. The songs go in display order when the view has them, else nil so
/// the sheet loads them; a selection shares only server songs and needs two of them.
@MainActor
final class CollectionShareEntryTests: XCTestCase {
    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Song \(id)", artist: "Artist", album: nil, duration: nil, coverArtID: nil)
    }

    func testAlbumFromAMenuLeavesTheTracksToTheSheet() {
        let album = NavidromeAlbum(id: "al-1", name: "Kind of Blue", artist: "Miles Davis")
        let draft = CollectionShareEntry.album(album)
        XCTAssertEqual(draft.source, .album(id: "al-1"))
        XCTAssertEqual(draft.title, "Kind of Blue")
        XCTAssertEqual(draft.artist, "Miles Davis")
        XCTAssertNil(draft.songs)
    }

    func testAlbumHeaderPassesLoadedTracksInOrderAndEmptyMeansNotLoaded() {
        let album = NavidromeAlbum(id: "al-1", name: "A", artist: nil)
        XCTAssertEqual(CollectionShareEntry.album(album, songs: [song("3"), song("1"), song("2")]).songs?.map(\.id),
                       ["3", "1", "2"])
        XCTAssertEqual(CollectionShareEntry.album(album, songs: [song("1")]).artist, "")
        XCTAssertNil(CollectionShareEntry.album(album, songs: []).songs)
    }

    func testPlaylistUsesTheShownNameAndOrder() {
        let playlist = NavidromePlaylist(id: "pl-9", name: "Old Name", songCount: 2)
        let draft = CollectionShareEntry.playlist(playlist, name: "Renamed", songs: [song("b"), song("a")])
        XCTAssertEqual(draft.source, .playlist(id: "pl-9"))
        XCTAssertEqual(draft.title, "Renamed")
        XCTAssertEqual(draft.songs?.map(\.id), ["b", "a"])
        XCTAssertEqual(CollectionShareEntry.playlist(playlist).title, "Old Name")
        XCTAssertNil(CollectionShareEntry.playlist(playlist).songs)
    }

    func testSelectionNeedsTwoServerSongsAndKeepsDisplayOrder() {
        XCTAssertNil(CollectionShareEntry.selection([]))
        XCTAssertNil(CollectionShareEntry.selection([song("a")]))
        let draft = CollectionShareEntry.selection([song("c"), song("a"), song("b")])
        XCTAssertEqual(draft?.source, .selection)
        XCTAssertEqual(draft?.title, "")
        XCTAssertEqual(draft?.songs?.map(\.id), ["c", "a", "b"])
        // Past the mixtape's 12: the composer routes it to a collection link, so no cap here.
        XCTAssertEqual(CollectionShareEntry.selection((1 ... 40).map { song("s\($0)") })?.songs?.count, 40)
    }

    func testSelectionDropsClippingsWhichHaveNoServerCopy() {
        let clipping = song("file:///Users/x/Music/Clip.m4a")
        XCTAssertTrue(clipping.isLocalOnly, "precondition: a file:// id is local-only")
        XCTAssertNil(CollectionShareEntry.selection([clipping, song("a")]))
        XCTAssertEqual(CollectionShareEntry.selection([song("a"), clipping, song("b")])?.songs?.map(\.id), ["a", "b"])
    }
}
