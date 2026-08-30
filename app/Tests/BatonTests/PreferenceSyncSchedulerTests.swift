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
    func testAnUnusableURLIsRejected() {
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: "baton.home.example",
                                                     token: "s3cret"),
                     "no scheme — URLSession would fail this with nothing useful to report")
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: "not a url at all",
                                                     token: "s3cret"))
    }
}
