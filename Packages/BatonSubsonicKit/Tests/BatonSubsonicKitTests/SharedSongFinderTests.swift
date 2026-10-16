import XCTest
@testable import BatonSubsonicKit
import BatonSubsonicModels

private actor CatalogPages {
    var calls: [(String, Int, Int)] = []
    let songs: [NavidromeSong]
    init(_ songs: [NavidromeSong]) { self.songs = songs }
    func fetch(_ query: String, _ offset: Int, _ count: Int) -> [NavidromeSong] {
        calls.append((query, offset, count))
        return Array(songs.dropFirst(offset).prefix(count))
    }
    func captured() -> [(String, Int, Int)] { calls }
}
final class SharedSongFinderTests: XCTestCase {
    private let recording = "83d9ea58-1a5b-4b02-8dc3-2955c705e326"
    private func song(_ id: String, title: String = "Song", artist: String = "Artist", recording: String? = nil) -> NavidromeSong {
        var song = NavidromeSong(id: id, title: title, artist: artist, album: "Album \(id)")
        song.musicBrainzID = recording
        return song
    }
    func testRecordingIdentityWinsEvenWhenLibraryTitleDiffers() {
        let result = SharedSongFinder.matches([
            song("same-text"), song("same-recording", title: "Other language", recording: recording.uppercased())
        ], title: "Song", artist: "Artist", recordingID: recording)
        XCTAssertEqual(result.basis, .recording)
        XCTAssertEqual(result.songs.map(\.id), ["same-recording"])
    }
    func testTitleArtistFallbackNormalizesCaseDiacriticsWhitespaceButKeepsVersions() {
        let result = SharedSongFinder.matches([
            song("copy", title: "  CAFÉ   SONG ", artist: "The Artist"),
            song("live", title: "Café Song (Live)", artist: "The Artist"),
            song("wrong-artist", title: "Café Song", artist: "Other")
        ], title: "Cafe Song", artist: "the  artist", recordingID: nil)
        XCTAssertEqual(result.songs.map(\.id), ["copy"])
        XCTAssertEqual(result.basis, .titleAndArtist)
    }
    func testDifferentKnownRecordingIsNotSilentlyChosenByTextFallback() {
        let result = SharedSongFinder.matches([
            song("different", recording: "46ee9cc6-3f8b-4d12-8b1c-9510663b7fbc"), song("untagged")
        ], title: "Song", artist: "Artist", recordingID: recording)
        XCTAssertEqual(result.songs.map(\.id), ["untagged"])
        XCTAssertTrue(SharedSongFinder.matches([song("x")], title: "Song", artist: "", recordingID: nil).songs.isEmpty)
    }
    func testCopiesRemainAmbiguousAndDeduplicatedByServerSongID() {
        let a = song("a", recording: recording), b = song("b", recording: recording)
        let result = SharedSongFinder.matches([b, a, a], title: "Song", artist: "Artist", recordingID: recording)
        XCTAssertEqual(result.songs.map(\.id), ["a", "b"], "the caller must offer both rather than auto-play")
    }
    func testBoundedPagedCatalogUsesEmptyQueryAndReportsPartialWithoutFallback() async throws {
        let catalog = CatalogPages((0..<501).map { song(String($0)) })
        let result = try await SharedSongFinder.find(title: "Song", artist: "Artist", recordingID: recording, maximumSongs: 500) {
            await catalog.fetch($0, $1, $2)
        }
        XCTAssertFalse(result.complete)
        XCTAssertTrue(result.songs.isEmpty)
        let calls = await catalog.captured()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "")
        XCTAssertEqual(calls[0].1, 0)
        XCTAssertEqual(calls[0].2, 500)
    }
    func testSecondCatalogPageContainsRecordingAndNormalSearchHasTitleArtistQuery() async throws {
        let catalog = CatalogPages((0..<500).map { song(String($0), title: "Other") } + [song("last", recording: recording)])
        let result = try await SharedSongFinder.find(title: "Song", artist: "Artist", recordingID: recording) {
            await catalog.fetch($0, $1, $2)
        }
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.songs.map(\.id), ["last"])
        let calls = await catalog.captured()
        XCTAssertEqual(calls.map { $0.1 }, [0, 500])
        let fallbackCatalog = CatalogPages([song("fallback")])
        _ = try await SharedSongFinder.find(title: "Song", artist: "Artist", recordingID: nil) {
            await fallbackCatalog.fetch($0, $1, $2)
        }
        let fallbackCalls = await fallbackCatalog.captured()
        XCTAssertEqual(fallbackCalls[0].0, "Song Artist")
    }
    func testCancellationDoesNotReturnAnIncompleteMatchAsComplete() async throws {
        let identity = recording
        let task = Task {
            try await SharedSongFinder.find(title: "Song", artist: "Artist", recordingID: identity) { _, _, _ in
                try await Task.sleep(for: .seconds(20))
                return []
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled search returned a result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testSearch3SendsOffsetAndEmptyCatalogQuery() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "songOffset" }?.value, "500")
            XCTAssertEqual(items.first { $0.name == "query" }?.value, "")
            return StubURLProtocol.ok(#""searchResult3":{"song":[]}"#, for: request)
        }
        let client = NavidromeClient(credentials: NavidromeCredentials(baseURL: URL(string: "https://music.example.invalid")!, username: "synthetic", secret: "synthetic", authMode: .tokenSalt), session: StubURLProtocol.session())
        let result = try await client.search3(query: "", songCount: 500, albumCount: 0, artistCount: 0, songOffset: 500)
        XCTAssertTrue(result.songs.isEmpty)
    }
}
