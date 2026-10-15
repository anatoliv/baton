import BatonShareKit
@testable import BatonShareServer
import Foundation
import XCTest

extension ShareEnforcementTests {
    func configurePreservation(retentionDays: Int64 = 30, quota: Int64? = nil) throws {
        var config = service.config
        config.enforcement = try EnforcementConfiguration(token: operatorToken, retentionSeconds: retentionDays * 86400,
            auditRetentionSeconds: 90 * 86400, reasonCodes: ["review", "correction"])
        if let quota { config.limits.quotaBytes = quota }
        service = try ShareService(config: config, clock: { [clock = clock!] in clock.now })
    }

    func testConsentedSevenDayShareSurvivesReviewAndResumesOnlyRemainingLifetime() throws {
        try configurePreservation()
        let id = try makeShare(cap: 3, expires: 604800, art: true, reviewConsent: true)
        let artwork = send("GET", "/v1/share/p/" + id + "/art").body
        let audio = send("GET", "/v1/share/p/" + id + "/audio")
        XCTAssertEqual(audio.status, 200)
        let start = Int64(clock.now.timeIntervalSince1970)
        clock.advance(86400)
        let request: [String: Any] = ["operationID": UUID().uuidString.lowercased(),
            "action": "disable-share", "shareID": id, "caseReference": "case_123", "reasonCode": "review",
            "reviewUntil": start + 20 * 86400, "preservationDeadline": start + 22 * 86400]
        let response = operatorCall("plan", body: try JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(response.status, 200)
        guard response.status == 200 else { return }
        XCTAssertEqual(operatorCall("apply", body: response.body).status, 200)
        clock.advance(19 * 86400)
        _ = try service.sweep()
        service = try ShareService(config: service.config, clock: { [clock = clock!] in clock.now })
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 410)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "applied")
        let owned = try decoded(ShareList.self, send("GET", "/v1/share/shares", secret: owner))
        XCTAssertEqual(owned.shares.first?.expiresAt, ShareDate.string(Date(timeIntervalSince1970: TimeInterval(start + 26 * 86400))))
        XCTAssertEqual(owned.shares.first?.stats.fetches, 1)
        XCTAssertEqual(owned.shares.first?.playCap, 3)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/art").body, artwork)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").body, audio.body)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 200)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410)
    }

    func preservationRequest(_ action: EnforcementAction, id: String, review: Int64, deadline: Int64,
                             court: Bool? = nil, revision: Int64? = nil) -> EnforcementRequest {
        var request = operation(action, id: id)
        request.reviewUntil = review; request.preservationDeadline = deadline
        request.courtReviewRequired = court; request.expectedRevision = revision
        return request
    }

    func preservationPlan(_ request: EnforcementRequest) throws -> EnforcementPlan {
        let response = operatorCall("plan", body: try encoded(request))
        XCTAssertEqual(response.status, 200)
        return try decoded(EnforcementPlan.self, response)
    }

    @discardableResult
    func disablePreserving(_ id: String, days: Int64 = 22, court: Bool = false) throws -> EnforcementPlan {
        let now = Int64(clock.now.timeIntervalSince1970)
        let reviewed = try preservationPlan(preservationRequest(.disableShare, id: id,
            review: now + (days - 2) * 86400, deadline: now + days * 86400, court: court))
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).status, 200)
        return reviewed
    }

    func preservationStorage() throws -> Int64 {
        let response = send("GET", "/v1/share/admin/stats", secret: statsToken)
        XCTAssertEqual(response.status, 200)
        return try decoded(ShareReport.self, response).health.storedBytes
    }

    func preservationReopen() throws {
        service = try ShareService(config: service.config, clock: { [clock = clock!] in clock.now })
    }

    func testConsentCannotBeInferredAndExpiredShareCannotGainPausedLifetime() throws {
        try configurePreservation()
        let consented = try makeShare(expires: 604800, reviewConsent: true)
        XCTAssertEqual(operatorCall("plan", body: try encoded(operation(.disableShare, id: consented))).status, 409)
        let legacy = try makeShare(expires: 604800)
        try apply(.disableShare, id: legacy)
        clock.advance(7 * 86400)
        let current = Int64(clock.now.timeIntervalSince1970)
        XCTAssertEqual(operatorCall("plan", body: try encoded(preservationRequest(.disableShare, id: consented,
            review: current + 20 * 86400, deadline: current + 22 * 86400))).status, 409)
        _ = try service.sweep()
        try preservationReopen()
        XCTAssertEqual(try apply(.restoreShare, id: legacy).outcome, "unrestorable")
        XCTAssertEqual(try preservationStorage(), 0)
    }

    func testCaseReviewIsRevisionCheckedAndCannotResetPreservationCeiling() throws {
        try configurePreservation(retentionDays: 90)
        let id = try makeShare(expires: 604800, reviewConsent: true)
        let initial = try disablePreserving(id)
        let startedAt = try XCTUnwrap(initial.affected.first?.preservationStartedAt)
        clock.advance(10 * 86400)
        let current = try plan(.restoreShare, id: id)
        var extensionRequest = preservationRequest(.reviewPreservation, id: id,
            review: startedAt + 48 * 86400, deadline: startedAt + 50 * 86400,
            court: false, revision: current.affected[0].revision)
        var wrongCase = extensionRequest; wrongCase.caseReference = "another_case"
        XCTAssertEqual(operatorCall("plan", body: try encoded(wrongCase)).status, 409)
        var tooLong = extensionRequest; tooLong.preservationDeadline = startedAt + 91 * 86400
        XCTAssertEqual(operatorCall("plan", body: try encoded(tooLong)).status, 409)
        let extended = try preservationPlan(extensionRequest)
        XCTAssertEqual(operatorCall("apply", body: try encoded(extended)).status, 200)
        XCTAssertEqual(operatorCall("plan", body: try encoded(extensionRequest)).status, 409)
        let repeated = try plan(.disableShare, id: id)
        XCTAssertEqual(repeated.affected[0].preservationStartedAt, startedAt)
        XCTAssertEqual(repeated.affected[0].preservationCeiling, startedAt + 90 * 86400)
        XCTAssertEqual(repeated.affected[0].retentionDeadline, startedAt + 50 * 86400)
        XCTAssertEqual(operatorCall("apply", body: try encoded(repeated)).status, 200)
        try preservationReopen()
        clock.advance(30 * 86400)
        _ = try service.sweep()
        XCTAssertGreaterThan(try preservationStorage(), 0)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "applied")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 200)
        extensionRequest.expectedRevision = repeated.affected[0].revision + 1
        XCTAssertEqual(operatorCall("plan", body: try encoded(extensionRequest)).status, 409)
    }

    func testCourtReviewBlocksRestorationUntilExplicitReviewedClearance() throws {
        try configurePreservation()
        let id = try makeShare(expires: 604800, reviewConsent: true)
        let initial = try disablePreserving(id, court: true)
        clock.advance(14 * 86400)
        _ = try service.sweep(); try preservationReopen()
        let restore = try plan(.restoreShare, id: id)
        XCTAssertEqual(restore.affected[0].restorationBlock, "courtReview")
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "unrestorable")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410)
        let start = try XCTUnwrap(initial.affected[0].preservationStartedAt)
        let reviewed = try preservationPlan(preservationRequest(.reviewPreservation, id: id,
            review: start + 20 * 86400, deadline: start + 22 * 86400,
            court: false, revision: restore.affected[0].revision))
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).status, 200)
        try preservationReopen()
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "applied")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 200)
    }

    func testExactNinetyDayCeilingPurgesAndLateReviewCannotReviveMaterial() throws {
        try configurePreservation(retentionDays: 90)
        let id = try makeShare(expires: 604800, reviewConsent: true)
        let now = Int64(clock.now.timeIntervalSince1970)
        let tooLate = preservationRequest(.disableShare, id: id,
            review: now + 89 * 86400, deadline: now + 91 * 86400)
        XCTAssertEqual(operatorCall("plan", body: try encoded(tooLate)).status, 409)
        let initial = try disablePreserving(id, days: 90)
        clock.advance(90 * 86400 - 1)
        _ = try service.sweep(); try preservationReopen()
        XCTAssertGreaterThan(try preservationStorage(), 0)
        XCTAssertEqual(try plan(.restoreShare, id: id).affected[0].restorable, true)
        clock.advance(1)
        let expired = try plan(.restoreShare, id: id)
        XCTAssertEqual(expired.affected[0].restorationBlock, "expired")
        let late = preservationRequest(.reviewPreservation, id: id, review: now + 91 * 86400,
            deadline: now + 93 * 86400, court: false, revision: expired.affected[0].revision)
        XCTAssertEqual(operatorCall("plan", body: try encoded(late)).status, 409)
        _ = try service.sweep(); try preservationReopen()
        XCTAssertEqual(try preservationStorage(), 0)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "unrestorable")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410)
        XCTAssertEqual(operatorCall("apply", body: try encoded(initial)).status, 409, "expired audit receipt cannot revive content")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 410)
    }

    func testHeldQuotaAndRevocationRemainTruthfulAndOwnerBound() throws {
        try configurePreservation()
        let id = try makeShare(expires: 604800, reviewConsent: true)
        try disablePreserving(id)
        let retained = try preservationStorage()
        let ownerRead = send("GET", "/v1/share/shares", secret: owner)
        let notice = try decoded(ShareList.self, ownerRead).shares[0].actionRequired ?? ""
        XCTAssertTrue(notice.contains("privately preserved until"))
        XCTAssertTrue(notice.contains("604800 seconds"))
        XCTAssertFalse(String(decoding: ownerRead.body, as: UTF8.self).contains("case_123"))
        XCTAssertEqual(send("DELETE", "/v1/share/shares/" + id, secret: differentOwner).status, 404)
        XCTAssertEqual(send("PATCH", "/v1/share/shares/" + id, body: Data("{\"extendBySeconds\":604800}".utf8), secret: owner).status, 403)
        try configurePreservation(quota: retained - 1)
        let now = Int64(clock.now.timeIntervalSince1970)
        clock.advance(20 * 86400)
        let state = try plan(.restoreShare, id: id).affected[0]
        XCTAssertEqual(operatorCall("plan", body: try encoded(preservationRequest(.reviewPreservation, id: id,
            review: now + 25 * 86400, deadline: now + 27 * 86400, court: false, revision: state.revision))).status, 503)
        XCTAssertEqual(try preservationStorage(), retained)
        XCTAssertEqual(send("DELETE", "/v1/share/shares/" + id, secret: owner).status, 204)
        try preservationReopen()
        XCTAssertEqual(try preservationStorage(), 0)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "unrestorable")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410)
    }

    func testPreservationAdmissionCannotBypassQuotaOrSpendMoreLifetimeDuringPlanReview() throws {
        try configurePreservation()
        let id = try makeShare(expires: 604800, reviewConsent: true)
        let retained = try preservationStorage()
        let now = Int64(clock.now.timeIntervalSince1970)
        let request = preservationRequest(.disableShare, id: id, review: now + 20 * 86400, deadline: now + 22 * 86400)
        let initial = try preservationPlan(request)
        try configurePreservation(quota: retained - 1)
        XCTAssertEqual(operatorCall("apply", body: try encoded(initial)).status, 503)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 200)
        try configurePreservation(quota: retained)
        clock.advance(599)
        XCTAssertEqual(operatorCall("apply", body: try encoded(initial)).status, 200)
        let paused = try plan(.restoreShare, id: id).affected[0]
        XCTAssertEqual(paused.remainingLifetimeSeconds, 604800 - 599)
        XCTAssertEqual(paused.preservationStartedAt, now + 599)
        clock.advance(20 * 86400)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "applied")
        let owned = try decoded(ShareList.self, send("GET", "/v1/share/shares", secret: owner)).shares[0]
        XCTAssertEqual(owned.expiresAt, ShareDate.string(Date(timeIntervalSince1970: TimeInterval(now + 27 * 86400))))
    }

    func testPausedRestoreNeverResetsSpentCapAndSuspensionMustEndFirst() throws {
        try configurePreservation()
        let id = try makeShare(cap: 1, expires: 604800, reviewConsent: true)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 200)
        try disablePreserving(id)
        XCTAssertEqual(try plan(.restoreShare, id: id).affected[0].restorationBlock, "spentCap")
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "unrestorable")
        let other = try makeShare(expires: 604800, reviewConsent: true)
        // Both shares are in the same case. A repeated suspension must preserve the held cap.
        try disablePreserving(other)
        try apply(.suspendSharer, id: other)
        XCTAssertEqual(try plan(.restoreShare, id: other).affected[0].restorationBlock, "suspended")
        try apply(.unsuspendSharer, id: other)
        clock.advance(14 * 86400)
        _ = try service.sweep(); try preservationReopen()
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "unrestorable")
        XCTAssertEqual(try apply(.restoreShare, id: other).outcome, "applied")
        XCTAssertEqual(send("GET", "/v1/share/p/" + other + "/audio").status, 200)
    }

    func testPausedRestoreExpiryAndReceiptRollBackTogether() throws {
        try configurePreservation()
        let id = try makeShare(expires: 604800, reviewConsent: true)
        let original = try decoded(ShareList.self, send("GET", "/v1/share/shares", secret: owner)).shares[0].expiresAt
        try disablePreserving(id)
        clock.advance(20 * 86400)
        let reviewed = try plan(.restoreShare, id: id)
        // Inject a synthetic receipt-write failure; assertions stay at public boundaries.
        try service.store.database.execute("CREATE TRIGGER preservation_receipt_failure BEFORE INSERT ON enforcement_operations BEGIN SELECT RAISE(ABORT,'synthetic receipt failure'); END;")
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).status, 500)
        try preservationReopen()
        let owned = try decoded(ShareList.self, send("GET", "/v1/share/shares", secret: owner)).shares[0]
        XCTAssertEqual(owned.expiresAt, original)
        XCTAssertNotNil(owned.actionRequired)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410)
        try service.store.database.execute("DROP TRIGGER preservation_receipt_failure")
        let first = operatorCall("apply", body: try encoded(reviewed))
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(try decoded(EnforcementReceipt.self, first).outcome, "applied")
        let expires = try decoded(ShareList.self, send("GET", "/v1/share/shares", secret: owner)).shares[0].expiresAt
        clock.advance(1000); try preservationReopen()
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).body, first.body)
        XCTAssertEqual(try decoded(ShareList.self, send("GET", "/v1/share/shares", secret: owner)).shares[0].expiresAt, expires)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 200)
    }

    func testPausedMissingBytesAndExplicitPurgeNeverRestore() throws {
        try configurePreservation()
        let missing = try makeShare(expires: 604800, reviewConsent: true)
        try disablePreserving(missing)
        try FileManager.default.removeItem(at: service.store.blobURL(id: missing, kind: .audio))
        XCTAssertEqual(try plan(.restoreShare, id: missing).affected[0].restorationBlock, "missingMaterial")
        XCTAssertEqual(try apply(.restoreShare, id: missing).outcome, "unrestorable")
        let purged = try makeShare(expires: 604800, reviewConsent: true)
        try disablePreserving(purged)
        XCTAssertEqual(try apply(.purgeDisabledShare, id: purged).outcome, "purgeQueued")
        try preservationReopen()
        let restore = try plan(.restoreShare, id: purged)
        XCTAssertNil(restore.affected[0].preservationStartedAt)
        XCTAssertEqual(restore.affected[0].restorationBlock, "purged")
        XCTAssertEqual(try apply(.restoreShare, id: purged).outcome, "unrestorable")
        XCTAssertEqual(send("GET", "/v1/share/p/" + purged + "/audio").status, 410)
    }

    func testRestoreAndRedisableCannotResetFirstDisableCeiling() throws {
        try configurePreservation(retentionDays: 90)
        let id = try makeShare(expires: 604800, reviewConsent: true)
        let initial = try disablePreserving(id)
        let firstDisable = try XCTUnwrap(initial.affected[0].preservationStartedAt)
        clock.advance(20 * 86400)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "applied")
        clock.advance(86400)
        let request = preservationRequest(.disableShare, id: id,
            review: firstDisable + 48 * 86400, deadline: firstDisable + 50 * 86400)
        let second = try preservationPlan(request)
        XCTAssertEqual(second.affected[0].preservationStartedAt, firstDisable)
        XCTAssertEqual(second.affected[0].preservationCeiling, firstDisable + 90 * 86400)
        XCTAssertEqual(second.affected[0].remainingLifetimeSeconds, 6 * 86400)
        XCTAssertEqual(operatorCall("apply", body: try encoded(second)).status, 200)
        var beyond = preservationRequest(.reviewPreservation, id: id,
            review: firstDisable + 89 * 86400, deadline: firstDisable + 91 * 86400,
            court: false, revision: second.affected[0].revision + 1)
        XCTAssertEqual(operatorCall("plan", body: try encoded(beyond)).status, 409)
        beyond.preservationDeadline = firstDisable + 90 * 86400; beyond.reviewUntil = firstDisable + 88 * 86400
        XCTAssertEqual(operatorCall("plan", body: try encoded(beyond)).status, 200)
    }

    func testSuspensionPreservesOtherCasesAndAdmitsFreshConsentedScope() throws {
        try configurePreservation(retentionDays: 90)
        let held = try makeShare(expires: 604800, reviewConsent: true)
        let initial = try disablePreserving(held, court: true)
        clock.advance(86400)
        let fresh = try makeShare(expires: 604800, reviewConsent: true)
        let now = Int64(clock.now.timeIntervalSince1970)
        var request = preservationRequest(.suspendSharer, id: fresh,
            review: now + 20 * 86400, deadline: now + 22 * 86400, court: false)
        request.caseReference = "another_case"
        let response = operatorCall("plan", body: try encoded(request))
        XCTAssertEqual(response.status, 200)
        guard response.status == 200 else { return }
        let suspended = try decoded(EnforcementPlan.self, response)
        XCTAssertEqual(suspended.affected.count, 2)
        XCTAssertEqual(operatorCall("apply", body: try encoded(suspended)).status, 200)
        let existing = try plan(.restoreShare, id: held)
        XCTAssertEqual(existing.affected[0].revision, initial.affected[0].revision + 1)
        XCTAssertEqual(existing.affected[0].retentionDeadline, initial.affected[0].retentionDeadline)
        XCTAssertEqual(existing.affected[0].courtReviewRequired, true)
        try apply(.unsuspendSharer, id: fresh)
        XCTAssertEqual(try plan(.restoreShare, id: held).affected[0].restorationBlock, "courtReview")
        XCTAssertEqual(try apply(.restoreShare, id: held).outcome, "unrestorable")
        var restoreNew = operation(.restoreShare, id: fresh); restoreNew.caseReference = "another_case"
        let restored = try preservationPlan(restoreNew)
        XCTAssertEqual(operatorCall("apply", body: try encoded(restored)).status, 200)
        XCTAssertEqual(send("GET", "/v1/share/p/" + fresh + "/audio").status, 200)
        XCTAssertEqual(send("GET", "/v1/share/p/" + held + "/audio").status, 410)
    }

    func testSuspensionPlanReportsUnchangedLegacyHoldAfterConfiguredLimitDrops() throws {
        try configurePreservation()
        let held = try makeShare(expires: 604800)
        let original = try plan(.disableShare, id: held)
        XCTAssertEqual(operatorCall("apply", body: try encoded(original)).status, 200)
        clock.advance(86400)
        service = try reopen() // Shorter current configuration must not rewrite an existing case.
        let fresh = try makeShare(expires: 604800)
        let suspended = try plan(.suspendSharer, id: fresh)
        let heldPlan = try XCTUnwrap(suspended.affected.first { $0.id == held })
        XCTAssertEqual(heldPlan.retentionDeadline, original.affected[0].retentionDeadline)
        XCTAssertEqual(operatorCall("apply", body: try encoded(suspended)).status, 200)
        clock.advance(2 * 86400)
        _ = try service.sweep()
        try configurePreservation()
        XCTAssertEqual(try plan(.restoreShare, id: held).affected[0].retentionDeadline, original.affected[0].retentionDeadline)
        XCTAssertGreaterThan(try preservationStorage(), 0)
    }
}
