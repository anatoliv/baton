import BatonShareKit
import Foundation
import XCTest
@testable import BatonShareServer

private actor ServicePushProvider: ReactionPushProvider {
    let operation: @Sendable (ReactionPushLease) async throws -> ReactionPushResult
    private(set) var sends = 0
    init(_ operation: @escaping @Sendable (ReactionPushLease) async throws -> ReactionPushResult = { _ in .accepted }) {
        self.operation = operation
    }
    func send(_ lease: ReactionPushLease) async throws -> ReactionPushResult {
        sends += 1
        return try await operation(lease)
    }
}

extension ShareServiceTests {
    private func setupPushBridge(queueLimit: Int = 1000) throws -> ReactionPushStore {
        let existingClock = clock!
        service = try ShareService(config: service.config,
            reactionPushPolicy: ReactionPushPolicy(enabled: true, key: Data(repeating: 0x42, count: 32),
                topics: ["io.tonebox.baton.tests": .sandbox], queueLimit: queueLimit),
            clock: { existingClock.now })
        let push = try XCTUnwrap(service.reactionPushStore)
        try push.register(owner: service.sharer(bearer: secret)!.digest,
            deviceID: "11111111-1111-1111-1111-111111111111", token: Data("synthetic-token".utf8),
            topic: "io.tonebox.baton.tests", environment: .sandbox,
            now: Int64(clock.now.timeIntervalSince1970) * 1000)
        return push
    }

    func testPushBridgeDefaultServiceCreatesNoTokenTablesOrProviderWork() async throws {
        XCTAssertNil(service.reactionPushStore)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='reaction_push_devices'"), 0)
        let provider = ServicePushProvider()
        let ran = try await service.makeReactionPushDispatcher(provider: provider).runOnce()
        let sends = await provider.sends
        XCTAssertFalse(ran); XCTAssertEqual(sends, 0)
    }

    func testPushBridgeReactionEventAndOutboxCommitTogether() throws {
        _ = try setupPushBridge()
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
        XCTAssertEqual(try service.store.reactions(shareID: made.id).count, 1)
        XCTAssertEqual(try events("reaction_sent").count, 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 1)
        XCTAssertFalse(service.reactionPushEnqueueFailed)
    }

