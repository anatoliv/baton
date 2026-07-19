import XCTest
@testable import Baton

/// Coverage for the cross-type Pin ("Later") store — toggle/dedupe, identity across kinds,
/// factories, ordering, and persistence.
@MainActor
final class PinsTests: XCTestCase {
    private func makeStore() -> (PinStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (PinStore(directory: dir), dir)
    }

    private func song(_ id: String, _ title: String = "t") -> NavidromeSong {
        NavidromeSong(id: id, title: title, artist: "artist", album: nil, duration: nil, coverArtID: "cov")
    }

    func testToggleIsIdempotentPinUnpin() {
        let (store, _) = makeStore()
        let pin = PinnedItem.song(song("s1"))
        store.toggle(pin)
        XCTAssertTrue(store.isPinned(pin.id))
        XCTAssertEqual(store.pins.count, 1)
        store.toggle(pin)                       // toggles off
        XCTAssertFalse(store.isPinned(pin.id))
        XCTAssertTrue(store.pins.isEmpty)
    }

    func testIdentityIsKindPlusRef() {
        // Same underlying id but different kinds are distinct pins; same kind+id dedupes.
        let asSong = PinnedItem.song(song("x"))
        let asAlbum = PinnedItem.album(NavidromeAlbum(id: "x", name: "X", artist: nil))
        XCTAssertNotEqual(asSong.id, asAlbum.id)
        let (store, _) = makeStore()
        store.toggle(asSong); store.toggle(asAlbum)
        XCTAssertEqual(store.pins.count, 2)
        store.toggle(PinnedItem.song(song("x", "different title")))  // same kind+ref → removes
        XCTAssertFalse(store.isPinned(asSong.id))
        XCTAssertTrue(store.isPinned(asAlbum.id))
    }

    func testFactoriesCarrySnapshot() {
        let s = PinnedItem.song(song("s1", "Song"))
        XCTAssertEqual(s.kind, .song)
        XCTAssertEqual(s.title, "Song")
        XCTAssertEqual(s.subtitle, "artist")
        XCTAssertEqual(s.coverArtID, "cov")
        // Round-trips back to a playable song (id + art preserved).
        XCTAssertEqual(s.asSong.id, "s1")
        XCTAssertEqual(s.asSong.coverArtID, "cov")

        let channel = PodcastChannel(feedURL: URL(string: "https://f/x")!, title: "Show",
                                     description: nil, imageURL: URL(string: "https://i/s.jpg"),
                                     episodes: [], lastRefreshed: nil)
        let ep = PodcastEpisode(id: "g", title: "Ep", description: nil, publishDate: nil,
                                duration: nil, enclosureURL: URL(string: "https://cdn/e.mp3")!, imageURL: nil)
        let pinned = PinnedItem.episode(ep, channel: channel)
        XCTAssertEqual(pinned.kind, .podcastEpisode)
        XCTAssertEqual(pinned.refID, "https://cdn/e.mp3")
        XCTAssertEqual(pinned.subtitle, "Show")
        XCTAssertEqual(pinned.artworkURL, URL(string: "https://i/s.jpg")) // falls back to channel art
        XCTAssertEqual(pinned.asSong.artworkURL, URL(string: "https://i/s.jpg"))
    }

    func testOrderedIsNewestFirstAndPersists() throws {
        let (store, dir) = makeStore()
        var older = PinnedItem.song(song("a")); older.pinnedAt = Date(timeIntervalSince1970: 100)
        var newer = PinnedItem.song(song("b")); newer.pinnedAt = Date(timeIntervalSince1970: 200)
        store.toggle(older); store.toggle(newer)
        XCTAssertEqual(store.ordered.map(\.refID), ["b", "a"])

        let reborn = PinStore(directory: dir)
        reborn.loadIfNeeded()
        XCTAssertEqual(Set(reborn.pins.map(\.id)), Set([older.id, newer.id]))
    }
}
