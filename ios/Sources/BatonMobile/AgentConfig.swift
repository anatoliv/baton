import Foundation
import Observation
import CryptoKit

/// Where the music friend's brain lives, and whether it has been proven to work.
///
/// The Mac's equivalent is the "Natural language" section of `BatonRemotePane`:
/// provider dialect, key, model, base URL, and a Test button that spends one real
/// request. The phone adds one route the Mac doesn't have — a self-hosted gateway —
/// and one rule the Mac doesn't need: **the Friend tab only appears once a test has
/// passed.**
///
/// That rule is why this type exists rather than a handful of loose UserDefaults
/// reads. "Configured" is cheap to check and nearly worthless: a typo'd key is
/// configured. What the tab needs to know is "configured *and* known to work", and
/// the only honest way to know that is to have asked. So a passing test records a
/// fingerprint of the exact configuration that passed; any later edit changes the
/// fingerprint and the tab goes away until it is tested again. Nothing else can
/// mark it verified.
@MainActor
@Observable
final class AgentConfig {
    /// Which brain answers. The gateway is the phone-only route: the loop runs on
    /// the home server against server-side tools.
    enum Route: String, CaseIterable, Identifiable {
        case gateway
        case direct

        var id: String { rawValue }

        var label: String {
            switch self {
            case .gateway: "Home server"
            case .direct: "Model provider"
            }
        }
    }

    private enum Keys {
        static let route = "baton.agent.route"
        static let provider = "baton.agent.provider"
        static let model = "baton.agent.model"
        static let baseURL = "baton.agent.baseURL"
        static let gatewayURL = "baton.agent.gatewayURL"
        static let verified = "baton.agent.verifiedFingerprint"
        static let apiKeyAccount = "baton.agent.apiKey"
        static let gatewayTokenAccount = "baton.agent.gatewayToken"
    }

    private let defaults: UserDefaults
    /// Injectable so tests can exercise the verification rules without a Keychain.
    private let secrets: any SecretStore

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        route = Route(rawValue: defaults.string(forKey: Keys.route) ?? "")
            // Before this setting existed, having a gateway URL *was* the choice.
            ?? ((defaults.string(forKey: Keys.gatewayURL)?.isEmpty == false) ? .gateway : .direct)
        provider = RemoteControlSettings.LLMProvider(
            rawValue: defaults.string(forKey: Keys.provider) ?? ""
        ) ?? .anthropic
        model = defaults.string(forKey: Keys.model) ?? "claude-haiku-4-5-20251001"
        baseURL = defaults.string(forKey: Keys.baseURL) ?? RemoteControlSettings.LLMProvider.anthropic.defaultBaseURL
        gatewayURL = defaults.string(forKey: Keys.gatewayURL) ?? ""
        apiKey = secrets.secret(for: Keys.apiKeyAccount) ?? ""
        gatewayToken = secrets.secret(for: Keys.gatewayTokenAccount) ?? ""
    }

    // MARK: Stored settings
    //
    // Every one of these invalidates verification on write, because every one of
    // them can be the reason the next request fails.

    var route: Route { didSet { persist(route.rawValue, Keys.route) } }
    var provider: RemoteControlSettings.LLMProvider { didSet { persist(provider.rawValue, Keys.provider) } }
    var model: String { didSet { persist(model, Keys.model) } }
    var baseURL: String { didSet { persist(baseURL, Keys.baseURL) } }
    var gatewayURL: String { didSet { persist(gatewayURL, Keys.gatewayURL) } }

    var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            secrets.setSecret(apiKey, for: Keys.apiKeyAccount)
            invalidateVerification()
        }
    }

    var gatewayToken: String {
        didSet {
            guard gatewayToken != oldValue else { return }
            secrets.setSecret(gatewayToken, for: Keys.gatewayTokenAccount)
            invalidateVerification()
        }
    }

    private func persist(_ value: String, _ key: String) {
        defaults.set(value, forKey: key)
        invalidateVerification()
    }

    // MARK: Readiness

    /// Everything the chosen route needs is filled in. Necessary, not sufficient —
    /// a wrong key is perfectly well "configured".
    var isConfigured: Bool {
        switch route {
        case .gateway:
            guard let url = URL(string: gatewayURL.trimmingCharacters(in: .whitespaces)),
                  url.scheme?.hasPrefix("http") == true else { return false }
            return true
        case .direct:
            return !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                && !model.trimmingCharacters(in: .whitespaces).isEmpty
                && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Configured *and* proven — the gate on the Friend tab. False the moment any
    /// field changes, so a tab that is showing has been tested as it stands.
    var isReady: Bool { isConfigured && defaults.string(forKey: Keys.verified) == fingerprint }

    /// Identifies the exact configuration a test passed against. The key is included
    /// (hashed) because changing the key is exactly the change most likely to break
    /// things while everything else still looks right.
    var fingerprint: String {
        let secret = (route == .gateway) ? gatewayToken : apiKey
        let material = [
            route.rawValue,
            provider.rawValue,
            model.trimmingCharacters(in: .whitespaces),
            baseURL.trimmingCharacters(in: .whitespaces),
            gatewayURL.trimmingCharacters(in: .whitespaces),
            SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined(),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Called only by a test that actually passed.
    func markVerified() { defaults.set(fingerprint, forKey: Keys.verified) }

    func invalidateVerification() { defaults.removeObject(forKey: Keys.verified) }

    // MARK: Provider switching

    /// Switching dialect carries the URL and model with it, but only when they were
    /// still the *other* dialect's defaults — someone who typed their own endpoint
    /// chose it deliberately, and a picker silently overwriting that is worse than
    /// leaving a value that needs editing. (Same rule as the Mac's pane.)
    func switchProvider(to newProvider: RemoteControlSettings.LLMProvider) {
        let previous = provider
        guard previous != newProvider else { return }
        if baseURL.trimmingCharacters(in: .whitespaces).isEmpty || baseURL == previous.defaultBaseURL {
            baseURL = newProvider.defaultBaseURL
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty || model == previous.defaultModel {
            model = newProvider.defaultModel
        }
        provider = newProvider
    }

    /// The shared config the agent loop and the connection test both run on, so a
    /// pass means the next real message takes the identical path.
    var naturalLanguageConfig: RemoteControlSettings.NaturalLanguageConfig {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.isAgentEnabled = true
        config.provider = provider
        config.model = model.trimmingCharacters(in: .whitespaces)
        config.apiKey = apiKey
        config.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        return config
    }
}
