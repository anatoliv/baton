import XCTest
@testable import Baton

/// Unit coverage for the hand-rolled Navidrome/Subsonic client: auth-token
/// correctness, query signing (no plaintext password leak), response decoding,
/// and error mapping — all against a stubbed `URLProtocol`, no real network.
final class NavidromeClientTests: XCTestCase {
    override func tearDown() {
        NavidromeMockURLProtocol.handler = nil
        super.tearDown()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func creds(_ mode: NavidromeAuthMode = .tokenSalt) -> NavidromeCredentials {
        NavidromeCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "joe",
            secret: mode == .apiKey ? "KEY-123" : "sesame",
            authMode: mode
        )
    }

    // MARK: - Auth primitives (REQ-2, REQ-3)

    /// Canonical Subsonic vector: md5("sesame" + "c19b2d").
    func testTokenMatchesCanonicalVector() {
        XCTAssertEqual(
            NavidromeClient.token(password: "sesame", salt: "c19b2d"),
            "26719a1196d2a940705a59634eb18eab"
        )
    }

    func testSaltIsAtLeastSixChars() {
        for _ in 0 ..< 50 {
            XCTAssertGreaterThanOrEqual(NavidromeClient.makeSalt().count, 6)
        }
    }

    /// token+salt request carries u/t/s, and the token matches md5(password+salt)
    /// for the salt actually sent — proving the plaintext password never appears.
    func testTokenSaltQueryNeverLeaksPassword() throws {
        let client = NavidromeClient(credentials: creds(.tokenSalt), session: mockSession())
        let url = try client.makeURL("ping.view")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(byName["u"], "joe")
        let salt = try XCTUnwrap(byName["s"])
        let token = try XCTUnwrap(byName["t"])
        XCTAssertEqual(token, NavidromeClient.token(password: "sesame", salt: salt))
        XCTAssertNil(byName["apiKey"])
        // The plaintext password must appear nowhere in the URL.
        XCTAssertFalse(url.absoluteString.contains("sesame"))
    }

    ///  / NET-06: the salt is stable per client, so two URLs for the same resource are
    /// byte-identical and URLCache/AsyncImage can cache them (was a fresh salt every call).
    func testSaltIsStablePerClient() throws {
        let client = NavidromeClient(credentials: creds(.tokenSalt), session: mockSession())
        let a = try client.makeURL("getCoverArt.view", query: [URLQueryItem(name: "id", value: "art1")], json: false)
        let b = try client.makeURL("getCoverArt.view", query: [URLQueryItem(name: "id", value: "art1")], json: false)
        XCTAssertEqual(a.absoluteString, b.absoluteString, "same resource must yield an identical URL")
    }

    /// apiKey request carries apiKey and NOT u/t/s.
    func testAPIKeyQueryShape() throws {
        let client = NavidromeClient(credentials: creds(.apiKey), session: mockSession())
        let url = try client.makeURL("ping.view")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(byName["apiKey"], "KEY-123")
        XCTAssertNil(byName["t"])
        XCTAssertNil(byName["s"])
    }

    // MARK: - Stream URL is self-authenticating (REQ-5 support)

    func testStreamURLIsSignedAndCarriesID() throws {
        let client = NavidromeClient(credentials: creds(.tokenSalt), session: mockSession())
        let url = try client.streamURL(songID: "track-42")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertTrue(url.path.hasSuffix("/rest/stream.view"))
        XCTAssertEqual(byName["id"], "track-42")
        XCTAssertNotNil(byName["t"]) // signed
        XCTAssertNil(byName["f"]) // binary endpoint: no f=json
    }

    // MARK: - Decoding (REQ-4, REQ-11)

