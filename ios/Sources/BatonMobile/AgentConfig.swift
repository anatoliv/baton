import BatonSubsonicKit
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

    init(defaults: UserDefaults = BatonStorage.defaults, secrets: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        let stored = Self.read(defaults: defaults, secrets: secrets)
        route = stored.route
        provider = stored.provider
        model = stored.model
        baseURL = stored.baseURL
        gatewayURL = stored.gatewayURL
        apiKey = stored.apiKey
        gatewayToken = stored.gatewayToken
        verifiedFingerprint = stored.verifiedFingerprint
    }

    /// Every stored field as storage currently holds it.
    private struct Stored {
        var route: Route
        var provider: RemoteControlSettings.LLMProvider
        var model: String
        var baseURL: String
        var gatewayURL: String
        var apiKey: String
        var gatewayToken: String
        var verifiedFingerprint: String?
    }

    /// The one reader, used by `init` and by `reload()` alike.
    ///
    /// One copy rather than two, because two is how the launch path and the after-import
    /// path quietly stop agreeing about what a missing `provider` falls back to — and the
    /// after-import path is the one nobody exercises by hand.
    private static func read(defaults: UserDefaults, secrets: any SecretStore) -> Stored {
        Stored(
            route: Route(rawValue: string(Keys.route, defaults) ?? "")
                // Before this setting existed, having a gateway URL *was* the choice.
                ?? ((string(Keys.gatewayURL, defaults)?.isEmpty == false) ? .gateway : .direct),
            provider: RemoteControlSettings.LLMProvider(
                rawValue: string(Keys.provider, defaults) ?? ""
            ) ?? .anthropic,
            model: string(Keys.model, defaults) ?? "claude-haiku-4-5-20251001",
            baseURL: string(Keys.baseURL, defaults)
                ?? RemoteControlSettings.LLMProvider.anthropic.defaultBaseURL,
            gatewayURL: string(Keys.gatewayURL, defaults) ?? "",
            apiKey: secrets.secret(for: Keys.apiKeyAccount) ?? "",
            gatewayToken: secrets.secret(for: Keys.gatewayTokenAccount) ?? "",
            verifiedFingerprint: defaults.string(forKey: Keys.verified)
        )
    }

    /// `defaults.string(forKey:)`, with a DEBUG-only environment override checked first.
    ///
    /// `FriendVerificationEvidenceTests` and `LiveFriendComposerCaptureTests` set
    /// `route`/`provider`/`model`/`baseURL` at launch so the Friend tab is reachable without
    /// a real provider. That used to be `-baton.agent.route direct` etc. in
    /// `app.launchArguments`, read automatically off `UserDefaults`'s NSArgumentDomain.
    /// TBX-5336: `XCUIApplication.launchArguments` drops a whole `-key value` group about one
    /// launch in four, so these now come through `app.launchEnvironment` — and because
    /// `AgentConfig` reads its stored values once, at construction (in a `MobileModel`
    /// property initializer, before `MobileModel.init()`'s own body — including its
    /// `-baton.resetSession` handling — has run at all), the override has to be checked here,
    /// at the read, rather than seeded into `UserDefaults` at some other point in startup.
    private static func string(_ key: String, _ defaults: UserDefaults) -> String? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[key] { return override }
        #endif
        return defaults.string(forKey: key)
    }

    /// Re-read everything, for when storage changed underneath this object.
    ///
    /// WHY THIS EXISTS. "Set up from a Mac" writes the Mac's whole configuration
    /// into `UserDefaults` and the Keychain — provider, model, base URL, gateway URL, route,
    /// and both secrets, all of which `SettingsTransfer` has always carried. But this object
    /// is built once at launch and copies those values into stored properties, so an import
    /// that lands afterwards changed storage and nothing else. The Music Friend screen went
    /// on showing the phone's launch-time values, which reads exactly like a transfer that
    /// dropped the music friend, and touching any field there wrote the stale value back
    /// over what had just been imported.
    ///
    /// Deliberately does NOT mark anything verified. The Mac's base URL is very often a LAN
    /// address the phone cannot reach on cellular, so "the Mac could talk to it" is not
    /// evidence this phone can. The imported settings arrive filled in and one tap from a
    /// test, which is the honest version of carrying them over.
    func reload() {
        let stored = Self.read(defaults: defaults, secrets: secrets)
        isLoading = true
        defer { isLoading = false }
        route = stored.route
        provider = stored.provider
        model = stored.model
        baseURL = stored.baseURL
        gatewayURL = stored.gatewayURL
        apiKey = stored.apiKey
        gatewayToken = stored.gatewayToken
        verifiedFingerprint = stored.verifiedFingerprint
    }

    /// True only while `reload()` is assigning. The `didSet`s below mean "the owner edited
    /// this", and a load is not an edit: letting them run would write storage straight back
    /// to itself and, far worse, discard a verification that is still perfectly valid when
    /// the reload changed nothing.
    private var isLoading = false

    // MARK: Stored settings
    //
    // Every one of these invalidates verification on write, because every one of
    // them can be the reason the next request fails.

    // Each guards on the value actually changing, exactly as the two secrets below already
    // did. Without it, re-writing a field with the value it already holds discards a
    // perfectly good verification and hides the Friend tab — and a SwiftUI `TextField`
    // binding writes on every edit, including the ones that change nothing. The existing
    // `testRewritingTheSameKeyKeepsItReady` had settled this for the key and nowhere else.
    var route: Route { didSet { guard route != oldValue else { return }; persist(route.rawValue, Keys.route) } }
    var provider: RemoteControlSettings.LLMProvider {
        didSet { guard provider != oldValue else { return }; persist(provider.rawValue, Keys.provider) }
    }
    var model: String { didSet { guard model != oldValue else { return }; persist(model, Keys.model) } }
    var baseURL: String { didSet { guard baseURL != oldValue else { return }; persist(baseURL, Keys.baseURL) } }
    var gatewayURL: String {
        didSet { guard gatewayURL != oldValue else { return }; persist(gatewayURL, Keys.gatewayURL) }
    }

    var apiKey: String {
        didSet {
            guard !isLoading, apiKey != oldValue else { return }
            secrets.setSecret(apiKey, for: Keys.apiKeyAccount)
            invalidateVerification()
        }
    }

    var gatewayToken: String {
        didSet {
            guard !isLoading, gatewayToken != oldValue else { return }
            secrets.setSecret(gatewayToken, for: Keys.gatewayTokenAccount)
            invalidateVerification()
        }
    }

    private func persist(_ value: String, _ key: String) {
        guard !isLoading else { return }
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
    /// The fingerprint a connection test last passed against, held in a **stored property**
    /// rather than read from `UserDefaults` on demand.
    ///
    /// WHY IT IS STORED. `defaults` is a `private let`, which the Observation
    /// macro does not instrument, so a computed `isReady` that read the key directly moved
    /// without publishing anything. `markVerified()` would write to `UserDefaults`, `isReady`
    /// would start returning true, and nothing would tell SwiftUI — so the Friend tab, whose
    /// only condition is `isReady`, had no reason to appear until some unrelated change
    /// happened to re-render the tab view. Worse on the import path, where
    /// `reloadAfterSettingsImport()` invalidates *before* the probe runs, so the one
    /// re-render that did happen was the one where the answer was still false.
    ///
    /// `UserDefaults` stays the persistence; this is the value anything observing reads.
    private(set) var verifiedFingerprint: String?

    /// Configured *and* proven — the gate on the Friend tab. False the moment any field
    /// changes, so a tab that is showing has been tested as it stands.
    var isReady: Bool { isConfigured && verifiedFingerprint == fingerprint }

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
    func markVerified() {
        let mark = fingerprint
        defaults.set(mark, forKey: Keys.verified)
        // The stored property second and unconditionally: this is the write anything
        // observing actually sees, and the tab appearing depends on it.
        verifiedFingerprint = mark
    }

    func invalidateVerification() {
        defaults.removeObject(forKey: Keys.verified)
        verifiedFingerprint = nil
    }

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