    func testPushBridgeEventFailureRollsBackReactionAndNotification() throws {
        _ = try setupPushBridge()
        let made = try makeReadyShare()
        try service.store.database.execute("""
          CREATE TRIGGER fail_reaction_event BEFORE INSERT ON events WHEN NEW.type='reaction_sent'
          BEGIN SELECT RAISE(ABORT,'synthetic event failure'); END;
          """)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 500)
        XCTAssertEqual(try service.store.reactions(shareID: made.id).count, 0)
        XCTAssertEqual(try events("reaction_sent").count, 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 0)
    }

    func testPushBridgeOptionalQueueFailureKeepsAcceptedReactionAndEvent() throws {
        _ = try setupPushBridge()
        let made = try makeReadyShare()
        try service.store.database.execute("""
          CREATE TRIGGER fail_optional_queue AFTER INSERT ON reaction_push_jobs
          BEGIN SELECT RAISE(FAIL,'synthetic partial queue failure'); END;
          """)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
        XCTAssertEqual(try service.store.reactions(shareID: made.id).count, 1)
        XCTAssertEqual(try events("reaction_sent").count, 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 0)
        XCTAssertTrue(service.reactionPushEnqueueFailed)
    }

    func testPushBridgeSaturatedQueueStillAcceptsOtherSharesReaction() throws {
        _ = try setupPushBridge(queueLimit: 1)
        let a = try makeReadyShare(), b = try makeReadyShare()
        for made in [a, b] {
            XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
            XCTAssertEqual(try service.store.reactions(shareID: made.id).count, 1)
        }
        XCTAssertEqual(try events("reaction_sent").count, 2)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 1)
        XCTAssertFalse(service.reactionPushEnqueueFailed)
    }

    func testPushBridgeRevocationBeforeDispatchRejectsSendAndRetiresJob() async throws {
        _ = try setupPushBridge()
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
        XCTAssertEqual(request("DELETE", "/v1/share/shares/\(made.id)", secret: secret).status, 204)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 0,
                       "revocation cancels before any dispatcher can run")
        clock.advance(61)
        let provider = ServicePushProvider()
        let ran = try await service.makeReactionPushDispatcher(provider: provider).runOnce()
        let sends = await provider.sends
        XCTAssertFalse(ran); XCTAssertEqual(sends, 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 0)
    }

    func testPushBridgeLeasedDeviceOptOutRotationAndExpiryInvalidateAdmission() throws {
        let push = try setupPushBridge()
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
        clock.advance(61)
        let now = Int64(clock.now.timeIntervalSince1970) * 1000
        let lease = try XCTUnwrap(push.lease(now: now))
        XCTAssertTrue(try service.admitReactionPush(lease))
        clock.advance(31)
        XCTAssertFalse(try service.admitReactionPush(lease), "a cached lease must not outlive its deadline")
        clock.advance(-31)
        XCTAssertTrue(try service.admitReactionPush(lease))
        try push.register(owner: lease.owner, deviceID: lease.deviceID, token: Data("rotated-synthetic-token".utf8),
            topic: lease.topic, environment: lease.environment, now: now)
        XCTAssertFalse(try service.admitReactionPush(lease), "rotation invalidates even a prepared lease")
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "🔥"]).status, 204)
        clock.advance(61)
        let current = try XCTUnwrap(push.lease(now: now + 61_000))
        XCTAssertTrue(try service.admitReactionPush(current))
        try push.optOut(owner: current.owner, deviceID: current.deviceID)
        XCTAssertFalse(try service.admitReactionPush(current))
    }

    func testPushBridgeCommitFailureRollsBackAcceptedReactionEventAndQueuedJob() throws {
        _ = try setupPushBridge()
        let made = try makeReadyShare()
        // Enable a deferred constraint only in this fault fixture: the existing service
        // schema does not depend on SQLite foreign-key enforcement being enabled.
        try service.store.database.execute("PRAGMA foreign_keys=ON")
        XCTAssertEqual(try service.store.database.scalar("PRAGMA foreign_keys"), 1)
        try service.store.database.execute("""
          CREATE TABLE push_commit_guard(share_id TEXT REFERENCES shares(id) DEFERRABLE INITIALLY DEFERRED);
          CREATE TRIGGER fail_push_commit AFTER INSERT ON reaction_push_jobs
          BEGIN INSERT INTO push_commit_guard VALUES('synthetic-missing-share'); END;
          """)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 500)
        XCTAssertEqual(try service.store.reactions(shareID: made.id).count, 0)
        XCTAssertEqual(try events("reaction_sent").count, 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM push_commit_guard"), 0)
    }

    func testPushBridgeProtectionKeyChangeFailsClosedBeforeUnexpiredAdmission() throws {
        let push = try setupPushBridge()
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
        clock.advance(61)
        let lease = try XCTUnwrap(push.lease(now: Int64(clock.now.timeIntervalSince1970) * 1000))
        XCTAssertTrue(try service.admitReactionPush(lease))
        push.policy = try ReactionPushPolicy(enabled: true, key: Data(repeating: 0x99, count: 32),
            topics: [lease.topic: lease.environment])
        XCTAssertFalse(try service.admitReactionPush(lease))
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 1)
    }

    func testPushBridgeProviderPauseInvalidatesAlreadyPreparedLeaseUntilExplicitResume() throws {
        let push = try setupPushBridge()
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
        clock.advance(61)
        let lease = try XCTUnwrap(push.lease(now: Int64(clock.now.timeIntervalSince1970) * 1000))
        XCTAssertTrue(try service.admitReactionPush(lease))
        try service.store.database.execute("INSERT OR REPLACE INTO reaction_push_meta VALUES('paused',1)")
        XCTAssertFalse(try service.admitReactionPush(lease), "prepared work cannot bypass a later provider pause")
        try push.resumeProviderAfterConfigurationFix()
        XCTAssertTrue(try service.admitReactionPush(lease))
    }

    func testPushBridgeDefaultOffRestartSweepsExpiredWorkWithoutKeyAndPeriodicTraffic() throws {
        _ = try setupPushBridge()
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 1)
        let configuration = service.config
        let ownClock = clock!
        service = nil // release the enabled owner before reopening its private synthetic DB
        clock.advance(7200)
        service = try ShareService(config: configuration, clock: { ownClock.now })
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 0,
                       "startup must clean expired work even with no key, provider or traffic")
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 1)
        XCTAssertFalse(try XCTUnwrap(service.reactionPushStore).policy.enabled)
        XCTAssertNil(service.reactionPushStore?.policy.key)
        clock.advance(31 * 86400)
        _ = try service.sweep()
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_registration_updates"), 0)
    }

    func testPushBridgeProviderRunsOutsideServiceLockAndFinishesExactJob() async throws {
        _ = try setupPushBridge()
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
        clock.advance(61)
        let ownService = service!
        let provider = ServicePushProvider { _ in
            // This deadlocks if a provider call retains the service's request lock.
            let response = ownService.handle(.init(method: "GET", path: "/health", query: [:], headers: [:], body: Data()))
            guard response.status == 200 else { throw ReactionPushFailure.invalid }
            return .accepted
        }
        let ran = try await service.makeReactionPushDispatcher(provider: provider).runOnce()
        let sends = await provider.sends
        XCTAssertTrue(ran); XCTAssertEqual(sends, 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 0)
    }
}

