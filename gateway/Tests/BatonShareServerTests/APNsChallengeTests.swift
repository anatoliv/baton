import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonShareServer

/// Observes the actual transport's response to a synthetic account challenge.
/// All Apple-host requests are intercepted in memory; no provider connection exists.
private final class SyntheticAPNsChallengePeer: URLProtocol, URLAuthenticationChallengeSender, @unchecked Sendable {
    nonisolated(unsafe) static var settled: XCTestExpectation?
    nonisolated(unsafe) static var disposition: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let space = URLProtectionSpace(host: "api.sandbox.push.apple.com", port: 443,
            protocol: "https", realm: "Synthetic account challenge", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: self)
        client?.urlProtocol(self, didReceive: challenge)
    }
    override func stopLoading() {
        // Cancelling a URLSession challenge closes its protocol without invoking the
        // protocol-provided sender. Observe the peer closure, preserving any earlier
        // default/credential disposition so it cannot masquerade as denial.
        guard Self.disposition == nil else { return }
        Self.disposition = "cancelled"
        Self.settled?.fulfill()
    }
    private func finish(_ value: String) {
        Self.disposition = value
        Self.settled?.fulfill()
        client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
    }
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { finish("credential") }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { finish("continued") }
    func cancel(_ challenge: URLAuthenticationChallenge) { finish("cancelled") }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { finish("default") }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { finish("rejected") }
}

final class APNsChallengeTests: XCTestCase {
    func testProviderCancelsAccountAuthenticationWithoutAdditionalAuthority() async {
        let settled = expectation(description: "Synthetic peer observed authentication disposition")
        SyntheticAPNsChallengePeer.settled = settled
        SyntheticAPNsChallengePeer.disposition = nil
        defer { SyntheticAPNsChallengePeer.settled = nil }
        var request = URLRequest(url: URL(string: "https://api.sandbox.push.apple.com/3/device/00")!)
        request.httpMethod = "POST"; request.httpBody = Data()
        let attempt = Task { try await URLSessionAPNsTransport(protocolClass: SyntheticAPNsChallengePeer.self).perform(request, timeout: 2) }
        await fulfillment(of: [settled], timeout: 1)
        _ = try? await attempt.value
        XCTAssertEqual(SyntheticAPNsChallengePeer.disposition, "cancelled", "Provider must refuse account authentication rather than add authority beyond its injected bearer")
    }
}
