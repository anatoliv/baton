import XCTest
import BatonSubsonicKit
@testable import Baton

/// Coverage for the cross-device handoff endpoints (`savePlayQueue`/`getPlayQueue`),
/// bookmarks, and the `maxBitRate` stream-URL cap — the Phase 1 client additions for
/// the iPhone app (docs/plan-ios-app.md). Same stubbed-`URLProtocol` harness as
/// `NavidromeClientTests`; no real network.
final class PlayQueueBookmarkTests: XCTestCase {
    override func tearDown() {
        NavidromeMockURLProtocol.handler = nil
        super.tearDown()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func client() -> NavidromeClient {
        NavidromeClient(
            credentials: NavidromeCredentials(
                baseURL: URL(string: "https://music.example.com")!,
                username: "joe",
                secret: "sesame",
                authMode: .tokenSalt
            ),
            session: mockSession()
        )
    }

    private static func ok(_ body: String, url: URL) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(body)}}"#.utf8)
        )
    }

    // MARK: - streamURL quality cap

    func testStreamURLDefaultHasNoBitrateCap() throws {
        let url = try client().streamURL(songID: "s1")
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("format=mp3"))
        XCTAssertFalse(query.contains("maxBitRate"))
    }

    func testStreamURLAppliesMaxBitRateAndFormat() throws {
        let url = try client().streamURL(songID: "s1", maxBitRate: 128, format: "opus")
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("maxBitRate=128"))
        XCTAssertTrue(query.contains("format=opus"))
    }

    func testStreamURLIgnoresNonPositiveBitrate() throws {
        let url = try client().streamURL(songID: "s1", maxBitRate: 0)
        XCTAssertFalse(url.query?.contains("maxBitRate") ?? true)
    }

    // MARK: - savePlayQueue

    func testSavePlayQueueSendsOrderedIDsCurrentAndPosition() async throws {
        NavidromeMockURLProtocol.handler = { request in
            Self.ok("", url: request.url!)
        }
        try await client().savePlayQueue(songIDs: ["a", "b", "c"], currentID: "b", positionMs: 61_500)
        let sent = NavidromeMockURLProtocol.lastRequestURL?.absoluteString ?? ""
        XCTAssertTrue(sent.contains("savePlayQueue.view"))
        // Order matters — the receiving device rebuilds the queue from this exact sequence.
        let ids = sent.components(separatedBy: "id=").dropFirst().map { $0.prefix(1) }
        XCTAssertEqual(ids.joined(), "abc")
        XCTAssertTrue(sent.contains("current=b"))
        XCTAssertTrue(sent.contains("position=61500"))
    }

    // MARK: - getPlayQueue

    func testGetPlayQueueRoundTrip() async throws {
        NavidromeMockURLProtocol.handler = { request in
            Self.ok(#"""
            ,"playQueue":{
                "current":"b","position":61500,"changedBy":"baton-mac",
                "entry":[
                    {"id":"a","title":"First","artist":"X","duration":100},
                    {"id":"b","title":"Second","artist":"X","duration":200}
                ]
            }
            """#, url: request.url!)
        }
        let queue = try await client().getPlayQueue()
        XCTAssertEqual(queue?.songs.map(\.id), ["a", "b"])
        XCTAssertEqual(queue?.currentID, "b")
        XCTAssertEqual(queue?.positionMs, 61_500)
        XCTAssertEqual(queue?.changedBy, "baton-mac")
    }

    /// Some Subsonic servers send `current` as a number rather than the id string.
    func testGetPlayQueueDecodesNumericCurrent() async throws {
        NavidromeMockURLProtocol.handler = { request in
            Self.ok(#","playQueue":{"current":42,"position":0,"entry":[]}"#, url: request.url!)
        }
        let queue = try await client().getPlayQueue()
        XCTAssertEqual(queue?.currentID, "42")
        XCTAssertEqual(queue?.songs, [])
    }

    func testGetPlayQueueNilWhenServerHasNone() async throws {
        NavidromeMockURLProtocol.handler = { request in
            Self.ok("", url: request.url!)
        }
        let queue = try await client().getPlayQueue()
        XCTAssertNil(queue)
    }

    // MARK: - Bookmarks

    func testBookmarksRoundTrip() async throws {
        NavidromeMockURLProtocol.handler = { request in
            Self.ok(#"""
            ,"bookmarks":{"bookmark":[
                {"position":90000,"comment":"episode resume",
                 "entry":{"id":"ep1","title":"Long Episode","artist":"Show","duration":5400}}
            ]}
            """#, url: request.url!)
        }
        let bookmarks = try await client().getBookmarks()
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.song.id, "ep1")
        XCTAssertEqual(bookmarks.first?.positionMs, 90_000)
        XCTAssertEqual(bookmarks.first?.comment, "episode resume")
    }

    func testCreateBookmarkSendsPositionAndClampsNegative() async throws {
        NavidromeMockURLProtocol.handler = { request in
            Self.ok("", url: request.url!)
        }
        try await client().createBookmark(songID: "ep1", positionMs: -5)
        let sent = NavidromeMockURLProtocol.lastRequestURL?.absoluteString ?? ""
        XCTAssertTrue(sent.contains("createBookmark.view"))
        XCTAssertTrue(sent.contains("position=0"))
    }

    func testDeleteBookmarkTargetsSong() async throws {
        NavidromeMockURLProtocol.handler = { request in
            Self.ok("", url: request.url!)
        }
        try await client().deleteBookmark(songID: "ep1")
        let sent = NavidromeMockURLProtocol.lastRequestURL?.absoluteString ?? ""
        XCTAssertTrue(sent.contains("deleteBookmark.view"))
        XCTAssertTrue(sent.contains("id=ep1"))
    }
}
