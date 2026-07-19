import XCTest
@testable import Baton

/// Unit coverage for the podcast client extension: decoding `getPodcasts` /
/// `getNewestPodcasts` payloads into the domain types, episode→song mapping for
/// playback, and the "only playable episodes stream" invariant. Reuses the same
/// stubbed `URLProtocol` (`NavidromeMockURLProtocol`) as `NavidromeClientTests`.
final class PodcastTests: XCTestCase {
    override func tearDown() {
        NavidromeMockURLProtocol.handler = nil
        super.tearDown()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func creds() -> NavidromeCredentials {
        NavidromeCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "joe",
            secret: "sesame",
            authMode: .tokenSalt
        )
    }

    // MARK: - getPodcasts decoding

    func testGetPodcastsDecodesChannelsAndEpisodes() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","version":"1.16.1","podcasts":{
              "channel":[
                {"id":"c1","title":"The Daily","description":"News.","coverArt":"pc1","url":"https://feed.example/daily.xml",
                 "episode":[
                   {"id":"e1","title":"Monday","description":"Ep notes","publishDate":"2026-07-13T09:00:00.000Z","duration":1800,"streamId":"str-1","coverArt":"ce1","status":"completed"},
                   {"id":"e2","title":"Tuesday","publishDate":"2026-07-14T09:00:00.000Z","duration":1500,"status":"downloading"}
                 ]},
                {"id":"c2","title":"Empty Show"}
              ]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let channels = try await client.getPodcasts(includeEpisodes: true)

        XCTAssertEqual(channels.count, 2)
        let daily = channels[0]
        XCTAssertEqual(daily.id, "c1")
        XCTAssertEqual(daily.title, "The Daily")
        XCTAssertEqual(daily.description, "News.")
        XCTAssertEqual(daily.coverArtID, "pc1")
        XCTAssertEqual(daily.episodes.count, 2)

        // Episodes are sorted newest-first (Tuesday before Monday).
        XCTAssertEqual(daily.episodes[0].title, "Tuesday")
        XCTAssertEqual(daily.episodes[1].title, "Monday")

        let monday = daily.episodes[1]
        XCTAssertEqual(monday.streamID, "str-1")
        XCTAssertEqual(monday.duration, 1800)
        XCTAssertEqual(monday.coverArtID, "ce1")
        XCTAssertEqual(monday.status, "completed")
        XCTAssertTrue(monday.isPlayable)

        // A downloading episode has no stream id → not playable.
        let tuesday = daily.episodes[0]
        XCTAssertNil(tuesday.streamID)
        XCTAssertFalse(tuesday.isPlayable)

