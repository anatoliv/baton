import XCTest
import BatonSubsonicKit
@testable import BatonMobile

/// What "Set up from a Mac" is supposed to hand the music friend.
///
/// `SettingsTransfer` has always carried the friend's whole configuration — provider,
/// model, base URL, gateway, and both secrets — into the same `UserDefaults` and Keychain
/// this app reads. What it could not do is make anything look again: `AgentConfig` copies
/// every field into a stored property in `init`, and `MobileModel` builds exactly one of
/// them, at launch. So the import landed and the Music Friend screen went on showing the
/// values the phone started with, which is indistinguishable from a transfer that dropped
/// the music friend entirely.
///
/// Every test here fails without `reload()`.
@MainActor
final class AgentConfigReloadTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var secrets: InMemorySecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "baton.agentconfig.reload.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = InMemorySecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        secrets = nil
        super.tearDown()
    }

    private func makeConfig() -> AgentConfig {
        AgentConfig(defaults: defaults, secrets: secrets)
    }

    /// Writes what a Mac export puts into storage, without going through `AgentConfig` —
    /// which is the whole point: the import writes storage directly, behind this object's back.
    private func importMacSettings() {
        defaults.set("direct", forKey: "baton.agent.route")
        defaults.set("openAICompatible", forKey: "baton.agent.provider")
        defaults.set("chat", forKey: "baton.agent.model")
        defaults.set("http://192.168.4.21:8000/v1", forKey: "baton.agent.baseURL")
        defaults.set("http://192.168.4.22:8788", forKey: "baton.agent.gatewayURL")
        secrets.setSecret("sk-from-the-mac", for: "baton.agent.apiKey")
        secrets.setSecret("gateway-token-from-the-mac", for: "baton.agent.gatewayToken")
    }

    // MARK: - The bug this exists for

    func testAnImportLandingAfterLaunchIsInvisibleUntilReload() {
        let config = makeConfig()
        importMacSettings()

        // Nothing has told it to look, so it still holds its launch-time defaults. This
        // assertion is the bug: it is what the user saw on the Music Friend screen.
        XCTAssertEqual(config.model, "claude-haiku-4-5-20251001")

        config.reload()

        XCTAssertEqual(config.route, .direct)
        XCTAssertEqual(config.provider, .openAICompatible)
        XCTAssertEqual(config.model, "chat")
        XCTAssertEqual(config.baseURL, "http://192.168.4.21:8000/v1")
        XCTAssertEqual(config.gatewayURL, "http://192.168.4.22:8788")
    }

    /// The secrets are the half a user cannot retype from memory, so losing them silently
    /// is the version of this bug that costs the most.
    func testReloadPicksUpBothSecrets() {
        let config = makeConfig()
        importMacSettings()
        config.reload()

        XCTAssertEqual(config.apiKey, "sk-from-the-mac")
        XCTAssertEqual(config.gatewayToken, "gateway-token-from-the-mac")
    }

    /// The half that costs the most, because it is invisible: `naturalLanguageConfig` is
    /// what the agent loop and the Test button both actually run against. A stale object
    /// meant the friend went on talking to the phone's launch-time endpoint with the
    /// phone's launch-time key while the screen and storage both said otherwise — so the
    /// test button failed against a configuration nobody had asked for.
    func testWhatTheFriendActuallyRunsOnReflectsTheImport() {
        let config = makeConfig()
        importMacSettings()
        config.reload()

        let running = config.naturalLanguageConfig
        XCTAssertEqual(running.provider, .openAICompatible)
        XCTAssertEqual(running.model, "chat")
        XCTAssertEqual(running.baseURL, "http://192.168.4.21:8000/v1")
        XCTAssertEqual(running.apiKey, "sk-from-the-mac")
    }

    // MARK: - What reload must NOT do

    /// A reload is not an edit. Re-reading identical values must leave a passing test
    /// standing, or every import would silently hide a Friend tab that still works.
    ///
    /// This one guards the opposite direction from the others, so a mutation that makes
    /// `reload()` do nothing leaves it green — correctly. Its mutation is a `reload()` that
    /// lets the `didSet`s treat a load as an edit and clear the verification.
    func testReloadingUnchangedStorageKeepsVerification() {
        let config = makeConfig()
        config.route = .direct
        config.apiKey = "sk-ant-test"
        config.model = "claude-haiku-4-5-20251001"
        config.baseURL = "https://api.anthropic.com"
        config.markVerified()
        XCTAssertTrue(config.isReady)

        config.reload()

        XCTAssertTrue(config.isReady, "re-reading the same values must not discard the test that passed")
    }

    /// But a reload that genuinely changes the configuration must not carry the old
    /// verification onto it. The Mac's base URL is routinely a LAN address this phone
    /// cannot reach on cellular, so "the Mac could talk to it" is not evidence about here.
    func testReloadingChangedStorageLeavesItUnverified() {
        let config = makeConfig()
        config.route = .direct
        config.apiKey = "sk-ant-test"
        config.model = "claude-haiku-4-5-20251001"
        config.baseURL = "https://api.anthropic.com"
        config.markVerified()
        XCTAssertTrue(config.isReady)

        importMacSettings()
        config.reload()

        XCTAssertTrue(config.isConfigured, "the imported settings are complete")
        XCTAssertFalse(config.isReady, "but nothing has proven they work from this device")
    }
}
