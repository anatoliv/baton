import XCTest
@testable import BatonSubsonicKit
import BatonSubsonicModels

/// Pins `NavidromeConfig.verify`'s extensions probe: a classic Subsonic server (no
/// OpenSubsonic support, so `getOpenSubsonicExtensions.view` 404s) must never present API
/// key auth as broken — only as unavailable-or-unknown — and a 404 there must never turn an
/// otherwise-working password login into a connect failure. TBX-5264.
final class NavidromeConfigVerifyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// `extensionsStatus` nil means "answer with `extensionsBody`"; a non-200 value simulates
    /// the probe failing outright (a 404 on a classic server, or any other transport hiccup).
    private func respond(extensionsStatus: Int? = nil, extensionsBody: String = "") {
        StubURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            if path.hasSuffix("ping.view") {
                return StubURLProtocol.ok("", for: request)
            }
            if path.hasSuffix("getOpenSubsonicExtensions.view") {
                if let status = extensionsStatus {
                    return (StubURLProtocol.http(status, for: request), Data())
                }
                return StubURLProtocol.ok(extensionsBody, for: request)
            }
            XCTFail("unexpected request to \(path)")
            return StubURLProtocol.ok("", for: request)
        }
    }

    private func verify(authMode: NavidromeAuthMode = .tokenSalt) async throws -> NavidromeConfig.ConnectInfo {
        try await NavidromeConfig.verify(
            urlString: "https://music.example.com",
            username: "joe", secret: "sesame", authMode: authMode,
            session: StubURLProtocol.session()
        )
    }

    /// A working password login must succeed even though the extensions probe 404s — the
    /// probe is best-effort and must never fail the connect itself.
    func testAWorkingPasswordLoginSucceedsDespiteA404OnExtensions() async throws {
        respond(extensionsStatus: 404)
        let info = try await verify()
        XCTAssertEqual(info.extensions, [])
    }

    /// The 404 must read as "we don't know", not "the server confirmed no extensions" — that
    /// is the distinction the picker relies on to avoid calling a classic server's API-key
    /// row broken.
    func testA404OnExtensionsIsUnknownNotConfirmedUnsupported() async throws {
        respond(extensionsStatus: 404)
        let info = try await verify()
        XCTAssertFalse(info.extensionsProbed)
        XCTAssertFalse(info.supportsAPIKey)
        XCTAssertFalse(info.apiKeyKnownUnsupported, "a probe failure must read as unknown, not as broken")
    }

    /// A server that actually answers the probe and omits `apiKeyAuthentication` gives
    /// positive evidence — unlike the 404 case above, this one is safe to call unsupported.
    func testAServerThatAnswersWithoutAPIKeySupportIsKnownUnsupported() async throws {
        respond(extensionsBody: #""openSubsonicExtensions":[{"name":"songLyrics","versions":[1]}]"#)
        let info = try await verify()
        XCTAssertTrue(info.extensionsProbed)
        XCTAssertFalse(info.supportsAPIKey)
        XCTAssertTrue(info.apiKeyKnownUnsupported)
    }

    /// A server that advertises `apiKeyAuthentication` is neither unsupported nor unknown.
    func testAServerThatAdvertisesAPIKeySupportIsNotKnownUnsupported() async throws {
        respond(extensionsBody: #""openSubsonicExtensions":[{"name":"apiKeyAuthentication","versions":[1]}]"#)
        let info = try await verify()
        XCTAssertTrue(info.supportsAPIKey)
        XCTAssertFalse(info.apiKeyKnownUnsupported)
    }
}
