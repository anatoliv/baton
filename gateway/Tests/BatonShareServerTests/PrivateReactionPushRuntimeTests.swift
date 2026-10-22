import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonShareServer

final class PrivateReactionPushRuntimeTests: XCTestCase {
    private let generation = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func inactive(_ directory: URL) -> PrivateReactionPushConfiguration {
        .init(directory: directory, keyID: "", teamID: "", environment: .sandbox,
            signingKeySHA256: "", storageKeySHA256: "", custodySHA256: "", generation: "")
    }

    func testInactiveStartupDoesNotRequireOrCreateProtectedInputsOrRecipients() async throws {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(try PrivateReactionPushLoader().load(inactive(absent)))
        let runtime = try PrivateReactionPushRuntime(configuration: inactive(absent),
            makeRecipients: { _, _ in XCTFail("Inactive startup created recipients"); throw FixtureFailure.stop })
        try await runtime.runUntilCancelled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    /// Fixed scalar 1 is a public mathematical fixture, never an Apple/owner credential.
    private func fixture() throws -> (URL, PrivateReactionPushConfiguration, Data, Data) {
        // The loader walks every component with O_NOFOLLOW, so the root must be symlink-free:
        // macOS's /tmp is a link to /private/tmp, and Linux has no /private.
        #if canImport(Darwin)
        let temporary = "/private/tmp"
        #else
        let temporary = "/tmp"
        #endif
        let root = URL(fileURLWithPath: temporary)
            .appendingPathComponent("baton-push-loader-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let storage = Data(repeating: 0xA5, count: 32)
        let signing = Data(try P256.Signing.PrivateKey(rawRepresentation:
            Data(repeating: 0, count: 31) + Data([1])).pemRepresentation.utf8)
        let custody = try JSONSerialization.data(withJSONObject: [
            "version": 1, "generation": generation,
            "storageKeySHA256": digest(storage), "signingKeySHA256": digest(signing),
            "topic": "io.tonebox.baton", "environment": "sandbox",
            "registrationTTLMilliseconds": 2_592_000_000, "jobTTLMilliseconds": 3_600_000,
            "backupDecisionReference": "synthetic-backup", "retentionDecisionReference": "synthetic-retention",
            "registrationIntegrityReference": "synthetic-integrity",
            "failureCoverageReference": "synthetic-failure", "restoreReconciled": true,
        ], options: .sortedKeys)
        for (name, bytes) in [("storage-key.bin", storage), ("apns-key.p8", signing), ("custody.json", custody)] {
            try bytes.write(to: root.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: root.appendingPathComponent(name).path)
        }
        let config = PrivateReactionPushConfiguration(enabled: true, directory: root,
            keyID: "TESTKEY123", teamID: "TESTTEAM12", environment: .sandbox,
            signingKeySHA256: digest(signing), storageKeySHA256: digest(storage),
            custodySHA256: digest(custody), generation: generation)
        return (root, config, storage, signing)
    }

    func testPinnedProtectedInputsReloadWithoutRegenerationAndRemainRedacted() throws {
        let (root, config, storage, signing) = try fixture()
        let first = try XCTUnwrap(PrivateReactionPushLoader().load(config))
        let restart = try XCTUnwrap(PrivateReactionPushLoader().load(config))
        XCTAssertEqual(first.storageKey, storage)
        XCTAssertEqual(restart.signingKey.publicKey.rawRepresentation, first.signingKey.publicKey.rawRepresentation)
        XCTAssertEqual(String(describing: first), "PrivateReactionPushMaterial(redacted)")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apns-key.p8")), signing)
    }

    func testWrongOrMissingKeyStopsStartupAndRetainsProtectedFiles() throws {
        let (root, config, storage, _) = try fixture()
        let path = root.appendingPathComponent("storage-key.bin")
        try Data(repeating: 0x5A, count: 32).write(to: path)
        XCTAssertThrowsError(try PrivateReactionPushLoader().load(config)) { error in
            XCTAssertEqual(String(describing: error), "Private reaction sender unavailable.")
        }
        XCTAssertEqual(try Data(contentsOf: path), Data(repeating: 0x5A, count: 32))
        try storage.write(to: path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("apns-key.p8"))
        XCTAssertThrowsError(try PrivateReactionPushLoader().load(config))
        XCTAssertEqual(try Data(contentsOf: path), storage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("custody.json").path))
    }

    func testReadableSymlinkOrHardlinkInputsNeverBecomeSigningAuthority() throws {
        let (root, config, _, _) = try fixture()
        let path = root.appendingPathComponent("apns-key.p8")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertThrowsError(try PrivateReactionPushLoader().load(config))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let original = root.appendingPathComponent("original.p8")
        try FileManager.default.moveItem(at: path, to: original)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: original)
        XCTAssertThrowsError(try PrivateReactionPushLoader().load(config))
        try FileManager.default.removeItem(at: path)
        try FileManager.default.linkItem(at: original, to: path)
        XCTAssertThrowsError(try PrivateReactionPushLoader().load(config))
    }

