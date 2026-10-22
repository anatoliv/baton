import XCTest
@testable import BatonSubsonicKit

/// `savePlayQueue` is a GET with one `id=` per song. A long queue overflowed the 8 KB request
/// line nginx allows, the save failed, and handoff swallowed the error, so the other device was
/// offered a stale queue or nothing.
final class PlayQueueSaveTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request, _ in StubURLProtocol.ok("", for: request) }
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

    private func sentIDs() throws -> [String] {
        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.last)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.filter { $0.name == "id" }.compactMap(\.value)
    }

    /// Navidrome ids are 22 characters.
    private let queue = (0..<500).map { String(format: "song%018d", $0) }

    func testALongQueueFitsTheRequestLineAndKeepsTheCurrentSong() async throws {
        let current = queue[300]
        try await client().savePlayQueue(songIDs: queue, currentID: current, positionMs: 42_000)

        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.last)
        XCTAssertLessThan(url.absoluteString.utf8.count, 8_000, "the request line overflows nginx's 8 KB")
        let ids = try sentIDs()
        let start = try XCTUnwrap(queue.firstIndex(of: ids.first ?? ""))
        XCTAssertEqual(ids, Array(queue[start ..< start + ids.count]), "not one run of the queue, in order")
        XCTAssertTrue(ids.contains(current))
        XCTAssertGreaterThan(ids.count - (ids.firstIndex(of: current) ?? 0), 100,
                             "the songs still to come should make up most of what is kept")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "current" }?.value, current)
        XCTAssertEqual(items.first { $0.name == "position" }?.value, "42000")
    }

    func testAShortQueueIsSentWhole() async throws {
        let short = Array(queue.prefix(30))
        try await client().savePlayQueue(songIDs: short, currentID: short[29], positionMs: 0)
        XCTAssertEqual(try sentIDs(), short)
    }

    /// A song queued twice: the window centred on its first copy, far from the one playing,
    /// which could fall outside what was saved (TBX-1000000506, C-30).
    func testTheWindowCentresOnTheCopyThatIsPlaying() async throws {
        var withRepeat = queue
        let repeated = withRepeat[10]
        withRepeat[450] = repeated
        try await client().savePlayQueue(songIDs: withRepeat, currentID: repeated, positionMs: 0, currentIndex: 450)
        let ids = try sentIDs()
        let start = try XCTUnwrap(withRepeat.firstIndex(of: ids.first ?? ""))
        XCTAssertTrue((start ..< start + ids.count).contains(450), "the copy playing is outside the saved window")
    }
}
