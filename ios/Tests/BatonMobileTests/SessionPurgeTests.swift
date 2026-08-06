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
}
