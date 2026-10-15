import BatonShareKit
@testable import BatonShareServer
import Foundation
import XCTest

/// Current behavior characterization for TBX-8937; these fixtures do not adopt
/// a retention policy or implement a legal clock/court-order workflow.
extension ShareEnforcementTests {
    private func restorationFixture() throws {
        clock = TestClock(Date(timeIntervalSince1970: 1_788_868_800)) // 2026-09-08 12:00 UTC
        var configuration = ShareConfiguration(dataDirectory: root,
            publicBase: URL(string: "https://batonmusic.app")!, adminToken: statsToken, blobDelivery: .direct)
        configuration.enforcement = try EnforcementConfiguration(token: operatorToken,
            retentionSeconds: 2_592_000, auditRetentionSeconds: 7_776_000,
            reasonCodes: ["review", "correction"])
        let currentClock = clock!
        service = try ShareService(config: configuration, clock: { currentClock.now })
    }

    private func reopenRestorationFixture() throws {
        let configuration = service.config
        let currentClock = clock!
        service = try ShareService(config: configuration, clock: { currentClock.now })
    }

    private func reportedStorage() throws -> Int64 {
        let response = send("GET", "/v1/share/admin/stats", secret: statsToken)
        XCTAssertEqual(response.status, 200)
        return try decoded(ShareReport.self, response).health.storedBytes
    }

    func testDefaultSevenDayMaterialEndsBeforeTenWeekdayReviewFixture() throws {
        try restorationFixture()
        let advertised = try decoded(ShareConfig.self, send("GET", "/v1/share/config"))
        XCTAssertEqual(advertised.defaultExpirySeconds, 604_800)
        let id = try makeShare(expires: 604_800)
        let reviewed = try plan(.disableShare, id: id)
        XCTAssertEqual(reviewed.affected.first?.expiresAt, 1_789_473_600) // Sep 15
        XCTAssertEqual(reviewed.affected.first?.retentionDeadline, 1_789_473_600)
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).status, 200)
        XCTAssertGreaterThan(try reportedStorage(), 0)
        clock.advance(604_800) // Sep 15: ordinary expiry, before any ten-weekday window.
        XCTAssertEqual(try plan(.restoreShare, id: id).affected.first?.restorationBlock, "expired")
        _ = try service.sweep()
        XCTAssertEqual(try reportedStorage(), 0)
        try reopenRestorationFixture()
        clock.advance(604_800) // Sep 22: ten weekdays after the Sep 8 fixture receipt.
        XCTAssertEqual(Int64(clock.now.timeIntervalSince1970), 1_790_078_400)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "unrestorable")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 410)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410)
        XCTAssertEqual(try reportedStorage(), 0)
    }

    func testThirtyDayEligibleMaterialRestoresAtFourteenWeekdaysWithoutResettingCap() throws {
        try restorationFixture()
        let id = try makeShare(cap: 2, expires: 2_592_000, art: true)
        let art = send("GET", "/v1/share/p/" + id + "/art").body
        XCTAssertEqual(art.count, 43, "the public fixture must return actual JPEG bytes")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 200)
        try apply(.disableShare, id: id)
        let retained = try reportedStorage()
        XCTAssertGreaterThan(retained, 0)
        clock.advance(1_728_000) // Sep 28: fourteen weekdays, twenty calendar days.
        XCTAssertEqual(Int64(clock.now.timeIntervalSince1970), 1_790_596_800)
        _ = try service.sweep()
        try reopenRestorationFixture()
        XCTAssertEqual(try reportedStorage(), retained)
        let reviewed = try plan(.restoreShare, id: id)
        XCTAssertEqual(reviewed.affected.first?.expiresAt, 1_791_460_800) // Oct 8
        XCTAssertEqual(reviewed.affected.first?.retentionDeadline, 1_791_460_800)
        XCTAssertEqual(reviewed.affected.first?.restorable, true)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "applied")
        try reopenRestorationFixture()
        let owned = try decoded(ShareList.self, send("GET", "/v1/share/shares", secret: owner))
        XCTAssertEqual(owned.shares.first?.expiresAt, "2026-10-08T12:00:00Z")
        XCTAssertEqual(owned.shares.first?.playCap, 2)
        XCTAssertEqual(owned.shares.first?.stats.fetches, 1)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 200)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/art").body, art)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 200)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410)
        XCTAssertEqual(try reportedStorage(), retained)
    }

    func testCourtEscalationReferenceCannotExtendHoldOrImplementPreservation() throws {
        try restorationFixture()
        let id = try makeShare(expires: 604_800)
        try apply(.disableShare, id: id)
        clock.advance(86_400) // Sep 9: synthetic external court escalation recorded separately.
        var request = operation(.disableShare, id: id)
        request.caseReference = "court_escalation_fixture"
        let response = operatorCall("plan", body: try encoded(request))
        XCTAssertEqual(response.status, 200)
        let reviewed = try decoded(EnforcementPlan.self, response)
        XCTAssertEqual(reviewed.affected.first?.retentionDeadline, 1_789_473_600)
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).status, 200)
        XCTAssertEqual(send("PATCH", "/v1/share/shares/" + id,
            body: Data("{\"extendBySeconds\":604800}".utf8), secret: owner).status, 403)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 410)
        XCTAssertGreaterThan(try reportedStorage(), 0)
        clock.advance(518_400) // Sep 15: original expiry still controls deletion.
        _ = try service.sweep()
        try reopenRestorationFixture()
        XCTAssertEqual(try reportedStorage(), 0)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "unrestorable")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410)
    }
}
