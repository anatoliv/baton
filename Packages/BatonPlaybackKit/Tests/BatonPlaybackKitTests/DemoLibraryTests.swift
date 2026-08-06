import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Coverage for demo mode — the bundled-library path that lets Baton run with no server
/// at all (App Review's only way in, and a first run that isn't a wall).
///
/// The rule these tests exist to protect: **in demo mode nothing may reach for a server.**
/// A demo session has no credentials, so a load that falls through to the network doesn't
/// degrade gracefully, it fails — which is exactly the empty-app impression demo mode was
/// built to prevent.
@MainActor
final class DemoLibraryTests: XCTestCase {
    private func makeStore() -> MusicLibraryStore { MusicLibraryStore() }

    private func song(_ id: String, _ title: String, album: String = "Baton Demo",
                      albumID: String = "demo-album") -> NavidromeSong {
        NavidromeSong(id: id, title: title, artist: "Tonebox", album: album,
                      albumID: albumID, duration: 60, coverArtID: "\(id)-cover")
    }

    private var demoAlbum: NavidromeAlbum {
        NavidromeAlbum(id: "demo-album", name: "Baton Demo", artist: "Tonebox", songCount: 2)
    }

    // MARK: - Seeding

    func testSeedingSwitchesToDemoAndFillsTheLibrary() {
        let store = makeStore()
        XCTAssertFalse(store.isDemo)

        store.seedDemo(songs: [song("a", "First Light"), song("b", "Static Bloom")],
                       albums: [demoAlbum])

        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.demoSongs.count, 2)
        XCTAssertEqual(store.albums.map(\.id), ["demo-album"])
    }

    /// The demo catalogue is deliberately NOT stored as "Liked" — only the subset passed
    /// as `liked` shows there, so the Liked screen means what it says.
    func testOnlyTheLikedSubsetAppearsUnderLiked() {
        let store = makeStore()
        let songs = [song("a", "First Light"), song("b", "Static Bloom")]

        store.seedDemo(songs: songs, albums: [demoAlbum], liked: [songs[0]])

        XCTAssertEqual(store.demoSongs.count, 2)
        XCTAssertEqual(store.starred.songs.map(\.id), ["a"])
    }

    func testExitingDemoClearsEverythingItSeeded() {
        let store = makeStore()
        store.seedDemo(songs: [song("a", "First Light")], albums: [demoAlbum],
                       liked: [song("a", "First Light")],
                       artwork: ["a-cover": URL(fileURLWithPath: "/tmp/a.png")])

        store.exitDemo()

        XCTAssertFalse(store.isDemo)
        XCTAssertTrue(store.demoSongs.isEmpty)
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertTrue(store.starred.songs.isEmpty)
        XCTAssertNil(store.coverArtURL(id: "a-cover"))
    }

    // MARK: - Serving the library without a server

    func testAlbumSongsComeFromTheBundleNotTheServer() async {
        let store = makeStore()
        store.seedDemo(songs: [song("a", "First Light"),
                               song("b", "Static Bloom"),
                               song("c", "Elsewhere", album: "Other", albumID: "other")],
                       albums: [demoAlbum])

        let songs = await store.albumSongs(id: "demo-album")

        XCTAssertEqual(songs.map(\.id), ["a", "b"])
    }

    func testCoverArtResolvesToTheBundledFile() {
        let store = makeStore()
        let art = URL(fileURLWithPath: "/tmp/a-cover.png")
        store.seedDemo(songs: [song("a", "First Light")], albums: [demoAlbum],
                       artwork: ["a-cover": art])

        XCTAssertEqual(store.coverArtURL(id: "a-cover", size: 400), art)
        // Unknown ids resolve to nil rather than a server URL that could never load.
        XCTAssertNil(store.coverArtURL(id: "not-in-the-bundle", size: 400))
    }

    // MARK: - Search

    func testSearchFiltersTheBundledCatalogue() async {
        let store = makeStore()
        store.seedDemo(songs: [song("a", "First Light"), song("b", "Static Bloom")],
                       albums: [demoAlbum])

        await store.search("light")

        XCTAssertEqual(store.searchResults.songs.map(\.id), ["a"])
    }

    func testSearchMatchesArtistAndAlbumNotJustTitle() async {
        let store = makeStore()
        store.seedDemo(songs: [song("a", "First Light"), song("b", "Static Bloom")],
                       albums: [demoAlbum])

        await store.search("tonebox")
        XCTAssertEqual(store.searchResults.songs.count, 2, "artist should match every demo track")

        await store.search("baton demo")
        XCTAssertEqual(store.searchResults.albums.map(\.id), ["demo-album"])
    }

    func testEmptySearchClearsRatherThanMatchingEverything() async {
        let store = makeStore()
        store.seedDemo(songs: [song("a", "First Light")], albums: [demoAlbum])

        await store.search("light")
        XCTAssertFalse(store.searchResults.songs.isEmpty)

        await store.search("   ")
        XCTAssertTrue(store.searchResults.songs.isEmpty)
    }

    func testSearchWithNoMatchesReturnsNothingWithoutError() async {
        let store = makeStore()
        store.seedDemo(songs: [song("a", "First Light")], albums: [demoAlbum])

        await store.search("bagpipes")

        XCTAssertTrue(store.searchResults.songs.isEmpty)
        XCTAssertNil(store.lastError, "a demo search must never surface a connection failure")
    }

    // MARK: - Never reaching for a server

    /// Home is the first screen after "Try the demo", and every shelf on it is fed by a
    /// discovery call. Before these guards those calls reached for a server that isn't
    /// configured, so the demo's landing page was blank.
    func testDiscoveryShelvesAreServedFromTheBundle() async {
        let store = makeStore()
        let songs = [song("a", "First Light"), song("b", "Static Bloom")]
        store.seedDemo(songs: songs, albums: [demoAlbum])

        let newest = await store.albums(type: "newest", size: 16)
        let mix = await store.mixSongs(type: "random")
        let similar = await store.similarSongs(seedID: "a")

        XCTAssertEqual(newest.map(\.id), ["demo-album"])
        XCTAssertEqual(Set(mix.map(\.id)), Set(["a", "b"]))
        XCTAssertEqual(similar.map(\.id), ["b"], "a seed can't be similar to itself")
    }

    /// Genres are derived from the bundle rather than fetched, so the Genres screen and
    /// the daily-mix cards have something to show.
    func testGenresAreDerivedFromTheBundledTracks() async {
        let store = makeStore()
        var ambient = song("a", "First Light")
        ambient.genre = "Ambient"
        ambient.genres = ["Ambient"]
        store.seedDemo(songs: [ambient], albums: [demoAlbum])

        await store.loadGenres()

        XCTAssertEqual(store.genres.map(\.name), ["Ambient"])
        XCTAssertEqual(store.genres.first?.songCount, 1)
        let byGenre = await store.songsByGenre("Ambient")
        XCTAssertEqual(byGenre.map(\.id), ["a"])
    }

    /// `loadAlbums` is called on every launch and by pull-to-refresh. In demo mode it must
    /// leave the seeded catalogue alone: falling through to the network would empty the
    /// library and report a connection error the user can do nothing about.
    func testRefreshingLoadsDoesNotWipeTheSeededLibrary() async {
        let store = makeStore()
        store.seedDemo(songs: [song("a", "First Light")], albums: [demoAlbum],
                       liked: [song("a", "First Light")])

        await store.loadAlbums()
        await store.loadStarred()
        await store.loadPlaylists()
        await store.loadArtists()

        XCTAssertEqual(store.albums.count, 1)
        XCTAssertEqual(store.starred.songs.count, 1)
        XCTAssertNil(store.lastError)
    }
}
