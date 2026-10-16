import XCTest
@testable import Baton
@testable import BatonPlaybackKit

/// The Mac now syncs shared settings on its own.
///
/// It always could — but the only caller was the "Sync now" button in Settings, so the
/// phone's searches, podcasts and EQ curve sat in the shared document until someone
/// pressed a button they had no reason to press. A feature that never fires is
/// indistinguishable from a broken one, and was reported as broken.
///
/// The guard is what these cover. It is silent when wrong in either direction: too strict
/// and the scheduler runs on time, finds nothing to talk to, and never syncs; too loose and
/// it makes doomed requests on every activation for people who have no gateway at all.
@MainActor
final class PreferenceSyncSchedulerTests: XCTestCase {
    func testAConfiguredGatewayIsUsed() {
        let gateway = PreferenceSyncScheduler.gateway(
            urlString: "https://baton.home.example", token: "s3cret"
        )
        XCTAssertEqual(gateway?.url.absoluteString, "https://baton.home.example")
        XCTAssertEqual(gateway?.token, "s3cret")
    }

    func testSurroundingWhitespaceIsNotAMisconfiguration() {
        let gateway = PreferenceSyncScheduler.gateway(
            urlString: "  https://baton.home.example  ", token: " s3cret "
        )
        XCTAssertEqual(gateway?.url.absoluteString, "https://baton.home.example")
        XCTAssertEqual(gateway?.token, "s3cret", "a pasted token often carries a space")
    }

