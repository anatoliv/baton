import XCTest
import BatonSubsonicKit
@testable import BatonMobile

/// The phone-side agent routing: which brain answers, and when it may hop.
/// The loop itself is covered in BatonAgentKit's own suite — what's phone-specific
/// is the profile selection, the failover predicate and the transport gate.
@MainActor
final class AgentRoutingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // An isolated suite: these used to run against `UserDefaults.standard` and
        // wrote the app's own agent settings as a side effect.
        suiteName = "baton.agentrouting.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeConfig() -> AgentConfig {
        AgentConfig(defaults: defaults, secrets: InMemorySecretStore())
    }

    // MARK: - Transport gate

    /// A bearer key may cross plain HTTP only on the user's own network. This is
    /// the rule that keeps a self-hosted gateway convenient without making a
    /// public-internet mistake possible.
    func testPlainHTTPIsAllowedOnlyOnTheLAN() {
        for host in ["localhost", "navidrome.local", "10.0.0.5", "192.168.1.20",
                     "172.16.4.1", "172.31.255.254"] {
            XCTAssertTrue(AgentClient.isPrivateHost(host), "\(host) is a private host")
        }
        for host in ["api.anthropic.com", "example.com", "172.32.0.1", "8.8.8.8",
                     "notlocalhost.io", ""] {
            XCTAssertFalse(AgentClient.isPrivateHost(host), "\(host) is NOT private")
        }
    }

    /// 172.16–172.31 is private; 172.15 and 172.32 are not. Off-by-one here would
    /// either block a real home network or leak a key to a public host.
    func testRFC1918SecondOctetBoundaries() {
        XCTAssertFalse(AgentClient.isPrivateHost("172.15.0.1"))
        XCTAssertTrue(AgentClient.isPrivateHost("172.16.0.1"))
        XCTAssertTrue(AgentClient.isPrivateHost("172.31.0.1"))
        XCTAssertFalse(AgentClient.isPrivateHost("172.32.0.1"))
    }

    // MARK: - Profile selection

    func testGatewayProfileIsNilUntilConfigured() {
        let config = makeConfig()
        config.route = .gateway
        XCTAssertNil(AgentClient.makeGatewayProfile(config))
    }

    func testGatewayProfileIsPreferredWhenSet() {
        let config = makeConfig()
        config.route = .gateway
        config.gatewayURL = "http://192.168.1.9:8788"
        let profile = AgentClient.makeGatewayProfile(config)
        XCTAssertEqual(profile?.dialect, .gateway)
        XCTAssertEqual(profile?.baseURL.absoluteString, "http://192.168.1.9:8788")
        // The gateway holds the bearer token, never the model API key.
        XCTAssertEqual(profile?.keyAccount, "baton.agent.gatewayToken")
    }

    /// An empty string is what a cleared text field leaves behind — it must read
    /// as "no gateway", not as a URL.
    func testBlankGatewayURLIsNotAProfile() {
        let config = makeConfig()
        config.route = .gateway
        config.gatewayURL = ""
        XCTAssertNil(AgentClient.makeGatewayProfile(config))
    }

    func testModelDefaultsToACheapFastOne() {
        let config = makeConfig()
        config.route = .gateway
        config.gatewayURL = "http://192.168.1.9:8788"
        // The routing/fallback tier is deliberately Haiku-class; the big model
        // lives behind the gateway.
        XCTAssertEqual(AgentClient.makeGatewayProfile(config)?.model, "claude-haiku-4-5-20251001")
    }

    func testGatewayRouteMakesTheGatewayPrimary() {
        let config = makeConfig()
        config.route = .gateway
        config.gatewayURL = "http://192.168.1.9:8788"
        XCTAssertEqual(AgentClient.makePrimaryProfile(config)?.dialect, .gateway)
    }

    /// Choosing the direct route means the phone talks to the provider even though a
    /// gateway address is still sitting in the field from an earlier setup.
    func testDirectRouteIgnoresALeftoverGatewayAddress() {
        let config = makeConfig()
        config.gatewayURL = "http://192.168.1.9:8788"
        config.route = .direct
        config.apiKey = "sk-ant-test"

        XCTAssertEqual(AgentClient.makePrimaryProfile(config)?.dialect, .direct)
    }

    /// With the gateway chosen but unreachable-by-configuration (no address yet), the
    /// direct provider still answers rather than the app claiming nothing is set up.
    func testGatewayRouteFallsBackToTheProviderWhenNoAddressIsSet() {
        let config = makeConfig()
        config.route = .gateway
        config.apiKey = "sk-ant-test"

        XCTAssertEqual(AgentClient.makePrimaryProfile(config)?.dialect, .direct)
    }

    // MARK: - Falling back to the model provider

    /// The Music Friend screen promises "Baton falls back to the model provider below if the
    /// server can't be reached." It did not, in either way a home server actually fails, and
    /// the second of those was invisible: a transport failure was modelled as
    /// `.http(URLError.errorCode, …)`, whose code is negative and could never match an HTTP
    /// range. The case the fallback exists for was the one case it could not see.

    /// The literal promise on the screen.
    func testAnUnreachableGatewayFallsBack() {
        XCTAssertTrue(AgentClient.shouldFallback(on: .unreachable("Could not connect to the server.")))
    }

    /// Something is listening, but it is not a gateway — exactly what a fallback is for.
    func testA404FallsBack() {
        XCTAssertTrue(AgentClient.shouldFallback(on: .http(404, "no /v1/agent")))
    }

    func testOverloadedAndBrokenGatewaysFallBack() {
        XCTAssertTrue(AgentClient.shouldFallback(on: .http(429, "rate limited")))
        for code in [500, 502, 503, 599] {
            XCTAssertTrue(AgentClient.shouldFallback(on: .http(code, "server error")), "HTTP \(code)")
        }
    }

    /// A rejected token must NOT hop. It is a configuration error the user has to fix, and
    /// silently moving their conversation to a paid provider because the gateway token is
    /// wrong is a worse outcome than failing — it hides the very thing they need to see.
    func testARejectedTokenDoesNotFallBack() {
        XCTAssertFalse(AgentClient.shouldFallback(on: .http(401, "unauthorized")))
        XCTAssertFalse(AgentClient.shouldFallback(on: .http(403, "forbidden")))
    }

    /// Config errors fail identically twice, so hopping only doubles the wait.
    func testConfigErrorsDoNotFallBack() {
        XCTAssertFalse(AgentClient.shouldFallback(on: .notConfigured))
        XCTAssertFalse(AgentClient.shouldFallback(on: .config("bad URL")))
    }

    /// A transport failure is not an HTTP answer, and must not read like one. This is what
    /// produced "answered HTTP -1004" for a server that answered nothing at all.
    func testUnreachableReadsAsUnreachableRatherThanAnHTTPCode() {
        let described = AgentClient.AgentError.unreachable("Could not connect to the server.").errorDescription ?? ""
        XCTAssertTrue(described.contains("Couldn't reach it"), "got: \(described)")
        XCTAssertFalse(described.contains("HTTP"), "a refused connection is not an HTTP answer: \(described)")
    }
}
