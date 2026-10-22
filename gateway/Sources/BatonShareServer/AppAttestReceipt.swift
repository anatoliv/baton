import Crypto
import Foundation
import SwiftASN1
import X509

extension AppAttestVerifier {
    /// Only Apple's receipt profile is accepted: embedded data, one signer,
    /// SHA-256/ECDSA-P256, rooted at the separate Apple G3 receipt root.
    func verifyReceipt(_ data: Data, leaf: Certificate, clientHash: Data, now: Date) throws {
        guard !data.isEmpty, data.count <= 32768 else { throw AppAttestError.invalid }
        let signedDataOID: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 2]
        let contentOID: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 1]
        let sha256: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 2, 1]
        let ecdsa256: ASN1ObjectIdentifier = [1, 2, 840, 10045, 4, 3, 2]
        let outer = try Self.children(BER.parse(Array(data)), identifier: .sequence)
        guard outer.count == 2, try ASN1ObjectIdentifier(berEncoded: outer[0]) == signedDataOID else { throw AppAttestError.invalid }
        let wrapped = try Self.children(outer[1], identifier: .init(tagWithNumber: 0, tagClass: .contextSpecific))
        guard wrapped.count == 1 else { throw AppAttestError.invalid }
        let signed = try Self.children(wrapped[0], identifier: .sequence)
        guard signed.count == 5, try Int(berEncoded: signed[0]) == 1 else { throw AppAttestError.invalid }
        let digestAlgorithms = try Self.children(signed[1], identifier: .set)
        guard digestAlgorithms.count == 1, try Self.algorithm(digestAlgorithms[0]) == sha256 else { throw AppAttestError.invalid }
        let content = try Self.children(signed[2], identifier: .sequence)
        guard content.count == 2, try ASN1ObjectIdentifier(berEncoded: content[0]) == contentOID else { throw AppAttestError.invalid }
        let contentWrapper = try Self.children(content[1], identifier: .init(tagWithNumber: 0, tagClass: .contextSpecific))
        guard contentWrapper.count == 1 else { throw AppAttestError.invalid }
        let payload = try Self.octets(contentWrapper[0])
        let certificateNodes = try Self.children(signed[3], identifier: .init(tagWithNumber: 0, tagClass: .contextSpecific))
        guard (2...4).contains(certificateNodes.count) else { throw AppAttestError.invalid }
        let certificates = try certificateNodes.map { try Certificate(derEncoded: $0.encodedBytes) }
        let signerNodes = try Self.children(signed[4], identifier: .set)
        guard signerNodes.count == 1 else { throw AppAttestError.invalid }
        let signer = try Self.children(signerNodes[0], identifier: .sequence)
        guard (5...6).contains(signer.count), try Int(berEncoded: signer[0]) == 1,
              try Self.algorithm(signer[2]) == sha256 else { throw AppAttestError.invalid }
        let sid = try Self.children(signer[1], identifier: .sequence)
        guard sid.count == 2 else { throw AppAttestError.invalid }
        let matching = try certificates.filter { certificate in
            let tbs = try Self.children(DER.parse(certificate.tbsCertificateBytes), identifier: .sequence)
            let serialIndex = tbs[0].identifier == .init(tagWithNumber: 0, tagClass: .contextSpecific) ? 1 : 0
            return certificate.issuer == (try DistinguishedName(derEncoded: sid[0]))
                && tbs[serialIndex].encodedBytes == sid[1].encodedBytes
        }
        guard matching.count == 1, let signingCertificate = matching.first,
              let key = P256.Signing.PublicKey(signingCertificate.publicKey) else { throw AppAttestError.invalid }
        try Self.validateChain(leaf: signingCertificate, intermediates: certificates.filter { $0 != signingCertificate && $0 != receiptRoot },
                               root: receiptRoot, now: now)
        let signatureIndex = signer.count - 1
        guard try Self.algorithm(signer[signatureIndex - 1], allowsNull: false) == ecdsa256 else { throw AppAttestError.invalid }
        var signedBytes = payload
        if signer.count == 6 {
            let attributes = try Self.children(signer[3], identifier: .init(tagWithNumber: 0, tagClass: .contextSpecific))
            // RFC5652 requires DER for signed attributes even inside BER CMS.
            // DER.parse checks lengths/tags, but SET OF ordering needs an explicit check.
            let encodings = attributes.map { Data($0.encodedBytes) }
            guard !encodings.isEmpty, encodings == encodings.sorted(by: { $0.lexicographicallyPrecedes($1) }) else { throw AppAttestError.invalid }
            var seen = Set<ASN1ObjectIdentifier>()
            var validDigest = false, validContent = false
            for attribute in attributes {
                let pair = try Self.children(attribute, identifier: .sequence)
                guard pair.count == 2 else { throw AppAttestError.invalid }
                let oid = try ASN1ObjectIdentifier(derEncoded: pair[0])
                guard seen.insert(oid).inserted else { throw AppAttestError.invalid }
                let values = try Self.children(pair[1], identifier: .set)
                guard values.count == 1 else { throw AppAttestError.invalid }
                if oid == [1, 2, 840, 113549, 1, 9, 4] { validDigest = try Self.octets(values[0]) == Data(SHA256.hash(data: payload)) }
                if oid == [1, 2, 840, 113549, 1, 9, 3] { validContent = try ASN1ObjectIdentifier(derEncoded: values[0]) == contentOID }
            }
            guard validDigest, validContent else { throw AppAttestError.invalid }
            // RFC5652 signs the DER SET, not the implicit context-specific tag.
            signedBytes = Data(signer[3].encodedBytes)
            signedBytes[0] = 0x31
            _ = try DER.parse(Array(signedBytes))
        }
        guard key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: Self.octets(signer[signatureIndex])), for: signedBytes) else { throw AppAttestError.invalid }
        let fields = try Self.receiptFields(payload)
        guard fields[2] == Data(config.policy.appID.utf8), fields[4] == clientHash,
              fields[6] == Data("ATTEST".utf8), let certificate = fields[3],
              try Certificate(derEncoded: Array(certificate)).publicKey == leaf.publicKey,
              let time = fields[12], let string = String(data: time, encoding: .utf8), let created = Self.receiptDate(string),
              // Allow at most 30 seconds of server clock skew; never receipts over five minutes old.
              now.timeIntervalSince(created) >= -30, now.timeIntervalSince(created) <= 300 else { throw AppAttestError.invalid }
        // Apple does not define receipt field 7 as an environment. Unknown signed
        // fields remain opaque; attest() enforces the environment with the signed
        // AAGUID before reaching this receipt check.
    }

    static func algorithm(_ node: ASN1Node, allowsNull: Bool = true) throws -> ASN1ObjectIdentifier {
        let values = try children(node, identifier: .sequence)
        guard (1...2).contains(values.count) else { throw AppAttestError.invalid }
        if values.count == 2 {
            guard allowsNull else { throw AppAttestError.invalid }
            _ = try ASN1Null(berEncoded: values[1])
        }
        return try ASN1ObjectIdentifier(berEncoded: values[0])
    }
    static func receiptFields(_ payload: Data) throws -> [Int: Data] {
        let entries = try children(BER.parse(Array(payload)), identifier: .set)
        var result: [Int: Data] = [:]
        for entry in entries {
            let values = try children(entry, identifier: .sequence)
            guard values.count == 3, try Int(berEncoded: values[1]) == 1 else { throw AppAttestError.invalid }
            let id = try Int(berEncoded: values[0])
            guard id > 0, result[id] == nil else { throw AppAttestError.invalid }
            result[id] = try octets(values[2])
        }
        return result
    }
    static func receiptDate(_ value: String) -> Date? {
        // Receipts use UTC ISO8601 text. Foundation also accepts prefixes/trailing
        // characters, which would make an otherwise signed malformed value ambiguous.
        // `\z`, not `$`: ICU's `$` also matches before a final line terminator, and on Linux
        // corelibs' ISO8601DateFormatter then accepts the trailing newline that Apple's refuses
        //
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z\z"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return nil }
        // ISO8601DateFormatter may normalize dates such as February 30.
        let seconds = ISO8601DateFormatter().string(from: date)
        guard seconds.prefix(19) == value.prefix(19) else { return nil }
        return date
    }
}
