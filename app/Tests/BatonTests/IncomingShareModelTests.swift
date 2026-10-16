@testable import Baton
import BatonShareKit
import Foundation
import XCTest

private actor SuspendedIncomingTransport: ShareReceiverTransport {
    private var response: CheckedContinuation<ShareReceiverResponse, Error>?
    private var arrived: CheckedContinuation<Void, Never>?
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ShareReceiverResponse {
        try await withCheckedThrowingContinuation { continuation in
            response = continuation
            arrived?.resume(); arrived = nil
        }
    }
    func waitForRequest() async {
        if response != nil { return }
        await withCheckedContinuation { arrived = $0 }
    }
    func complete(_ body: Data) { response?.resume(returning: .init(status: 200, body: body)); response = nil }
}

@MainActor
final class IncomingShareModelTests: XCTestCase {
    func testClosingWhileMetadataRequestIsSuspendedDoesNotRestorePrivateContent() async throws {
        let transport = SuspendedIncomingTransport()
        let model = SharedWithYouModel(client: try ShareReceiverClient(transport: transport))
        let key = Data(repeating: 4, count: 16)
        let invitation = ShareInvitation(id: Base64URL.encode(Data(repeating: 3, count: 16)), key: key)
        let task = Task { await model.load(invitation) }
        await transport.waitForRequest()
        model.clear()
        let metadata = ShareMetadata(title: "Private synthetic song", durationSeconds: 30)
        let sealed = try ShareCrypto.seal(JSONEncoder().encode(metadata), key: key, purpose: .meta)
        let payload = PublicShare(status: .ready, preview: nil, encryptedMeta: sealed.base64EncodedString(),
            audioBytes: 100, hasArt: false, hasCard: false,
            expiresAt: ShareDate.string(Date().addingTimeInterval(3600)))
        await transport.complete(try JSONEncoder().encode(payload))
        await task.value
        XCTAssertNil(model.metadata, "a late authenticated response must not revive a closed presentation")
        XCTAssertNil(model.artwork)
        XCTAssertNil(model.libraryResult)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.canReact)
    }
}
