import Foundation
import XCTest
@testable import BatonShareKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A synthetic HTTP peer keeps its body open after exceeding the receipt limit.
/// Cancellation is observed by that peer, independently of a final client error.
private final class PushReceiptPeer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var started: XCTestExpectation?
    nonisolated(unsafe) static var stopped: XCTestExpectation?
    nonisolated(unsafe) static var active: PushReceiptPeer?
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "synthetic.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.active = self
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 4096))
        client?.urlProtocol(self, didLoad: Data([66]))
        Self.started?.fulfill()
        // No completion: a bounded client must cancel before the peer ends this body.
    }
    override func stopLoading() { Self.stopped?.fulfill(); Self.stopped = nil }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
}

final class ReactionPushClientTests: XCTestCase {
    func testRegistrationCancelsOverflowBeforeAnUnfinishedPeerCompletes() async throws {
        let started = expectation(description: "synthetic peer began its overflowing response")
        let stopped = expectation(description: "peer observed early cancellation")
        PushReceiptPeer.started = started; PushReceiptPeer.stopped = stopped
        XCTAssertTrue(URLProtocol.registerClass(PushReceiptPeer.self))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushReceiptPeer.self]
        let session = URLSession(configuration: configuration)
        defer {
            PushReceiptPeer.active?.finish()
            PushReceiptPeer.active = nil; PushReceiptPeer.started = nil; PushReceiptPeer.stopped = nil
            URLProtocol.unregisterClass(PushReceiptPeer.self)
            session.invalidateAndCancel()
        }
        let client = ShareClient(base: URL(string: "https://synthetic.invalid")!,
                                 secret: "synthetic-installation", session: session)
        let registration = Task {
            try await client.registerReactionDevice(deviceID: UUID(), token: Data([1, 2, 3]),
                topic: "io.tonebox.baton.tests", environment: "sandbox", proof: Data([4]))
        }
        await fulfillment(of: [started], timeout: 2)
        await fulfillment(of: [stopped], timeout: 1)
        // Also finish the legacy unbounded path, so a red regression leaves no request behind.
        PushReceiptPeer.active?.finish()
        do { try await registration.value; XCTFail("An overflowing registration receipt escaped") }
        catch {
            let text = String(describing: error)
            XCTAssertFalse(text.contains("synthetic-installation"))
            XCTAssertFalse(text.contains("synthetic.invalid"))
        }
    }
}
