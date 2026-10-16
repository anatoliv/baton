import BatonShareKit
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonShareServer

private actor CapturingAPNsTransport: APNsTransport {
    var requests: [URLRequest] = []
    let response: APNsResponse
    init(status: Int = 200, body: Data = Data(), http2: Bool = true) {
        response = APNsResponse(status: status, body: body, negotiatedHTTP2: http2)
    }
    func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> APNsResponse {
        requests.append(request); return response
    }
}

/// Intercepts the fixed Apple-host request entirely in memory; no APNs connection exists.
private final class SyntheticOversizedAPNsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 4096))
        client?.urlProtocol(self, didLoad: Data([2]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ShareReactionPushProviderTests: XCTestCase {
    private let timestamp: Int64 = 1_790_000_000_000
    private func lease(environment: PushEnvironment = .sandbox, expiration: Int64? = nil,
                       topic: String = "io.tonebox.baton.tests") -> ReactionPushLease {
        ReactionPushLease(jobID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", leaseID: UUID().uuidString,
                          owner: String(repeating: "a", count: 64), deviceID: UUID().uuidString,
                          revision: UUID().uuidString, generation: 1, registeredAt: timestamp,
                          shareID: "AAAAAAAAAAAAAAAAAAAAAA", topic: topic, environment: environment,
                          token: Data([0, 17, 255]), deadline: timestamp + 30_000,
                          expiration: expiration ?? timestamp + 3_600_000)
    }
    func testRealES256JWTAndBoundedAPNsRequestUseNoShareMetadata() async throws {
        let key = P256.Signing.PrivateKey(); let transport = CapturingAPNsTransport()
        let publicKeyBytes = key.publicKey.rawRepresentation
        let timestamp = self.timestamp
        // The provider gets its own copy: Swift Crypto's key is not Sendable on Linux, and this
        // test keeps `key` to verify the signature after the provider actor has used it.
        let provider = try APNsReactionPushProvider(key: P256.Signing.PrivateKey(rawRepresentation: key.rawRepresentation),
            keyID: "TESTKEY123", teamID: "TESTTEAM12",
            topics: ["io.tonebox.baton.tests": .sandbox], transport: transport,
            clock: { Date(timeIntervalSince1970: Double(timestamp) / 1000) })
        let result = try await provider.send(lease()); XCTAssertEqual(result, .accepted)
        let requests = await transport.requests; let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/0011ff")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-expiration"), "1790003600")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-id"), "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "alert")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "io.tonebox.baton.tests")
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "authorization"))
        let parts = authorization.dropFirst(7).split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let claims = try XCTUnwrap(try JSONSerialization.jsonObject(with: Base64URL.decode(parts[1])!) as? [String: Any])
        XCTAssertEqual(claims["iss"] as? String, "TESTTEAM12")
        XCTAssertEqual(claims["iat"] as? Int64, timestamp / 1000)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Base64URL.decode(parts[2])!)
        XCTAssertTrue(try P256.Signing.PublicKey(rawRepresentation: publicKeyBytes)
            .isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["aps", "baton"])
        let aps = try XCTUnwrap(payload["aps"] as? [String: String]); XCTAssertEqual(Set(aps.keys), ["alert"])
        XCTAssertEqual(aps["alert"], "Someone reacted to your shared song.")
        _ = try await provider.send(lease())
        let repeated = await transport.requests
        XCTAssertEqual(repeated[1].value(forHTTPHeaderField: "authorization"), authorization)
    }
    func testWrongTopicEnvironmentAndExpiredWorkNeverStartTransport() async throws {
        let transport = CapturingAPNsTransport(); let timestamp = self.timestamp
        let provider = try APNsReactionPushProvider(key: .init(), keyID: "TESTKEY123", teamID: "TESTTEAM12",
            topics: ["io.tonebox.baton.tests": .sandbox], transport: transport,
            clock: { Date(timeIntervalSince1970: Double(timestamp) / 1000) })
        let mismatch = try await provider.send(lease(environment: .production))
        let expired = try await provider.send(lease(expiration: timestamp))
        XCTAssertEqual(mismatch, .providerPaused); XCTAssertEqual(expired, .discarded)
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testHTTP1OrUnmeasuredResponseCannotClaimAPNsAcceptance() async throws {
        let timestamp = self.timestamp; let transport = CapturingAPNsTransport(http2: false)
        let provider = try APNsReactionPushProvider(key: .init(), keyID: "TESTKEY123", teamID: "TESTTEAM12",
            topics: ["io.tonebox.baton.tests": .sandbox], transport: transport,
            clock: { Date(timeIntervalSince1970: Double(timestamp) / 1000) })
        let result = try await provider.send(lease()); XCTAssertEqual(result, .retry(delayMilliseconds: 900_000))
    }
    func testTransportRejectsNonAppleOrInsecureRequestBeforeAnyNetwork() async throws {
        for value in ["http://api.push.apple.com/3/device/aa", "https://example.com/3/device/aa",
                      "https://api.push.apple.com:444/3/device/aa", "https://api.push.apple.com/3/device/aa?extra=1"] {
            var request = URLRequest(url: URL(string: value)!); request.httpMethod = "POST"; request.httpBody = Data()
            do { _ = try await URLSessionAPNsTransport().perform(request, timeout: 1); XCTFail("Unexpected transport admission") }
            catch APNsProviderFailure.invalid {} catch { XCTFail("Wrong admission result") }
        }
    }
    func testStreamingResponseOverflowSettlesAsFailureWithoutReturningBytes() async throws {
        var request = URLRequest(url: URL(string: "https://api.sandbox.push.apple.com/3/device/00")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        do {
            _ = try await URLSessionAPNsTransport(protocolClass: SyntheticOversizedAPNsProtocol.self)
                .perform(request, timeout: 1)
            XCTFail("An oversized response must never be accepted")
        } catch APNsProviderFailure.transport {} catch { XCTFail("Unexpected bounded transport result") }
    }
    func testExplicitSchedulerCancellationAndOnePollerAtATime() async throws {
        let started = SchedulerStartSignal()
        let dispatcher = ReactionPushDispatcher(provider: CapturingPushProviderForScheduler(),
            prepare: { await started.mark(); return nil }, admit: { _ in true }, finish: { _, _ in })
        let first = Task { try await dispatcher.runUntilCancelled(idleMilliseconds: 250) }
        await started.wait()
        do { try await dispatcher.runUntilCancelled(idleMilliseconds: 250); XCTFail("Duplicate scheduler") }
        catch APNsProviderFailure.invalid {} catch { XCTFail("Wrong duplicate result") }
        first.cancel()
        do { try await first.value } catch is CancellationError {}
        let running = await dispatcher.schedulerRunning; XCTAssertFalse(running)
    }
}

private actor SchedulerStartSignal {
    private var seen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func mark() { seen = true; continuation?.resume(); continuation = nil }
    func wait() async {
        if seen { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private struct CapturingPushProviderForScheduler: ReactionPushProvider {
    func send(_ lease: ReactionPushLease) async throws -> ReactionPushResult { .accepted }
}

private struct SyntheticRegistrationAdmission: ReactionPushRegistrationAdmission {
    let accept: Bool
    func admits(ownerDigest: String, deviceID: String, token: Data, topic: String,
                environment: PushEnvironment, proof: Data, now: Int64) -> Bool {
        accept && proof == Data("synthetic-proof".utf8)
    }
}

extension ShareServiceTests {
    private var pushDevice: String { "11111111-1111-1111-1111-111111111111" }
    private var pushPath: String { "/v1/share/owner/push-devices/" + pushDevice }
    private var pushBody: [String: String] {
        ["token": Data("synthetic-token".utf8).base64EncodedString(), "topic": "io.tonebox.baton.tests",
         "environment": "sandbox", "proof": Data("synthetic-proof".utf8).base64EncodedString()]
    }
    private func registrationService(admission: (any ReactionPushRegistrationAdmission)? = SyntheticRegistrationAdmission(accept: true)) throws {
        let clock = self.clock!
        service = try ShareService(config: service.config,
            reactionPushPolicy: ReactionPushPolicy(enabled: true, key: Data(repeating: 42, count: 32),
                                                  topics: ["io.tonebox.baton.tests": .sandbox]),
            registrationAdmission: admission, clock: { clock.now })
    }
    func testPushRegistrationDefaultUnavailableAndInstallBearerAloneInsufficient() throws {
        XCTAssertEqual(request("PUT", pushPath, json: pushBody, secret: secret).status, 404)
        try registrationService(admission: nil); _ = try makeReadyShare()
        XCTAssertEqual(request("PUT", pushPath, json: pushBody, secret: secret).status, 503)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 0)
    }
    func testPushConfigurationAdvertisesOnlyExplicitlyProtectedRegistration() throws {
        func config() throws -> ShareConfig {
            try JSONDecoder().decode(ShareConfig.self, from: request("GET", "/v1/share/config").body)
        }
        XCTAssertNil(try config().reactionPush)
        try registrationService(admission: nil); XCTAssertNil(try config().reactionPush)
        try registrationService()
        let advertisement = try XCTUnwrap(try config().reactionPush)
        XCTAssertTrue(advertisement.permits(topic: "io.tonebox.baton.tests", environment: "sandbox"))
        XCTAssertFalse(advertisement.permits(topic: "io.tonebox.baton.tests", environment: "production"))
        service.reactionPushStore?.policy = try ReactionPushPolicy()
        XCTAssertNil(try config().reactionPush)
    }
    func testPushRegistrationRequiresExistingAuthenticatedOwnerAndDeviceIntegrity() throws {
        try registrationService(admission: SyntheticRegistrationAdmission(accept: false))
        XCTAssertEqual(request("PUT", pushPath, json: pushBody, secret: otherSecret).status, 401)
        _ = try makeReadyShare()
        XCTAssertEqual(request("PUT", pushPath, json: pushBody).status, 401)
        XCTAssertEqual(request("PUT", pushPath, json: pushBody, secret: secret).status, 401)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 0)
    }
    func testPushRegistrationBoundsAndAllowlistRejectBeforeStorage() throws {
        try registrationService(); _ = try makeReadyShare()
        var bad = pushBody; bad["topic"] = "attacker.topic"
        XCTAssertEqual(request("PUT", pushPath, json: bad, secret: secret).status, 400)
        bad = pushBody; bad["environment"] = "production"
        XCTAssertEqual(request("PUT", pushPath, json: bad, secret: secret).status, 400)
        bad = pushBody; bad["token"] = Data(repeating: 1, count: 1025).base64EncodedString()
        XCTAssertEqual(request("PUT", pushPath, json: bad, secret: secret).status, 400)
        bad = pushBody; bad["unexpected"] = "ignored?"
        XCTAssertEqual(request("PUT", pushPath, json: bad, secret: secret).status, 400)
        XCTAssertEqual(request("PUT", pushPath, body: Data(repeating: 1, count: 8193), secret: secret).status, 400)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 0)
    }
    func testPushRegistrationOptOutIsOwnerBoundAndWorksWithoutKeyWhilePaused() throws {
        try registrationService(); let made = try makeReadyShare()
        _ = try makeReadyShare(secret: otherSecret)
        XCTAssertEqual(request("PUT", pushPath, json: pushBody, secret: secret).status, 200)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"]).status, 204)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 1)
        XCTAssertEqual(request("DELETE", pushPath, secret: otherSecret).status, 204)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 1)
        service.reactionPushStore?.policy = try ReactionPushPolicy()
        XCTAssertEqual(request("DELETE", pushPath, secret: secret).status, 204)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_devices"), 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM reaction_push_jobs"), 0)
    }
}
