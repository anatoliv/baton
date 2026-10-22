import XCTest
@testable import Baton
import BatonSubsonicModels
import BatonSubsonicKit

/// MCP song ids name a song without naming where it lives.
///
/// A podcast episode's id is its enclosure URL and a clipping's or demo track's is its file URL,
/// and both used to reach the agent as they were: to its model provider and, from Telegram or
/// Discord, the chat platform. That showed the Mac's folders and feed URLs, which can carry
/// tracking parameters. They now go out as `s1_` ids the server maps back.
@MainActor
final class MCPSongIDTests: XCTestCase {
    private let focus = BatonAudioFocusRegistry()
    private var savedIDs: MCPSongIDs!
    private var store: URL!

    /// A fixed key and a throwaway map file, so no test writes the owner's Keychain.
    override func setUp() async throws {
        savedIDs = MCPSongIDs.shared
        store = FileManager.default.temporaryDirectory.appending(path: "mcp-song-ids-\(UUID().uuidString).json")
        MCPSongIDs.shared = MCPSongIDs(key: Data(repeating: 7, count: 32), storeURL: store)
    }

    override func tearDown() async throws {
        MCPSongIDs.shared = savedIDs
        try? FileManager.default.removeItem(at: store)
    }
    private let enclosure = "https://feeds.example.invalid/show/episode-1.mp3?utm_source=tracker"
    private var localFile: String {
        URL(fileURLWithPath: NSHomeDirectory() + "/Music/Clippings/clip.m4a").absoluteString
    }

    // MARK: - Results

