import XCTest
@testable import Baton

/// Covers `SpeechConfig.deliveryPlan` — how the primary timing choice (announce immediately vs.
/// let the agent decide), the auto-play gate, and the two independent alert surfaces resolve
/// into the concrete actions for one summary. Pure routing, fully unit-tested.
///
/// Model: the agent owns *timing* (may it speak now?), the user owns *where it shows*
/// (notification / banner), and those alert surfaces apply under both primaries.
final class SpeechDeliveryTests: XCTestCase {
    private typealias Plan = SpeechConfig.DeliveryPlan

    private func plan(
        announce: Bool,
        allowAgentAuto: Bool = false,
        notification: Bool = false,
        banner: Bool = false,
        requested: String = "notify"
    ) -> Plan {
        SpeechConfig.deliveryPlan(
            announceImmediately: announce,
            allowAgentAutoPlay: allowAgentAuto,
            notification: notification,
            banner: banner,
            requestedMode: requested
        )
    }

    // MARK: - Announce immediately (user forces playback)

    func testAnnounceImmediatelySpeaksNow() {
        XCTAssertEqual(plan(announce: true), Plan(speakNow: true, notify: false, banner: false))
    }

    func testAnnounceImmediatelyIsNotGated() {
        // The user's own choice ignores the agent auto-play gate and the agent's requested mode.
        XCTAssertEqual(plan(announce: true, allowAgentAuto: false, requested: "notify"),
                       Plan(speakNow: true, notify: false, banner: false))
    }

    func testAnnounceImmediatelyPlusAlertsLeavesRecord() {
        // Speak now AND keep a notification + banner as a replayable record.
        XCTAssertEqual(plan(announce: true, notification: true, banner: true),
                       Plan(speakNow: true, notify: true, banner: true))
    }

    // MARK: - Let the agent decide (timing deferred to the agent)

    func testAgentWaitsWhenNotAuto() {
        // A non-auto summary waits and surfaces through the user's chosen alerts.
        XCTAssertEqual(plan(announce: false, notification: true, requested: "notify"),
                       Plan(speakNow: false, notify: true, banner: false))
    }

    func testAgentAutoGatedOffStillWaits() {
        // Agent asked to play now, but the gate is off → it waits as an alert, never blasts audio.
        XCTAssertEqual(plan(announce: false, allowAgentAuto: false, notification: true, requested: "auto"),
                       Plan(speakNow: false, notify: true, banner: false))
    }

    func testAgentAutoAllowedSpeaksNow() {
        // Gate on + agent asked for auto → speaks now, and any alerts still fire.
        XCTAssertEqual(plan(announce: false, allowAgentAuto: true, notification: true, requested: "auto"),
                       Plan(speakNow: true, notify: true, banner: false))
    }

    func testAgentBannerModeUsesUserSurfaces() {
        // The agent's notify-vs-banner choice defers to the user's surfaces (user owns "where").
        XCTAssertEqual(plan(announce: false, banner: true, requested: "banner"),
                       Plan(speakNow: false, notify: false, banner: true))
    }

    // MARK: - Alerts apply under both primaries, and combine

    func testNotificationAndBannerTogether() {
        XCTAssertEqual(plan(announce: false, notification: true, banner: true),
                       Plan(speakNow: false, notify: true, banner: true))
    }

    // MARK: - Reachability invariant

    func testAgentDecideWithNoSurfaceKeepsBanner() {
        // Waiting summary with no alert would vanish → a banner is forced on.
        XCTAssertEqual(plan(announce: false), Plan(speakNow: false, notify: false, banner: true))
    }

    func testAnnounceWithNoAlertsNeedsNoBanner() {
        // Announcing IS a surface, so no banner is forced.
        XCTAssertEqual(plan(announce: true), Plan(speakNow: true, notify: false, banner: false))
    }

    func testAgentAutoAllowedWithNoAlertsNeedsNoBanner() {
        // The agent will speak it → reachable without forcing a banner.
        XCTAssertEqual(plan(announce: false, allowAgentAuto: true, requested: "auto"),
                       Plan(speakNow: true, notify: false, banner: false))
    }
}
