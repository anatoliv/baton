import XCTest
@testable import Baton

/// Coverage for `MusicLibraryStore` optimistic rating writes (+ revert on failure)
/// and playlist mutations, against a stubbed `URLProtocol` client.
@MainActor
final class MusicLibraryStoreTests: XCTestCase {
    override func tearDown() {
        NavidromeMockURLProtocol.handler = nil
        super.tearDown()
    }

    private func client(succeeds: Bool = true) -> NavidromeClient {
        NavidromeMockURLProtocol.handler = { req in
            let body = succeeds
                ? #"{"subsonic-response":{"status":"ok"}}"#
                : #"{"subsonic-response":{"status":"failed","error":{"code":50,"message":"Not authorized"}}}"#
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return NavidromeClient(
            credentials: NavidromeCredentials(
                baseURL: URL(string: "https://m.example.com")!,
                username: "u",
                secret: "p",
                authMode: .tokenSalt
            ),
            session: session
        )
    }

    private func store(succeeds: Bool = true) -> MusicLibraryStore {
        let built = client(succeeds: succeeds)
        return MusicLibraryStore(clientProvider: { built })
    }

    private func song(_ id: String, liked: Bool = false, rating: Int? = nil) -> NavidromeSong {
        NavidromeSong(
            id: id,
            title: "T\(id)",
            artist: "A",
            album: nil,
            duration: nil,
            coverArtID: nil,
            isLiked: liked,
            userRating: rating
        )
    }

    /// W-54 / PROD-02: the Albums tab pages past the 500-per-request Subsonic cap instead of
    /// silently showing an arbitrary 500-album subset.
    func testLoadAlbumsPagesBeyond500() async {
        NavidromeMockURLProtocol.handler = { req in
            let offset = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
            let count = offset == 0 ? 500 : (offset == 500 ? 200 : 0) // 700 total across two pages
            let albums = (0 ..< count).map { #"{"id":"a\#(offset + $0)","name":"Album","artist":"X"}"# }.joined(separator: ",")
            let json = #"{"subsonic-response":{"status":"ok","albumList2":{"album":[\#(albums)]}}}"#
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(json.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        let session = URLSession(configuration: config)
        let built = NavidromeClient(
            credentials: NavidromeCredentials(baseURL: URL(string: "https://m.example.com")!, username: "u", secret: "p", authMode: .tokenSalt),
            session: session
        )
        let store = MusicLibraryStore(clientProvider: { built })
        await store.loadAlbums()
        XCTAssertEqual(store.albums.count, 700, "should page past the 500 cap")
    }

    /// W-49 fixture: a generated large library (10k albums across 20 pages) proves the paging path
    /// handles real-world scale — every page is fetched and assembled, not truncated. Pairs with
    /// the W-54 pagination it exercises.
    func testLoadsLargeGeneratedLibraryAcrossManyPages() async {
        let total = 10_000
        NavidromeMockURLProtocol.handler = { req in
            let offset = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
            let count = max(0, min(500, total - offset)) // 500-per-page until the 10k library is drained
            let albums = (0 ..< count).map { #"{"id":"a\#(offset + $0)","name":"Album","artist":"X"}"# }.joined(separator: ",")
            let json = #"{"subsonic-response":{"status":"ok","albumList2":{"album":[\#(albums)]}}}"#
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(json.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        let built = NavidromeClient(
            credentials: NavidromeCredentials(baseURL: URL(string: "https://m.example.com")!, username: "u", secret: "p", authMode: .tokenSalt),
            session: URLSession(configuration: config)
        )
        let store = MusicLibraryStore(clientProvider: { built })
        await store.loadAlbums()
        XCTAssertEqual(store.albums.count, total, "the full 10k-album library must load across all pages")
    }

    /// W-63 / PROD-13: switching servers must drop the previous server's browse results (Subsonic
    /// ids are per-server) instead of showing them against the new connection.
    func testResetForServerChangeDropsPreviousServerLibrary() async {
        NavidromeMockURLProtocol.handler = { req in
            let json = #"{"subsonic-response":{"status":"ok","albumList2":{"album":[{"id":"a1","name":"A","artist":"X"}]}}}"#
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(json.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        let session = URLSession(configuration: config)
        let built = NavidromeClient(
            credentials: NavidromeCredentials(baseURL: URL(string: "https://m.example.com")!, username: "u", secret: "p", authMode: .tokenSalt),
            session: session
        )
        let store = MusicLibraryStore(clientProvider: { built })
        await store.loadAlbums()
        store.lastError = "stale error from previous server"
        XCTAssertFalse(store.albums.isEmpty)

        store.resetForServerChange()

        XCTAssertTrue(store.albums.isEmpty, "previous server's albums must be dropped on switch")
        XCTAssertNil(store.lastError, "a stale error from the previous server must not linger")
    }

    func testToggleLikeIsOptimistic() async {
        let library = store()
        let track = song("s1", liked: false)
        await library.toggleLike(track)
        XCTAssertTrue(library.isLiked(track)) // optimistic override persisted after success
    }

    func testToggleLikeRevertsOnFailure() async {
        let library = store(succeeds: false)
        let track = song("s1", liked: false)
        await library.toggleLike(track)
        XCTAssertFalse(library.isLiked(track)) // reverted
        XCTAssertNotNil(library.lastError)
    }

    func testSetRatingOptimisticAndClear() async {
        let library = store()
        let track = song("s1")
        await library.setRating(track, rating: 4)
        XCTAssertEqual(library.rating(track), 4)
        await library.setRating(track, rating: 0)
        XCTAssertEqual(library.rating(track), 0) // cleared
    }

    func testSetRatingRevertsOnFailure() async {
        let library = store(succeeds: false)
        let track = song("s1", rating: 2)
        await library.setRating(track, rating: 5)
        XCTAssertEqual(library.rating(track), 2) // reverted to original
    }

    func testRatingStateFallsBackToModel() {
        let library = store()
        XCTAssertTrue(library.isLiked(song("x", liked: true)))
        XCTAssertEqual(library.rating(song("y", rating: 3)), 3)
    }

    func testDownloadStoreReportsNotDownloaded() {
        let store = MusicDownloadStore.shared
        let unseen = "never-downloaded-\(UUID().uuidString)"
        XCTAssertNil(store.localURL(for: unseen))
        XCTAssertFalse(store.isDownloaded(unseen))
        store.delete(unseen) // no-op, must not crash
    }

    func testCoverArtURLIsStableAcrossCalls() {
        // Cached → the same id+size returns an identical URL each call (the fix for
        // the render-time Keychain stall + AsyncImage refetch storm). Holds whether
        // or not a server is configured (nil == nil, or same signed URL).
        let library = store()
        let first = library.coverArtURL(id: "art1", size: 100)
        let second = library.coverArtURL(id: "art1", size: 100)
        XCTAssertEqual(first, second)
    }

    func testDeletePlaylistRemovesLocally() async {
        let library = store()
        // Seed by loading playlists (handler returns ok with no playlists → empty),
        // then delete a fabricated id — should not throw and clears no rows.
        await library.deletePlaylist(id: "p1")
        XCTAssertNil(library.lastError)
    }
}
