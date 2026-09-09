import XCTest
@testable import BatonSubsonicKit
import BatonSubsonicModels

/// The transport's two promises: a read rides out a blip, a write never repeats itself, and
/// every surface maps a refused sign-in the same way.
final class NavidromeTransportTests: XCTestCase {
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

    /// Fails the first attempt with a dropped connection, succeeds on the second.
    private func failFirstThenSucceed(_ body: @escaping @Sendable () -> String) {
        StubURLProtocol.handler = { request, attempt in
            if attempt == 1 { throw URLError(.networkConnectionLost) }
            return StubURLProtocol.ok(body(), for: request)
        }
    }

    // MARK: - S-F8: retry belongs to reads only

    func testAReadRidesOutADroppedConnection() async throws {
        failFirstThenSucceed { #""album":{"id":"a1","song":[]}"# }
        let songs = try await client().getAlbum(id: "a1")
        XCTAssertEqual(StubURLProtocol.attempts, 2, "a read should try again after a transport blip")
        XCTAssertTrue(songs.isEmpty)
    }

    /// The one that was wrong. `.networkConnectionLost` and `.timedOut` fire after the server
    /// has applied a request just as readily as before, so retrying `createPlaylist` created a
    /// second playlist with the same name.
    func testCreatePlaylistIsNeverRetried() async {
        failFirstThenSucceed { #""playlist":{"id":"p1","name":"Evening"}"# }
        do {
            _ = try await client().createPlaylist(name: "Evening", songIDs: [])
            XCTFail("the write should have surfaced the transport failure, not retried it")
        } catch {
            XCTAssertEqual(StubURLProtocol.attempts, 1, "a write must be attempted exactly once")
        }
    }

    func testAddingTracksToAPlaylistIsNeverRetried() async {
        failFirstThenSucceed { "" }
        do {
            try await client().updatePlaylist(id: "p1", songIDsToAdd: ["s1", "s2"])
            XCTFail("the write should have surfaced the transport failure, not retried it")
        } catch {
            XCTAssertEqual(StubURLProtocol.attempts, 1, "appending tracks twice doubles the playlist")
        }
    }

    func testScrobbleIsNeverRetried() async {
        failFirstThenSucceed { "" }
        do {
            try await client().scrobble(id: "s1", submission: true)
            XCTFail("the write should have surfaced the transport failure, not retried it")
        } catch {
            XCTAssertEqual(StubURLProtocol.attempts, 1, "a retried scrobble counts one play as two")
        }
    }

    func testStarIsNeverRetried() async {
        failFirstThenSucceed { "" }
        do {
            try await client().star(id: "s1")
            XCTFail("the write should have surfaced the transport failure, not retried it")
        } catch {
            XCTAssertEqual(StubURLProtocol.attempts, 1)
        }
    }

    // MARK: - S-F20: the same 401 mapping everywhere

    func testPodcastsMapA401ToUnauthorized() async {
        StubURLProtocol.handler = { request, _ in (StubURLProtocol.http(401, for: request), Data()) }
        do {
            _ = try await client().getPodcasts()
            XCTFail("expected .unauthorized")
        } catch let error as NavidromeError {
            XCTAssertEqual(error, .unauthorized,
                           "the Podcasts tab used to say HTTP 401 where every other screen said to check credentials")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testPodcastsMapA403ToUnauthorized() async {
        StubURLProtocol.handler = { request, _ in (StubURLProtocol.http(403, for: request), Data()) }
        do {
            _ = try await client().getPodcasts()
            XCTFail("expected .unauthorized")
        } catch let error as NavidromeError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRadioMapsA401ToUnauthorized() async {
        StubURLProtocol.handler = { request, _ in (StubURLProtocol.http(401, for: request), Data()) }
        do {
            _ = try await client().getInternetRadioStations()
            XCTFail("expected .unauthorized")
        } catch let error as NavidromeError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testPodcastsRideOutADroppedConnection() async throws {
        failFirstThenSucceed { #""podcasts":{"channel":[]}"# }
        _ = try await client().getPodcasts()
        XCTAssertEqual(StubURLProtocol.attempts, 2, "Podcasts failed on a blip the rest of the app rode out")
    }

    func testRadioRidesOutADroppedConnection() async throws {
        failFirstThenSucceed { #""internetRadioStations":{"internetRadioStation":[]}"# }
        _ = try await client().getInternetRadioStations()
        XCTAssertEqual(StubURLProtocol.attempts, 2)
    }

    func testCreatingARadioStationIsNeverRetried() async {
        failFirstThenSucceed { "" }
        do {
            try await client().createInternetRadioStation(name: "BBC", streamUrl: "https://s.example/1")
            XCTFail("the write should have surfaced the transport failure, not retried it")
        } catch {
            XCTAssertEqual(StubURLProtocol.attempts, 1)
        }
    }

    // MARK: - S-F24 first slice: the folder trio, which had no test anywhere

    func testGetIndexesKeepsTheServersIndexLetters() async throws {
        StubURLProtocol.handler = { request, _ in
            StubURLProtocol.ok(
                #""indexes":{"index":[{"name":"A","artist":[{"id":"f1","name":"Aphex Twin"}]},"#
                    + #"{"name":"B","artist":[{"id":"f2","name":"Boards of Canada"}]}]}"#,
                for: request
            )
        }
        let index = try await client().getFolderIndex()
        XCTAssertEqual(index.buckets.map(\.letter), ["A", "B"])
        XCTAssertEqual(index.items.map(\.name), ["Aphex Twin", "Boards of Canada"])
    }

    func testGetMusicDirectorySplitsFoldersFromSongs() async throws {
        StubURLProtocol.handler = { request, _ in
            StubURLProtocol.ok(
                #""directory":{"id":"d1","name":"Selected Ambient Works","child":["#
                    + #"{"id":"d2","title":"Disc 2","isDir":true},"#
                    + #"{"id":"s1","title":"Xtal","isDir":false,"duration":293}]}"#,
                for: request
            )
        }
        let directory = try await client().getMusicDirectory(id: "d1")
        XCTAssertEqual(directory.name, "Selected Ambient Works")
        XCTAssertEqual(directory.folders.map(\.id), ["d2"])
        XCTAssertEqual(directory.songs.map(\.title), ["Xtal"])
    }

    /// It was the one endpoint in the package that fabricated a success, inventing a folder
    /// called "Folder" for a body that was not there. Its siblings throw.
    func testGetMusicDirectoryThrowsRatherThanInventingAFolder() async {
        StubURLProtocol.handler = { request, _ in StubURLProtocol.ok("", for: request) }
        do {
            let directory = try await client().getMusicDirectory(id: "d1")
            XCTFail("expected a throw, got a folder named \(directory.name)")
        } catch let error as NavidromeError {
            guard case .decoding = error else { return XCTFail("expected .decoding, got \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testASubsonicWrongPasswordMapsToUnauthorized() async {
        StubURLProtocol.handler = { request, _ in
            StubURLProtocol.subsonicError(40, "Wrong username or password", for: request)
        }
        do {
            _ = try await client().getAlbum(id: "a1")
            XCTFail("expected .unauthorized")
        } catch let error as NavidromeError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - dataWithOneRetry itself

    func testDataWithOneRetryGivesUpAfterTheSecondAttempt() async {
        StubURLProtocol.handler = { _, _ in throw URLError(.timedOut) }
        let request = URLRequest(url: URL(string: "https://music.example.com/x")!)
        do {
            _ = try await NavidromeClient.dataWithOneRetry(session: StubURLProtocol.session(), request: request)
            XCTFail("expected the second failure to surface")
        } catch {
            XCTAssertEqual(StubURLProtocol.attempts, 2, "one retry means two attempts, not a loop")
        }
    }

    func testDataWithOneRetryDoesNotRetryANonTransientError() async {
        StubURLProtocol.handler = { _, _ in throw URLError(.userAuthenticationRequired) }
        let request = URLRequest(url: URL(string: "https://music.example.com/x")!)
        do {
            _ = try await NavidromeClient.dataWithOneRetry(session: StubURLProtocol.session(), request: request)
            XCTFail("expected the failure to surface")
        } catch {
            XCTAssertEqual(StubURLProtocol.attempts, 1)
        }
    }
}
