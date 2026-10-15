import BatonShareKit
import CryptoKit
import Foundation
import XCTest
@testable import BatonMobile

/// Real coordinator + upload engine, with synthetic device/transport boundaries.
/// These assertions concern requests and durable results, not Apple cryptography
/// or operating-system background scheduling.
@MainActor
final class SignedShareIntegrationTests: XCTestCase {
    private var directory: URL!
    private var configuration: URLSessionConfiguration!
    private var device: SignedShareDevice!
    private var engine: BackgroundShareUploadEngine!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("signed-share-integration-\(UUID())")
        configuration = .ephemeral
        configuration.protocolClasses = [SignedShareTransport.self]
        device = SignedShareDevice()
        SignedShareTransport.reset()
        let coordinator = SongShareAppAttest(directory: directory.appendingPathComponent("attest"),
                                            device: device, configuration: configuration)
        engine = BackgroundShareUploadEngine(directory: directory.appendingPathComponent("jobs"),
            ledgerURL: directory.appendingPathComponent("ledger.json"), configuration: configuration,
            appAttest: coordinator, secretProvider: { SignedShareTransport.secret })
    }

    override func tearDownWithError() throws {
        engine = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func makeEngine() -> BackgroundShareUploadEngine {
        let coordinator = SongShareAppAttest(directory: directory.appendingPathComponent("attest"),
                                            device: device, configuration: configuration)
        return BackgroundShareUploadEngine(directory: directory.appendingPathComponent("jobs"),
            ledgerURL: directory.appendingPathComponent("ledger.json"), configuration: configuration,
            appAttest: coordinator, secretProvider: { SignedShareTransport.secret })
    }

    private func prepared() throws -> PreparedShare {
        try PreparedShare.make(audio: Data("SYNTHETIC_SIGNED_SONG".utf8),
            metadata: ShareMetadata(title: "Synthetic signed fixture", durationSeconds: 1), isPrivate: true,
            expiresInSeconds: 86400, playCap: 100,
            client: ShareClientInfo(platform: "ios", appVersion: "test"))
    }

    private func share() async throws -> ShareLedger.Record {
        try await engine.enqueue(prepared(), client: ShareClient(base: SignedShareTransport.base,
            secret: SignedShareTransport.secret), songID: "synthetic", title: "Synthetic", artist: "",
            attestationPolicy: SignedShareTransport.policy)
    }

    func testSignedCreateUploadFinalizeAndSubsequentAssertion() async throws {
        let first = try await share()
        let second = try await share()
        XCTAssertEqual(first.summary?.status, .ready)
        XCTAssertEqual(second.summary?.status, .ready)
        XCTAssertNotEqual(first.id, second.id)
        let requests = SignedShareTransport.snapshot()
        XCTAssertEqual(requests.creates.count, 2)
        XCTAssertTrue(requests.creates.allSatisfy { $0.proof != nil })
        XCTAssertEqual(Set(requests.creates.compactMap { $0.proof?.requestID }).count, 2)
        XCTAssertEqual(Set(requests.creates.compactMap { $0.proof?.challengeID }).count, 2)
        XCTAssertEqual(requests.shareCount, 2)
        XCTAssertEqual(requests.audioUploads, 2)
        XCTAssertEqual(requests.finalizations, 2)
        XCTAssertTrue(requests.violations.isEmpty, requests.violations.joined(separator: ", "))
        XCTAssertEqual(device.keyCalls, 1)
        XCTAssertEqual(device.attestCalls, 1)
        XCTAssertEqual(device.assertionCalls, 2)
        let ledger = ShareLedger.load(from: engine.store.ledgerURL)
        XCTAssertEqual(ledger.records.count, 2)
        XCTAssertTrue(ledger.pendingFailures.isEmpty)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }

    func testLostEnrollmentResponseReusesObjectAfterCoordinatorAndEngineReopen() async throws {
        SignedShareTransport.loseNextEnrollment()
        do { _ = try await share(); XCTFail("The synthetic enrollment response must be lost") }
        catch { }
        XCTAssertTrue(SignedShareTransport.snapshot().creates.isEmpty)
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).pendingFailures.count, 1)
        engine = makeEngine()
        let record = try await share()
        XCTAssertEqual(record.summary?.status, .ready)
        let requests = SignedShareTransport.snapshot()
        XCTAssertEqual(requests.enrollments.count, 2)
        let first = try JSONDecoder().decode(ShareAttestationEnrollment.self, from: XCTUnwrap(requests.enrollments.first))
        let second = try JSONDecoder().decode(ShareAttestationEnrollment.self, from: XCTUnwrap(requests.enrollments.last))
        XCTAssertEqual(first.keyID, second.keyID)
        XCTAssertEqual(first.challengeID, second.challengeID)
        XCTAssertEqual(first.object, second.object, "Reopening must reuse the one-time object")
        XCTAssertEqual(requests.creates.count, 1)
        XCTAssertEqual(requests.shareCount, 1)
        XCTAssertTrue(requests.violations.isEmpty, requests.violations.joined(separator: ", "))
        XCTAssertEqual(device.keyCalls, 1)
        XCTAssertEqual(device.attestCalls, 1)
        XCTAssertEqual(device.assertionCalls, 1)
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).records.count, 1)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }

    func testLostSignedCreateReplaysExactRequestAfterReopenWithoutDuplicateShare() async throws {
        SignedShareTransport.loseNextCreate()
        do { _ = try await share(); XCTFail("The accepted synthetic create response must be lost") }
        catch { }
        let pending = try XCTUnwrap(engine.store.load().jobs.first)
        let originalKey = pending.key
        XCTAssertNotNil(pending.createProof)
        XCTAssertNotNil(pending.createBody)
        XCTAssertNil(pending.created)
        XCTAssertTrue(ShareLedger.load(from: engine.store.ledgerURL).pendingFailures.isEmpty)
        XCTAssertEqual(SignedShareTransport.snapshot().shareCount, 1)
        engine = makeEngine()
        await engine.restore()
        for _ in 0..<150 where ShareLedger.load(from: engine.store.ledgerURL).records.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        await engine.restore()
        let ledger = ShareLedger.load(from: engine.store.ledgerURL)
        let record = try XCTUnwrap(ledger.records.first)
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(record.summary?.status, .ready)
        XCTAssertEqual(ShareLink(url: URL(string: record.link)!, allowedHosts: nil)?.key, originalKey)
        XCTAssertTrue(ledger.pendingFailures.isEmpty)
        let requests = SignedShareTransport.snapshot()
        XCTAssertEqual(requests.creates.count, 2)
        XCTAssertEqual(requests.creates.first, requests.creates.last,
                       "Body and signed header must survive recovery byte for byte")
        XCTAssertEqual(requests.shareCount, 1)
        XCTAssertEqual(requests.audioUploads, 1)
        XCTAssertEqual(requests.finalizations, 1)
        XCTAssertTrue(requests.violations.isEmpty, requests.violations.joined(separator: ", "))
        XCTAssertEqual(device.keyCalls, 1)
        XCTAssertEqual(device.attestCalls, 1)
        XCTAssertEqual(device.assertionCalls, 1, "Recovery must not ask for a replacement assertion")
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }

    func testSupportedDeviceProofFailureNeverSendsUnsignedCreate() async throws {
        device.failAssertion = true
        do { _ = try await share(); XCTFail("Supported-device proof failure must fail the share") }
        catch { }
        let requests = SignedShareTransport.snapshot()
        XCTAssertTrue(requests.creates.isEmpty)
        XCTAssertEqual(requests.shareCount, 0)
        XCTAssertEqual(requests.audioUploads, 0)
        XCTAssertEqual(requests.finalizations, 0)
        XCTAssertTrue(requests.violations.isEmpty)
        XCTAssertEqual(device.assertionCalls, 1)
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).pendingFailures.count, 1)
        XCTAssertTrue(ShareLedger.load(from: engine.store.ledgerURL).records.isEmpty)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }
}

