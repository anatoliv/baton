import BatonMCPProtocol
import BatonShareKit
@testable import BatonShareServer
import Crypto
import Foundation
import SwiftASN1
import X509
import XCTest

/// Synthetic keys/certificates only. Shared by the independent receipt suite.
enum AppAttestTestFixture {
    static let policy = AppAttestConfiguration(appID: "ABCDEFGHIJ.io.fixture.baton", environment: "development", audience: ShareLink.defaultBase.absoluteString,
        bundleVersions: ["123"], validationCategories: [1])
    static func root(_ key: P256.Signing.PrivateKey, now: Date, name: String = "Synthetic App Attest Root") throws -> Certificate {
        let dn = try DistinguishedName { CommonName(name) }
        return try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + 86400, issuer: dn, subject: dn,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 2))
                Critical(KeyUsage(keyCertSign: true))
            }, issuerPrivateKey: .init(key))
    }
    static func cbor(_ value: AppAttestCBOR) -> Data {
        func prefix(_ major: UInt8, _ count: Int) -> Data {
            if count < 24 { return Data([major << 5 | UInt8(count)]) }
            if count <= 255 { return Data([major << 5 | 24, UInt8(count)]) }
            if count <= 65535 { return Data([major << 5 | 25, UInt8(count >> 8), UInt8(count & 255)]) }
            return Data([major << 5 | 26, UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        }
        switch value {
        case let .integer(v): return v >= 0 ? prefix(0, Int(v)) : prefix(1, Int(-1-v))
        case let .bytes(v): return prefix(2, v.count) + v
        case let .text(v): return prefix(3, v.utf8.count) + Data(v.utf8)
        case let .array(v): return v.reduce(prefix(4, v.count)) { $0 + cbor($1) }
        case let .map(v): return v.reduce(prefix(5, v.count)) { $0 + cbor($1.key) + cbor($1.value) }
        case let .boolean(v): return Data([v ? 0xf5 : 0xf4])
        case .null: return Data([0xf6])
        }
    }
    static func assertion(key: P256.Signing.PrivateKey, appID: String = policy.policy.appID, counter: UInt32 = 1,
                          envelope: Data, extensions: AppAttestCBOR? = nil, extensionFlag: Bool = true) throws -> Data {
        var auth = Data(SHA256.hash(data: Data(appID.utf8)))
        auth.append(extensions == nil || !extensionFlag ? 0 : 0x80)
        var count = counter.bigEndian
        withUnsafeBytes(of: &count) { auth.append(contentsOf: $0) }
        if let extensions { auth.append(cbor(extensions)) }
        let signature = try key.signature(for: SHA256.hash(data: auth + Data(SHA256.hash(data: envelope))))
        return cbor(.map([.text("signature"): .bytes(signature.derRepresentation), .text("authenticatorData"): .bytes(auth)]))
    }
}

final class AppAttestTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func verifier() throws -> AppAttestVerifier {
        let root = try AppAttestTestFixture.root(P256.Signing.PrivateKey(), now: now)
        return .init(config: AppAttestTestFixture.policy, attestationRoot: root, receiptRoot: root)
    }
    func testAssertionValidatesSignatureBodyCounterAndAppIdentity() throws {
        let v = try verifier(), key = P256.Signing.PrivateKey(), envelope = Data("frozen-body+nonce".utf8)
        let assertion = try AppAttestTestFixture.assertion(key: key, envelope: envelope)
        XCTAssertEqual(try v.assertion(object: assertion, publicKey: key.publicKey.x963Representation, envelope: envelope, previousCounter: 0), 1)
        XCTAssertThrowsError(try v.assertion(object: assertion, publicKey: key.publicKey.x963Representation, envelope: Data("changed".utf8), previousCounter: 0))
        XCTAssertThrowsError(try v.assertion(object: assertion, publicKey: key.publicKey.x963Representation, envelope: envelope, previousCounter: 1))
        XCTAssertThrowsError(try v.assertion(object: assertion, publicKey: P256.Signing.PrivateKey().publicKey.x963Representation, envelope: envelope, previousCounter: 0))
        XCTAssertThrowsError(try v.assertion(object: AppAttestTestFixture.assertion(key: key, appID: "DIFFERENT.fixture", envelope: envelope), publicKey: key.publicKey.x963Representation, envelope: envelope, previousCounter: 0))
    }
    func testNewAuthenticatorExtensionsAreValidatedAndOlderProofsRemainDistinct() throws {
        let v = try verifier(), key = P256.Signing.PrivateKey(), envelope = Data("fixture".utf8)
        let good = AppAttestCBOR.map([.text("apple_validation_category_01"): .bytes(Data([1,0,0,0])), .text("apple_bundle_version_01"): .text("123")])
        XCTAssertEqual(try v.assertion(object: AppAttestTestFixture.assertion(key: key, envelope: envelope, extensions: good), publicKey: key.publicKey.x963Representation, envelope: envelope, previousCounter: 0), 1)
        // Apple's published iOS27 specimen appends a map while ED is clear.
        XCTAssertEqual(try v.assertion(object: AppAttestTestFixture.assertion(key: key, envelope: envelope, extensions: good, extensionFlag: false), publicKey: key.publicKey.x963Representation, envelope: envelope, previousCounter: 0), 1)
        for bad in [AppAttestCBOR.map([.text("apple_validation_category_01"): .integer(99), .text("apple_bundle_version_01"): .text("123")]),
                    .map([.text("apple_validation_category_01"): .integer(1), .text("apple_bundle_version_01"): .text("changed")]), .map([:])] {
            XCTAssertThrowsError(try v.assertion(object: AppAttestTestFixture.assertion(key: key, envelope: envelope, extensions: bad), publicKey: key.publicKey.x963Representation, envelope: envelope, previousCounter: 0))
        }
    }
    func testCBORRejectsDuplicatesIndefiniteLengthsTrailingBytesAndDepth() throws {
        for data in [Data([0xa2,0x61,0x61,1,0x61,0x61,2]), Data([0x9f,0xff]), Data([0xc0,1]), Data([1,1]),
                     Data(Array(repeating: UInt8(0x81), count: 9) + [0]), Data(repeating: 0, count: 65537)] {
            XCTAssertThrowsError(try AppAttestCBOR.decode(data))
        }
        XCTAssertEqual(try AppAttestCBOR.decode(Data([0xa1,0x20,0x01]))[-1]?.integer, 1)
    }
    func testConfigurationRequiresExplicitIdentityEnvironmentVersionsAndCategories() throws {
        XCTAssertNil(try ShareConfiguration.fromEnvironment([:]).appAttest)
        XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(["BATON_SHARE_APP_ATTEST_ENVIRONMENT":"production"]))
        let env = ["BATON_SHARE_APP_ATTEST_APP_ID":"ABCDEFGHIJ.io.fixture.baton", "BATON_SHARE_APP_ATTEST_ENVIRONMENT":"development",
                   "BATON_SHARE_APP_ATTEST_BUNDLE_VERSIONS":"123,124", "BATON_SHARE_APP_ATTEST_CATEGORIES":"1,2"]
        XCTAssertEqual(try ShareConfiguration.fromEnvironment(env).appAttest?.bundleVersions, ["123","124"])
        var bad = env; bad["BATON_SHARE_APP_ATTEST_APP_ID"] = "io.fixture.baton"
        XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(bad))
        bad = env; bad["BATON_SHARE_PUBLIC_BASE"] = "https://EXAMPLE.invalid:9443/"
        XCTAssertEqual(try ShareConfiguration.fromEnvironment(bad).appAttest?.policy.audience, "https://example.invalid:9443")
        bad["BATON_SHARE_PUBLIC_BASE"] = "http://example.invalid"
        XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(bad))
    }
    func testProofHeaderAndEnvelopeAreStableAndBindExactBytes() throws {
        let proof = ShareAttestationProof(keyID: "key", challengeID: "challenge", requestID: "request", assertion: "signature")
        XCTAssertEqual(try proof.headerValue(), try proof.headerValue())
        let challenge = ShareAttestationChallenge(id: "id", nonce: "nonce", expiresAt: "unused")
        let policy = AppAttestTestFixture.policy.policy
        let body = Data("{}".utf8)
        let envelope = ShareAttestationEnvelope.data(challenge: challenge, policy: policy, secret: "secret", requestID: "request", body: body)
        XCTAssertNotEqual(envelope, ShareAttestationEnvelope.data(challenge: challenge, policy: policy, secret: "secret", requestID: "request", body: Data("{ }".utf8)))
        XCTAssertNotEqual(envelope, ShareAttestationEnvelope.data(challenge: challenge, policy: policy, secret: "other", requestID: "request", body: body))
        var otherAudience = policy; otherAudience.audience = "https://other.invalid"
        XCTAssertNotEqual(envelope, ShareAttestationEnvelope.data(challenge: challenge, policy: otherAudience, secret: "secret", requestID: "request", body: body))
        XCTAssertEqual(ShareAttestationPolicy.origin(URL(string: "HTTPS://EXAMPLE.invalid:443/")!), "https://example.invalid")
        XCTAssertNil(ShareAttestationPolicy.origin(URL(string: "https://example.invalid/path")!))
        XCTAssertNil(ShareAttestationPolicy.origin(URL(string: "https://user:password@example.invalid")!))
    }
}

