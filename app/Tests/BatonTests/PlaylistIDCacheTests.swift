import XCTest
import BatonSubsonicKit
@testable import Baton

/// The name cache must pick the same playlist the uncached resolver picks: an exact name
/// first, otherwise the first playlist in server order whose name contains the query
/// (TBX-1000000480 A-9).
@MainActor
final class PlaylistIDCacheTests: XCTestCase {
    override func setUp() { PlaylistIDCache.shared.reset() }
    override func tearDown() { PlaylistIDCache.shared.reset() }

    /// Dictionary order is arbitrary, so several sets of many near matches make a lucky pass
    /// vanishingly unlikely.
    func testANearMatchTakesTheFirstInServerOrder() {
        for prefix in ["mix", "focus", "run"] {
            let pairs = (0 ..< 40).map { ("\(prefix) \($0)", "\(prefix)-\($0)") }
            PlaylistIDCache.shared.store(pairs)
            XCTAssertEqual(PlaylistIDCache.shared.id(forLoweredName: prefix), "\(prefix)-0")
        }
    }

    func testAnExactNameWinsOverAnEarlierNearMatch() {
        PlaylistIDCache.shared.store([("focus deep", "1"), ("focus", "2")])
        XCTAssertEqual(PlaylistIDCache.shared.id(forLoweredName: "focus"), "2")
    }

    func testDuplicateNamesTakeTheFirst() {
        PlaylistIDCache.shared.store([("focus", "1"), ("focus", "2")])
        XCTAssertEqual(PlaylistIDCache.shared.id(forLoweredName: "focus"), "1")
    }

    func testResetForgetsEverything() {
        PlaylistIDCache.shared.store([("focus", "1")])
        PlaylistIDCache.shared.reset()
        XCTAssertNil(PlaylistIDCache.shared.id(forLoweredName: "focus"))
    }

    /// Every create and delete, from an MCP tool (music_create_playlist, speak_mix) or the UI,
    /// reloads the library's playlists. That reload must drop the cache, or a near match cached
    /// before the create keeps winning for up to 30 seconds over the playlist just made.
    func testReloadingTheLibrarysPlaylistsDropsAStaleNearMatch() async {
        let (suiteName, suite) = ThrowawayDefaults.suite("PlaylistIDCacheTests")
        NavidromeKeychain.inMemoryStore = [:]
        NavidromeConfig.defaults = suite // no server configured: the reload fetches nothing
        defer {
            NavidromeConfig.defaults = .standard
            NavidromeKeychain.inMemoryStore = nil
            suite.removePersistentDomain(forName: suiteName)
        }
        let music = MusicModel()
        PlaylistIDCache.shared.store([("workout old", "old")])
        XCTAssertEqual(PlaylistIDCache.shared.id(forLoweredName: "workout"), "old")

        await music.musicLibrary.loadPlaylists()

        XCTAssertNil(PlaylistIDCache.shared.id(forLoweredName: "workout"),
                     "a playlist reload must not leave the pre-create near match in the cache")
    }
}
