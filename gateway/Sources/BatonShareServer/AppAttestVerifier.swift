import BatonShareKit
import Crypto
import Foundation
import SwiftASN1
import X509

public struct AppAttestConfiguration: Sendable {
    public var policy: ShareAttestationPolicy
    /// Build versions, not user-supplied marketing versions. Empty disables newer proof acceptance.
    public var bundleVersions: Set<String>
    public var validationCategories: Set<UInt32>
    public init(appID: String, environment: String, audience: String, bundleVersions: Set<String>, validationCategories: Set<UInt32>) {
        policy = .init(appID: appID, environment: environment, audience: audience)
        self.bundleVersions = bundleVersions; self.validationCategories = validationCategories
    }
}

struct AppAttestVerifiedKey: Sendable {
    var publicKey: Data
    var receipt: Data
}

struct AppAttestVerifier: Sendable {
    let config: AppAttestConfiguration
    let attestationRoot: Certificate
    let receiptRoot: Certificate
    static let nonceOID: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 8, 2]

    init(config: AppAttestConfiguration) throws {
        self.config = config
        guard let attestURL = Bundle.module.url(forResource: "Apple_App_Attestation_Root_CA", withExtension: "pem", subdirectory: "AttestationRoots"),
              let receiptURL = Bundle.module.url(forResource: "AppleRootCA-G3", withExtension: "cer", subdirectory: "AttestationRoots") else { throw AppAttestError.invalid }
        attestationRoot = try Certificate(pemEncoded: String(contentsOf: attestURL, encoding: .utf8))
        receiptRoot = try Certificate(derEncoded: Array(Data(contentsOf: receiptURL)))
    }

    /// Root injection is internal and used only by synthetic cryptographic tests.
    init(config: AppAttestConfiguration, attestationRoot: Certificate, receiptRoot: Certificate) {
        self.config = config; self.attestationRoot = attestationRoot; self.receiptRoot = receiptRoot
    }

    func attest(object: Data, keyID: String, challenge: Data, now: Date) throws -> AppAttestVerifiedKey {
        guard object.count <= 32768, let id = Data(base64Encoded: keyID), id.count == 32 else { throw AppAttestError.invalid }
        let cbor = try AppAttestCBOR.decode(object)
        guard cbor["fmt"]?.text == "apple-appattest", let statement = cbor["attStmt"],
              let chain = statement["x5c"]?.array, chain.count == 2,
              let certData = chain[0].bytes, let intermediate = chain[1].bytes,
              let receipt = statement["receipt"]?.bytes, !receipt.isEmpty,
              let auth = cbor["authData"]?.bytes else { throw AppAttestError.invalid }
        let leaf = try Certificate(derEncoded: Array(certData))
        try Self.validateChain(leaf: leaf, intermediates: [try Certificate(derEncoded: Array(intermediate))],
                               root: attestationRoot, now: now, nonceExtension: true)
        guard let key = P256.Signing.PublicKey(leaf.publicKey), Data(SHA256.hash(data: key.x963Representation)) == id,
              let nonceExtension = leaf.extensions[oid: Self.nonceOID] else { throw AppAttestError.invalid }
        let nonce = Data(SHA256.hash(data: auth + Data(SHA256.hash(data: challenge))))
        let sequence = try Self.children(DER.parse(nonceExtension.value), identifier: .sequence)
        guard sequence.count == 1, sequence[0].identifier == ASN1Identifier(tagWithNumber: 1, tagClass: .contextSpecific),
              try Self.children(sequence[0]).count == 1,
              let wrapped = try Self.children(sequence[0]).first, try Self.octets(wrapped) == nonce else { throw AppAttestError.invalid }
        let parsed = try authenticator(auth, attestation: true)
        let expectedAAGUID = config.policy.environment == "development"
            ? Data("appattestdevelop".utf8) : Data(Array("appattest".utf8) + Array(repeating: UInt8(0), count: 7))
        let x = Data(key.x963Representation.dropFirst().prefix(32))
        let y = Data(key.x963Representation.suffix(32))
        guard parsed.counter == 0, parsed.credential == id,
              parsed.aaguid == expectedAAGUID,
              parsed.cose?[1]?.integer == 2, parsed.cose?[3]?.integer == -7, parsed.cose?[-1]?.integer == 1,
              parsed.cose?[-2]?.bytes == x, parsed.cose?[-3]?.bytes == y else { throw AppAttestError.invalid }
        try verifyReceipt(receipt, leaf: leaf, clientHash: Data(SHA256.hash(data: challenge)), now: now)
        return .init(publicKey: key.x963Representation, receipt: receipt)
    }

    func assertion(object: Data, publicKey: Data, envelope: Data, previousCounter: Int64) throws -> Int64 {
        guard object.count <= 8192 else { throw AppAttestError.invalid }
        let cbor = try AppAttestCBOR.decode(object)
        guard let auth = cbor["authenticatorData"]?.bytes, let signature = cbor["signature"]?.bytes else { throw AppAttestError.invalid }
        let parsed = try authenticator(auth, attestation: false)
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        let digest = SHA256.hash(data: auth + Data(SHA256.hash(data: envelope)))
        guard parsed.counter > previousCounter,
              key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: digest) else { throw AppAttestError.invalid }
        return parsed.counter
    }

    struct Authenticator {
        var counter: Int64
        var credential: Data?
        var aaguid: Data?
        var cose: AppAttestCBOR?
    }

    func authenticator(_ data: Data, attestation: Bool) throws -> Authenticator {
        var parser = AppAttestCBOR.Parser(bytes: Array(data))
        guard try parser.take(32) == Data(SHA256.hash(data: Data(config.policy.appID.utf8))) else { throw AppAttestError.invalid }
        let flags = try parser.take(1).first!
        guard (flags & 0x40 != 0) == attestation, flags & 0x3e == 0 else { throw AppAttestError.invalid }
        let counter = try parser.take(4).reduce(Int64(0)) { ($0 << 8) | Int64($1) }
        var result = Authenticator(counter: counter)
        if attestation {
            result.aaguid = try parser.take(16)
            let length = try parser.take(2).reduce(0) { ($0 << 8) | Int($1) }
            guard length == 32 else { throw AppAttestError.invalid }
            result.credential = try parser.take(length)
            result.cose = try parser.value(depth: 0)
        }
        if parser.offset < parser.bytes.count {
            let ext = try parser.value(depth: 0)
            let category: UInt32?
            if let v = ext["apple_validation_category_01"]?.integer, (0...Int64(UInt32.max)).contains(v) { category = UInt32(v) }
            else if let bytes = ext["apple_validation_category_01"]?.bytes, bytes.count == 4 {
                category = bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
            } else { category = nil }
            guard let category, config.validationCategories.contains(category),
                  let version = ext["apple_bundle_version_01"]?.text, config.bundleVersions.contains(version) else { throw AppAttestError.invalid }
        } else if flags & 0x80 != 0 { throw AppAttestError.invalid }
        // Earlier iOS versions have no extension map. Newer maps, when present,
        // are fully checked; never trust client-reported OS/platform to skip them.
        guard parser.offset == parser.bytes.count else { throw AppAttestError.invalid }
        return result
    }

    static func children(_ node: ASN1Node, identifier: ASN1Identifier? = nil) throws -> [ASN1Node] {
        if let identifier, node.identifier != identifier { throw AppAttestError.invalid }
        guard case let .constructed(values) = node.content else { throw AppAttestError.invalid }
        let result = Array(values)
        guard result.count <= 64 else { throw AppAttestError.invalid }
        return result
    }
    static func octets(_ node: ASN1Node) throws -> Data {
        Data(try ASN1OctetString(berEncoded: node).bytes)
    }

    /// The transport is synchronous. Run Apple's bounded, offline path validator on
    /// an independent task; never dispatch back to the actor blocked by this caller.
    ///
    /// The task runs on a queue of its own rather than the cooperative pool. This caller waits on
    /// a pool thread, under the service lock, and so does every request queued behind that lock:
    /// with about core-count requests at once there was no pool thread left to run the validator,
    /// and every attestation failed after a 5 s stall (TBX-1000000496 D-7).
    static func validateChain(leaf: Certificate, intermediates: [Certificate], root: Certificate,
                              now: Date, nonceExtension: Bool = false) throws {
        guard intermediates.count <= 3, leaf != root else { throw AppAttestError.invalid }
        let state = ChainResult()
        Task.detached(executorPreference: validationExecutor) {
            var verifier = Verifier(rootCertificates: CertificateStore([root])) {
                RFC5280Policy(validationTime: now)
                AppAttestChainPolicy(nonceExtension: nonceExtension)
            }
            let result = await verifier.validate(leafCertificate: leaf, intermediates: CertificateStore(intermediates))
            if case let .validCertificate(chain) = result, chain.count >= 2, chain.last == root { state.finish(true) }
            else { state.finish(false) }
        }
        guard state.semaphore.wait(timeout: .now() + 5) == .success, state.valid else { throw AppAttestError.invalid }
    }
    private static let validationExecutor = QueueExecutor(label: "baton-share.app-attest")

    /// Runs its jobs on a serial dispatch queue, whose threads are not the cooperative pool's.
    /// Serial on purpose: a serial queue always gets a thread, while a concurrent one waits for the
    /// same busy global pool (tried: the starvation came back). Callers are serialised by the
    /// service lock anyway, so one validation running past its 5 s bound delays the next at most.
    private final class QueueExecutor: TaskExecutor, @unchecked Sendable {
        private let queue: DispatchQueue
        init(label: String) { queue = DispatchQueue(label: label) }
        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        }
    }

    private final class ChainResult: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result = false
        var valid: Bool { lock.lock(); defer { lock.unlock() }; return result }
        func finish(_ value: Bool) { lock.lock(); result = value; lock.unlock(); semaphore.signal() }
    }
}

private struct AppAttestChainPolicy: VerifierPolicy {
    var nonceExtension: Bool
    var verifyingCriticalExtensions: [ASN1ObjectIdentifier] { nonceExtension ? [AppAttestVerifier.nonceOID] : [] }
    func chainMeetsPolicyRequirements(chain: UnverifiedCertificateChain) async -> PolicyEvaluationResult {
        do {
            guard let usage = try chain.leaf.extensions.keyUsage, usage.digitalSignature else { return .failsToMeetPolicy(reason: "missing signing usage") }
            for certificate in chain.dropFirst() {
                guard let usage = try certificate.extensions.keyUsage, usage.keyCertSign else { return .failsToMeetPolicy(reason: "missing CA usage") }
                if certificate.extensions[oid: AppAttestVerifier.nonceOID]?.critical == true { return .failsToMeetPolicy(reason: "nonce on CA") }
            }
            return .meetsPolicy
        } catch { return .failsToMeetPolicy(reason: "invalid usage") }
    }
}