    func testQueueAndNowPlayingNameNoPathOrEnclosure() async {
        let music = model()
        for tool in ["music_get_queue", "music_now_playing"] {
            let (text, isError) = await BatonMCPToolCatalog.run(name: tool, arguments: [:], music: music, focus: focus)
            XCTAssertFalse(isError, text)
            assertNothingRevealed(text, in: tool)
        }
        let queue = await run("music_get_queue", music)
        let ids = (queue["queue"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids.first, "lib-1", "a library id is already opaque and stays as it is")
        XCTAssertTrue(ids.dropFirst().allSatisfy { $0.hasPrefix("s1_") }, "\(ids)")
    }

    func testResourcesNameNoPathOrEnclosure() {
        let music = model()
        for uri in [BatonMCPConstants.queueURI, BatonMCPConstants.nowPlayingURI] {
            let payload = BatonMCPResources.read(uri: uri, music: music)
            let text = ((payload?["contents"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            XCTAssertFalse(text.isEmpty, uri)
            assertNothingRevealed(text, in: uri)
        }
    }

    // MARK: - Inputs

    /// The id an agent was given brings back the same song, and comes back out unchanged.
    func testAnOpaqueIDResolvesToTheSong() async {
        let music = model()
        let queue = await run("music_get_queue", music)
        let rows = (queue["queue"] as? [[String: Any]]) ?? []
        guard let episode = rows.first(where: { $0["title"] as? String == "Episode One" }),
              let id = episode["id"] as? String else { return XCTFail("no episode row in \(rows)") }

        XCTAssertTrue(id.hasPrefix("s1_"), "the episode went out as \(id)")
        let answer = await run("music_transcript", music, ["song_id": id])
        XCTAssertEqual(answer["title"] as? String, "Episode One", "the id did not resolve to the queued episode")
        XCTAssertEqual(answer["song_id"] as? String, id, "the same song must keep the same id")
    }

    /// An agent that cached an id before this change still reaches the song, and is answered
    /// with the new id rather than the address again.
    func testAnOldRawIDStillWorks() async {
        let music = model()
        let answer = await run("music_transcript", music, ["song_id": enclosure])
        XCTAssertEqual(answer["title"] as? String, "Episode One")
        XCTAssertTrue((answer["song_id"] as? String)?.hasPrefix("s1_") == true, "\(answer)")
    }

    /// The id is the HMAC of the real one: the same everywhere, and different under another key.
    func testIDsAreStableAndKeyed() {
        let ids = MCPSongIDs.shared
        let first = ids.opaque(enclosure)
        XCTAssertEqual(first, ids.opaque(enclosure))
        XCTAssertTrue(first.hasPrefix("s1_"))
        XCTAssertEqual(first.count, 3 + 43, "s1_ and 32 bytes of base64url without padding")
        XCTAssertFalse(first.contains("+") || first.contains("/") || first.contains("="), first)
        XCTAssertNotEqual(first, MCPSongIDs(key: Data(repeating: 8, count: 32), storeURL: nil).opaque(enclosure))
        XCTAssertEqual(ids.opaque("lib-1"), "lib-1")
    }

    /// An id an agent kept resolves after Baton restarts: the map is on disk, and private.
    func testTheMapSurvivesARelaunch() throws {
        let token = MCPSongIDs.shared.opaque(localFile)
        _ = MCPSongIDs.shared.outgoing(#"{"id":"lib-1"}"#)   // a save point, as every call is
        let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let relaunched = MCPSongIDs(key: Data(repeating: 7, count: 32), storeURL: store)
        XCTAssertEqual(relaunched.original(token), localFile)
    }

    /// Old raw ids are counted as they arrive, so the compatibility window's use shows in the log.
    func testOldRawIDsAreNoticed() async {
        let music = model()
        _ = await run("music_transcript", music, ["song_id": localFile])
        XCTAssertEqual(MCPSongIDs.shared.rawIDUses, 1)
        _ = await run("music_transcript", music, ["song_id": "lib-1"])
        XCTAssertEqual(MCPSongIDs.shared.rawIDUses, 1, "a library id is not an old raw id")
    }

    /// An error that repeats the id the agent sent repeats the opaque one.
    func testAnErrorRepeatsTheOpaqueID() throws {
        let ids = MCPSongIDs.shared
        let token = ids.opaque(enclosure)
        let (_, resolved) = try ids.incoming(["song_ids": [token]])
        XCTAssertEqual(ids.outgoing("No song with id \(enclosure).", resolved: resolved), "No song with id \(token).")
    }

    /// The same inside a JSON result under any other key, where "/" is written "\\/".
    func testAJSONMessageRepeatsTheOpaqueID() throws {
        let ids = MCPSongIDs.shared
        let token = ids.opaque(enclosure)
        let (_, resolved) = try ids.incoming(["song_id": token])
        let text = ids.outgoing(BatonMCPToolCatalog.jsonText(["detail": "Couldn't fetch \(enclosure)"]), resolved: resolved)
        assertNothingRevealed(text, in: "detail")
        XCTAssertTrue(text.contains(token), text)
    }

    // MARK: - Review rework (REVIEW 1-4)

    /// An id the map has lost (evicted, or issued before the map file was lost) is found again
    /// among the songs at hand, because the id is the HMAC of the real one.
    func testALostIDIsFoundAgainAmongTheSongsAtHand() async {
        let music = model()
        let token = MCPSongIDs(key: Data(repeating: 7, count: 32), storeURL: nil).opaque(enclosure)
        let answer = await run("music_transcript", music, ["song_id": token])
        XCTAssertEqual(answer["title"] as? String, "Episode One", "the lost id did not resolve: \(answer)")
    }

    /// One that cannot be found says so, rather than letting the tool answer about nothing.
    func testAnUnknownIDSaysItHasExpired() async {
        let music = model()
        let (text, isError) = await BatonMCPToolCatalog.run(
            name: "music_transcript", arguments: ["song_id": "s1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
            music: music, focus: focus)
        XCTAssertTrue(isError, text)
        XCTAssertTrue(text.contains("expired") && text.contains("list again"), text)
    }

    /// One listing bigger than the map keeps every id it hands out until the reply has gone.
    func testOneLargeListingKeepsItsOwnIDs() {
        let ids = MCPSongIDs.shared
        let raws = (0 ..< 5_001).map { "https://cdn.example.invalid/episode-\($0).mp3" }
        let text = ids.outgoing(BatonMCPToolCatalog.jsonText(["queue": raws.map { ["id": $0] }]))
        let rows = ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["queue"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rows.count, 5_001)
        let first = rows.first?["id"] as? String ?? ""
        XCTAssertEqual(ids.original(first), raws[0], "the listing evicted its own first id")
    }

    /// Least recently used goes first: an id in use stays.
    func testUsingAnIDKeepsIt() {
        let ids = MCPSongIDs.shared
        let raws = (0 ..< 5_002).map { "https://cdn.example.invalid/track-\($0).mp3" }
        let tokens = raws.prefix(5_000).map(ids.opaque)
        XCTAssertEqual(ids.original(tokens[0]), raws[0])   // the agent uses the oldest one
        _ = ids.opaque(raws[5_000]); _ = ids.opaque(raws[5_001])
        _ = ids.outgoing(#"{"ok":true}"#)                   // the end of a call
        XCTAssertEqual(ids.original(tokens[0]), raws[0], "an id in use was evicted")
        XCTAssertNotEqual(ids.original(tokens[1]), raws[1], "the least recently used id should have gone")
    }

    /// Only a whole address or path is one; "/", "~" and "http://" are not, and nothing else in
    /// the result is touched because an argument happened to be one of them.
    func testOnlyAWholeAddressOrPathCounts() throws {
        let ids = MCPSongIDs.shared
        for id in ["/", "~", "http://", "https://", "file:", "//"] {
            XCTAssertEqual(ids.opaque(id), id, id)
        }
        XCTAssertTrue(ids.opaque("/Users/someone/Music/a.m4a").hasPrefix("s1_"))
        XCTAssertTrue(ids.opaque("~/Music/a.m4a").hasPrefix("s1_"))
        let result = #"{"note":"a/b ~ http://x","path":"/","song_id":"lib-1"}"#
        for id in ["/", "~", "http://"] {
            let (_, resolved) = try ids.incoming(["song_id": id])
            XCTAssertEqual(ids.outgoing(result, resolved: resolved), result, id)
        }
    }

    /// A key in the Keychain that is not a key is replaced once and kept, so ids stay the same
    /// from one launch to the next.
    func testAMalformedKeyIsRepairedOnce() {
        let saved = NavidromeKeychain.inMemoryStore
        defer { NavidromeKeychain.inMemoryStore = saved }
        NavidromeKeychain.inMemoryStore = [MCPSongIDs.keyAccount: Data("not a key".utf8)]
        let first = MCPSongIDs.live(environment: .production).opaque(enclosure)
        let second = MCPSongIDs.live(environment: .production).opaque(enclosure)
        XCTAssertEqual(first, second, "a new key at every launch")
        let stored = NavidromeKeychain.secret(account: MCPSongIDs.keyAccount).flatMap { Data(base64Encoded: $0) }
        XCTAssertEqual(stored?.count, 32)
    }

    // MARK: - Helpers

    private func assertNothingRevealed(_ text: String, in source: String, file: StaticString = #filePath, line: UInt = #line) {
        // JSONSerialization writes "/" as "\/"; read it as the agent's model does.
        let plain = text.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertFalse(plain.contains("file://"), "\(source) names a file: \(plain)", file: file, line: line)
        XCTAssertFalse(plain.contains(NSHomeDirectory()), "\(source) names a home path: \(plain)", file: file, line: line)
        XCTAssertFalse(plain.contains("feeds.example.invalid"), "\(source) names an enclosure: \(plain)", file: file, line: line)
        XCTAssertFalse(plain.contains("utm_source"), "\(source) carries a tracking parameter: \(plain)", file: file, line: line)
    }

    /// A library track, a podcast episode and a file on this Mac, queued. Nothing can play: the
    /// library id has no server behind it, so the queue sits on its first entry.
    private func model() -> MusicModel {
        let music = MusicModel()
        music.music.play([NavidromeSong(id: "lib-1", title: "Library Song", artist: "Artist", album: "Album", duration: 180)])
        music.music.enqueue([
            NavidromeSong(id: enclosure, title: "Episode One", artist: "A Show", album: nil, duration: 1800),
            NavidromeSong(id: localFile, title: "A Clipping", artist: nil, album: nil, duration: 60),
        ])
        return music
    }

    private func run(_ name: String, _ music: MusicModel, _ arguments: [String: Any] = [:]) async -> [String: Any] {
        let (text, isError) = await BatonMCPToolCatalog.run(name: name, arguments: arguments, music: music, focus: focus)
        XCTAssertFalse(isError, "\(name): \(text)")
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }
}
