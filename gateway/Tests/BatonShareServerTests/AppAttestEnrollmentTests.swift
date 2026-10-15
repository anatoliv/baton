import BatonMCPProtocol
import BatonShareKit
@testable import BatonShareServer
import Crypto
import Foundation
import X509
import XCTest

struct AppAttestEnrollmentFixture {
    typealias R = AppAttestReceiptFixture
    let now: Date
    let key = P256.Signing.PrivateKey()
    let rootKey = P256.Signing.PrivateKey()
    let intermediateKey = P256.Signing.PrivateKey()
    let receiptIdentity: R.Identity
    let root: Certificate
    let intermediate: Certificate
    var keyID: String { Data(SHA256.hash(data: key.publicKey.x963Representation)).base64EncodedString() }
    var verifier: AppAttestVerifier { .init(config: AppAttestTestFixture.policy, attestationRoot: root, receiptRoot: receiptIdentity.root) }
    init(now: Date) throws {
        self.now = now
        receiptIdentity = try R.identity(now: now)
        root = try AppAttestTestFixture.root(rootKey, now: now)
        intermediate = try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(intermediateKey.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + 86400, issuer: root.subject,
            subject: DistinguishedName { CommonName("Synthetic Attestation CA") }, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions { Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0)); Critical(KeyUsage(keyCertSign: true)) }, issuerPrivateKey: .init(rootKey))
    }
    func object(challenge: Data, appID: String = AppAttestTestFixture.policy.policy.appID,
                aaguid: Data = Data("appattestdevelop".utf8), counter: UInt32 = 0,
                credential: Data? = nil, nonce: Data? = nil, badReceipt: Bool = false,
                leafExpired: Bool = false, signingUsage: Bool = true, criticalUnknown: Bool = false,
                receiptFieldSeven: Data? = nil,
                extensions: AppAttestCBOR? = nil, extensionFlag: Bool = true) throws -> Data {
        let id = Data(base64Encoded: keyID)!
        var auth = Data(SHA256.hash(data: Data(appID.utf8))) + Data([extensions == nil || !extensionFlag ? 0x40 : 0xc0])
        var count = counter.bigEndian
        withUnsafeBytes(of: &count) { auth.append(contentsOf: $0) }
        auth.append(aaguid); auth.append(contentsOf: [0,32]); auth.append(credential ?? id)
        let cose = AppAttestCBOR.map([.integer(1):.integer(2), .integer(3):.integer(-7), .integer(-1):.integer(1),
            .integer(-2):.bytes(Data(key.publicKey.x963Representation.dropFirst().prefix(32))), .integer(-3):.bytes(Data(key.publicKey.x963Representation.suffix(32)))])
        auth.append(AppAttestTestFixture.cbor(cose))
        if let extensions { auth.append(AppAttestTestFixture.cbor(extensions)) }
        let challengeHash = Data(SHA256.hash(data: challenge))
        let expectedNonce = Data(SHA256.hash(data: auth + challengeHash))
        let value = R.sequence([R.wrap(0xa1, R.octets(nonce ?? expectedNonce))])
        let leaf = try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
            notValidBefore: now - 3600, notValidAfter: leafExpired ? now - 1 : now + 3600, issuer: intermediate.subject,
            subject: DistinguishedName { CommonName("Synthetic Attested Instance") }, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: signingUsage))
                Certificate.Extension(oid: AppAttestVerifier.nonceOID, critical: false, value: Array(value)[...])
                if criticalUnknown { Certificate.Extension(oid: [1,2,3,4], critical: true, value: [5,0]) }
            }, issuerPrivateKey: .init(intermediateKey))
        let receiptHash = badReceipt ? Data(repeating: 0, count: 32) : challengeHash
        let receiptFields = try R.fields(leaf: leaf, clientHash: receiptHash, now: now, opaqueFieldSeven: receiptFieldSeven)
        let receipt = try R.receipt(receiptIdentity, leaf: leaf, clientHash: receiptHash, now: now, fields: receiptFields)
        return try AppAttestTestFixture.cbor(.map([.text("fmt"):.text("apple-appattest"), .text("authData"):.bytes(auth),
            .text("attStmt"):.map([.text("x5c"):.array([.bytes(R.der(leaf)),.bytes(R.der(intermediate))]), .text("receipt"):.bytes(receipt)])]))
    }
}

