import XCTest
import BatonSubsonicKit
@testable import BatonPlaybackKit

/// Search history shared between the Mac and the phone.
///
/// Two lists, deliberately different: `FilterHistory` remembers what you *typed*,
/// `SearchRecents` remembers what you *opened*. Both accumulate, and that is the whole
/// difficulty — the sync layer's default rule is last-write-wins, which is correct for a
/// scalar and destructive for a list. These tests are mostly about the one failure that
/// would be invisible in use until something you searched for was simply gone.
@MainActor
final class SearchHistorySyncTests: XCTestCase {

    // MARK: - Typed queries

    /// The bug the merge exists to prevent.
    func testMergingKeepsTermsFromBothDevices() {
        let mac = ["dido", "yello", "summer"]
        let phone = ["portishead", "dido", "massive attack"]

        let merged = FilterHistory.merge(mac, phone, cap: 15)

        for term in mac + phone {
            XCTAssertTrue(merged.contains(term), "\(term) must survive the merge")
        }
    }

    func testMergingDeduplicatesCaseInsensitively() {
        let merged = FilterHistory.merge(["Dido"], ["dido"], cap: 15)
        XCTAssertEqual(merged.count, 1, "the same query typed either way is one entry")
    }

    /// Position stands in for recency: both lists are most-recent-first, so the lower index
    /// across the two is the stronger claim.
    func testTheMostRecentlyUsedTermLeads() {
        let merged = FilterHistory.merge(["old", "dido"], ["dido", "other"], cap: 15)
        XCTAssertEqual(merged.first, "dido", "top of one list beats second place in the other")
    }

    func testMergingRespectsTheCap() {
        let merged = FilterHistory.merge(["a", "b", "c"], ["d", "e", "f"], cap: 4)
        XCTAssertEqual(merged.count, 4)
    }

    /// An unstable merge rewrites the list every sync and pushes forever. Merging a list
    /// with itself, or re-merging a result, must be a no-op.
    func testTheMergeIsStableAndIdempotent() {
        let a = ["dido", "yello", "summer"]
        let b = ["yello", "portishead"]
        let once = FilterHistory.merge(a, b, cap: 15)

        XCTAssertEqual(FilterHistory.merge(once, once, cap: 15), once, "re-merging must not churn")
        XCTAssertEqual(FilterHistory.merge(a, b, cap: 15), once, "same inputs, same output")
        XCTAssertEqual(FilterHistory.merge(once, b, cap: 15), once,
                       "a device with nothing new must not change the result")
    }

    // MARK: - Opened albums and artists

    private func entry(_ id: String, _ kind: SearchRecents.Entry.Kind = .album,
                       at date: Date, server: String? = "srv") -> SearchRecents.Entry {
        SearchRecents.Entry(kind: kind, id: id, title: id, lastOpened: date, serverID: server)
    }

    func testMergingKeepsEntitiesFromBothDevices() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mac = [entry("a", at: now), entry("b", at: now - 60)]
        let phone = [entry("c", at: now - 30)]

        let merged = SearchRecents.merge(mac, phone)

