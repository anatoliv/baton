import BatonShareKit
import Foundation
import XCTest
@testable import BatonMobile

@MainActor
final class SongShareAppAttestTests: XCTestCase {
    private var directory: URL!
    private var configuration: URLSessionConfiguration!
    private var device: AttestDeviceFixture!
    private let client = ShareClient(base: URL(string: "https://attest.invalid")!, secret: "synthetic-install-secret")
    private let policy = ShareAttestationPolicy(appID: "ABCDEFGHIJ.io.fixture.baton", environment: "development", audience: "https://attest.invalid")
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("attest-coordinator-\(UUID())")
        configuration = .ephemeral
        configuration.protocolClasses = [AttestTransportFixture.self]
        device = AttestDeviceFixture()
        AttestTransportFixture.reset()
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func testUnsupportedDeviceDoesNotEnrollOrWriteIdentity() async throws {
        device.isSupported = false
        let coordinator = SongShareAppAttest(directory: directory, device: device, configuration: configuration)
        let proof = try await coordinator.proof(client: client, policy: policy, body: Data("{}".utf8), requestID: UUID().uuidString)
        XCTAssertNil(proof)
        XCTAssertEqual(device.keyCalls, 0)
        XCTAssertEqual(AttestTransportFixture.count("status"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testLostEnrollmentResponseReusesExactAppleObjectAndNonceAfterRelaunch() async throws {
        let first = SongShareAppAttest(directory: directory, device: device, configuration: configuration)
        do {
            _ = try await first.proof(client: client, policy: policy, body: Data("{}".utf8), requestID: UUID().uuidString)
            XCTFail("The fixture loses its first enrollment response")
        } catch { }
        let state = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: state.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(String(decoding: try Data(contentsOf: state), as: UTF8.self).contains(client.secret))
        let resumed = SongShareAppAttest(directory: directory, device: device, configuration: configuration)
        let proof = try await resumed.proof(client: client, policy: policy, body: Data("{}".utf8), requestID: UUID().uuidString)
        XCTAssertNotNil(proof)
        XCTAssertEqual(device.keyCalls, 1)
        XCTAssertEqual(device.attestCalls, 1, "attestKey is a one-time operation")
        XCTAssertEqual(AttestTransportFixture.count("challenge"), 2, "Only one enroll nonce and one create nonce")
        XCTAssertEqual(AttestTransportFixture.count("enroll"), 2)
        XCTAssertEqual(device.assertionCalls, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        XCTAssertNil(object["enrollment"], "Receipt/object is cleared once the key is registered")
    }
    func testUnexpectedServiceAudienceFailsBeforeAppleEnrollment() async throws {
        var other = policy; other.audience = "https://other.invalid"
        let coordinator = SongShareAppAttest(directory: directory, device: device, configuration: configuration)
        do {
            _ = try await coordinator.proof(client: client, policy: other, body: Data("{}".utf8), requestID: UUID().uuidString)
            XCTFail("An unexpected deployment audience cannot enroll this client")
        } catch { }
        XCTAssertEqual(device.keyCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testAssertionAPIErrorFailsWithoutReturningUnverifiedProof() async throws {
        AttestTransportFixture.allowFirstEnrollment()
        device.failAssertion = true
        let coordinator = SongShareAppAttest(directory: directory, device: device, configuration: configuration)
        do {
            _ = try await coordinator.proof(client: client, policy: policy, body: Data("{}".utf8), requestID: UUID().uuidString)
            XCTFail("An API error must not silently downgrade")
        } catch { }
        XCTAssertEqual(device.assertionCalls, 1)
        XCTAssertEqual(device.keyCalls, 1)
    }
}

@MainActor
private final class AttestDeviceFixture: SongShareAttestDevice {
    var isSupported = true
    var keyCalls = 0, attestCalls = 0, assertionCalls = 0
    var failAssertion = false
    func generateKey() async throws -> String { keyCalls += 1; return Data(repeating: 7, count: 32).base64EncodedString() }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { attestCalls += 1; return Data("synthetic-attestation".utf8) }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionCalls += 1
        if failAssertion { throw URLError(.cannotConnectToHost) }
        return Data("synthetic-assertion".utf8)
    }
}

private final class AttestTransportFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String: Int] = [:]
    nonisolated(unsafe) private static var loseEnrollment = true
    static func reset() { lock.lock(); requests = [:]; loseEnrollment = true; lock.unlock() }
    static func allowFirstEnrollment() { lock.lock(); loseEnrollment = false; lock.unlock() }
    static func count(_ action: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests[action] ?? 0 }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "attest.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let action = request.url!.lastPathComponent
        Self.lock.lock()
        Self.requests[action, default: 0] += 1
        let lose = Self.loseEnrollment && action == "enroll" && Self.requests[action] == 1
        Self.lock.unlock()
        if lose { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let data: Data
        if action == "challenge" {
            data = try! JSONEncoder().encode(ShareAttestationChallenge(id: UUID().uuidString, nonce: "synthetic-nonce",
                expiresAt: ShareDate.string(Date() + 300)))
        } else { data = Data((action == "status" ? #"{"registered":false}"# : #"{"registered":true}"#).utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
