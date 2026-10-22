import XCTest
@testable import BatonSubsonicKit

/// A playlist rewrite in several requests is not one transaction. The
/// first request replaces the playlist with its first batch, so a later batch failing used to
/// leave the playlist cut down to that batch.
final class PlaylistRewriteRollbackTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> NavidromeClient {
        NavidromeClient(
            credentials: NavidromeCredentials(
                baseURL: URL(string: "https://music.example.com")!,
                username: "joe", secret: "sesame", authMode: .tokenSalt
            ),
            session: StubURLProtocol.session()
        )
    }

    private func ids(_ url: URL, _ name: String) -> [String] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { $0.name == name }.compactMap(\.value)
    }

    func testALaterBatchFailingPutsThePlaylistBack() async throws {
        let original = (0..<5).map { "old\($0)" }
        let entries = original.map { #"{"id":"\#($0)","title":"\#($0)"}"# }.joined(separator: ",")
        nonisolated(unsafe) var appends = 0
        StubURLProtocol.handler = { request, _ in
            let path = request.url!.path
            if path.hasSuffix("getPlaylist.view") {
                return StubURLProtocol.ok(#""playlist":{"id":"p1","name":"Mix","songCount":5,"entry":[\#(entries)]}"#, for: request)
            }
            if path.hasSuffix("updatePlaylist.view") {
                appends += 1
                if appends == 1 { return StubURLProtocol.subsonicError(0, "boom", for: request) }
            }
            return StubURLProtocol.ok("", for: request)
        }
        let wanted = (0..<7).map { "new\($0)" }
        do {
            try await client().setPlaylistSongsChunked(id: "p1", songIDs: wanted, name: "Mix", chunkSize: 3)
            XCTFail("the failure was not reported")
        } catch {}

        let writes = StubURLProtocol.requestedURLs.filter { $0.path.hasSuffix("createPlaylist.view") || $0.path.hasSuffix("updatePlaylist.view") }
        // The overwrite with the first batch, the failed append, then the old songs written back.
        let lastOverwrite = try XCTUnwrap(writes.last { $0.path.hasSuffix("createPlaylist.view") })
        let restoredStart = try XCTUnwrap(writes.lastIndex(of: lastOverwrite))
        var restored = ids(lastOverwrite, "songId")
        for append in writes[(restoredStart + 1)...] { restored += ids(append, "songIdToAdd") }
        XCTAssertEqual(restored, original, "the playlist was left cut down to the first batch")
    }

    func testOneRequestRewritesWithoutReadingFirst() async throws {
        StubURLProtocol.handler = { request, _ in StubURLProtocol.ok("", for: request) }
        try await client().setPlaylistSongsChunked(id: "p1", songIDs: ["a", "b"], name: "Mix", chunkSize: 3)
        XCTAssertEqual(StubURLProtocol.requestedURLs.map(\.lastPathComponent), ["createPlaylist.view"])
    }
}