        // A channel with no episode array decodes to an empty list, not nil.
        XCTAssertEqual(channels[1].title, "Empty Show")
        XCTAssertTrue(channels[1].episodes.isEmpty)
    }

    /// A blank `streamId` (present but empty) must be treated as absent — those episodes
    /// aren't downloaded yet and can't stream.
    func testBlankStreamIdIsNotPlayable() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","podcasts":{"channel":[
              {"id":"c1","title":"Show","episode":[
                {"id":"e1","title":"Blank","streamId":"","status":"skipped"}
              ]}]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let episode = try await client.getPodcasts(includeEpisodes: true).first?.episodes.first
        XCTAssertNil(episode?.streamID)
        XCTAssertFalse(try XCTUnwrap(episode).isPlayable)
    }

    // MARK: - getNewestPodcasts decoding

    func testGetNewestPodcastsDecodesEpisodes() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","newestPodcasts":{"episode":[
              {"id":"e9","title":"Latest","publishDate":"2026-07-17T12:00:00.000Z","duration":600,"streamId":"str-9","status":"completed"}
            ]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let episodes = try await client.getNewestPodcasts(count: 5)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].id, "e9")
        XCTAssertEqual(episodes[0].streamID, "str-9")
        XCTAssertTrue(episodes[0].isPlayable)
    }

    /// The request must hit `getNewestPodcasts.view` with the count and be signed (`t`/`s`).
    func testGetNewestPodcastsSignsAndTargetsEndpoint() async throws {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(#"{"subsonic-response":{"status":"ok","newestPodcasts":{"episode":[]}}}"#, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        _ = try await client.getNewestPodcasts(count: 7)
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("getNewestPodcasts.view"))
        XCTAssertTrue(url.contains("count=7"))
        XCTAssertTrue(url.contains("t=") && url.contains("s="))
        XCTAssertFalse(url.contains("sesame")) // password never leaks
    }

    /// A Subsonic protocol error surfaces as `NavidromeError.subsonic` through the podcast
    /// transport, same as the shared client.
    func testPodcastSubsonicErrorMaps() async throws {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(#"{"subsonic-response":{"status":"failed","error":{"code":70,"message":"Not found"}}}"#, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        do {
            _ = try await client.getPodcasts()
            XCTFail("expected an error")
        } catch let NavidromeError.subsonic(code, _) {
            XCTAssertEqual(code, 70)
        }
    }

    // MARK: - downloadPodcastEpisode

    /// The download request must hit `downloadPodcastEpisode.view` with the *episode* id and be
    /// signed (`t`/`s`), and succeed on the empty body the server returns.
    func testDownloadPodcastEpisodeSignsAndTargetsEndpoint() async throws {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.downloadPodcastEpisode(episodeID: "e42")
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("downloadPodcastEpisode.view"))
        XCTAssertTrue(url.contains("id=e42"))
        XCTAssertTrue(url.contains("t=") && url.contains("s="))
        XCTAssertFalse(url.contains("sesame")) // password never leaks
    }

    /// A Subsonic error on download surfaces through the podcast transport.
    func testDownloadPodcastEpisodeErrorMaps() async throws {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(#"{"subsonic-response":{"status":"failed","error":{"code":70,"message":"Not found"}}}"#, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        do {
            try await client.downloadPodcastEpisode(episodeID: "nope")
            XCTFail("expected an error")
        } catch let NavidromeError.subsonic(code, _) {
            XCTAssertEqual(code, 70)
        }
    }

    /// `isDownloadingOnServer` reflects the server's status word (case-insensitively).
    func testEpisodeDownloadingStatusFlag() {
        func episode(status: String?) -> NavidromePodcastEpisode {
            NavidromePodcastEpisode(
                id: "e", title: "t", description: nil, publishDate: nil,
                duration: nil, streamID: nil, coverArtID: nil, status: status
            )
        }
        XCTAssertTrue(episode(status: "downloading").isDownloadingOnServer)
        XCTAssertTrue(episode(status: "Downloading").isDownloadingOnServer)
        XCTAssertFalse(episode(status: "new").isDownloadingOnServer)
        XCTAssertFalse(episode(status: nil).isDownloadingOnServer)
    }

    // MARK: - Episode → Song mapping (playback)

    func testEpisodeMapsToSongByStreamID() {
        let episode = NavidromePodcastEpisode(
            id: "e1", title: "Monday", description: nil, publishDate: nil,
            duration: 1800, streamID: "str-1", coverArtID: "ce1", status: "completed"
        )
        let song = episode.asSong(channelTitle: "The Daily", fallbackCoverID: "pc1")
        // The song id MUST be the stream id — that's what the player feeds to `stream`.
        XCTAssertEqual(song.id, "str-1")
        XCTAssertEqual(song.title, "Monday")
        XCTAssertEqual(song.artist, "The Daily")
        XCTAssertEqual(song.duration, 1800)
        XCTAssertEqual(song.coverArtID, "ce1")
    }

    func testEpisodeSongFallsBackToChannelCover() {
        let episode = NavidromePodcastEpisode(
            id: "e2", title: "No art", description: nil, publishDate: nil,
            duration: nil, streamID: "str-2", coverArtID: nil, status: "completed"
        )
        let song = episode.asSong(channelTitle: "Show", fallbackCoverID: "pc9")
        XCTAssertEqual(song.coverArtID, "pc9")
    }
}
