#if os(iOS) || os(macOS)
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The active server's extra headers (often a proxy's credential, such as a Cloudflare Access
/// secret or an Authorization header) go only to that server. A client-side podcast episode's id
/// is its enclosure URL on the podcast's own host, and downloading it used to carry those headers
/// to the podcast's CDN.
@MainActor
final class PodcastHeaderScopeTests: XCTestCase {
    private var folder: URL!
    private var realDefaults: UserDefaults!

    override func setUp() async throws {
        StubStream.reset()
        NavidromeKeychain.inMemoryStore = [:]
        realDefaults = NavidromeConfig.defaults
        NavidromeConfig.defaults = ThrowawayDefaults.make("podcast-header-scope")
        NavidromeConfig.addServer(displayName: "Home", urlString: "https://music.example", username: "u",
                                  secret: "p", authMode: .tokenSalt)
        NavidromeConfig.setCustomHeaders(["X-Proxy-Key": "k1"])
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-header-scope-\(UUID().uuidString)", isDirectory: true)
        BatonStorage.defaults.set(folder.path, forKey: MusicDownloadStore.folderKey)
    }

    override func tearDown() async throws {
        BatonStorage.defaults.removeObject(forKey: MusicDownloadStore.folderKey)
        NavidromeConfig.defaults = realDefaults
        NavidromeKeychain.inMemoryStore = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func store() throws -> MusicDownloadStore {
        StubStream.body = try Data(contentsOf: XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil)))
        let store = MusicDownloadStore()
        store.urlSession = StubStream.session()
        return store
    }

    func testAPodcastEpisodeOnAnotherHostIsDownloadedWithoutTheServersHeaders() async throws {
        let store = try store()
        let episode = NavidromeSong(id: "https://cdn.other.example/ep.mp3", title: "Episode", artist: "Show")
        let downloaded = await store.download(episode)
        XCTAssertTrue(downloaded)
        XCTAssertEqual(StubStream.seen.count, 1)
        XCTAssertEqual(StubStream.seen.first?.url?.host, "cdn.other.example")
        XCTAssertNil(StubStream.seen.first?.headers["X-Proxy-Key"],
                     "the music server's proxy header was sent to the podcast's host")
    }

    func testASongOnTheServerStillCarriesTheServersHeaders() async throws {
        let store = try store()
        let downloaded = await store.download(NavidromeSong(id: "song-1", title: "Song", artist: "Artist"))
        XCTAssertTrue(downloaded)
        XCTAssertEqual(StubStream.seen.first?.url?.host, "music.example")
        XCTAssertEqual(StubStream.seen.first?.headers["X-Proxy-Key"], "k1")
    }

    /// Transcription fetches a library track from the server, which behind a header-checking
    /// proxy refuses a request without the headers (C2-25).
    func testTranscriptionFetchesAServerTrackWithTheServersHeaders() async throws {
        StubStream.body = Data(count: 4096)
        StubStream.requiredHeader = ("X-Proxy-Key", "k1")
        let source = TranscriptionAudioSource.remote(URL(string: "https://music.example/rest/stream?id=song-1")!)
        let (file, isTemporary) = try await source.materialize(session: StubStream.session())
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(isTemporary)
        XCTAssertEqual(StubStream.seen.first?.headers["X-Proxy-Key"], "k1")

        StubStream.reset()
        let episode = TranscriptionAudioSource.remote(URL(string: "https://cdn.other.example/ep.mp3")!)
        let (other, _) = try await episode.materialize(session: StubStream.session())
        try? FileManager.default.removeItem(at: other)
        XCTAssertNil(StubStream.seen.first?.headers["X-Proxy-Key"])
    }

    /// The AVPlayer deck builds the gapless preload and the crossfade item for a different URL
    /// from the one it loaded. Each must carry the headers for its own URL: none for a podcast
    /// that follows a song, and the server's for a song that follows a download.
    func testTheDeckGivesEachPreloadAndCrossfadeTheHeadersForItsOwnURL() throws {
        let server = URL(string: "https://music.example/rest/stream?id=song-2&format=mp3")!
        let episode = URL(string: "https://cdn.other.example/ep.mp3")!
        let local = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil))
        let song = NavidromeSong(id: "song-1", title: "Song", artist: "Artist")
        let next = NavidromeSong(id: episode.absoluteString, title: "Episode", artist: "Show")

        let afterSong = AVPlayerDeck()
        afterSong.load(song: song, url: URL(string: "https://music.example/rest/stream?id=song-1&format=mp3")!,
                       startingAt: 0, autoplay: false, headers: ["X-Proxy-Key": "k1"], supportsTimeOffset: false)
        XCTAssertTrue(afterSong.prepareNext(song: next, at: 1, url: episode))
        XCTAssertNil(afterSong.lastAssetHeaders["X-Proxy-Key"], "the gapless preload of a podcast carried the server's header")
        afterSong.clearPreparedNext()
        afterSong.beginCrossfade(into: next, url: episode, targetIn: 1, duration: 0.01, steps: 1) {}
        XCTAssertNil(afterSong.lastAssetHeaders["X-Proxy-Key"], "the crossfade into a podcast carried the server's header")

        let afterDownload = AVPlayerDeck()
        afterDownload.load(song: song, url: local, startingAt: 0, autoplay: false, headers: [:], supportsTimeOffset: false)
        XCTAssertTrue(afterDownload.prepareNext(song: song, at: 1, url: server))
        XCTAssertEqual(afterDownload.lastAssetHeaders["X-Proxy-Key"], "k1",
                       "a server song preloaded after a download went without the server's header")
    }

    func testTheHeadersGoOnlyToTheServersSchemeHostAndPort() {
        func headers(_ raw: String) -> [String: String] { NavidromeConfig.customHeaders(for: URL(string: raw)!) }
        XCTAssertEqual(headers("https://music.example/rest/stream?id=1"), ["X-Proxy-Key": "k1"])
        XCTAssertEqual(headers("https://MUSIC.example:443/rest/stream"), ["X-Proxy-Key": "k1"], "the default port is the same origin")
        XCTAssertEqual(headers("https://music.example:8443/rest/stream"), [:], "another port")
        XCTAssertEqual(headers("http://music.example/rest/stream"), [:], "another scheme")
        XCTAssertEqual(headers("https://music.example.evil/ep.mp3"), [:], "another host")
        XCTAssertEqual(headers("https://cdn.other.example/ep.mp3"), [:])
    }
}
#endif