// Exercise the actual authenticated plan/apply operator boundary, not direct overlay writes.
extension ShareEnforcementTests {
    private func enablePushBridge() throws {
        let configuration = service.config
        let ownClock = clock!
        service = try ShareService(config: configuration,
            reactionPushPolicy: ReactionPushPolicy(enabled: true, key: Data(repeating: 0x42, count: 32),
                topics: ["io.tonebox.baton.tests": .sandbox]), clock: { ownClock.now })
        let push = try XCTUnwrap(service.reactionPushStore)
        let digest = try XCTUnwrap(service.sharer(bearer: owner)).digest
        try push.register(owner: digest, deviceID: "11111111-1111-1111-1111-111111111111",
            token: Data("synthetic-operator-push-token".utf8), topic: "io.tonebox.baton.tests",
            environment: .sandbox, now: Int64(clock.now.timeIntervalSince1970) * 1000)
    }
    private func reactForPush(_ id: String) throws {
        XCTAssertEqual(send("POST", "/v1/share/p/\(id)/reactions", body: Data(#"{"emoji":"❤️"}"#.utf8)).status, 204)
    }
    private func jobs() throws -> Int64 {
        try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs")
    }

    func testPushBridgeDisableThenRestoreCannotReplayPreHoldNotification() async throws {
        try enablePushBridge()
        let id = try makeShare()
        try reactForPush(id)
        XCTAssertEqual(try jobs(), 1)
        XCTAssertEqual(try apply(.disableShare, id: id).outcome, "applied")
        XCTAssertEqual(try jobs(), 0, "disable cancels queued work inside the operator transaction")
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "applied")
        clock.advance(61)
        let provider = ServicePushProvider()
        let ran = try await service.makeReactionPushDispatcher(provider: provider).runOnce()
        let sends = await provider.sends
        XCTAssertFalse(ran); XCTAssertEqual(sends, 0)
        try reactForPush(id)
        XCTAssertEqual(try jobs(), 1, "a fresh post-restoration reaction may create new work")
        _ = try apply(.disableShare, id: id) // exercises UPDATE of the existing overlay
        XCTAssertEqual(try jobs(), 0)
    }

    func testPushBridgeSuspensionCancelsAllOwnerJobsAndUnsuspendNeverResurrectsThem() async throws {
        try enablePushBridge()
        let a = try makeShare(), b = try makeShare()
        try reactForPush(a); try reactForPush(b)
        XCTAssertEqual(try jobs(), 2)
        _ = try apply(.suspendSharer, id: a)
        XCTAssertEqual(try jobs(), 0)
        _ = try apply(.unsuspendSharer, id: a)
        _ = try apply(.restoreShare, id: a)
        _ = try apply(.restoreShare, id: b)
        clock.advance(61)
        let provider = ServicePushProvider()
        let ran = try await service.makeReactionPushDispatcher(provider: provider).runOnce()
        let sends = await provider.sends
        XCTAssertFalse(ran); XCTAssertEqual(sends, 0); XCTAssertEqual(try jobs(), 0)
        try reactForPush(a)
        XCTAssertEqual(try jobs(), 1)
        _ = try apply(.suspendSharer, id: a) // exercises UPDATE of existing suspension
        XCTAssertEqual(try jobs(), 0)
    }

    func testPushBridgeDefaultOffRestartCancelsUnexpiredLegacyHeldJobWithoutDecryptingToken() throws {
        try enablePushBridge()
        let id = try makeShare()
        _ = try apply(.disableShare, id: id)
        let push = try XCTUnwrap(service.reactionPushStore)
        let record = try XCTUnwrap(service.store.share(id: id))
        let milliseconds = Int64(clock.now.timeIntervalSince1970) * 1000
        try service.store.database.transaction {
            _ = try push.enqueueWithinReactionTransaction(owner: record.sharerDigest, shareID: id,
                shareExpiresAt: record.expiresAt * 1000, now: milliseconds)
        }
        XCTAssertEqual(try jobs(), 1, "pre-hook legacy row is deliberately present and unexpired")
        let configuration = service.config
        let ownClock = clock!
        service = nil
        service = try ShareService(config: configuration, clock: { ownClock.now })
        XCTAssertEqual(try jobs(), 0, "cleanup must suppress legacy held work even with collection disabled")
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 1)
        XCTAssertFalse(try XCTUnwrap(service.reactionPushStore).policy.enabled)
        XCTAssertNil(service.reactionPushStore?.policy.key)
    }

    func testPushBridgeOperatorRollbackRestoresNotificationWithUnchangedShare() throws {
        try enablePushBridge()
        let id = try makeShare()
        try reactForPush(id)
        let reviewed = try plan(.disableShare, id: id)
        try service.store.database.execute("""
          CREATE TRIGGER fail_operator_receipt AFTER INSERT ON enforcement_operations
          BEGIN SELECT RAISE(ABORT,'synthetic operator receipt failure'); END;
          """)
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).status, 500)
        XCTAssertEqual(try jobs(), 1, "a failed operator transaction cannot partially cancel a notification")
        XCTAssertFalse(try service.store.isEnforced(XCTUnwrap(service.store.share(id: id))))
        try service.store.database.execute("DROP TRIGGER fail_operator_receipt")
        _ = try apply(.disableShare, id: id)
        XCTAssertEqual(try jobs(), 0)
    }
}
