import Foundation
import XCTest
@testable import BatonShareServer

final class ShareReactionPushTests: XCTestCase {
    let owner = String(repeating: "a", count: 64)
    let share = "AAAAAAAAAAAAAAAAAAAAAA"
    let now: Int64 = 1_000_000
    let topic = "io.tonebox.baton.tests"
    let device = "11111111-1111-1111-1111-111111111111"
    let token = Data("synthetic-variable-length-device-token-never-real".utf8)
    let key = Data(repeating: 0x42, count: 32)
    var root: URL!
    var db: SQLiteDatabase!
    var store: ReactionPushStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-push-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("push.sqlite")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        db = try SQLiteDatabase(path: file.path)
        store = try ReactionPushStore(database: db, policy: enabledPolicy())
    }
    override func tearDownWithError() throws {
        store = nil; db = nil; try FileManager.default.removeItem(at: root)
    }
    private func enabledPolicy(queue: Int = 1000, devices: Int = 4) throws -> ReactionPushPolicy {
        try ReactionPushPolicy(enabled: true, key: key, topics: [topic: .sandbox], devicesPerOwner: devices, queueLimit: queue)
    }
    @discardableResult
    private func register(_ at: Int64? = nil) throws -> String {
        try store.register(owner: owner, deviceID: device, token: token, topic: topic, environment: .sandbox, now: at ?? now)
    }
    private func enqueue(_ id: String? = nil, at: Int64? = nil, expiry: Int64? = nil) throws {
        let time = at ?? now
        try db.transaction { try store.enqueueWithinReactionTransaction(owner: owner, shareID: id ?? share,
            shareExpiresAt: expiry ?? time + 10_000_000, now: time) }
    }
    private func count(_ table: String) throws -> Int64 { try db.scalar("SELECT COUNT(*) FROM \(table)") }

    func testDefaultOffRejectsRegistrationAndDoesNotCollectJobs() throws {
        store = try ReactionPushStore(database: db)
        XCTAssertThrowsError(try register())
        try enqueue()
        XCTAssertNil(try store.lease(now: now + 60_000))
        XCTAssertEqual(try count("reaction_push_devices"), 0)
        XCTAssertEqual(try count("reaction_push_jobs"), 0)
        XCTAssertThrowsError(try ReactionPushPolicy(enabled: true, topics: [topic: .sandbox]))
    }

    func testProtectedTokenRoundTripAndGenericPayload() throws {
        try register(); try enqueue()
        let row = try XCTUnwrap(db.query("SELECT sealed_token,token_hash FROM reaction_push_devices").first)
        XCTAssertNotEqual(row["sealed_token"]?.text, token.base64EncodedString())
        XCTAssertFalse(try Data(contentsOf: root.appendingPathComponent("push.sqlite")).contains(token))
        let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        XCTAssertEqual(lease.token, token)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: lease.payload) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["aps", "baton"])
        XCTAssertEqual((payload["aps"] as? [String: String])?["alert"], "Someone reacted to your shared song.")
        let route = try XCTUnwrap(payload["baton"] as? [String: Any])
        XCTAssertEqual(Set(route.keys), ["v", "route", "shareID"])
        XCTAssertEqual(route["route"] as? String, "shared-links")
        XCTAssertEqual(route["shareID"] as? String, share)
        XCTAssertLessThanOrEqual(lease.collapseID.utf8.count, 64)
        XCTAssertEqual(String(describing: lease), "ReactionPushLease(redacted)")
        XCTAssertEqual(String(reflecting: lease), "ReactionPushLease(redacted)")
        XCTAssertLessThanOrEqual(lease.deadline, lease.expiration)
    }

    func testMissingOrWrongProtectionKeyDoesNotEraseMaterialOrLease() throws {
        try register(); try enqueue()
        store.policy = try ReactionPushPolicy(enabled: true, key: Data(repeating: 2, count: 32), topics: [topic: .sandbox])
        XCTAssertThrowsError(try store.lease(now: now + 60_000))
        XCTAssertEqual(try count("reaction_push_devices"), 1)
        XCTAssertEqual(try db.scalar("SELECT attempts FROM reaction_push_jobs"), 0)
    }

    func testTokenAADPreventsRegistrationSwapping() throws {
        try register(); try enqueue()
        try db.run("UPDATE reaction_push_devices SET revision='changed'")
        try db.run("UPDATE reaction_push_jobs SET revision='changed'")
        XCTAssertThrowsError(try store.lease(now: now + 60_000))
    }

    func testVariableTokenLengthTopicEnvironmentAndDeviceBounds() throws {
        for size in [1, 17, 256, 1024] {
            _ = try store.register(owner: owner, deviceID: device, token: Data(repeating: 7, count: size),
                                   topic: topic, environment: .sandbox, now: now)
        }
        XCTAssertThrowsError(try store.register(owner: owner, deviceID: device, token: Data(), topic: topic, environment: .sandbox, now: now))
        XCTAssertThrowsError(try store.register(owner: owner, deviceID: device, token: Data(repeating: 7, count: 1025), topic: topic, environment: .sandbox, now: now))
        XCTAssertThrowsError(try store.register(owner: owner, deviceID: device, token: token, topic: "other.topic", environment: .sandbox, now: now))
        XCTAssertThrowsError(try store.register(owner: owner, deviceID: device, token: token, topic: topic, environment: .production, now: now))
        store.policy = try enabledPolicy(devices: 1)
        XCTAssertThrowsError(try store.register(owner: owner, deviceID: UUID().uuidString, token: token, topic: topic, environment: .sandbox, now: now))
    }

    func testRegistrationUpdateRateSurvivesOptOutAndExpiresAtDayBoundary() throws {
        for _ in 0 ..< 64 { try register(); try store.optOut(owner: owner, deviceID: device) }
        XCTAssertThrowsError(try register())
        XCTAssertEqual(try count("reaction_push_devices"), 0)
        try register(86_400_000)
        XCTAssertEqual(try count("reaction_push_devices"), 1)
    }

    func testGlobalRegistrationAndProtectedByteBoundsRejectBeforePersistence() throws {
        store.policy = try ReactionPushPolicy(enabled: true, key: key, topics: [topic: .sandbox], totalDevices: 1)
        try register()
        XCTAssertThrowsError(try store.register(owner: String(repeating: "b", count: 64), deviceID: UUID().uuidString,
            token: Data([1]), topic: topic, environment: .sandbox, now: now))
        XCTAssertEqual(try count("reaction_push_devices"), 1)
        XCTAssertEqual(try count("reaction_push_registration_updates"), 1)
        store.policy = try ReactionPushPolicy(enabled: true, key: key, topics: [topic: .sandbox], protectedBytes: 256)
        XCTAssertThrowsError(try store.register(owner: owner, deviceID: device,
            token: Data(repeating: 1, count: 1024), topic: topic, environment: .sandbox, now: now))
        XCTAssertEqual(try count("reaction_push_devices"), 1)
        XCTAssertEqual(try db.scalar("SELECT updates FROM reaction_push_registration_updates"), 1)
        try enqueue()
        XCTAssertEqual(try store.lease(now: now + 60_000)?.token, token)
    }

    func testOptOutDeletesDeviceAndQueuedOrLeasedJobsEvenWhenDisabled() throws {
        try register(); try enqueue(); let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        store.policy = try ReactionPushPolicy()
        try store.optOut(owner: owner, deviceID: device)
        try store.complete(lease, result: .accepted, now: now + 60_001)
        XCTAssertEqual(try count("reaction_push_devices"), 0); XCTAssertEqual(try count("reaction_push_jobs"), 0)
    }

    func testRefreshUsesNewRevisionAndOld410CannotEraseIt() throws {
        let old = try register(); try enqueue()
        let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        let new = try register(now + 60_001)
        XCTAssertNotEqual(old, new)
        try store.complete(lease, result: .inactive(timestampMilliseconds: now + 60_000), now: now + 60_002)
        XCTAssertEqual(try count("reaction_push_devices"), 1)
        XCTAssertEqual(try db.query("SELECT revision FROM reaction_push_devices").first?["revision"]?.text, new)
    }

    func test410TimestampOlderThanAcceptanceKeepsCurrentRegistration() throws {
        try register(); try enqueue(); let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        try store.complete(lease, result: .inactive(timestampMilliseconds: now - 1), now: now + 60_001)
        XCTAssertEqual(try count("reaction_push_devices"), 1); XCTAssertEqual(try count("reaction_push_jobs"), 0)
    }

    func testSameTokenRebindMovesRegistrationAndCancelsPriorOwnerWork() throws {
        try register(); try enqueue()
        let old = try XCTUnwrap(store.lease(now: now + 60_000))
        let newOwner = String(repeating: "b", count: 64)
        let revision = try store.register(owner: newOwner, deviceID: device, token: token,
            topic: topic, environment: .sandbox, now: now + 60_001)
        try store.complete(old, result: .invalidToken, now: now + 60_002)
        XCTAssertEqual(try count("reaction_push_devices"), 1)
        XCTAssertEqual(try count("reaction_push_jobs"), 0)
        let row = try XCTUnwrap(db.query("SELECT owner,revision FROM reaction_push_devices").first)
        XCTAssertEqual(row["owner"]?.text, newOwner); XCTAssertEqual(row["revision"]?.text, revision)
    }

    func test410AtAcceptanceRetiresOnlyFailedRevision() throws {
        try register(); try enqueue(); let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        try store.complete(lease, result: .inactive(timestampMilliseconds: now), now: now + 60_001)
        XCTAssertEqual(try count("reaction_push_devices"), 0); XCTAssertEqual(try count("reaction_push_jobs"), 0)
    }

    func testReactionTransactionRollbackIncludesOutbox() throws {
        try register()
        try db.execute("CREATE TABLE synthetic_reaction(id INTEGER PRIMARY KEY)")
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO synthetic_reaction VALUES(1)")
            try store.enqueueWithinReactionTransaction(owner: owner, shareID: share, shareExpiresAt: now + 5_000_000, now: now)
            throw ReactionPushFailure.invalid
        })
        XCTAssertEqual(try count("synthetic_reaction"), 0); XCTAssertEqual(try count("reaction_push_jobs"), 0)
        try db.transaction {
            try db.run("INSERT INTO synthetic_reaction VALUES(1)")
            try store.enqueueWithinReactionTransaction(owner: owner, shareID: share, shareExpiresAt: now + 5_000_000, now: now)
        }
        XCTAssertEqual(try count("synthetic_reaction"), 1); XCTAssertEqual(try count("reaction_push_jobs"), 1)
    }

    func testCoalescingDoesNotExtendAgeAndNewReactionDuringLeaseIsRetained() throws {
        try register(); try enqueue(); let expiry = try db.scalar("SELECT expires_at FROM reaction_push_jobs")
        for _ in 0 ..< 20 { try enqueue(at: now + 20_000) }
        XCTAssertEqual(try count("reaction_push_jobs"), 1)
        XCTAssertEqual(try db.scalar("SELECT expires_at FROM reaction_push_jobs"), expiry)
        let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        try enqueue(at: now + 60_001)
        try store.complete(lease, result: .accepted, now: now + 60_002)
        XCTAssertEqual(try count("reaction_push_jobs"), 1)
        XCTAssertEqual(try db.scalar("SELECT attempts FROM reaction_push_jobs"), 0)
        XCTAssertNil(try store.lease(now: now + 100_000))
        let next = try XCTUnwrap(store.lease(now: now + 120_002))
        XCTAssertGreaterThan(next.generation, lease.generation)
    }

    func testQueueCapacityDropsWorkWithoutThrowingOrGrowing() throws {
        store.policy = try enabledPolicy(queue: 1); try register(); try enqueue()
        try enqueue("AAAAAAAAAAAAAAAAAAAAAQ")
        XCTAssertEqual(try count("reaction_push_jobs"), 1)
    }

    func testExpiredCoalescingStartsFreshBoundedJobWithoutPeriodicSweep() throws {
        store.policy = try enabledPolicy(queue: 1)
        try register(); try enqueue()
        let oldID = try XCTUnwrap(db.query("SELECT id FROM reaction_push_jobs").first?["id"]?.text)
        let freshTime = now + store.policy.jobTTL + 1
        let shareExpiry = freshTime + 300_000
        try enqueue(at: freshTime, expiry: shareExpiry)
        let row = try XCTUnwrap(db.query("SELECT id,expires_at,generation FROM reaction_push_jobs").first)
        XCTAssertNotEqual(row["id"]?.text, oldID)
        XCTAssertEqual(row["expires_at"]?.int, shareExpiry)
        XCTAssertEqual(row["generation"]?.int, 1)
        XCTAssertEqual(try count("reaction_push_jobs"), 1)
        let lease = try XCTUnwrap(store.lease(now: freshTime + store.policy.coalesceDelay))
        XCTAssertEqual(lease.jobID, row["id"]?.text)
    }

    func testExpiredJobReplacementRollsBackWithCallerReactionTransaction() throws {
        try register(); try enqueue()
        let oldRows = try db.query("SELECT * FROM reaction_push_jobs")
        let freshTime = now + store.policy.jobTTL + 1
        var replacementObserved = false
        XCTAssertThrowsError(try db.transaction {
            let added = try store.enqueueWithinReactionTransaction(owner: owner, shareID: share,
                shareExpiresAt: freshTime + 300_000, now: freshTime)
            XCTAssertEqual(added, 1)
            let replacement = try db.query("SELECT * FROM reaction_push_jobs")
            XCTAssertNotEqual(replacement.first?["id"], oldRows.first?["id"])
            replacementObserved = true
            throw ReactionPushFailure.invalid
        }) { error in
            guard let failure = error as? ReactionPushFailure, case .invalid = failure else {
                return XCTFail("Expected the deliberate caller rollback, not an enqueue/transaction error")
            }
        }
        XCTAssertTrue(replacementObserved)
        XCTAssertEqual(try db.query("SELECT * FROM reaction_push_jobs"), oldRows)
    }

    func testChangedAllowlistDoesNotBlockAnotherEligibleTopic() throws {
        let otherTopic = "io.tonebox.baton.other-tests"
        let otherDevice = "22222222-2222-2222-2222-222222222222"
        for removedTopic in [true, false] {
            try store.optOut(owner: owner, deviceID: device)
            try store.optOut(owner: owner, deviceID: otherDevice)
            store.policy = try enabledPolicy()
            try register(); try enqueue()
            store.policy = try ReactionPushPolicy(enabled: true, key: key,
                topics: [topic: .sandbox, otherTopic: .production])
            try store.register(owner: owner, deviceID: otherDevice, token: Data([9]),
                topic: otherTopic, environment: .production, now: now + 1)
            try enqueue("AAAAAAAAAAAAAAAAAAAAAQ", at: now + 1)
            store.policy = try ReactionPushPolicy(enabled: true, key: key,
                topics: removedTopic ? [otherTopic: .production] : [topic: .production, otherTopic: .production])
            let lease = try XCTUnwrap(store.lease(now: now + 60_001))
            XCTAssertEqual(lease.topic, otherTopic)
            XCTAssertEqual(lease.environment, .production)
            try store.complete(lease, result: .accepted, now: now + 60_002)
            XCTAssertNil(try store.lease(now: now + 60_003))
        }
    }

    func testCrashRecoveryDelaysUnknownDeliveryAndFencesLateResults() throws {
        try register(); try enqueue(); let old = try XCTUnwrap(store.lease(now: now + 60_000))
        let reopened = try SQLiteDatabase(path: root.appendingPathComponent("push.sqlite").path)
        let resumed = try ReactionPushStore(database: reopened, policy: enabledPolicy())
        XCTAssertNil(try resumed.lease(now: old.deadline + 1))
        XCTAssertNil(try resumed.lease(now: old.deadline + 899_999))
        let new = try XCTUnwrap(resumed.lease(now: old.deadline + 900_000))
        XCTAssertNotEqual(old.leaseID, new.leaseID)
        try resumed.complete(old, result: .invalidToken, now: old.deadline + 900_001)
        XCTAssertEqual(try count("reaction_push_devices"), 1)
        XCTAssertEqual(try count("reaction_push_jobs"), 1)
        try resumed.complete(new, result: .accepted, now: old.deadline + 900_002)
        XCTAssertEqual(try count("reaction_push_jobs"), 0)
    }

    func testExpiredLeaseCannotCommitEvenBeforeAnotherWorkerRecovers() throws {
        try register(); try enqueue(); let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        try store.complete(lease, result: .accepted, now: lease.deadline + 1)
        XCTAssertEqual(try count("reaction_push_jobs"), 1)
        XCTAssertNil(try store.lease(now: lease.deadline + 2))
    }

    func testRetryDelayAttemptAndJobAgeAreBounded() throws {
        try register(); try enqueue(); let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        try store.complete(lease, result: .retry(delayMilliseconds: 900_000), now: now + 60_001)
        XCTAssertNil(try store.lease(now: now + 960_000))
        XCTAssertNotNil(try store.lease(now: now + 960_001))
        try store.sweep(now: now + 3_600_000)
        XCTAssertEqual(try count("reaction_push_jobs"), 0)
    }

    func testProviderPausePersistsRestartAndRequiresExplicitResume() throws {
        try register(); try enqueue(); let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        try store.complete(lease, result: .providerPaused, now: now + 60_001)
        try enqueue("AAAAAAAAAAAAAAAAAAAAAQ", at: now + 60_001)
        let resumed = try ReactionPushStore(database: db, policy: enabledPolicy())
        XCTAssertNil(try resumed.lease(now: now + 500_000))
        XCTAssertEqual(try count("reaction_push_devices"), 1)
        try resumed.resumeProviderAfterConfigurationFix()
        XCTAssertNotNil(try resumed.lease(now: now + 500_000))
    }

    func testFourthLiveAttemptIsPreservedAndRetryBudgetThenExhausts() throws {
        try register(); try enqueue(); var time = now + 60_000
        for attempt in 1 ... 4 {
            let lease = try XCTUnwrap(store.lease(now: time))
            XCTAssertEqual(try db.scalar("SELECT attempts FROM reaction_push_jobs"), Int64(attempt))
            try store.sweep(now: time + 1)
            XCTAssertEqual(try count("reaction_push_jobs"), 1)
            try store.complete(lease, result: .retry(delayMilliseconds: 60_000), now: time + 2)
            if attempt < 4 { time = try db.scalar("SELECT due_at FROM reaction_push_jobs") }
        }
        XCTAssertEqual(try count("reaction_push_jobs"), 0)
    }

    func testExpiryAndLifecycleCancellationRemoveJobs() throws {
        try register(); try enqueue(expiry: now + 50_000)
        XCTAssertNil(try store.lease(now: now + 60_000))
        try enqueue(); try store.cancel(shareID: share)
        XCTAssertEqual(try count("reaction_push_jobs"), 0)
        try store.sweep(now: now + store.policy.registrationTTL)
        XCTAssertEqual(try count("reaction_push_devices"), 0)
    }

    func testAppleResponseClassificationBoundsAndTimestampUnits() {
        func result(_ status: Int, _ json: String) -> ReactionPushResult {
            .classify(status: status, body: Data(json.utf8))
        }
        XCTAssertEqual(result(200, ""), .accepted)
        XCTAssertEqual(result(410, "{\"reason\":\"Unregistered\",\"timestamp\":1700000000123}"), .inactive(timestampMilliseconds: 1_700_000_000_123))
        XCTAssertEqual(result(410, "{\"reason\":\"Unregistered\",\"timestamp\":true}"), .discarded)
        XCTAssertEqual(result(410, "{\"reason\":\"Unregistered\"}"), .discarded)
        XCTAssertEqual(result(400, "{\"reason\":\"BadDeviceToken\"}"), .invalidToken)
        XCTAssertEqual(result(400, "{\"reason\":\"DeviceTokenNotForTopic\"}"), .providerPaused)
        XCTAssertEqual(result(403, "{\"reason\":\"Forbidden\"}"), .providerPaused)
        XCTAssertEqual(result(429, "{\"reason\":\"TooManyProviderTokenUpdates\"}"), .providerPaused)
        XCTAssertEqual(result(429, "{\"reason\":\"TooManyRequests\"}"), .retry(delayMilliseconds: 60_000))
        for status in [500, 503] { XCTAssertEqual(result(status, "{}"), .retry(delayMilliseconds: 900_000)) }
        XCTAssertEqual(ReactionPushResult.classify(status: 400, body: Data(repeating: 0, count: 4097)), .providerPaused)
    }

    func testDispatcherRechecksEligibilityAndProviderRunsOutsideOwnerLock() async throws {
        try register(); try enqueue()
        let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        let hooks = PushTestHooks(lease)
        let provider = PushTestProvider(hooks: hooks)
        let dispatcher = ReactionPushDispatcher(provider: provider,
            prepare: { hooks.prepare() }, admit: { hooks.admit($0) }, finish: { hooks.finish($0, $1) })
        let sent = try await dispatcher.runOnce()
        XCTAssertTrue(sent)
        XCTAssertEqual(hooks.results(), [.accepted])
        XCTAssertTrue(hooks.providerHadUnlockedAccess())

        let denied = PushTestHooks(lease, eligible: false)
        let deniedDispatcher = ReactionPushDispatcher(provider: PushTestProvider(hooks: denied),
            prepare: { denied.prepare() }, admit: { denied.admit($0) }, finish: { denied.finish($0, $1) })
        let deniedSent = try await deniedDispatcher.runOnce()
        XCTAssertFalse(deniedSent); XCTAssertEqual(denied.results(), [.discarded])
        XCTAssertFalse(denied.providerHadUnlockedAccess())
    }

    func testDispatcherAllowsOnlyOneLiveAttemptAndUnknownFailureIsDelayed() async throws {
        try register(); try enqueue()
        let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        let hooks = PushTestHooks(lease)
        let provider = BlockingPushTestProvider()
        let dispatcher = ReactionPushDispatcher(provider: provider,
            prepare: { hooks.prepare() }, admit: { hooks.admit($0) }, finish: { hooks.finish($0, $1) })
        let first = Task { try await dispatcher.runOnce() }
        await provider.waitUntilStarted()
        let second = try await dispatcher.runOnce()
        XCTAssertFalse(second)
        await provider.fail()
        let ran = try await first.value
        XCTAssertTrue(ran)
        XCTAssertEqual(hooks.results(), [.retry(delayMilliseconds: 900_000)])
        let attempts = await provider.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testCancellationWhileAdmissionSuspendsNeverStartsProvider() async throws {
        try register(); try enqueue()
        let lease = try XCTUnwrap(store.lease(now: now + 60_000))
        let hooks = PushTestHooks(lease)
        let admission = SuspendedPushTestAdmission()
        let provider = CountingPushTestProvider()
        let dispatcher = ReactionPushDispatcher(provider: provider,
            prepare: { hooks.prepare() }, admit: { _ in await admission.admit() },
            finish: { hooks.finish($0, $1) })
        let attempt = Task { try await dispatcher.runOnce() }
        await admission.waitUntilSuspended()
        attempt.cancel()
        await admission.allow()
        let sent = try await attempt.value
        XCTAssertFalse(sent)
        let sends = await provider.sends
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(hooks.results(), [.discarded])
        XCTAssertEqual(hooks.finishedLeaseIDs(), [lease.leaseID])
    }
}