final class AppAttestEnrollmentTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let challenge = Data("synthetic-server-nonce".utf8)
    func testFullCertificateNonceAuthenticatorAndReceiptEnrollment() throws {
        let f = try AppAttestEnrollmentFixture(now: now)
        let key = try f.verifier.attest(object: f.object(challenge: challenge), keyID: f.keyID, challenge: challenge, now: now)
        XCTAssertEqual(key.publicKey, f.key.publicKey.x963Representation)
        XCTAssertFalse(key.receipt.isEmpty)
        let ext = AppAttestCBOR.map([.text("apple_validation_category_01"):.bytes(Data([1,0,0,0])), .text("apple_bundle_version_01"):.text("123")])
        XCTAssertNoThrow(try f.verifier.attest(object: f.object(challenge: challenge, extensions: ext), keyID: f.keyID, challenge: challenge, now: now))
        XCTAssertNoThrow(try f.verifier.attest(object: f.object(challenge: challenge, extensions: ext, extensionFlag: false), keyID: f.keyID, challenge: challenge, now: now))
    }
    func testSignedAAGUIDKeepsDevelopmentAndProductionSeparateWithOpaqueReceiptField() throws {
        let f = try AppAttestEnrollmentFixture(now: now)
        let opaque = Data([0xff, 0x00, 0x81])
        let development = try f.object(challenge: challenge, receiptFieldSeven: opaque)
        let production = try f.object(challenge: challenge,
            aaguid: Data(Array("appattest".utf8) + Array(repeating: 0, count: 7)), receiptFieldSeven: opaque)
        var productionPolicy = AppAttestTestFixture.policy
        productionPolicy.policy.environment = "production"
        let productionVerifier = AppAttestVerifier(config: productionPolicy,
            attestationRoot: f.root, receiptRoot: f.receiptIdentity.root)
        XCTAssertNoThrow(try f.verifier.attest(object: development, keyID: f.keyID, challenge: challenge, now: now))
        XCTAssertThrowsError(try f.verifier.attest(object: production, keyID: f.keyID, challenge: challenge, now: now))
        XCTAssertNoThrow(try productionVerifier.attest(object: production, keyID: f.keyID, challenge: challenge, now: now))
        XCTAssertThrowsError(try productionVerifier.attest(object: development, keyID: f.keyID, challenge: challenge, now: now))
    }
    func testSignedEnrollmentRejectsWrongNonceAppEnvironmentKeyCounterAndReceipt() throws {
        let f = try AppAttestEnrollmentFixture(now: now)
        let invalid = try [f.object(challenge: challenge, appID: "ABCDEFGHIJ.wrong"),
            f.object(challenge: challenge, aaguid: Data(Array("appattest".utf8) + Array(repeating: 0, count: 7))),
            f.object(challenge: challenge, counter: 1), f.object(challenge: challenge, credential: Data(repeating: 0, count: 32)),
            f.object(challenge: challenge, nonce: Data(repeating: 0, count: 32)), f.object(challenge: challenge, badReceipt: true)]
        for object in invalid { XCTAssertThrowsError(try f.verifier.attest(object: object, keyID: f.keyID, challenge: challenge, now: now)) }
        XCTAssertThrowsError(try f.verifier.attest(object: f.object(challenge: challenge), keyID: Data(repeating: 0, count: 32).base64EncodedString(), challenge: challenge, now: now))
        XCTAssertThrowsError(try f.verifier.attest(object: f.object(challenge: challenge), keyID: f.keyID, challenge: Data("other".utf8), now: now))
    }
    func testCertificateRootExpiryUsageAndUnknownCriticalExtensionRejected() throws {
        let f = try AppAttestEnrollmentFixture(now: now), other = try AppAttestEnrollmentFixture(now: now)
        XCTAssertThrowsError(try other.verifier.attest(object: f.object(challenge: challenge), keyID: f.keyID, challenge: challenge, now: now))
        for object in try [f.object(challenge: challenge, leafExpired: true), f.object(challenge: challenge, signingUsage: false), f.object(challenge: challenge, criticalUnknown: true)] {
            XCTAssertThrowsError(try f.verifier.attest(object: object, keyID: f.keyID, challenge: challenge, now: now))
        }
    }
    func testServiceEnrollsOnceConsumesNonceAndAcceptsBoundAssertion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attest-full-flow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var configuration = ShareConfiguration(dataDirectory: dir, blobDelivery: .direct)
        configuration.appAttest = AppAttestTestFixture.policy
        let now = self.now, f = try AppAttestEnrollmentFixture(now: now), secret = ShareClient.newSecret()
        let service = try ShareService(config: configuration, clock: { now })
        service.attestationVerifier = f.verifier
        func request(_ path: String, _ body: Data, proof: ShareAttestationProof? = nil) throws -> ShareResponse {
            var headers = ["authorization":"Bearer \(secret)"]
            if let proof { headers[ShareAttestationProof.header.lowercased()] = try proof.headerValue() }
            return service.handle(.init(method: "POST", path: "/v1/share/" + path, query: [:], headers: headers, body: body))
        }
        let challengeResponse = try request("attestation/challenge", JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "enroll", keyID: f.keyID)))
        let challenge = try JSONDecoder().decode(ShareAttestationChallenge.self, from: challengeResponse.body)
        let enrollment = try JSONEncoder().encode(ShareAttestationEnrollment(keyID: f.keyID, challengeID: challenge.id, object: f.object(challenge: Data(challenge.nonce.utf8)).base64EncodedString()))
        XCTAssertEqual(try request("attestation/enroll", enrollment).status, 200)
        XCTAssertEqual(try request("attestation/enroll", enrollment).status, 401)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_keys"), 1)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM app_attest_challenges"), 0)
        let prepared = try PreparedShare.make(audio: Data("synthetic".utf8), metadata: .init(title: "Fixture", durationSeconds: 1), isPrivate: true, expiresInSeconds: 86400, playCap: 100, client: .init(platform: "macos", appVersion: "fixture"))
        let body = try JSONEncoder().encode(prepared.request), id = UUID().uuidString
        let next = try request("attestation/challenge", JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "create", keyID: f.keyID)))
        let nonce = try JSONDecoder().decode(ShareAttestationChallenge.self, from: next.body)
        let envelope = ShareAttestationEnvelope.data(challenge: nonce, policy: configuration.appAttest!.policy, secret: secret, requestID: id, body: body)
        let proof = ShareAttestationProof(keyID: f.keyID, challengeID: nonce.id, requestID: id, assertion: try AppAttestTestFixture.assertion(key: f.key, envelope: envelope).base64EncodedString())
        XCTAssertEqual(try request("shares", body, proof: proof).status, 201)
        let props = try service.store.database.query("SELECT props FROM events WHERE type='share_created'").first?["props"]?.text
        XCTAssertTrue(props?.contains("app_attest") == true, "Trust is cryptographic, independent of claimed macos platform")
    }
}
