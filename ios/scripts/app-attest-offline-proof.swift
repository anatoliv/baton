import Foundation

private struct Evidence: Decodable {
    let keyID: String
    let challenge: String
    let assertionEnvelope: String
    let appBundleVersion: String
    let sourceCommit: String
    let probeSuite: String
    let capturedAt: Date
    let attestation: Data
    let assertion: Data
}

private func provisionalExtensions(_ object: Data, attestation: Bool) throws -> (UInt32?, String?) {
    let map = try AppAttestCBOR.decode(object)
    guard let auth = map[attestation ? "authData" : "authenticatorData"]?.bytes else { throw AppAttestError.invalid }
    var p = AppAttestCBOR.Parser(bytes: Array(auth))
    _ = try p.take(37)
    if attestation {
        _ = try p.take(16)
        let length = try p.take(2).reduce(0) { ($0 << 8) | Int($1) }
        guard length == 32 else { throw AppAttestError.invalid }
        _ = try p.take(length); _ = try p.value(depth: 0)
    }
    if p.offset == p.bytes.count { return (nil, nil) }
    let fields = try p.value(depth: 0)
    guard p.offset == p.bytes.count else { throw AppAttestError.invalid }
    let category: UInt32?
    if let n = fields["apple_validation_category_01"]?.integer, (0...Int64(UInt32.max)).contains(n) { category = UInt32(n) }
    else if let data = fields["apple_validation_category_01"]?.bytes, data.count == 4 {
        category = data.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
    } else { category = nil }
    guard let category, let version = fields["apple_bundle_version_01"]?.text else { throw AppAttestError.invalid }
    return (category, version)
}

@main
private enum OfflineProof {
    static func main() {
        do {
            let args = CommandLine.arguments
            if args.count == 2, args[1] == "--self-check" {
                let verifier = try AppAttestVerifier(config: .init(appID: "Q8822GNL2H.io.tonebox.baton", environment: "development", audience: "https://dev.batonmusic.app", bundleVersions: ["1"], validationCategories: []))
                var rejected = false
                do { _ = try verifier.attest(object: Data(), keyID: "", challenge: Data(), now: Date()) }
                catch { rejected = true }
                guard rejected else { throw AppAttestError.invalid }
                print("{\"result\":\"PASS\",\"appleRootsLoaded\":true,\"malformedProofRejected\":true,\"physicalProofVerified\":false}")
                return
            }
            guard args.count == 2 else { throw AppAttestError.invalid }
            let url = URL(fileURLWithPath: args[1])
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  (values[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (values[.size] as? NSNumber)?.intValue ?? Int.max <= 65536 else { throw AppAttestError.invalid }
            let e = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: url))
            let now = Date()
            guard e.sourceCommit == "60368d111db2c58285ffb93beef5f85093ee8257", e.appBundleVersion == "1",
                  e.probeSuite == "probe-attest-2450a4e63e0e426eb1c3f76b43cee77a",
                  UUID(uuidString: e.challenge) != nil,
                  e.assertionEnvelope.hasPrefix("baton-development-classification:"),
                  UUID(uuidString: String(e.assertionEnvelope.dropFirst("baton-development-classification:".count))) != nil,
                  (1...32768).contains(e.attestation.count), (1...8192).contains(e.assertion.count),
                  now.timeIntervalSince(e.capturedAt) >= -30, now.timeIntervalSince(e.capturedAt) <= 300 else { throw AppAttestError.invalid }
            // Untrusted candidates only constrain this offline call. No classification is
            // emitted and no service allowlist exists until all cryptographic checks pass.
            let att = try provisionalExtensions(e.attestation, attestation: true)
            let ass = try provisionalExtensions(e.assertion, attestation: false)
            let categories = Set([att.0, ass.0].compactMap { $0 })
            guard categories.count <= 1, [att.1, ass.1].compactMap({ $0 }).allSatisfy({ $0 == e.appBundleVersion }) else { throw AppAttestError.invalid }
            let verifier = try AppAttestVerifier(config: .init(appID: "Q8822GNL2H.io.tonebox.baton", environment: "development", audience: "https://dev.batonmusic.app", bundleVersions: [e.appBundleVersion], validationCategories: categories))
            let verified = try verifier.attest(object: e.attestation, keyID: e.keyID, challenge: Data(e.challenge.utf8), now: now)
            let counter = try verifier.assertion(object: e.assertion, publicKey: verified.publicKey,
                                                envelope: Data(e.assertionEnvelope.utf8), previousCounter: 0)
            var report: [String: Any] = ["result":"PASS", "appleChainNonceAppIDAAGUIDReceiptVerified":true,
                "assertionVerified":true, "environment":"development", "pinnedCaptureBuild":e.appBundleVersion,
                "pinnedCaptureSource":e.sourceCommit, "authenticatedCategories":categories.sorted(),
                "attestationExtensionsPresent":att.0 != nil, "assertionExtensionsPresent":ass.0 != nil,
                "assertionCounterPositive":counter > 0, "receiptFreshnessEnforced":true, "policyActivated":false]
            if let authenticatedVersion = att.1 ?? ass.1 {
                report["authenticatedBundleVersion"] = authenticatedVersion
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("{\"result\":\"FAIL\",\"authenticatedClassification\":false,\"privateDetailsWithheld\":true}")
            exit(1)
        }
    }
}
