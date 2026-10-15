import BatonShareKit
@testable import BatonShareServer
import Crypto
import Foundation
import SwiftASN1
@_spi(CMS) import X509
import XCTest

final class AppAttestReceiptTests: XCTestCase {
    typealias F = AppAttestReceiptFixture
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let challengeHash = Data(SHA256.hash(data: Data("synthetic challenge".utf8)))
    func verify(_ receipt: Data, _ identity: F.Identity, hash: Data? = nil, now: Date? = nil) throws {
        try identity.verifier.verifyReceipt(receipt, leaf: identity.leaf, clientHash: hash ?? self.challengeHash, now: now ?? self.now)
    }
    func testDirectAndSignedAttributeCMSVerifyWithPinnedSyntheticRoot() throws {
        let i = try F.identity(now: now)
        for attrs in [false, true] { try verify(F.receipt(i, clientHash: challengeHash, now: now, signedAttributes: attrs), i) }
    }
    func testReviewedSwiftCertificatesCMSProducerInteroperates() throws {
        let i = try F.identity(now: now)
        let payload = try F.payload(F.fields(leaf: i.leaf, clientHash: challengeHash, now: now))
        let cms = try CMS.sign(payload, signatureAlgorithm: .ecdsaWithSHA256,
            additionalIntermediateCertificates: [i.root], certificate: i.signer,
            privateKey: .init(i.signingKey), detached: false)
        try verify(Data(cms), i)
        // The pinned library's signedAttrs producer omits intermediates when signingTime
        // is set. Add the known synthetic root to the certificate bag only: neither the
        // payload nor signedAttrs/signature are altered, proving independent DER interoperability.
        let withAttrs = try CMS.sign(payload, signatureAlgorithm: .ecdsaWithSHA256,
            certificate: i.signer, privateKey: .init(i.signingKey), signingTime: now, detached: false)
        let outer = try AppAttestVerifier.children(DER.parse(withAttrs))
        let signed = try AppAttestVerifier.children(AppAttestVerifier.children(outer[1])[0])
        var fields = signed.map { Data($0.encodedBytes) }
        let certs = try AppAttestVerifier.children(signed[3]).map { Data($0.encodedBytes) }
        fields[3] = F.wrap(0xa0, (certs + [try F.der(i.root)]).reduce(Data(), +))
        let attached = F.sequence([Data(outer[0].encodedBytes), F.wrap(0xa0, F.sequence(fields))])
        try verify(attached, i)
    }
    func testReceiptBindsAppIdentityChallengeAndAttestedPublicKey() throws {
        let i = try F.identity(now: now), receipt = try F.receipt(i, clientHash: challengeHash, now: now)
        XCTAssertThrowsError(try verify(receipt, i, hash: Data(repeating: 0, count: 32)))
        let other = try F.identity(now: now)
        XCTAssertThrowsError(try i.verifier.verifyReceipt(receipt, leaf: other.leaf, clientHash: challengeHash, now: now))
        let wrongPolicy = AppAttestConfiguration(appID: "ABCDEFGHIJ.other", environment: "development", audience: ShareLink.defaultBase.absoluteString, bundleVersions: ["123"], validationCategories: [1])
        let v = AppAttestVerifier(config: wrongPolicy, attestationRoot: i.root, receiptRoot: i.root)
        XCTAssertThrowsError(try v.verifyReceipt(receipt, leaf: i.leaf, clientHash: challengeHash, now: now))
    }
    func testWrongRootAndExpiredSignerAreRejected() throws {
        let i = try F.identity(now: now), receipt = try F.receipt(i, clientHash: challengeHash, now: now)
        let other = try F.identity(now: now)
        XCTAssertThrowsError(try other.verifier.verifyReceipt(receipt, leaf: i.leaf, clientHash: challengeHash, now: now))
        // Keep payload current so failure comes from certificate validation.
        let expiredReceipt = try F.receipt(i, clientHash: challengeHash, now: now + 4000)
        XCTAssertThrowsError(try verify(expiredReceipt, i, now: now + 4000))
    }
    func testEveryRequiredFieldIsRequiredAndUnique() throws {
        let i = try F.identity(now: now), fields = try F.fields(leaf: i.leaf, clientHash: challengeHash, now: now)
        for id in [2,3,4,6,12] {
            XCTAssertThrowsError(try verify(F.receipt(i, clientHash: challengeHash, now: now, fields: fields.filter { $0.0 != id }), i), "missing field \(id)")
            XCTAssertThrowsError(try verify(F.receipt(i, clientHash: challengeHash, now: now, fields: fields + [fields.first { $0.0 == id }!]), i), "duplicate field \(id)")
        }
    }
    func testSignedWrongFieldValuesAndReceiptTypeAreRejected() throws {
        let i = try F.identity(now: now), fields = try F.fields(leaf: i.leaf, clientHash: challengeHash, now: now)
        for (id, value) in [(2, Data("OTHER.fixture".utf8)), (3, Data([0x30,0])), (4, Data([0])), (6, Data("RECEIPT".utf8)), (12, Data("invalid".utf8))] {
            let changed = fields.map { $0.0 == id ? (id, value) : $0 }
            XCTAssertThrowsError(try verify(F.receipt(i, clientHash: challengeHash, now: now, fields: changed), i), "field \(id)")
        }
    }
    func testFreshnessIncludesFiveMinuteBoundaryAndBoundsFutureSkew() throws {
        let i = try F.identity(now: now)
        for delta in [0.0, -300, 30] { try verify(F.receipt(i, clientHash: challengeHash, now: now + delta), i) }
        for delta in [-300.001, 30.001] { XCTAssertThrowsError(try verify(F.receipt(i, clientHash: challengeHash, now: now + delta), i)) }
    }
    func testDateRejectsTrailingTextNonUTCAndImpossibleDate() throws {
        for string in ["2026-10-03T12:00:00Zgarbage", "2026-10-03T12:00:00+01:00", "2026-99-99T12:00:00Z", "2026-02-30T12:00:00Z", "2026-10-03", "2026-10-03T12:00:00Z\n"] { XCTAssertNil(AppAttestVerifier.receiptDate(string), string) }
        XCTAssertNotNil(AppAttestVerifier.receiptDate("2026-10-03T12:00:00Z"))
        XCTAssertNotNil(AppAttestVerifier.receiptDate("2026-10-03T12:00:00.123Z"))
    }
    func testUnknownSignedFieldsRemainCompatible() throws {
        let i = try F.identity(now: now)
        var fields = try F.fields(leaf: i.leaf, clientHash: challengeHash, now: now)
        fields.append((100, Data("future signed field".utf8)))
        try verify(F.receipt(i, clientHash: challengeHash, now: now, fields: fields), i)
    }
    func testSignedOpaqueFieldSevenIsNotAnEnvironmentPolicy() throws {
        let i = try F.identity(now: now)
        let documented = try F.fields(leaf: i.leaf, clientHash: challengeHash, now: now)
        XCTAssertFalse(documented.contains { $0.0 == 7 }, "The synthetic receipt must contain only one field 7")
        // Apple does not define receipt field 7. Valid signed unknown data must
        // not override the environment bound by the attestation AAGUID.
        for opaque in [Data("opaque synthetic value".utf8), Data([0xff, 0x00, 0x81])] {
            for attributes in [false, true] {
                XCTAssertNoThrow(try verify(F.receipt(i, clientHash: challengeHash, now: now,
                    fields: documented + [(7, opaque)], signedAttributes: attributes), i))
            }
        }
    }
    func testPayloadFieldVersionAndNonpositiveFieldIDRejected() throws {
        let i = try F.identity(now: now), fields = try F.fields(leaf: i.leaf, clientHash: challengeHash, now: now)
        XCTAssertThrowsError(try verify(F.cms(i, payload: F.payload(fields, version: 2)), i))
        XCTAssertThrowsError(try verify(F.receipt(i, clientHash: challengeHash, now: now, fields: fields + [(0,Data())]), i))
    }
    func testDetachedMultiSignerWrongIssuerSerialAndAlgorithmsRejected() throws {
        let i = try F.identity(now: now), payload = try F.payload(F.fields(leaf: i.leaf, clientHash: challengeHash, now: now))
        XCTAssertThrowsError(try verify(F.cms(i, payload: payload, detached: true), i))
        for count in [0,2] { XCTAssertThrowsError(try verify(F.cms(i, payload: payload, signerCount: count), i)) }
        XCTAssertThrowsError(try verify(F.cms(i, payload: payload, sidSerial: 2), i))
        XCTAssertThrowsError(try verify(F.cms(i, payload: payload, digestOID: [1,3,14,3,2,26]), i))
        XCTAssertThrowsError(try verify(F.cms(i, payload: payload, signatureOID: [1,2,840,10045,4,3,3]), i))
    }
    func testSignedAttributesMustHaveUniqueContentTypeAndMatchingDigest() throws {
        let i = try F.identity(now: now), payload = try F.payload(F.fields(leaf: i.leaf, clientHash: challengeHash, now: now))
        let content = try F.sequence([F.oid([1,2,840,113549,1,9,3]), F.set([F.oid([1,2,840,113549,1,7,1])])])
        let digest = try F.sequence([F.oid([1,2,840,113549,1,9,4]), F.set([F.octets(Data(SHA256.hash(data: payload)))])])
        let wrongDigest = try F.sequence([F.oid([1,2,840,113549,1,9,4]), F.set([F.octets(Data(repeating: 0, count: 32))])])
        let wrongType = try F.sequence([F.oid([1,2,840,113549,1,9,3]), F.set([F.oid([1,2,840,113549,1,7,2])])])
        for attrs in [[],[content],[digest],[content,digest,digest],[content,wrongDigest],[wrongType,digest]] {
            XCTAssertThrowsError(try verify(F.cms(i, payload: payload, signedAttributes: true, attributes: attrs), i))
        }
    }
    func testSignedAttributesRejectNonCanonicalSetOrderDespiteValidSignature() throws {
        let i = try F.identity(now: now), payload = try F.payload(F.fields(leaf: i.leaf, clientHash: challengeHash, now: now))
        let content = try F.sequence([F.oid([1,2,840,113549,1,9,3]), F.set([F.oid([1,2,840,113549,1,7,1])])])
        let digest = try F.sequence([F.oid([1,2,840,113549,1,9,4]), F.set([F.octets(Data(SHA256.hash(data: payload)))])])
        let unsorted = [content,digest].sorted { $1.lexicographicallyPrecedes($0) }
        XCTAssertThrowsError(try verify(F.cms(i, payload: payload, signedAttributes: true, attributes: unsorted, canonicalAttributes: false), i))
    }
    func testAlgorithmParametersAreValidatedWithoutWeakeningSignatureBinding() throws {
        let i = try F.identity(now: now), receipt = try F.receipt(i, clientHash: challengeHash, now: now)
        let outer = try AppAttestVerifier.children(DER.parse(Array(receipt)))
        let signed = try AppAttestVerifier.children(AppAttestVerifier.children(outer[1])[0])
        let signer = try AppAttestVerifier.children(AppAttestVerifier.children(signed[4])[0])
        let digestOID = try F.oid([2,16,840,1,101,3,4,2,1])
        let signatureOID = try F.oid([1,2,840,10045,4,3,2])
        func replacing(digest: Data? = nil, signature: Data? = nil) -> Data {
            var fields = signed.map { Data($0.encodedBytes) }, signerFields = signer.map { Data($0.encodedBytes) }
            if let digest { fields[1] = F.set([digest]); signerFields[2] = digest }
            if let signature { signerFields[3] = signature }
            fields[4] = F.set([F.sequence(signerFields)])
            return F.sequence([Data(outer[0].encodedBytes), F.wrap(0xa0, F.sequence(fields))])
        }
        // AlgorithmIdentifier metadata lies outside this direct CMS signature.
        // These variants retain a valid payload signature, so parser policy is tested.
        try verify(replacing(digest: F.sequence([digestOID])), i)
        XCTAssertThrowsError(try verify(replacing(digest: F.sequence([digestOID, Data([5,1,0])])), i))
        XCTAssertThrowsError(try verify(replacing(signature: F.sequence([signatureOID, Data([5,0])])), i))
    }
    func testCertificateBagRequiresOneIdentifiedSignerAndRemainsBounded() throws {
        let i = try F.identity(now: now), payload = try F.payload(F.fields(leaf: i.leaf, clientHash: challengeHash, now: now))
        for certificates in [[i.root], [i.root,i.signer,i.signer], Array(repeating: i.root, count: 4) + [i.signer]] {
            XCTAssertThrowsError(try verify(F.cms(i, payload: payload, certificates: certificates), i))
        }
    }
    func testTamperedTruncatedTrailingAndOversizedCMSRejected() throws {
        let i = try F.identity(now: now), receipt = try F.receipt(i, clientHash: challengeHash, now: now)
        var tampered = receipt; tampered[tampered.count - 1] ^= 1
        for bad in [Data(), tampered, Data(receipt.dropLast()), receipt + Data([0]), Data(repeating: 0, count: 32769)] { XCTAssertThrowsError(try verify(bad, i)) }
    }
    func testApplePublishedBERSampleCryptographyAtHistoricalCreationTime() throws {
        let data = AppAttestReceiptAppleSample.receipt
        let outer = try AppAttestVerifier.children(BER.parse(Array(data)))
        let signed = try AppAttestVerifier.children(AppAttestVerifier.children(outer[1])[0])
        let content = try AppAttestVerifier.children(signed[2])
        let payload = try AppAttestVerifier.octets(AppAttestVerifier.children(content[1])[0])
        let fields = try AppAttestVerifier.receiptFields(payload)
        let leaf = try Certificate(derEncoded: Array(fields[3]!))
        let policy = AppAttestConfiguration(appID: "1234567890.com.example.myapp", environment: "production", audience: ShareLink.defaultBase.absoluteString, bundleVersions: ["1"], validationCategories: [1])
        let v = try AppAttestVerifier(config: policy)
        let date = AppAttestVerifier.receiptDate(String(data: fields[12]!, encoding: .utf8)!)!
        // Apple's specimen field4 contains the raw example challenge, unlike the
        // documented hashed production flow. Exercise its actual signed bytes,
        // and explicitly reject substituting the challenge hash.
        XCTAssertEqual(fields[4], Data("example_server_challenge".utf8))
        try v.verifyReceipt(data, leaf: leaf, clientHash: fields[4]!, now: date)
        XCTAssertThrowsError(try v.verifyReceipt(data, leaf: leaf, clientHash: Data(SHA256.hash(data: fields[4]!)), now: date))
        XCTAssertThrowsError(try v.verifyReceipt(data, leaf: leaf, clientHash: fields[4]!, now: date + 301))
    }
}