private final class PushTestHooks: @unchecked Sendable {
    let lock = NSLock()
    private var lease: ReactionPushLease?
    private let eligible: Bool
    private var finished: [ReactionPushResult] = []
    private var finishedIDs: [String] = []
    private var unlocked = false
    init(_ lease: ReactionPushLease, eligible: Bool = true) { self.lease = lease; self.eligible = eligible }
    func prepare() -> ReactionPushLease? { lock.lock(); defer { lock.unlock() }; let value = lease; lease = nil; return value }
    func admit(_ lease: ReactionPushLease) -> Bool { lock.lock(); defer { lock.unlock() }; return eligible }
    func finish(_ lease: ReactionPushLease, _ result: ReactionPushResult) { lock.lock(); defer { lock.unlock() }; finished.append(result); finishedIDs.append(lease.leaseID) }
    func observeProvider() -> Bool {
        guard lock.try() else { return false }
        unlocked = true; lock.unlock(); return true
    }
    func results() -> [ReactionPushResult] { lock.lock(); defer { lock.unlock() }; return finished }
    func finishedLeaseIDs() -> [String] { lock.lock(); defer { lock.unlock() }; return finishedIDs }
    func providerHadUnlockedAccess() -> Bool { lock.lock(); defer { lock.unlock() }; return unlocked }
}

private actor SuspendedPushTestAdmission {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func admit() async -> Bool {
        await withCheckedContinuation {
            continuation = $0
            started?.resume(); started = nil
        }
    }
    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func allow() { continuation?.resume(returning: true); continuation = nil }
}
private actor CountingPushTestProvider: ReactionPushProvider {
    var sends = 0
    func send(_ lease: ReactionPushLease) async throws -> ReactionPushResult {
        sends += 1
        return .accepted
    }
}
private struct PushTestProvider: ReactionPushProvider {
    let hooks: PushTestHooks
    func send(_ lease: ReactionPushLease) async throws -> ReactionPushResult {
        guard hooks.observeProvider() else { throw ReactionPushFailure.invalid }
        return .accepted
    }
}
private actor BlockingPushTestProvider: ReactionPushProvider {
    var attempts = 0
    private var continuation: CheckedContinuation<ReactionPushResult, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if attempts > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func send(_ lease: ReactionPushLease) async throws -> ReactionPushResult {
        attempts += 1; started?.resume(); started = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func fail() { continuation?.resume(throwing: ReactionPushFailure.invalid); continuation = nil }
}