        XCTAssertEqual(Set(merged.map(\.id)), ["a", "b", "c"])
    }

    /// Unlike typed queries, entities carry a real timestamp — so the later open wins
    /// outright rather than being guessed at from list position.
    func testTheSameEntityKeepsTheLaterOpen() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = SearchRecents.Entry(kind: .album, id: "a", title: "stale",
                                        lastOpened: now - 600, serverID: "srv")
        let newer = SearchRecents.Entry(kind: .album, id: "a", title: "fresh",
                                        lastOpened: now, serverID: "srv")

        XCTAssertEqual(SearchRecents.merge([older], [newer]).first?.title, "fresh")
        XCTAssertEqual(SearchRecents.merge([newer], [older]).first?.title, "fresh",
                       "argument order must not decide it")
    }

    /// An album id and an artist id can collide; they are different entries.
    func testAnAlbumAndAnArtistWithTheSameIDStaySeparate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let merged = SearchRecents.merge([entry("x", .album, at: now)],
                                         [entry("x", .artist, at: now)])
        XCTAssertEqual(merged.count, 2)
    }

    /// The cap is per server, so a second library cannot evict the first one's list.
    func testTheCapAppliesPerServer() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = (0 ..< SearchRecents.cap).map { entry("a\($0)", at: now - Double($0), server: "one") }
        let b = (0 ..< SearchRecents.cap).map { entry("b\($0)", at: now - Double($0), server: "two") }

        let merged = SearchRecents.merge(a, b)

        XCTAssertEqual(merged.filter { $0.serverID == "one" }.count, SearchRecents.cap)
        XCTAssertEqual(merged.filter { $0.serverID == "two" }.count, SearchRecents.cap)
    }

    func testTheMergeIsIdempotentForEntities() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let once = SearchRecents.merge([entry("a", at: now)], [entry("b", at: now - 5)])
        XCTAssertEqual(SearchRecents.merge(once, once), once, "re-merging must not churn")
    }

    // MARK: - Server scoping

    /// The same server signed in the same way must fingerprint identically on both
    /// devices — the local server UUIDs are minted per device and would never match.
    func testTheFingerprintIsStableAcrossDevices() {
        let mac = SearchRecents.fingerprint(urlString: "https://music.example.com", username: "anatoli")
        let phone = SearchRecents.fingerprint(urlString: "https://music.example.com/", username: "Anatoli")
        XCTAssertEqual(mac, phone, "a trailing slash and letter case are not different servers")
    }

    func testDifferentServersFingerprintDifferently() {
        let a = SearchRecents.fingerprint(urlString: "https://one.example.com", username: "me")
        let b = SearchRecents.fingerprint(urlString: "https://two.example.com", username: "me")
        let c = SearchRecents.fingerprint(urlString: "https://one.example.com", username: "you")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c, "a different account on the same server is a different list")
    }

    /// The fingerprint travels in the shared document; the LAN hostname should not.
    func testTheFingerprintDoesNotContainTheURL() {
        let print = SearchRecents.fingerprint(urlString: "http://192.168.4.21:4533", username: "me")
        XCTAssertFalse(print.contains("192.168"))
        XCTAssertFalse(print.contains("4533"))
    }

    private func store(_ suite: String) -> UserDefaults { UserDefaults(suiteName: suite)! }

    /// The bug hand-verification caught and every test here missed.
    ///
    /// `NavidromeConfig.save` has routed sign-in through the server *list* since
    /// multi-server support landed, so `tonebox.navidrome.url` is absent on a current
    /// install. Reading only that key reported "no server configured" on a Mac plainly
    /// signed in — which scoped its history under "local" while the phone used a real
    /// fingerprint. Two devices that never share a scope never share a list: the sync
    /// runs, reports success, and moves nothing.
    func testTheFingerprintComesFromTheServerListNotTheLegacyKeys() {
        let defaults = store("fp.\(UUID().uuidString)")   // no legacy keys, as on any current install
        let entry = NavidromeServerEntry(displayName: "Home",
                                         urlString: "https://music.example.com",
                                         username: "anatoli", authMode: .tokenSalt)

        let resolved = SearchRecents.currentServerFingerprint(defaults: defaults, server: entry)

        XCTAssertEqual(resolved,
                       SearchRecents.fingerprint(urlString: "https://music.example.com",
                                                 username: "anatoli"),
                       "a configured server must produce a real fingerprint, not fall through")
        XCTAssertNotEqual(resolved, SearchRecents.unscoped)
    }

    /// Falling back is still right for an install that predates the server list.
    func testTheLegacyKeysStillWorkWhenThereIsNoServerEntry() {
        let defaults = store("fp.\(UUID().uuidString)")
        defaults.set("https://old.example.com", forKey: NavidromeConfig.urlKey)
        defaults.set("anatoli", forKey: NavidromeConfig.usernameKey)

        XCTAssertEqual(SearchRecents.currentServerFingerprint(defaults: defaults, server: nil),
                       SearchRecents.fingerprint(urlString: "https://old.example.com",
                                                 username: "anatoli"))
    }

    func testNoConfigurationMeansNoFingerprint() {
        let defaults = store("fp.\(UUID().uuidString)")
        XCTAssertNil(SearchRecents.currentServerFingerprint(defaults: defaults, server: nil))
    }

    func testOnlyTheCurrentServersEntriesAreVisible() {
        let defaults = store("recents.\(UUID().uuidString)")
        let recents = SearchRecents(defaults: defaults, serverID: "one")
        recents.record(album: .init(id: "a", name: "Here"))
        recents.setServer("two")
        recents.record(album: .init(id: "b", name: "There"))

        XCTAssertEqual(recents.entries.map(\.id), ["b"], "another library's rows would open onto errors")
        recents.setServer("one")
        XCTAssertEqual(recents.entries.map(\.id), ["a"], "and switching back restores the first")
    }

    func testClearingOnlyDiscardsTheCurrentServer() {
        let defaults = store("recents.\(UUID().uuidString)")
        let recents = SearchRecents(defaults: defaults, serverID: "one")
        recents.record(album: .init(id: "a", name: "Here"))
        recents.setServer("two")
        recents.record(album: .init(id: "b", name: "There"))

        recents.clear()

        XCTAssertTrue(recents.entries.isEmpty)
        recents.setServer("one")
        XCTAssertEqual(recents.entries.map(\.id), ["a"], "another library's list isn't yours to discard")
    }

    /// The demo library isn't a server, but its entries must still be scoped. Treating
    /// them as unscoped would give them the legacy "visible everywhere" rule, so demo
    /// albums would follow you onto a real server as rows that open onto errors.
    func testDemoEntriesDoNotFollowYouOntoARealServer() {
        let defaults = store("recents.\(UUID().uuidString)")
        let recents = SearchRecents(defaults: defaults, serverID: nil)   // no server configured
        recents.record(album: .init(id: "demo-1", name: "Demo Album"))
        XCTAssertEqual(recents.entries.map(\.id), ["demo-1"], "visible while in the demo")

        recents.setServer("a-real-server")

        XCTAssertTrue(recents.entries.isEmpty,
                      "a demo id means nothing on a real server")
    }

    /// Entries written before scoping existed have no server. Hiding them would look like
    /// data loss on upgrade.
    func testEntriesFromBeforeScopingStayVisible() {
        let defaults = store("recents.\(UUID().uuidString)")
        let legacy = SearchRecents.Entry(kind: .album, id: "old", title: "Old", serverID: nil)
        defaults.set(try! JSONEncoder().encode([legacy]), forKey: SearchRecents.storageKey)

        let recents = SearchRecents(defaults: defaults, serverID: "one")

        XCTAssertEqual(recents.entries.map(\.id), ["old"])
    }

    /// Rows written before `lastOpened` and `serverID` existed must still decode. A
    /// synthesized initializer throws on them, which empties the list silently.
    func testOldEntriesWithoutTheNewFieldsStillDecode() throws {
        let json = Data("""
        [{"kind":"album","id":"a","title":"Life for Rent","subtitle":"Dido"}]
        """.utf8)

        let decoded = try JSONDecoder().decode([SearchRecents.Entry].self, from: json)

        XCTAssertEqual(decoded.first?.title, "Life for Rent")
        XCTAssertEqual(decoded.first?.lastOpened, .distantPast, "unknown age sorts last, not first")
        XCTAssertNil(decoded.first?.serverID)
    }

    // MARK: - What the sync layer carries

    func testBothHistoriesAreCarriedAndMergedNotOverwritten() {
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(SearchRecents.storageKey))
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(FilterHistory.storageKey("search")))
        for key in FilterHistory.allKeys {
            XCTAssertTrue(PreferenceSync.mergedKeys.contains(FilterHistory.storageKey(key)),
                          "\(key) is a list — last-write-wins would drop the other device's terms")
        }
        XCTAssertTrue(PreferenceSync.mergedKeys.isSubset(of: PreferenceSync.syncedKeys),
                      "a merged key that isn't synced is merged with nothing")
    }

    /// The scalar keys must keep the last-write-wins path — merging is only for lists.
    func testOrdinarySettingsAreNotMerged() {
        XCTAssertFalse(PreferenceSync.mergedKeys.contains("tonebox.navidrome.crossfade"))
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(FilterHistory.sizeKey),
                      "how long the lists may get is itself worth carrying")
    }

    func testMergedValueUnionsTypedQueries() {
        let merged = PreferenceSync.mergedValue(
            key: FilterHistory.storageKey("search"), local: ["dido"], remote: ["yello"]
        ) as? [String]
        XCTAssertEqual(Set(merged ?? []), ["dido", "yello"])
    }

    func testMergedValueUnionsOpenedEntities() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let local = try JSONEncoder().encode([entry("a", at: now)])
        let remote = try JSONEncoder().encode([entry("b", at: now - 10)])

        let merged = PreferenceSync.mergedValue(
            key: SearchRecents.storageKey, local: local, remote: remote
        ) as? Data
        let decoded = try JSONDecoder().decode([SearchRecents.Entry].self, from: try XCTUnwrap(merged))

        XCTAssertEqual(decoded.map(\.id), ["a", "b"], "newest first, and nothing dropped")
    }

    /// Nothing on either side means nothing to write — otherwise every device pushes an
    /// empty array over the shared document on first sync.
    func testMergingTwoEmptyListsProducesNothing() {
        XCTAssertNil(PreferenceSync.mergedValue(key: FilterHistory.storageKey("search"),
                                                local: nil, remote: nil))
        XCTAssertNil(PreferenceSync.mergedValue(key: SearchRecents.storageKey,
                                                local: nil, remote: nil))
    }
}
