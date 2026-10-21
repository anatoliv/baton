import XCTest
import BatonSubsonicKit
@testable import BatonMobile

/// The rule behind the Friend tab: it appears only when the music friend has been
/// configured **and** proven to work, and it disappears again the moment anything
/// that could break it changes.
///
/// Worth testing carefully because the failure is silent and confusing. If a config
/// edit didn't clear verification, a tab would sit there promising a feature that a
/// revoked key or a typo'd model id has already broken — the user finds out by asking
/// it something and getting an error, which is exactly the experience the gate exists
/// to prevent.
@MainActor
final class AgentConfigTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = ThrowawayDefaults.name("baton.agentconfig.tests")
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

    /// A configuration that is complete but untested.
    private func configured() -> AgentConfig {
        let config = makeConfig()
        config.route = .direct
        config.apiKey = "sk-ant-test"
        config.model = "claude-haiku-4-5-20251001"
        config.baseURL = "https://api.anthropic.com"
        return config
    }

    // MARK: - The gate

    func testFreshConfigIsNeitherConfiguredNorReady() {
        let config = makeConfig()
        XCTAssertFalse(config.isConfigured)
        XCTAssertFalse(config.isReady)
    }

    func testConfiguredButUntestedIsNotReady() {
        let config = configured()
        XCTAssertTrue(config.isConfigured)
        XCTAssertFalse(config.isReady, "a key that has never been tried proves nothing")
    }

    func testPassingATestMakesItReady() {
        let config = configured()
        config.markVerified()
        XCTAssertTrue(config.isReady)
    }

    // MARK: - Every edit invalidates

    func testChangingTheKeyHidesTheTabAgain() {
        let config = configured()
        config.markVerified()
        config.apiKey = "sk-ant-a-different-key"
        XCTAssertFalse(config.isReady)
    }

    func testChangingTheModelHidesTheTabAgain() {
        let config = configured()
        config.markVerified()
        config.model = "claude-opus-5"
        XCTAssertFalse(config.isReady)
    }

    func testChangingTheBaseURLHidesTheTabAgain() {
        let config = configured()
        config.markVerified()
        config.baseURL = "https://api.example.com/v1"
        XCTAssertFalse(config.isReady)
    }

    func testSwitchingProviderHidesTheTabAgain() {
        let config = configured()
        config.markVerified()
        config.switchProvider(to: .openAICompatible)
        XCTAssertFalse(config.isReady, "a pass against one dialect says nothing about the other")
    }

    func testSwitchingRouteHidesTheTabAgain() {
        let config = configured()
        config.markVerified()
        config.route = .gateway
        XCTAssertFalse(config.isReady)
    }

    func testChangingTheGatewayHidesTheTabAgain() {
        let config = makeConfig()
        config.route = .gateway
        config.gatewayURL = "https://baton.home.example"
        config.gatewayToken = "token"
        config.markVerified()
        XCTAssertTrue(config.isReady)

        config.gatewayURL = "https://elsewhere.example"
        XCTAssertFalse(config.isReady)
    }

    /// Re-entering the *same* value is not a change, so it must not cost a re-test.
    func testRewritingTheSameKeyKeepsItReady() {
        let config = configured()
        config.markVerified()
        config.apiKey = "sk-ant-test"
        XCTAssertTrue(config.isReady)
    }

    /// Verification has to survive a relaunch, or the tab vanishes every cold start.
    func testVerificationSurvivesReload() {
        let config = configured()
        config.markVerified()

        let secrets = InMemorySecretStore()
        secrets.setSecret("sk-ant-test", for: "baton.agent.apiKey")
        let reloaded = AgentConfig(defaults: defaults, secrets: secrets)

        XCTAssertTrue(reloaded.isReady)
    }

    // MARK: - What counts as configured

    func testGatewayRouteNeedsAUsableURL() {
        let config = makeConfig()
        config.route = .gateway
        XCTAssertFalse(config.isConfigured)

        config.gatewayURL = "baton.home.example"     // no scheme
        XCTAssertFalse(config.isConfigured)

        config.gatewayURL = "https://baton.home.example"
        XCTAssertTrue(config.isConfigured)
    }

    func testDirectRouteNeedsKeyModelAndBase() {
        let config = makeConfig()
        config.route = .direct
        config.model = "claude-haiku-4-5-20251001"
        config.baseURL = "https://api.anthropic.com"
        XCTAssertFalse(config.isConfigured, "no key")

        config.apiKey = "sk-ant-test"
        XCTAssertTrue(config.isConfigured)

        config.model = "   "
        XCTAssertFalse(config.isConfigured, "whitespace is not a model id")
    }

    // MARK: - Provider switching carries defaults, not choices

    func testSwitchingProviderCarriesUntouchedDefaults() {
        let config = makeConfig()
        config.provider = .anthropic
        config.baseURL = RemoteControlSettings.LLMProvider.anthropic.defaultBaseURL
        config.model = RemoteControlSettings.LLMProvider.anthropic.defaultModel

        config.switchProvider(to: .openAICompatible)

        XCTAssertEqual(config.baseURL, RemoteControlSettings.LLMProvider.openAICompatible.defaultBaseURL)
        XCTAssertEqual(config.model, RemoteControlSettings.LLMProvider.openAICompatible.defaultModel)
    }

    func testSwitchingProviderLeavesADeliberateEndpointAlone() {
        let config = makeConfig()
        config.provider = .anthropic
        config.baseURL = "http://192.168.1.10:11434/v1"   // someone's own Ollama
        config.model = "llama3.1:70b"

        config.switchProvider(to: .openAICompatible)

        XCTAssertEqual(config.baseURL, "http://192.168.1.10:11434/v1")
        XCTAssertEqual(config.model, "llama3.1:70b")
    }

    // MARK: - The config the loop actually runs on

    /// The test and the next real message must run on the same settings, or a pass
    /// means nothing.
    func testNaturalLanguageConfigMirrorsTheSettings() {
        let config = configured()
        config.switchProvider(to: .openAICompatible)
        config.apiKey = "sk-openai"
        config.model = "gpt-4o-mini"
        config.baseURL = "https://api.openai.com/v1"

        let nl = config.naturalLanguageConfig

        XCTAssertEqual(nl.provider, .openAICompatible)
        XCTAssertEqual(nl.apiKey, "sk-openai")
        XCTAssertEqual(nl.model, "gpt-4o-mini")
        XCTAssertEqual(nl.baseURL, "https://api.openai.com/v1")
        XCTAssertTrue(nl.isConfigured)
    }

    // MARK: - A pass belongs to the configuration that was tested

    /// The connection test fingerprinted the configuration when the answer came back, so an
    /// edit made while the request was in flight was marked verified without ever being
    /// tried (TBX-1000000480 B-7).
    func testAnEditMadeWhileTheTestRunsIsNotMarkedVerified() async throws {
        let config = makeConfig()
        config.route = .gateway
        config.gatewayURL = "http://127.0.0.1:59997"
        let model = MobileModel()
        let client = AgentClient(tools: AgentTools(model: model), player: model.music, config: config)
        URLProtocol.registerClass(SlowAgentGatewayProtocol.self)
        defer { URLProtocol.unregisterClass(SlowAgentGatewayProtocol.self) }

        let test = Task { await client.runConnectionTest() }
        try await Task.sleep(for: .milliseconds(100))
        config.gatewayURL = "http://127.0.0.1:59996"
        let outcome = await test.value

        guard case .ok = outcome else { return XCTFail("precondition: the stub gateway answers, got \(outcome)") }
        XCTAssertFalse(config.isReady, "an address nobody tested was marked verified")
    }

    func testAnUnchangedConfigurationIsMarkedVerifiedByAPass() async {
        let config = makeConfig()
        config.route = .gateway
        config.gatewayURL = "http://127.0.0.1:59997"
        let model = MobileModel()
        let client = AgentClient(tools: AgentTools(model: model), player: model.music, config: config)
        URLProtocol.registerClass(SlowAgentGatewayProtocol.self)
        defer { URLProtocol.unregisterClass(SlowAgentGatewayProtocol.self) }

        _ = await client.runConnectionTest()

        XCTAssertTrue(config.isReady)
    }
}

/// A Baton server on 127.0.0.1:59997 that answers `/v1/agent` after 300 ms.
final class SlowAgentGatewayProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.port == 59997
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, let url = self.request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(#"{"text":"Nothing is playing."}"#.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
}
