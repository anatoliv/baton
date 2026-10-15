import BatonShareKit
@testable import BatonShareServer
import Crypto
import Foundation
import SwiftASN1
import X509

/// Independent signed CMS fixtures; all keys/certificates are throwaway synthetic data.
enum AppAttestReceiptFixture {
    struct Identity {
        let root: Certificate
        let signer: Certificate
        let signingKey: P256.Signing.PrivateKey
        let leaf: Certificate
        let verifier: AppAttestVerifier
    }
    static func identity(now: Date, policy: AppAttestConfiguration = AppAttestTestFixture.policy) throws -> Identity {
        let rootKey = P256.Signing.PrivateKey(), signingKey = P256.Signing.PrivateKey()
        let root = try AppAttestTestFixture.root(rootKey, now: now, name: "Synthetic Receipt Root")
        let signer = try Certificate(version: .v3, serialNumber: .init(bytes: [1]), publicKey: .init(signingKey.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + 3600, issuer: root.subject,
            subject: DistinguishedName { CommonName("Synthetic Receipt Signer") }, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions { Critical(BasicConstraints.notCertificateAuthority); Critical(KeyUsage(digitalSignature: true)) },
            issuerPrivateKey: .init(rootKey))
        let leaf = try AppAttestTestFixture.root(P256.Signing.PrivateKey(), now: now, name: "Synthetic Attested Key")
        return .init(root: root, signer: signer, signingKey: signingKey, leaf: leaf,
            verifier: .init(config: policy, attestationRoot: root, receiptRoot: root))
    }
    static func der<T: DERSerializable>(_ value: T) throws -> Data {
        var serializer = DER.Serializer(); try serializer.serialize(value); return Data(serializer.serializedBytes)
    }
    static func wrap(_ tag: UInt8, _ bytes: Data) -> Data {
        var header = Data([tag])
        if bytes.count < 128 { header.append(UInt8(bytes.count)) }
        else {
            var n = bytes.count, length = [UInt8]()
            while n > 0 { length.insert(UInt8(n & 255), at: 0); n >>= 8 }
            header.append(0x80 | UInt8(length.count)); header.append(contentsOf: length)
        }
        return header + bytes
    }
    static func sequence(_ bytes: [Data]) -> Data { wrap(0x30, bytes.reduce(Data(), +)) }
    static func set(_ bytes: [Data], sorted: Bool = true) -> Data {
        wrap(0x31, (sorted ? bytes.sorted { $0.lexicographicallyPrecedes($1) } : bytes).reduce(Data(), +))
    }
    static func oid(_ value: ASN1ObjectIdentifier) throws -> Data { try der(value) }
    static func integer(_ value: Int) throws -> Data { try der(value) }
    static func octets(_ value: Data) -> Data { wrap(4, value) }
    static func fields(leaf: Certificate, clientHash: Data, now: Date,
                       appID: String = AppAttestTestFixture.policy.policy.appID,
                       opaqueFieldSeven: Data? = nil) throws -> [(Int, Data)] {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [(Int, Data)] = [(2, Data(appID.utf8)), (3, try der(leaf)), (4, clientHash), (6, Data("ATTEST".utf8)), (12, Data(formatter.string(from: now).utf8))]
        if let opaqueFieldSeven { result.append((7, opaqueFieldSeven)) }
        return result
    }
    static func payload(_ fields: [(Int, Data)], version: Int = 1) throws -> Data {
        try set(fields.map { try sequence([integer($0.0), integer(version), octets($0.1)]) })
    }
    static func receipt(_ identity: Identity, leaf: Certificate? = nil, clientHash: Data, now: Date,
                        fields: [(Int, Data)]? = nil, signedAttributes: Bool = false) throws -> Data {
        let payload = try payload(fields ?? self.fields(leaf: leaf ?? identity.leaf, clientHash: clientHash, now: now))
        return try cms(identity, payload: payload, signedAttributes: signedAttributes)
    }
    /// Parameters deliberately permit invalid-but-signed variants, so rejection tests do
    /// not merely damage signatures before exercising payload/CMS policy.
    static func cms(_ identity: Identity, payload: Data, signedAttributes: Bool = false,
                    attributes: [Data]? = nil, canonicalAttributes: Bool = true,
                    certificates: [Certificate]? = nil, signerCount: Int = 1,
                    sidSerial: Int = 1, digestOID: ASN1ObjectIdentifier = [2,16,840,1,101,3,4,2,1],
                    signatureOID: ASN1ObjectIdentifier = [1,2,840,10045,4,3,2], detached: Bool = false) throws -> Data {
        let dataOID: ASN1ObjectIdentifier = [1,2,840,113549,1,7,1]
        let digest = try sequence([oid(digestOID), Data([5,0])])
        var signer = try [integer(1), sequence([der(identity.signer.issuer), integer(sidSerial)]), digest]
        var signedBytes = payload
        if signedAttributes {
            let attrs = try attributes ?? [
                sequence([oid([1,2,840,113549,1,9,3]), set([oid(dataOID)])]),
                sequence([oid([1,2,840,113549,1,9,4]), set([octets(Data(SHA256.hash(data: payload)))])])]
            signedBytes = set(attrs, sorted: canonicalAttributes)
            var implicit = signedBytes; implicit[0] = 0xa0; signer.append(implicit)
        }
        signer.append(try sequence([oid(signatureOID)]))
        signer.append(octets(try identity.signingKey.signature(for: signedBytes).derRepresentation))
        let content = try sequence([oid(dataOID)] + (detached ? [] : [wrap(0xa0, octets(payload))]))
        let certs = try (certificates ?? [identity.root, identity.signer]).map { try der($0) }
        let signed = try sequence([integer(1), set([digest]), content, wrap(0xa0, certs.reduce(Data(), +)), set(Array(repeating: sequence(signer), count: signerCount))])
        return try sequence([oid([1,2,840,113549,1,7,2]), wrap(0xa0, signed)])
    }
}
