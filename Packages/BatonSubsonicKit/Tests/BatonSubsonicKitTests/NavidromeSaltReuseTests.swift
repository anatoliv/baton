import XCTest
@testable import BatonSubsonicKit
import BatonSubsonicModels

/// The salt has to survive the client, because nothing in either app survives a request.
///
/// Every call site builds a `NavidromeClient` and drops it, so a salt cached on the instance
/// was minted and thrown away 645 times for 456 covers in the owner's live `URLCache`
///. These tests are about the pair of query items two consecutive requests carry,
/// not about the class that mints them.
final class NavidromeSaltReuseTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        NavidromeSaltCache.removeAll()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        NavidromeSaltCache.removeAll()
        super.tearDown()
    }

    private func credentials(
        host: String = "https://music.example.com",
        username: String = "joe",
        secret: String = "sesame",
        authMode: NavidromeAuthMode = .tokenSalt
    ) -> NavidromeCredentials {
        NavidromeCredentials(
            baseURL: URL(string: host)!, username: username, secret: secret, authMode: authMode
        )
    }

    /// One request through a freshly built client, the way every call site does it.
    private func ping(_ credentials: NavidromeCredentials) async throws {
        StubURLProtocol.handler = { request, _ in StubURLProtocol.ok("", for: request) }
        try await NavidromeClient(credentials: credentials, session: StubURLProtocol.session()).ping()
    }

    private func item(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    // MARK: - The one the card asks for

    /// Red before the fix: each `NavidromeClient(...)` minted its own salt, so two requests a
    /// second apart carried two different `s=` values and no cache could match them.
    func testTwoConsecutiveRequestsForTheSameServerReuseTheSalt() async throws {
        try await ping(credentials())
        try await ping(credentials())

        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 2)
        let first = StubURLProtocol.requestedURLs[0]
        let second = StubURLProtocol.requestedURLs[1]
        XCTAssertNotNil(item("s", in: first), "a tokenSalt request must carry a salt")
        XCTAssertEqual(
            item("s", in: second), item("s", in: first),
            "two requests to the same server must sign with the same salt, or no cache can match a repeat URL"
        )
        XCTAssertEqual(
            item("t", in: second), item("t", in: first),
            "the same salt and the same password must give the same token"
        )
    }

    /// The cache is what the URL is for. Two cover-art URLs built through two clients have to
    /// be byte-identical, which is the property `URLCache` and `AsyncImage` key on.
    func testTwoCoverArtURLsBuiltThroughSeparateClientsAreByteIdentical() {
        let credentials = credentials()
        let first = NavidromeClient(credentials: credentials).coverArtURL(id: "al-1", size: 600)
        let second = NavidromeClient(credentials: credentials).coverArtURL(id: "al-1", size: 600)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "the same cover through two clients must produce one URL")
    }

    // MARK: - What reuse must not paper over

    func testAChangedPasswordMintsAFreshSalt() async throws {
        try await ping(credentials(secret: "sesame"))
        try await ping(credentials(secret: "open-sesame"))

        let first = StubURLProtocol.requestedURLs[0]
        let second = StubURLProtocol.requestedURLs[1]
        XCTAssertNotEqual(
            item("s", in: second), item("s", in: first),
            "a new password must not be signed with the salt the old one was signed with"
        )
        XCTAssertEqual(
            item("t", in: second),
            NavidromeClient.token(password: "open-sesame", salt: item("s", in: second) ?? ""),
            "the token on the wire must be md5 of the current password and the salt beside it"
        )
    }

    func testEachServerAndEachUserGetsItsOwnSalt() async throws {
        try await ping(credentials())
        try await ping(credentials(host: "https://other.example.com"))
        try await ping(credentials(username: "jane"))

        let salts = StubURLProtocol.requestedURLs.compactMap { item("s", in: $0) }
        XCTAssertEqual(salts.count, 3)
        XCTAssertEqual(Set(salts).count, 3, "a salt must not cross a server boundary or a user boundary")
    }

    /// A salt is public, a password is not. The store may hold only what is already in the
    /// query string of every request Baton sends.
    func testTheCacheHoldsNoSecretAndNoDigestOfOne() async throws {
        let credentials = credentials(secret: "sesame")
        try await ping(credentials)

        let stored = try XCTUnwrap(NavidromeSaltCache.storedSignature(for: credentials))
        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.first)
        XCTAssertEqual(stored.salt, item("s", in: url))
        XCTAssertEqual(stored.token, item("t", in: url))
        XCTAssertNotEqual(stored.token, NavidromeClient.token(password: "sesame", salt: ""))
        XCTAssertFalse(stored.salt.contains("sesame"))
        XCTAssertFalse(stored.token.contains("sesame"))
    }

    /// Nothing is written anywhere that outlives the process, so a wipe leaves no trace and
    /// the next request starts over.
    func testClearingTheCacheMintsANewSaltNextTime() async throws {
        try await ping(credentials())
        NavidromeSaltCache.removeAll()
        XCTAssertNil(NavidromeSaltCache.storedSignature(for: credentials()))
        try await ping(credentials())

        XCTAssertNotEqual(
            item("s", in: StubURLProtocol.requestedURLs[1]),
            item("s", in: StubURLProtocol.requestedURLs[0]),
            "a cleared cache must not be able to hand back the salt it was holding"
        )
    }

    /// API-key auth sends neither `t` nor `s`, so nothing is minted and nothing is held.
    func testApiKeyAuthMintsNoSaltAtAll() async throws {
        let credentials = credentials(secret: "an-api-key", authMode: .apiKey)
        try await ping(credentials)

        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.first)
        XCTAssertNil(item("s", in: url))
        XCTAssertNil(item("t", in: url))
        XCTAssertEqual(item("apiKey", in: url), "an-api-key")
        XCTAssertNil(NavidromeSaltCache.storedSignature(for: credentials))
    }
}
