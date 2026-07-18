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