    func testUnreconciledRestoreOrChangedGenerationRefusesBeforeRecipientConstruction() throws {
        let (root, config, _, _) = try fixture()
        let path = root.appendingPathComponent("custody.json")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        json["restoreReconciled"] = false
        let bytes = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        try bytes.write(to: path)
        let restored = PrivateReactionPushConfiguration(enabled: true, directory: root,
            keyID: config.keyID, teamID: config.teamID, environment: config.environment,
            signingKeySHA256: config.signingKeySHA256, storageKeySHA256: config.storageKeySHA256,
            custodySHA256: digest(bytes), generation: config.generation)
        XCTAssertThrowsError(try PrivateReactionPushRuntime(configuration: restored,
            makeRecipients: { _, _ in XCTFail("Restore bypass reached recipients"); throw FixtureFailure.stop }))
        json["restoreReconciled"] = true
        json["generation"] = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let changed = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        try changed.write(to: path)
        let mismatch = PrivateReactionPushConfiguration(enabled: true, directory: root,
            keyID: config.keyID, teamID: config.teamID, environment: config.environment,
            signingKeySHA256: config.signingKeySHA256, storageKeySHA256: config.storageKeySHA256,
            custodySHA256: digest(changed), generation: config.generation)
        XCTAssertThrowsError(try PrivateReactionPushLoader().load(mismatch))
    }

    func testPrivateCurrentRecipientDenialFinishesDiscardedWithZeroProviderRequests() async throws {
        let (_, config, storage, _) = try fixture()
        let timestamp: Int64 = 1_790_000_000_000
        let recipients = DeniedPrivateRecipients(lease: ReactionPushLease(
            jobID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", leaseID: UUID().uuidString,
            owner: String(repeating: "a", count: 64), deviceID: UUID().uuidString,
            revision: UUID().uuidString, generation: 1, registeredAt: timestamp,
            shareID: "AAAAAAAAAAAAAAAAAAAAAA", topic: "io.tonebox.baton", environment: .sandbox,
            token: Data([1, 2, 3]), deadline: timestamp + 30_000, expiration: timestamp + 60_000))
        let transport = NoPrivateAPNsRequests()
        let runtime = try PrivateReactionPushRuntime(configuration: config, transport: transport,
            makeRecipients: { policy, generation in
                XCTAssertTrue(policy.enabled)
                XCTAssertEqual(policy.key, storage)
                XCTAssertEqual(policy.topics, ["io.tonebox.baton": .sandbox])
                XCTAssertEqual(generation, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
                return recipients
            }, clock: { Date(timeIntervalSince1970: Double(timestamp) / 1000) })
        let executed = try await runtime.runOnce()
        XCTAssertFalse(executed)
        let results = await recipients.results
        let requests = await transport.count
        XCTAssertEqual(results, [.discarded])
        XCTAssertEqual(requests, 0)
    }

    func testRecipientRestoreFailureDoesNotEscapeInStartupError() throws {
        let (_, config, _, _) = try fixture()
        XCTAssertThrowsError(try PrivateReactionPushRuntime(configuration: config,
            makeRecipients: { _, _ in throw FixtureFailure.stop })) { error in
                XCTAssertEqual(String(describing: error), "Private reaction sender unavailable.")
            }
    }
}

private enum FixtureFailure: Error { case stop }

private actor DeniedPrivateRecipients: PrivateReactionPushRecipients {
    let lease: ReactionPushLease
    var results: [ReactionPushResult] = []
    init(lease: ReactionPushLease) { self.lease = lease }
    func prepare() async throws -> ReactionPushLease? { lease }
    func admit(_ lease: ReactionPushLease) async throws -> Bool { false }
    func finish(_ lease: ReactionPushLease, result: ReactionPushResult) async throws { results.append(result) }
}

private actor NoPrivateAPNsRequests: APNsTransport {
    var count = 0
    func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> APNsResponse {
        count += 1
        throw FixtureFailure.stop
    }
}
