import Foundation
import XCTest
@testable import BatonShareKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A synthetic share service whose create answer names upload paths it chose. Records every
/// request it sees, with whether it carried the bearer.
private final class CreatePeer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var uploads = CreateShareResponse.Uploads(audio: "", art: "", card: "")
    nonisolated(unsafe) static var seen: [(host: String, method: String, bearer: Bool)] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        ["share.invalid", "elsewhere.invalid"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.withLock {
            Self.seen.append((url.host ?? "", request.httpMethod ?? "",
                              request.value(forHTTPHeaderField: "Authorization") != nil))
        }
        let body: Data
        if request.httpMethod == "POST", url.path == "/v1/share/shares" {
            body = try! JSONEncoder().encode(CreateShareResponse(
                id: "abcdefghijklmnopqrstuv", url: "https://share.invalid/s/abcdefghijklmnopqrstuv",
                expiresAt: "2026-10-28T00:00:00Z", uploads: Self.uploads))
        } else {
            body = Data(#"{"ok":true}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ShareClientUploadOriginTests: XCTestCase {
    private func client() -> (ShareClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreatePeer.self]
        let session = URLSession(configuration: configuration)
        return (ShareClient(base: URL(string: "https://share.invalid")!, secret: "synthetic-installation",
                            session: session), session)
    }

    private func prepared() throws -> PreparedShare {
        try PreparedShare.make(audio: Data(repeating: 7, count: 2048),
                               metadata: ShareMetadata(title: "Song", artist: "Artist", durationSeconds: 35),
                               isPrivate: true, expiresInSeconds: 604_800, playCap: 10,
                               client: ShareClientInfo(platform: "macos", appVersion: "0.0.0"))
    }

    /// C-25: the create answer chooses where the authenticated PUTs go. One that names another
    /// origin (absolute, or scheme-relative) is refused before any upload, so the install secret
    /// never reaches that host.
    func testUploadPathsOnAnotherOriginAreRefusedBeforeTheBearerIsSent() async throws {
        for audio in ["https://elsewhere.invalid/v1/share/shares/x/audio",
                      "//elsewhere.invalid/v1/share/shares/x/audio",
                      "http://share.invalid/v1/share/shares/x/audio"] {
            CreatePeer.lock.withLock { CreatePeer.seen = [] }
            CreatePeer.uploads = .init(audio: audio, art: "/v1/share/shares/x/art", card: "/v1/share/shares/x/card")
            let (client, session) = client()
            defer { session.invalidateAndCancel() }
            do {
                _ = try await client.share(prepared())
                XCTFail("\(audio): a share uploaded to a path on another origin")
            } catch {}
            let seen = CreatePeer.lock.withLock { CreatePeer.seen }
            XCTAssertEqual(seen.filter { $0.host != "share.invalid" }.count, 0, "\(audio): \(seen)")
            XCTAssertEqual(seen.map(\.method), ["POST"], "\(audio): nothing after the create")
        }
    }

    func testSameOriginUploadPathsStillShare() async throws {
        CreatePeer.lock.withLock { CreatePeer.seen = [] }
        CreatePeer.uploads = .init(audio: "/v1/share/shares/x/audio", art: "/v1/share/shares/x/art",
                                   card: "/v1/share/shares/x/card")
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        do { _ = try await client.share(prepared()) } catch {
            // The synthetic finalize body is not a summary; only the uploads matter here.
        }
        let seen = CreatePeer.lock.withLock { CreatePeer.seen }
        XCTAssertEqual(seen.map(\.method).prefix(2), ["POST", "PUT"])
        XCTAssertTrue(seen.allSatisfy { $0.host == "share.invalid" && $0.bearer })
    }
}
