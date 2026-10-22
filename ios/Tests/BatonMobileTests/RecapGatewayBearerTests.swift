import BatonDocuments
import BatonSubsonicKit
import XCTest
@testable import BatonMobile

/// Book recaps and the dialogue cast reach the home server through `MobileRecap.liveRouting`,
/// whose executor hands the gateway token to the `.homeServer` source. That path skipped the
/// bearer guard every other gateway client on the phone takes, so a gateway set to plain HTTP on
/// a public address got the household token in the clear.
@MainActor
final class RecapGatewayBearerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = ThrowawayDefaults.name("recap-bearer")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func homeServerSources(gateway: String) -> [ModelSource] {
        let config = AgentConfig(defaults: defaults, secrets: InMemorySecretStore())
        config.gatewayURL = gateway
        config.gatewayToken = "household-token"
        return MobileRecap.liveRouting(config).sources.filter { $0.provider == .homeServer }
    }

    func testAPublicPlainHTTPGatewayIsNoRecapSource() {
        XCTAssertEqual(homeServerSources(gateway: "http://203.0.113.7:8788"), [],
                       "the household token would go to a public address over plain HTTP")
    }

    func testTheHomeNetworkAndHTTPSGatewaysStillAre() {
        XCTAssertEqual(homeServerSources(gateway: "http://192.168.1.20:8788").count, 1)
        XCTAssertEqual(homeServerSources(gateway: "http://100.101.102.103:8788").count, 1, "Tailscale")
        XCTAssertEqual(homeServerSources(gateway: "https://203.0.113.7:8788").count, 1)
    }
}