final class ShareAppAttestServiceTests: XCTestCase {
    var directory: URL!, clock: TestClock!, service: ShareService!, key: P256.Signing.PrivateKey!, keyID: String!
    let secret = ShareClient.newSecret()
    var config: ShareConfiguration!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("attest-service-\(UUID())")
        clock = TestClock(); key = P256.Signing.PrivateKey()
        keyID = Data(SHA256.hash(data: key.publicKey.x963Representation)).base64EncodedString()
        config = ShareConfiguration(dataDirectory: directory, blobDelivery: .direct)
        config.appAttest = AppAttestTestFixture.policy
        let clock = self.clock!
        service = try ShareService(config: config, clock: { clock.now })
        try service.store.database.run("INSERT INTO app_attest_keys VALUES(?,?,?,?,?,0,?,?)", [.text(keyID), .text(ShareHash.secretDigest(secret)),
            .text("development"), .text(key.publicKey.x963Representation.base64EncodedString()), .text("synthetic-receipt"), .int(Int64(clock.now.timeIntervalSince1970)), .int(Int64(clock.now.timeIntervalSince1970))])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    func request(_ action: String, _ body: Data, header: String? = nil, secret: String? = nil) -> ShareResponse {
        var headers = ["authorization":"Bearer \(secret ?? self.secret)", "x-real-ip":"203.0.113.42"]
        if let header { headers[ShareAttestationProof.header.lowercased()] = header }
        return service.handle(.init(method: "POST", path: action, query: [:], headers: headers, body: body))
    }
    func prepared(platform: String = "ios") throws -> Data {
        let prepared = try PreparedShare.make(audio: Data("synthetic".utf8), metadata: .init(title: "Fixture", durationSeconds: 1),
            isPrivate: true, expiresInSeconds: 86400, playCap: 100, client: .init(platform: platform, appVersion: "fixture"))
        return try JSONEncoder().encode(prepared.request)
    }
    func proof(_ body: Data, counter: UInt32 = 1) throws -> ShareAttestationProof {
        let response = request("/v1/share/attestation/challenge", try JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "create", keyID: keyID)))
        XCTAssertEqual(response.status, 200)
        let challenge = try JSONDecoder().decode(ShareAttestationChallenge.self, from: response.body)
        let id = UUID().uuidString
        let envelope = ShareAttestationEnvelope.data(challenge: challenge, policy: config.appAttest!.policy, secret: secret, requestID: id, body: body)
        return .init(keyID: keyID, challengeID: challenge.id, requestID: id,
            assertion: try AppAttestTestFixture.assertion(key: key, counter: counter, envelope: envelope).base64EncodedString())
    }
    func testVerifiedCreateIsAtomicIdempotentAndSurvivesRestart() throws {
        let body = try prepared(), proof = try proof(body), header = try proof.headerValue()
        let first = request("/v1/share/shares", body, header: header)
        XCTAssertEqual(first.status, 201)
        let clock = self.clock!
        service = try ShareService(config: config, clock: { clock.now })
        let replay = request("/v1/share/shares", body, header: try proof.headerValue())
        XCTAssertEqual(replay.status, 201); XCTAssertEqual(replay.body, first.body)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares"), 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT counter FROM app_attest_keys"), 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM events WHERE type = 'share_created'"), 1)
        XCTAssertEqual(request("/v1/share/shares", body + Data(" ".utf8), header: header).status, 401)
    }
    func testSuspensionPrecedesSignedCreateReplayEvenWhenOperatorCapabilityIsOff() throws {
        let token = String(repeating: "O", count: 48)
        config.enforcement = try EnforcementConfiguration(token: token, retentionSeconds: 3600,
            auditRetentionSeconds: 7200, reasonCodes: ["review"])
        let currentClock = clock!
        service = try ShareService(config: config, clock: { currentClock.now })
        let body = try prepared(), signed = try proof(body), header = try signed.headerValue()
        let first = request("/v1/share/shares", body, header: header)
        XCTAssertEqual(first.status, 201)
        let share = try JSONDecoder().decode(CreateShareResponse.self, from: first.body)
        let operation = EnforcementRequest(operationID: UUID().uuidString.lowercased(), action: .suspendSharer,
            shareID: share.id, caseReference: "case_fixture", reasonCode: "review")
        func operatorCall(_ route: String, _ data: Data) -> ShareResponse {
            service.handle(.init(method: "POST", path: "/v1/share/admin/enforcement/" + route, query: [:],
                headers: ["authorization": "Bearer " + token], body: data), peer: .loopback)
        }
        let planned = operatorCall("plan", try JSONEncoder().encode(operation))
        XCTAssertEqual(planned.status, 200)
        XCTAssertEqual(operatorCall("apply", planned.body).status, 200)
        config.enforcement = nil
        service = try ShareService(config: config, clock: { currentClock.now })
        XCTAssertEqual(request("/v1/share/shares", body, header: header).status, 403)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares"), 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT counter FROM app_attest_keys"), 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM events WHERE type='share_created'"), 1)
    }
    func testInvalidCounterChallengeBodyAndCrossInstallDoNotCreate() throws {
        let body = try prepared(), proof = try proof(body)
        XCTAssertEqual(request("/v1/share/shares", body, header: try proof.headerValue(), secret: ShareClient.newSecret()).status, 401)
        clock.advance(301)
        XCTAssertEqual(request("/v1/share/shares", body, header: try proof.headerValue()).status, 401)
        let oldCounter = try self.proof(body, counter: 0)
        XCTAssertEqual(request("/v1/share/shares", body, header: try oldCounter.headerValue()).status, 401)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares"), 0)
    }
    func testDatabaseFailureRollsBackCreateCounterChallengeAndReceipt() throws {
        let body = try prepared(), proof = try proof(body), header = try proof.headerValue()
        try service.store.database.execute("CREATE TRIGGER fail_attest_receipt BEFORE INSERT ON app_attest_creates BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;")
        XCTAssertEqual(request("/v1/share/shares", body, header: header).status, 500)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares"), 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT counter FROM app_attest_keys"), 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_challenges"), 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM events WHERE type = 'share_created'"), 0)
        try service.store.database.execute("DROP TRIGGER fail_attest_receipt")
        XCTAssertEqual(request("/v1/share/shares", body, header: header).status, 201)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares"), 1)
    }
    func testIdleKeyRetirementAndMalformedJSONAreExplicitFailures() throws {
        XCTAssertEqual(request("/v1/share/attestation/status", Data("{broken".utf8)).status, 401)
        clock.advance(90 * 86400 + 1)
        let status = request("/v1/share/attestation/status", try JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "enroll", keyID: keyID)))
        XCTAssertEqual(status.status, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: status.body) as? [String: Bool], ["registered": false])
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_keys"), 0)
    }
    func testPeriodicSweepExpiresVerifiedCreateReceiptWithoutAttestationTraffic() throws {
        let body = try prepared(), proof = try proof(body)
        XCTAssertEqual(request("/v1/share/shares", body, header: try proof.headerValue()).status, 201)
        clock.advance(86400 - 1)
        _ = try service.sweep()
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_creates"), 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_keys"), 1)
        clock.advance(1)
        _ = try service.sweep()
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_creates"), 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_keys"), 1)
        clock.advance(89 * 86400)
        _ = try service.sweep()
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_keys"), 0)
    }
    func testDisabledPolicyStartupSweepHonorsExactRetentionBoundaries() throws {
        let now = Int64(clock.now.timeIntervalSince1970)
        try service.store.database.run("DELETE FROM app_attest_keys")
        for offset in [Int64(0), 1] {
            let id = "fixture-" + String(offset)
            try service.store.database.run("INSERT INTO app_attest_keys VALUES(?,?,?,?,?,0,?,?)", [
                .text(id), .text(ShareHash.secretDigest(secret)), .text("development"), .text("synthetic-public-key"), .text("synthetic-receipt"), .int(now), .int(now - 90 * 86400 + offset)])
            try service.store.database.run("INSERT INTO app_attest_challenges VALUES(?,?,?,?,?,?)", [
                .text(id), .text("synthetic-nonce"), .text(ShareHash.secretDigest(secret)), .text(id), .text("create"), .int(now + offset)])
            try service.store.database.run("INSERT INTO app_attest_creates VALUES(?,?,?,?,?,?)", [
                .text(id), .text(ShareHash.secretDigest(secret)), .text("synthetic-body-hash"), .text("synthetic-proof-hash"), .text("{}"), .int(now + offset)])
        }
        config.appAttest = nil
        let clock = self.clock!
        service = try ShareService(config: config, clock: { clock.now })
        XCTAssertNil(service.attestationVerifier)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_keys"), 2)
        _ = try service.sweep() // Same entry point used by startup and its periodic timer.
        for table in ["app_attest_keys", "app_attest_challenges", "app_attest_creates"] {
            XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM " + table), 1, table)
        }
        clock.advance(1)
        _ = try service.sweep()
        for table in ["app_attest_keys", "app_attest_challenges", "app_attest_creates"] {
            XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM " + table), 0, table)
        }
    }
    func testClaimedPlatformDoesNotGrantVerifiedTrustAndMacRemainsOpen() throws {
        for platform in ["macos","ios"] { XCTAssertEqual(request("/v1/share/shares", try prepared(platform: platform)).status, 201) }
        let events = try service.store.database.query("SELECT props FROM events WHERE type='share_created'")
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { ($0["props"]?.text ?? "").contains("unverified") })
    }
    func testEnrollmentRejectsMalformedProofAndChallengesAreBounded() throws {
        let bad = ShareAttestationEnrollment(keyID: keyID, challengeID: UUID().uuidString, object: "bad")
        XCTAssertEqual(request("/v1/share/attestation/enroll", try JSONEncoder().encode(bad)).status, 401)
        for _ in 0..<4 {
            XCTAssertEqual(request("/v1/share/attestation/challenge", try JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "create", keyID: keyID))).status, 200)
        }
        XCTAssertEqual(request("/v1/share/attestation/challenge", try JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "create", keyID: keyID))).status, 429)
        clock.advance(301)
        XCTAssertEqual(request("/v1/share/attestation/challenge", try JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "create", keyID: keyID))).status, 200)
    }
}