    func testSearch3DecodesSongs() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
              "song":[
                {"id":"s1","title":"So What","artist":"Miles Davis","album":"Kind of Blue","duration":545,"coverArt":"c1"},
                {"id":"s2","title":"Blue in Green","artist":"Miles Davis","album":"Kind of Blue"}
              ]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let results = try await client.search3(query: "miles")
        XCTAssertEqual(results.songs.count, 2)
        XCTAssertEqual(results.songs[0].id, "s1")
        XCTAssertEqual(results.songs[0].title, "So What")
        XCTAssertEqual(results.songs[0].duration, 545)
        XCTAssertEqual(results.songs[0].coverArtID, "c1")
        XCTAssertNil(results.songs[1].duration)
    }

    func testGetPlaylistDecodesOrderedSongs() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","playlist":{
              "id":"p1","name":"Focus","songCount":2,
              "entry":[{"id":"a","title":"One"},{"id":"b","title":"Two"}]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let playlist = try await client.getPlaylist(id: "p1")
        XCTAssertEqual(playlist.name, "Focus")
        XCTAssertEqual(playlist.songs.map(\.id), ["a", "b"])
    }

    func testGetPlaylistsMetadataOnly() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","playlists":{
              "playlist":[{"id":"p1","name":"Focus","songCount":10},{"id":"p2","name":"Chill","songCount":3}]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let playlists = try await client.getPlaylists()
        XCTAssertEqual(playlists.map(\.name), ["Focus", "Chill"])
        XCTAssertEqual(playlists[0].songCount, 10)
        XCTAssertTrue(playlists[0].songs.isEmpty)
    }

    func testGetAlbumDecodesOrderedSongs() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","album":{
              "id":"al1","name":"Kind of Blue",
              "song":[{"id":"t1","title":"So What"},{"id":"t2","title":"Freddie Freeloader"}]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let songs = try await client.getAlbum(id: "al1")
        XCTAssertEqual(songs.map(\.id), ["t1", "t2"])
    }

    /// Full request cycle in apiKey mode: the request carries apiKey (not t/s) and
    /// the response decodes.
    func testAPIKeyEndToEndRequestCycle() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = #"{"subsonic-response":{"status":"ok","searchResult3":{"song":[{"id":"s1","title":"X"}]}}}"#
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(.apiKey), session: mockSession())
        let results = try await client.search3(query: "x")
        XCTAssertEqual(results.songs.first?.id, "s1")
        let sent = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(sent.contains("apiKey=KEY-123"))
        XCTAssertFalse(sent.contains("&t="))
        XCTAssertFalse(sent.contains("&s="))
    }

    func testOpenSubsonicExtensionsDecodes() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","openSubsonicExtensions":[
              {"name":"apikeyauth","versions":[1]},{"name":"songLyrics","versions":[1]}]}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let exts = try await client.openSubsonicExtensions()
        XCTAssertEqual(Set(exts), ["apikeyauth", "songLyrics"])
    }

    // MARK: - Ratings + like state (full-player REQ-1,2)

    func testStarAndUnstarSendId() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.star(id: "song-9")
        XCTAssertTrue(try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString).contains("star.view"))
        XCTAssertTrue(try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString).contains("id=song-9"))
        try await client.unstar(id: "song-9")
        XCTAssertTrue(try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString).contains("unstar.view"))
    }

    func testSetRatingClampsAndSends() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.setRating(id: "s1", rating: 9) // clamps to 5
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("setRating.view"))
        XCTAssertTrue(url.contains("rating=5"))
    }

    func testSetPlaylistSongsOverwritesOrder() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.setPlaylistSongs(id: "pl-1", songIDs: ["b", "a", "c"], name: "My Mix")
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("createPlaylist.view"))
        XCTAssertTrue(url.contains("playlistId=pl-1"))
        XCTAssertTrue(url.contains("name=My%20Mix")) // title preserved through the overwrite
        // Order is preserved in the query (b, a, c).
        let songQuery = url.components(separatedBy: "&").filter { $0.hasPrefix("songId=") }
        XCTAssertEqual(songQuery, ["songId=b", "songId=a", "songId=c"])
    }

    func testSongDecodesLikeAndRating() async throws {
        NavidromeMockURLProtocol.handler = { req in
            let json = """
            {"subsonic-response":{"status":"ok","searchResult3":{"song":[
              {"id":"s1","title":"T","starred":"2026-01-01T00:00:00Z","userRating":4}]}}}
            """
            return navidromeOK(json, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let song = try await client.search3(query: "x").songs.first
        XCTAssertEqual(song?.isLiked, true)
        XCTAssertEqual(song?.userRating, 4)
    }

    // MARK: - Tier 2: scrobble, lyrics, similar

    func testScrobbleSendsIdAndSubmission() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.scrobble(id: "s5", submission: true)
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("scrobble.view"))
        XCTAssertTrue(url.contains("id=s5"))
        XCTAssertTrue(url.contains("submission=true"))
    }

    func testScrobbleIncludesStartTime() async throws { //  / SCR-03
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.scrobble(id: "s7", submission: true, time: 1_700_000_000_000)
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("time=1700000000000"), "scrobble must carry the real start time: \(url)")
    }

    func testGetLyricsDecodesSyncedLines() async throws {
        NavidromeMockURLProtocol.handler = { req in
            let json = """
            {"subsonic-response":{"status":"ok","lyricsList":{"structuredLyrics":[
              {"synced":true,"line":[{"start":0,"value":"Line one"},{"start":2500,"value":"Line two"}]}]}}}
            """
            return navidromeOK(json, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let lyrics = try await client.getLyrics(songID: "s1")
        XCTAssertEqual(lyrics?.synced, true)
        XCTAssertEqual(lyrics?.lines.count, 2)
        XCTAssertEqual(lyrics?.lines[1].start, 2.5) // 2500ms → 2.5s
        XCTAssertEqual(lyrics?.lines[1].text, "Line two")
    }

    func testGetLyricsNilWhenNone() async throws {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(#"{"subsonic-response":{"status":"ok","lyricsList":{"structuredLyrics":[]}}}"#, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let lyrics = try await client.getLyrics(songID: "s1")
        XCTAssertNil(lyrics)
    }

    func testGetSimilarSongsDecodes() async throws {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(
                #"{"subsonic-response":{"status":"ok","similarSongs2":{"song":[{"id":"a","title":"A"},{"id":"b","title":"B"}]}}}"#,
                req
            )
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let songs = try await client.getSimilarSongs(id: "seed")
        XCTAssertEqual(songs.map(\.id), ["a", "b"])
        XCTAssertTrue(try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
            .contains("getSimilarSongs2.view"))
    }

    // MARK: - Browse (full-player REQ-4,5)

    func testGetStarred2Decodes() async throws {
        NavidromeMockURLProtocol.handler = { req in
            let json = """
            {"subsonic-response":{"status":"ok","starred2":{
              "song":[{"id":"s1","title":"Liked"}],"album":[{"id":"al1","name":"A"}]}}}
            """
            return navidromeOK(json, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let starred = try await client.getStarred2()
        XCTAssertEqual(starred.songs.map(\.id), ["s1"])
        XCTAssertEqual(starred.albums.map(\.id), ["al1"])
    }

    func testGetAlbumList2SendsTypeAndDecodes() async throws {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(
                #"{"subsonic-response":{"status":"ok","albumList2":{"album":[{"id":"al1","name":"Top","userRating":5}]}}}"#,
                req
            )
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let albums = try await client.getAlbumList2(type: "highest")
        XCTAssertEqual(albums.first?.userRating, 5)
        XCTAssertTrue(try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString).contains("type=highest"))
    }

    func testGetArtistsFlattensIndex() async throws {
        NavidromeMockURLProtocol.handler = { req in
            let json = """
            {"subsonic-response":{"status":"ok","artists":{"index":[
              {"artist":[{"id":"a1","name":"ABBA"}]},{"artist":[{"id":"a2","name":"Basement Jaxx"}]}]}}}
            """
            return navidromeOK(json, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let artists = try await client.getArtists()
        XCTAssertEqual(artists.map(\.name), ["ABBA", "Basement Jaxx"])
    }

    // MARK: - Playlist CRUD (full-player REQ-6)

    func testCreatePlaylistReturnsPlaylist() async throws {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(
                #"{"subsonic-response":{"status":"ok","playlist":{"id":"p9","name":"New","songCount":0}}}"#,
                req
            )
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let playlist = try await client.createPlaylist(name: "New", songIDs: ["s1", "s2"])
        XCTAssertEqual(playlist.id, "p9")
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("songId=s1"))
        XCTAssertTrue(url.contains("songId=s2"))
    }

    func testUpdatePlaylistSendsRenameAndPublic() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.updatePlaylist(id: "p1", name: "Renamed", isPublic: true, songIDsToAdd: ["s3"])
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("playlistId=p1"))
        XCTAssertTrue(url.contains("name=Renamed"))
        XCTAssertTrue(url.contains("public=true"))
        XCTAssertTrue(url.contains("songIdToAdd=s3"))
    }

    func testDeletePlaylistSendsId() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.deletePlaylist(id: "p7")
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("deletePlaylist.view"))
        XCTAssertTrue(url.contains("id=p7"))
    }

    // MARK: - Error mapping (REQ-12, REQ-2)

    func testWrongCredentialsMapToUnauthorized() async {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"failed","error":{"code":40,"message":"Wrong username or password"}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        await assertThrows(client, expected: .unauthorized)
    }

    func testNotFoundMapsToSubsonicError() async {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"failed","error":{"code":70,"message":"Not found"}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        await assertThrows(client, expected: .subsonic(code: 70, message: "Not found"))
    }

    func testHTTP500MapsToHTTPError() async {
        NavidromeMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("boom".utf8))
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        await assertThrows(client, expected: .http(status: 500))
    }

    func testHTTP401MapsToUnauthorized() async { //  / NET-09 (reverse-proxy auth)
        NavidromeMockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        await assertThrows(NavidromeClient(credentials: creds(), session: mockSession()), expected: .unauthorized)
    }

    func testHTTP403MapsToUnauthorized() async {
        NavidromeMockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        await assertThrows(NavidromeClient(credentials: creds(), session: mockSession()), expected: .unauthorized)
    }

    // MARK: - notConfigured

    func testMakeClientThrowsWhenUnconfigured() {
        // No creds → makeClient throws. (verify uses ephemeral config; here we
        // just prove the guard, since UserDefaults may hold nothing in test.)
        let credentials = NavidromeConfig.credentials()
        if credentials == nil {
            XCTAssertThrowsError(try NavidromeConfig.makeClient()) { error in
                XCTAssertEqual(error as? NavidromeError, .notConfigured)
            }
        }
    }

    // MARK: - Helper

    private func assertThrows(
        _ client: NavidromeClient,
        expected: NavidromeError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.getPlaylists()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch let error as NavidromeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Threw unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - Chunked playlist reorder

    /// A large reorder must be batched — one `createPlaylist` overwrite with the first chunk, then
    /// `updatePlaylist` appends for the rest — so no single request URL overflows, and the
    /// concatenated server order equals the requested order exactly.
    func testChunkedReorderBatchesLargePlaylistPreservingOrder() async throws {
        // setPlaylistSongsChunked awaits each request before issuing the next, so the mock handler
        // is invoked serially and the await chain establishes ordering — no lock needed.
        nonisolated(unsafe) var captured: [URL] = []
        NavidromeMockURLProtocol.handler = { req in
            captured.append(req.url!)
            return navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let ids = (0 ..< 250).map { "s\($0)" }
        try await client.setPlaylistSongsChunked(id: "PL", songIDs: ids, name: "Big", chunkSize: 100)

        let urls = captured
        XCTAssertEqual(urls.count, 3, "250 ids at chunk 100 → 1 overwrite + 2 appends")

        func items(_ url: URL, _ name: String) -> [String] {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .filter { $0.name == name }.compactMap(\.value) ?? []
        }
        // First request overwrites with the first 100 ids in order.
        XCTAssertTrue(urls[0].path.contains("createPlaylist"))
        XCTAssertEqual(items(urls[0], "songId"), Array(ids[0 ..< 100]))
        // Remaining requests append the rest in order via updatePlaylist/songIdToAdd.
        XCTAssertTrue(urls[1].path.contains("updatePlaylist"))
        XCTAssertTrue(urls[2].path.contains("updatePlaylist"))
        let appended = items(urls[1], "songIdToAdd") + items(urls[2], "songIdToAdd")
        XCTAssertEqual(appended, Array(ids[100 ..< 250]))
    }
}

/// Builds a 200/JSON response for a stubbed request. Free function (not an
/// instance method) so the `@Sendable` mock handlers can call it without
/// capturing the non-Sendable `XCTestCase`.
@Sendable
func navidromeOK(_ bodyJSON: String, _ request: URLRequest) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(bodyJSON.utf8))
}

/// Handler-based `URLProtocol` stub — distinct from the shared `MockURLProtocol`
/// so tests can route by request and both stubs can coexist in the target.
final class NavidromeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    /// The URL of the most recent request — lets tests assert query signing.
    nonisolated(unsafe) static var lastRequestURL: URL?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequestURL = request.url
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
