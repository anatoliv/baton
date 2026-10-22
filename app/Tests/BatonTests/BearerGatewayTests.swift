import XCTest
@testable import Baton
@testable import BatonPlaybackKit

/// The gateway token never crosses the internet in the clear (the Mac half of
/// An internal task).
///
/// The phone asks `GatewayAddress.allowsBearer` before every gateway client it builds. On the
/// Mac only the document inbox asked; kept readings, revoiced clippings, deleting a shared copy,
/// home-server books and preference sync all attached the token to whatever address Settings
/// held, including `http://` to a public IP, which App Transport Security lets through.
@MainActor
final class BearerGatewayTests: XCTestCase {
    private let publicHTTP = "http://203.0.113.7:8788"

    /// Preference sync's own resolver, the one the scheduler runs on every activation.
    func testPreferenceSyncRefusesPlainHTTPToAPublicAddress() {
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: publicHTTP, token: "s3cret"))
        XCTAssertNil(PreferenceSyncScheduler.gateway(urlString: "http://[2001:db8::7]:8788", token: "s3cret"))
    }

    /// What the card asks for in so many words: a request built the way every Mac path builds
    /// one, for a public plain-HTTP gateway, sends no Authorization header. The home network
    /// still gets one, so the guard is not simply refusing everything.
    func testAPublicPlainHTTPGatewaySendsNoAuthorizationHeader() async {
        let publicHeaders = await headersSent(to: publicHTTP)
        XCTAssertTrue(publicHeaders.isEmpty, "a request reached \(publicHTTP): \(publicHeaders)")

        let homeHeaders = await headersSent(to: "http://192.168.1.20:8788")
        XCTAssertEqual(homeHeaders, ["Bearer s3cret"], "the home network must still be reached")
    }

    /// Every Mac path that attaches the token resolves the gateway through one place, so a new
    /// path cannot quietly skip the rule. Only the helper reads the token's Keychain account;
    /// Settings shows it through `BearerGateway.savedToken()` and sends it through `resolve`.
    func testOnlyTheHelperReadsTheGatewayToken() throws {
        let root = try repoRoot()
        let allowed: Set<String> = ["app/Sources/Baton/Remote/BearerGateway.swift"]
        var readers: [String] = []
        for folder in ["app/Sources", "Shared"] {
            let base = root.appending(path: folder)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      text.contains("secret(account: \"baton.agent.gatewayToken\")")
                        || text.contains("secret(account: BearerGateway.tokenAccount)") else { continue }
                let relative = String(url.path.dropFirst(root.path.count + 1))
                if !allowed.contains(relative) { readers.append(relative) }
            }
        }
        XCTAssertEqual(readers.sorted(), [], "these read the gateway token without BearerGateway")
    }

    /// The phone's rule, case by case: what still gets the token, and what does not.
    func testTheResolverKeepsTheHomeNetworkAndRefusesThePublicInternet() {
        for allowed in ["https://203.0.113.7:8788", "https://baton.example.com",
                        "http://192.168.1.20:8788", "http://10.0.0.5:8788", "http://127.0.0.1:8788",
                        "http://localhost:8788", "http://100.101.102.103:8788", "http://nas.local:8788",
                        "http://[fd7a:115c:a1e0::1]:8788"] {
            XCTAssertNotNil(BearerGateway.resolve(address: allowed, token: "s3cret"), allowed)
        }
        for refused in [publicHTTP, "http://8.8.8.8", "http://[2001:db8::7]:8788", "ftp://192.168.1.20"] {
            XCTAssertNil(BearerGateway.resolve(address: refused, token: "s3cret"), refused)
        }
        XCTAssertEqual(BearerGateway.resolve(address: " http://192.168.1.20:8788 ", token: " s3cret ")?.token, "s3cret")
        XCTAssertNil(BearerGateway.resolve(address: "http://192.168.1.20:8788", token: "  "))
        XCTAssertNil(BearerGateway.resolve(address: nil, token: "s3cret"))
    }

    /// Settings names the actual reason a Test or Sync now did not send the token.
    func testSettingsNamesWhyTheTokenWasNotSent() {
        XCTAssertNil(SharedSettingsPane.notSentReason(address: "http://192.168.1.20:8788", token: "s3cret"))
        XCTAssertTrue(SharedSettingsPane.notSentReason(address: publicHTTP, token: "s3cret")?.contains("unencrypted") == true)

        let blank = SharedSettingsPane.notSentReason(address: "http://192.168.1.20:8788", token: "   ") ?? ""
        XCTAssertTrue(blank.contains("token"), blank)
        XCTAssertFalse(blank.contains("home network"), "a blank token is not an address problem: \(blank)")

        let ftp = SharedSettingsPane.notSentReason(address: "ftp://192.168.1.20", token: "s3cret") ?? ""
        XCTAssertTrue(ftp.contains("http"), ftp)
        XCTAssertFalse(ftp.contains("home network"), "ftp on the home network is refused for its scheme: \(ftp)")
    }

    // MARK: - Helpers

    /// The Authorization headers a stand-in gateway saw while one Mac path listed its files.
    private func headersSent(to address: String) async -> [String] {
        let host = URL(string: address)!.host!
        BearerGatewayProbe.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BearerGatewayProbe.self]
        let session = URLSession(configuration: configuration)
        if let gateway = PreferenceSyncScheduler.gateway(urlString: address, token: "s3cret") {
            _ = try? await GatewayFiles(gatewayURL: gateway.url, token: gateway.token, session: session).list()
        }
        return BearerGatewayProbe.seen(host: host)
    }

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 8 {
            dir.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appending(path: "Shared/ArtworkPalette.swift").path) { return dir }
        }
        throw XCTSkip("repo root not found from \(#filePath)")
    }
}

/// Records the Authorization header of every request and answers an empty file list.
final class BearerGatewayProbe: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var headers: [(host: String, value: String)] = []
    private static let lock = NSLock()

    static func reset() { lock.withLock { headers = [] } }
    static func seen(host: String) -> [String] {
        lock.withLock { headers.filter { $0.host == host }.map(\.value) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let value = request.value(forHTTPHeaderField: "Authorization") ?? "(none)"
        Self.lock.withLock { Self.headers.append((host, value)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