@MainActor
private final class SignedShareDevice: SongShareAttestDevice {
    var isSupported = true
    var keyCalls = 0, attestCalls = 0, assertionCalls = 0
    var failAssertion = false
    func generateKey() async throws -> String {
        keyCalls += 1
        return Data(repeating: 7, count: 32).base64EncodedString()
    }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestCalls += 1
        return clientDataHash
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionCalls += 1
        if failAssertion { throw URLError(.cannotConnectToHost) }
        return clientDataHash
    }
}

/// In-memory external service contract. The synthetic proof is just an envelope
/// digest; this fixture deliberately does not claim Apple signature validation.
private final class SignedShareTransport: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://signed-share.invalid")!
    static let secret = "synthetic-signed-share-secret"
    static let policy = ShareAttestationPolicy(appID: "ABCDEFGHIJ.io.fixture.baton",
        environment: "development", audience: base.absoluteString)
    struct Create: Equatable {
        let body: Data
        let header: String?
        let proof: ShareAttestationProof?
    }
    struct Snapshot {
        var creates: [Create] = []
        var enrollments: [Data] = []
        var shareCount = 0, audioUploads = 0, finalizations = 0
        var violations: [String] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var observed = Snapshot()
    nonisolated(unsafe) private static var challenges: [String: ShareAttestationChallenge] = [:]
    nonisolated(unsafe) private static var enrolledKey: String?
    nonisolated(unsafe) private static var shares: [String: String] = [:]
    nonisolated(unsafe) private static var ready: Set<String> = []
    nonisolated(unsafe) private static var loseEnrollment = false, loseCreate = false
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        observed = Snapshot(); challenges = [:]; enrolledKey = nil; shares = [:]; ready = []
        loseEnrollment = false; loseCreate = false
    }
    static func loseNextEnrollment() { lock.lock(); loseEnrollment = true; lock.unlock() }
    static func loseNextCreate() { lock.lock(); loseCreate = true; lock.unlock() }
    static func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return observed }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == base.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    private static func response(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)" else {
            observed.violations.append("missing synthetic ownership")
            return (401, Data())
        }
        let data = body(request)
        if path == "/v1/share/attestation/status" {
            return (200, Data((enrolledKey == nil ? #"{"registered":false}"# : #"{"registered":true}"#).utf8))
        }
        if path == "/v1/share/attestation/challenge" {
            _ = try JSONDecoder().decode(ShareAttestationChallengeRequest.self, from: data)
            let challenge = ShareAttestationChallenge(id: UUID().uuidString, nonce: UUID().uuidString,
                expiresAt: ShareDate.string(Date() + 300))
            challenges[challenge.id] = challenge
            return (200, try JSONEncoder().encode(challenge))
        }
        if path == "/v1/share/attestation/enroll" {
            observed.enrollments.append(data)
            let enrollment = try JSONDecoder().decode(ShareAttestationEnrollment.self, from: data)
            guard let challenge = challenges[enrollment.challengeID],
                  Data(base64Encoded: enrollment.object) == Data(SHA256.hash(data: Data(challenge.nonce.utf8))) else {
                observed.violations.append("enrollment nonce/object mismatch")
                return (400, Data())
            }
            // Drop the first exchange before registration; reopening must reuse
            // the durable one-time object instead of asking the device again.
            if loseEnrollment { loseEnrollment = false; throw URLError(.networkConnectionLost) }
            enrolledKey = enrollment.keyID
            return (200, Data(#"{"registered":true}"#.utf8))
        }
        if path == "/v1/share/shares", method == "POST" {
            let header = request.value(forHTTPHeaderField: ShareAttestationProof.header)
            let proof = header.flatMap { Data(base64Encoded: $0) }.flatMap {
                try? JSONDecoder().decode(ShareAttestationProof.self, from: $0)
            }
            observed.creates.append(Create(body: data, header: header, proof: proof))
            guard let proof, proof.keyID == enrolledKey, let challenge = challenges[proof.challengeID],
                  Data(base64Encoded: proof.assertion) == Data(SHA256.hash(data: ShareAttestationEnvelope.data(
                    challenge: challenge, policy: policy, secret: secret, requestID: proof.requestID, body: data))) else {
                observed.violations.append("unsigned or mismatched create")
                return (401, Data())
            }
            let id = shares[proof.requestID] ?? Base64URL.encode(Data(UUID().uuidString.utf8).prefix(16))
            shares[proof.requestID] = id; observed.shareCount = shares.count
            if loseCreate { loseCreate = false; throw URLError(.networkConnectionLost) }
            return (201, try JSONEncoder().encode(CreateShareResponse(id: id, url: "\(base)/s/\(id)",
                expiresAt: ShareDate.string(Date() + 86400), uploads: .init(audio: "/v1/share/shares/\(id)/audio",
                    art: "/v1/share/shares/\(id)/art", card: "/v1/share/shares/\(id)/card"))))
        }
        if path == "/v1/share/shares", method == "GET" {
            return (200, try JSONEncoder().encode(ShareList(shares: shares.values.map { summary($0) })))
        }
        let parts = path.split(separator: "/")
        if parts.count == 5, shares.values.contains(String(parts[3])) {
            let id = String(parts[3])
            if parts[4] == "audio", method == "PUT" {
                observed.audioUploads += 1
                return (200, Data(#"{"ok":true}"#.utf8))
            }
            if parts[4] == "finalize", method == "POST" {
                observed.finalizations += 1; ready.insert(id)
                return (200, try JSONEncoder().encode(summary(id)))
            }
        }
        observed.violations.append("unexpected synthetic request")
        return (404, Data())
    }
    private static func summary(_ id: String) -> ShareSummary {
        ShareSummary(id: id, status: ready.contains(id) ? .ready : .pending, createdAt: ShareDate.string(Date()),
            expiresAt: ShareDate.string(Date() + 86400), playCap: 100, preview: nil, stats: ShareStats(), reactions: [])
    }
}
