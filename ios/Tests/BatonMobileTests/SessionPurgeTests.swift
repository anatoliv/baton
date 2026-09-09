import XCTest
import BatonSubsonicKit
@testable import BatonMobile

/// What must be gone after a session ends.
///
/// These exist because the failure they guard against is invisible: `disconnect()` looked
/// complete for months while leaving a previous account's downloads playable and its
/// unsent listens queued to fire into whichever scrobble account came next. A leak like
/// that produces no error and no crash — only a test that names each store can catch it.
@MainActor
final class SessionPurgeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "baton.purge.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - The preview the confirmation is built from

    func testPreviewReportsNothingWhenThereAreNoDownloads() {
        let preview = SessionPurge.Preview(downloadCount: 0, downloadBytes: 0, historyCount: 0)
        XCTAssertNil(preview.downloadSummary, "no downloads means no scary sentence")
        XCTAssertFalse(preview.hasDownloads)
    }

    /// The confirmation names the size because "delete downloads" and "delete 4.2 GB" are
    /// different decisions.
    func testPreviewSummarySpellsOutCountAndSize() {
        let preview = SessionPurge.Preview(downloadCount: 12, downloadBytes: 86_000_000, historyCount: 3)
        guard let summary = preview.downloadSummary else { return XCTFail("expected a summary") }
        XCTAssertTrue(summary.contains("12 downloads"), "got \(summary)")
        XCTAssertTrue(summary.contains("MB"), "size should be human-readable, got \(summary)")
    }

    func testPreviewUsesSingularForOneDownload() {
        let preview = SessionPurge.Preview(downloadCount: 1, downloadBytes: 5_000_000, historyCount: 0)
        XCTAssertTrue(preview.downloadSummary?.contains("1 download (") == true)
        XCTAssertFalse(preview.downloadSummary?.contains("downloads") == true)
    }

    // MARK: - The phase must describe reality, not call order

    /// `showsSetup = false` followed by `endDemo()` used to leave `phase == .demo` on a
    /// device that had just connected to a real server, because the setter read
    /// `isDemoMode` before `endDemo()` cleared it. Latent — only the `showsSetup` getter
    /// reads `phase` today — but a state machine that lies is a bug waiting for its second
    /// reader.
    func testConnectingFromDemoLeavesTheAppInTheReadyPhase() {
        let model = MobileModel()
        model.isDemoMode = true
        model.phase = .demo

        // Exactly the order BatonMobileApp uses on a successful connect.
        model.showsSetup = false
        model.endDemo()

        XCTAssertEqual(model.phase, .ready, "connected to a server is not demo mode")
        XCTAssertFalse(model.isDemoMode)
    }

    /// The reverse must also hold: ending a demo when setup is genuinely needed keeps it.
    func testEndingDemoWhileSetupIsNeededStaysAtSetup() {
        let model = MobileModel()
        model.isDemoMode = true
        model.phase = .needsSetup

        model.endDemo()

        XCTAssertEqual(model.phase, .needsSetup)
    }

    // MARK: - Stores clear themselves

    func testPlayHistoryClears() {
        let history = MusicPlayHistory(defaults: defaults)
        history.record(NavidromeSong(id: "a", title: "A", artist: "X"))
        XCTAssertFalse(history.entries.isEmpty)

        history.clear()

        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertNil(defaults.object(forKey: "tonebox.music.playHistory"))
    }

    func testRadioBansClear() {
        let bans = MusicRadioBans(defaults: defaults)
        bans.ban("song-1")
        XCTAssertTrue(bans.isBanned("song-1"))

        bans.clear()

        XCTAssertFalse(bans.isBanned("song-1"))
        XCTAssertNil(defaults.object(forKey: MusicRadioBans.storageKey))
    }

    /// The outbox is the one that would actively misbehave: queued listens belong to the
    /// account that made them, and delivering them under the next account's token would
    /// scrobble one person's music to another person's profile.
    func testScrobbleQueueClearsAndForgetsItsStorage() {
        let queue = ScrobbleQueue(defaults: defaults)
        queue.enqueue(Scrobble(song: NavidromeSong(id: "a", title: "A", artist: "X"), startedAt: Date()),
                      destination: "lastfm")
        XCTAssertEqual(queue.pending.count, 1)

        queue.clear()

        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertNil(defaults.object(forKey: ScrobbleQueue.storageKey),
                     "a surviving key would reload the same listens on next launch")
    }

    /// A cleared queue must not come back when a fresh store reads the same defaults.
    func testClearedScrobbleQueueStaysEmptyAcrossReload() {
        let queue = ScrobbleQueue(defaults: defaults)
        queue.enqueue(Scrobble(song: NavidromeSong(id: "a", title: "A", artist: "X"), startedAt: Date()),
                      destination: "listenbrainz")
        queue.clear()

        XCTAssertTrue(ScrobbleQueue(defaults: defaults).pending.isEmpty)
    }

    // MARK: - Every store on the model, named

    /// The one that catches the *next* leak.
    ///
    /// `SessionPurge`'s own doc comment sets the standard: one function that names every
    /// store, so a store added later shows up as a missing line. Four had gone missing
    /// anyway — search history, podcast subscriptions, clippings and the friend log — while
    /// the confirmation the user agreed to said "Baton will forget this server and remove
    /// its data from this iPhone". Search history was the worst of them: it carries the
    /// previous account's queries and the album and artist ids they opened, and it is the
    /// first thing the next sign-in would put on screen.
    ///
    /// This test walks the stores the model holds rather than the keys the purge happens to
    /// know about, so adding a store to `MobileModel` and forgetting the purge fails here.
    func testPurgeLeavesEveryStoreOnTheModelEmpty() throws {
        let model = MobileModel()

        model.history.record(NavidromeSong(id: "s1", title: "A", artist: "X"))
        model.radioBans.ban("s1")
        model.searchRecents.record(album: NavidromeAlbum(id: "al1", name: "An Album", artist: "X"))
        model.friendLog.record(FriendExchange(surface: .phone, request: "something mellow",
                                              reply: "here you go"))
        let clipping = try seedClipping(into: model.clippings)

        SessionPurge.purge(model, keepDownloads: false)

        XCTAssertTrue(model.history.entries.isEmpty, "play history")
        XCTAssertFalse(model.radioBans.isBanned("s1"), "radio bans")
        XCTAssertTrue(model.searchRecents.entries.isEmpty, "search history, this server")
        XCTAssertTrue(model.searchRecents.all.isEmpty, "search history, every server")
        XCTAssertTrue(model.podcastSubscriptions.channels.isEmpty, "podcast subscriptions")
        XCTAssertTrue(model.clippings.items.isEmpty, "clippings")
        XCTAssertTrue(model.friendLog.exchanges.isEmpty, "the friend log")
        XCTAssertTrue(model.pins.ordered.isEmpty, "Later / pins")
        XCTAssertEqual(model.scrobbles.pendingCount, 0, "the scrobble outbox")
        XCTAssertNil(model.handoff.offer, "a queue handed over from another device")

        // And the keys behind them, or the next write would put the list straight back.
        XCTAssertNil(BatonStorage.defaults.object(forKey: SearchRecents.storageKey),
                     "baton.search.recents survived")
        XCTAssertNil(BatonStorage.defaults.object(forKey: PodcastSubscriptionStore.ledgerKey),
                     "the podcast subscription ledger survived")
        XCTAssertNil(BatonStorage.defaults.object(forKey: PodcastSubscriptionStore.syncedFeedsKey),
                     "the legacy podcast feed list survived")

        XCTAssertFalse(FileManager.default.fileExists(atPath: clipping.url.path),
                       "the clipping's audio file survived the purge")
    }

    /// Clippings are the user's own recordings, so they follow the same rule as downloads:
    /// "switch servers" and "erase my recordings" are different intentions.
    func testKeepingDownloadsKeepsClippings() throws {
        let model = MobileModel()
        let clipping = try seedClipping(into: model.clippings)

        SessionPurge.purge(model, keepDownloads: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: clipping.url.path),
                      "keeping downloads must keep the recordings the user made themselves")
        model.clippings.remove(id: clipping.id, dismissing: false, everywhere: false)
    }

    /// TBX-5230 (owner decision, 2026-09-09): the purge now takes the friend's memory and
    /// its learned corrections too, not just the exchange log. Both live in the shared
    /// `baton.friend.ledger`, so clearing them here must publish tombstones — not merely go
    /// silent — or a peer device still holding the old rows would push them straight back on
    /// the next sync. `RemoteMemoryStore.forgetEverything()` / `FriendLearningStore.forgetAll()`
    /// already guarantee that at the store level — proved directly against the ledger by
    /// `testForgettingEverythingLeavesTombstonesRatherThanAnEmptyLedger`,
    /// `testForgettingEverythingIsNotUndoneByTheNextSync` and
    /// `testClearingEveryCorrectionIsNotUndoneByTheNextSync` in
    /// `BatonAgentKitTests/FriendSyncTests.swift`. This test only has to prove the purge
    /// actually calls them.
    func testPurgeErasesTheFriendsMemoryAndLearning() {
        let model = MobileModel()
        _ = model.friendMemory.remember(kind: "preference", text: "No vocals while working",
                                        quote: "no vocals while I'm working")
        _ = model.friendLearning.learn(from: FriendExchange(
            surface: .phone, request: "play something mellow", reply: "here you go",
            rating: .down, fault: .wrongTrack))
        XCTAssertNotNil(model.friendMemory.rendered(), "precondition: a memory to erase")
        XCTAssertNotNil(model.friendLearning.promptBlock, "precondition: a correction to erase")

        SessionPurge.purge(model, keepDownloads: true)

        XCTAssertNil(model.friendMemory.rendered(), "the friend's memory survived the purge")
        XCTAssertNil(model.friendLearning.promptBlock, "the friend's learned corrections survived the purge")
    }

    /// The DEBUG reset path (`-baton.resetSession`) is the one that found TBX-5230 in the
    /// first place: a UI fixture reset the session and still met last run's memories. It
    /// clears the same two stores `purge` does, through the same tombstoning calls.
    func testResetSessionWipesTheFriendsMemoryAndLearning() {
        let memory = RemoteMemoryStore()
        let learning = FriendLearningStore()
        _ = memory.remember(kind: "preference", text: "Nothing loud before nine",
                            quote: "nothing loud before nine in the morning")
        _ = learning.learn(from: FriendExchange(
            surface: .phone, request: "play something loud", reply: "here",
            rating: .down, fault: .wrongTrack))
        XCTAssertNotNil(memory.rendered(), "precondition: a memory to erase")
        XCTAssertNotNil(learning.promptBlock, "precondition: a correction to erase")

        SessionPurge.wipeStores()

        XCTAssertNil(RemoteMemoryStore().rendered(), "the friend's memory survived a session reset")
        XCTAssertNil(FriendLearningStore().promptBlock, "the friend's corrections survived a session reset")
    }

    private func seedClipping(into store: ClippingStore) throws -> ClippingStore.Item {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws6-\(UUID().uuidString).m4a")
        try Data("not really audio".utf8).write(to: source)
        return try store.adopt(source, title: "A reading", sourceName: "Tests")
    }
}