    /// The common case by far: nothing configured. It must stay silent rather than make a
    /// doomed request every time the app is brought to the front.
    func testNoGatewayMeansNoRequest() {
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: nil, token: nil))
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: "", token: "s3cret"))
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: "   ", token: "s3cret"))
    }

    /// A URL without a token can't authenticate, and a token without a URL has nowhere to
    /// go. Half a configuration is not a configuration.
    func testHalfAConfigurationIsRejected() {
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: "https://baton.home.example",
                                                     token: nil))
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: "https://baton.home.example",
                                                     token: "   "))
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: nil, token: "s3cret"))
    }

    /// The Mac must stamp its own changes, and for months it did not.
    ///
    /// The phone started observing at model init; the Mac started nothing, so its timestamp
    /// map stayed permanently empty. Both halves of `sync` read an empty map as "this device
    /// has never chosen anything": it could not push any key the phone had written, and it
    /// adopted the phone's copy on every pull, so a setting changed here reverted itself.
    ///
    /// Nothing else can catch this. There is no failure, no log line, and no difference in
    /// the request — a device that silently never pushes looks exactly like a device nobody
    /// changed a setting on, which is why it survived a release and a two-device matrix
    /// being planned around it.
    ///
    /// Safe to drive `start()` here: it is `@MainActor` and this test never suspends, so the
    /// heartbeat task cannot run before `stop()` cancels it and no request is made.
    func testTheSchedulerStampsChangesMadeOnThisMac() {
        let scheduler = PreferenceSyncScheduler(model: MusicModel())

        scheduler.start()
        defer { scheduler.stop() }

        XCTAssertTrue(scheduler.sync.isObservingChanges,
                      "an unobserving Mac can neither push its settings nor keep them")
    }

    /// Symmetry, so a stopped scheduler leaves nothing hanging on the notification centre.
    func testStoppingAlsoStopsObserving() {
        let scheduler = PreferenceSyncScheduler(model: MusicModel())
        scheduler.start()

        scheduler.stop()

        XCTAssertFalse(scheduler.sync.isObservingChanges)
    }

    /// Someone typing a host with no scheme should not produce a URL that fails later at a
    /// layer with no way to explain itself.
    /// A probe sharing the owner's gateway must not sync: the shared document carries the
    /// gateway address itself, so the probe would adopt the owner's address over its own.
    func testAProbeCanSwitchSyncOffThroughTheEnvironment() {
        XCTAssertTrue(PreferenceSyncScheduler.isSwitchedOff(by: ["BATON_DEBUG_PREFERENCE_SYNC": "off"]))
        XCTAssertFalse(PreferenceSyncScheduler.isSwitchedOff(by: ["BATON_DEBUG_PREFERENCE_SYNC": "on"]))
        XCTAssertFalse(PreferenceSyncScheduler.isSwitchedOff(by: [:]))
    }

    func testAnUnusableURLIsRejected() {
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: "baton.home.example",
                                                     token: "s3cret"),
                     "no scheme — URLSession would fail this with nothing useful to report")
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: "not a url at all",
                                                     token: "s3cret"))
    }

    // MARK: - The book ledger push

    /// A scheduler whose push only counts, on a model of its own, so each trigger starts from a
    /// ledger it has never sent.
    private func countingScheduler(_ pushes: @escaping @MainActor () -> Void) -> (PreferenceSyncScheduler, MusicModel) {
        let model = MusicModel()
        let scheduler = PreferenceSyncScheduler(model: model, pushDelay: .milliseconds(50)) {
            pushes()
            return true
        }
        scheduler.installPushTriggers()
        return (scheduler, model)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    /// Pause, stop and leaving the foreground each push the book ledger, after the debounce and
    /// not before. Before this a book stopped here reached the phone at the next heartbeat.
    func testPauseStopAndLeavingTheFrontEachPushTheBookLedger() async throws {
        var pushes = 0
        let (paused, pausedModel) = countingScheduler { pushes += 1 }
        defer { paused.stop() }
        pausedModel.music.pause()
        XCTAssertEqual(pushes, 0, "debounced, not at once")
        try await settle()
        XCTAssertEqual(pushes, 1, "pause")

        let (stopped, stoppedModel) = countingScheduler { pushes += 1 }
        defer { stopped.stop() }
        stoppedModel.music.stop()
        try await settle()
        XCTAssertEqual(pushes, 2, "stop")

        // Leaving the foreground is per app, so this one reaches both installed schedulers; each
        // has already sent its ledger, which has not moved since.
        let (away, _) = countingScheduler { pushes += 1 }
        defer { away.stop() }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await settle()
        XCTAssertEqual(pushes, 3, "leaving the foreground, once, from the scheduler with something to send")
    }

    /// Pause, then Stop, then switching away: one round trip.
    func testABurstOfHaltsIsOnePush() async throws {
        var pushes = 0
        let (scheduler, model) = countingScheduler { pushes += 1 }
        defer { scheduler.stop() }
        model.music.pause()
        model.music.stop()
        scheduler.ledgerPush?.schedule()
        try await settle()
        XCTAssertEqual(pushes, 1)
    }

    /// `MusicModel` saves the queue for handoff on pause; the push must sit beside that, not
    /// replace it, and `stop()` must hand the hooks back.
    func testThePushIsChainedOntoTheExistingPauseHook() async throws {
        let model = MusicModel()
        var handoffSaves = 0
        model.music.onPause = { handoffSaves += 1 }
        var pushes = 0
        let scheduler = PreferenceSyncScheduler(model: model, pushDelay: .milliseconds(50)) { pushes += 1; return true }
        scheduler.installPushTriggers()
        model.music.pause()
        try await settle()
        XCTAssertEqual(handoffSaves, 1)
        XCTAssertEqual(pushes, 1)

        scheduler.stop()
        model.music.pause()
        try await settle()
        XCTAssertEqual(handoffSaves, 2)
        XCTAssertEqual(pushes, 1, "a stopped scheduler pushes nothing")
        XCTAssertNil(model.music.onStop)
    }

    /// A probe launched with `BATON_DEBUG_PREFERENCE_SYNC=off` gets no push at all.
    func testASwitchedOffMacInstallsNoPush() {
        let model = MusicModel()
        let scheduler = PreferenceSyncScheduler(model: model)
        scheduler.start(environment: ["BATON_DEBUG_PREFERENCE_SYNC": "off"])
        defer { scheduler.stop() }
        XCTAssertNil(scheduler.ledgerPush)
        XCTAssertNil(model.music.onStop)
    }

    /// And an ordinary start installs it. Never suspends, so no request is made.
    func testStartInstallsThePush() {
        let model = MusicModel()
        let scheduler = PreferenceSyncScheduler(model: model)
        scheduler.start(environment: [:])
        defer { scheduler.stop() }
        XCTAssertNotNil(scheduler.ledgerPush)
        XCTAssertNotNil(model.music.onStop)
    }

    // MARK: - Play pulls first

    /// Play on a book fetches the phone's place through the same forced sync as the push, so a
    /// Mac left in front starts where the phone stopped. Stopping the scheduler takes it away.
    func testPlayOnABookPullsThroughTheForcedSync() async {
        var syncs = 0
        let (scheduler, model) = countingScheduler { syncs += 1 }
        guard let pull = model.bookPlacePull else {
            scheduler.stop()
            return XCTFail("a running scheduler gives book Play nothing to pull with")
        }
        let outcome = await BookPlacePull.run(sync: pull)
        XCTAssertEqual(outcome, .pulled)
        XCTAssertEqual(syncs, 1, "Play did not sync before starting")
        scheduler.stop()
        XCTAssertNil(model.bookPlacePull, "a stopped scheduler still pulls")
    }

    /// A probe launched with `BATON_DEBUG_PREFERENCE_SYNC=off` pulls nothing before Play.
    func testASwitchedOffMacPullsNothingBeforePlay() {
        let model = MusicModel()
        let scheduler = PreferenceSyncScheduler(model: model)
        scheduler.start(environment: ["BATON_DEBUG_PREFERENCE_SYNC": "off"])
        defer { scheduler.stop() }
        XCTAssertNil(model.bookPlacePull)
    }

    /// An ordinary start offers the pull.
    func testStartOffersThePullBeforePlay() {
        let model = MusicModel()
        let scheduler = PreferenceSyncScheduler(model: model)
        scheduler.start(environment: [:])
        defer { scheduler.stop() }
        XCTAssertNotNil(model.bookPlacePull)
    }
}
