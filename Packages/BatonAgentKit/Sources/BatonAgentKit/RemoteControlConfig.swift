import Foundation
import Observation
import BatonSubsonicKit
import BatonSubsonicModels

let remoteLog = Logger(subsystem: "io.tonebox.baton", category: "RemoteControl")

// MARK: - Chat platform

/// The chat services Baton can be driven from. Both connect **outbound only**
/// (Telegram long-polls `getUpdates`; Discord opens a Gateway WebSocket), so
/// nothing about the MCP server's loopback-only posture changes: Baton dials
/// out, and no port is ever exposed.
public enum RemotePlatform: String, CaseIterable, Codable, Sendable, Identifiable {
    case telegram
    case discord
    /// The app's own window, on the machine running the player.
    ///
    /// Not a bridge and not a network peer: nothing listens, nothing is polled, and there is
    /// no token. It exists as a platform so the desktop music friend routes through the same
    /// `RemoteCommandRouter` as the chat bridges instead of growing a second conversation
    /// with its own parser, memory and fallback — which is exactly how the phone and the Mac
    /// would drift apart. `bridges` is what settings iterates, so this never renders as a
    /// third thing to configure.
    case desktop

    /// The platforms that are actually remote, i.e. everything a person configures with a
    /// token and an allowlist. `desktop` is deliberately absent.
    public static let bridges: [RemotePlatform] = [.telegram, .discord]

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .telegram: "Telegram"
        case .discord: "Discord"
        case .desktop: "This Mac"
        }
    }

    public var symbol: String {
        switch self {
        case .telegram: "paperplane"
        case .discord: "bubble.left.and.bubble.right"
        case .desktop: "sparkles"
        }
    }

    /// Where the user gets a bot token, shown under the token field.
    public var tokenHint: String {
        switch self {
        case .telegram: "Message @BotFather → /newbot → paste the token it gives you."
        case .discord: "discord.com/developers → your app → Bot → Reset Token. Turn on the Message Content intent."
        // Never shown: the desktop friend has no token to get, which is the point of it.
        case .desktop: ""
        }
    }

    /// Keychain account for this platform's bot token.
    public var secretKey: String { "baton.remote.\(rawValue).token" }
}

// MARK: - Connection status

/// What a bridge is doing right now, surfaced in Settings so a wrong token or a
/// missing intent is visible instead of silent.
public enum RemoteConnectionState: Equatable, Sendable {
    case off
    case connecting
    case connected(account: String)
    case failed(String)

    public var isRunning: Bool {
        switch self {
        case .off, .failed: false
        case .connecting, .connected: true
        }
    }
}

// MARK: - Settings

/// Remote-control configuration. Non-secret preferences live in `UserDefaults`;
/// bot tokens and the LLM API key go to the Keychain through `SecretStore`, the
/// same seam the Navidrome credentials and webhook secrets use.
///
/// **Fail-closed authorization.** A bot token alone is not authorization: anyone
/// who finds the bot could otherwise drive your speakers. Every inbound message
/// is checked against a per-platform allowlist of sender ids, and an empty
/// allowlist authorizes *nobody*. The link code (below) is how ids get onto it
/// without hand-copying numeric ids out of a chat client.
@MainActor
@Observable
public final class RemoteControlSettings {
    // MARK: Stored state

    public var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }

    public var telegram: PlatformConfig { didSet { persist(telegram, platform: .telegram) } }
    public var discord: PlatformConfig { didSet { persist(discord, platform: .discord) } }

    /// Natural-language fallback: anything that isn't a recognized command is
    /// handed to an LLM that picks one of Baton's own MCP tools. Off unless the
    /// user configures it — Baton ships no key and makes no network call to any
    /// model provider otherwise.
    public var naturalLanguage: NaturalLanguageConfig {
        didSet { persistNaturalLanguage() }
    }

    /// Live per-platform status, for the Settings pane. Not persisted.
    public var state: [RemotePlatform: RemoteConnectionState] = [:]

    /// The rolling code an unknown chat sends as `/link <code>` to authorize
    /// itself. Regenerated on every launch and after each successful link, so a
    /// code that leaks into a chat log is already spent.
    public private(set) var linkCode: String = RemoteControlSettings.makeLinkCode()

    // MARK: Per-platform config

    public struct PlatformConfig: Equatable, Sendable {
        public var isEnabled: Bool = false
        /// Bot token. Empty when unset; stored in the Keychain, never `UserDefaults`.
        public var token: String = ""
        /// Sender ids allowed to drive playback. Empty ⇒ nobody (fail closed).
        public var allowedSenders: Set<String> = []
        /// Discord only: restrict to these channel ids. Empty ⇒ any channel the
        /// bot can see (senders are still checked).
        public var allowedChannels: Set<String> = []

        public var isConfigured: Bool { isEnabled && !token.isEmpty }
    }

    /// Which wire protocol the configured endpoint speaks. Two dialects cover
    /// effectively every provider worth pointing at: Anthropic's Messages API,
    /// and the OpenAI chat-completions shape that OpenAI, Groq, Together, and
    /// self-hosted vLLM/Ollama all implement.
    public enum LLMProvider: String, CaseIterable, Codable, Sendable, Identifiable {
        case anthropic
        case openAICompatible

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .anthropic: "Anthropic"
            case .openAICompatible: "OpenAI-compatible"
            }
        }

        public var defaultBaseURL: String {
            switch self {
            case .anthropic: "https://api.anthropic.com"
            case .openAICompatible: "https://api.openai.com/v1"
            }
        }

        public var defaultModel: String {
            switch self {
            case .anthropic: "claude-opus-5"
            case .openAICompatible: "gpt-4o-mini"
            }
        }

        public var keyPlaceholder: String {
            switch self {
            case .anthropic: "sk-ant-…"
            case .openAICompatible: "sk-…"
            }
        }

        public var hint: String {
            switch self {
            case .anthropic:
                "Anthropic's Messages API. Base URL is the API root — Baton adds /v1/messages itself."
            case .openAICompatible:
                """
                The chat-completions shape, which OpenAI, Groq, Together, and self-hosted \
                vLLM or Ollama all speak. Base URL is the root that /chat/completions hangs \
                off — for OpenAI that's https://api.openai.com/v1.
                """
            }
        }
    }

    public struct NaturalLanguageConfig: Equatable, Sendable {
        public var isEnabled: Bool = false
        /// Which dialect the endpoint speaks.
        public var provider: LLMProvider = .anthropic
        /// API key. Keychain-stored.
        public var apiKey: String = ""
        /// Model id.
        public var model: String = "claude-opus-5"
        /// API base — the root, not a full endpoint path (Baton appends that).
        public var baseURL: String = "https://api.anthropic.com"
        /// Let the model look around the library across several turns before it
        /// answers, instead of translating one sentence into one tool call.
        ///
        /// Off by default, and the reason is privacy rather than cost: an agent
        /// that browses **sends what it finds** — song titles, artists, genres —
        /// to whichever endpoint is configured, because the results come back
        /// into its context by construction. Single-shot mode never does. Point
        /// `baseURL` at a model on your own machine and this distinction stops
        /// mattering; point it at a hosted API and it matters a great deal.
        public var isAgentEnabled: Bool = false
        /// Whether Baton keeps durable notes about its owner between sessions.
        ///
        /// Separate from `isAgentEnabled` because it is a different promise.
        /// Agent mode sends library content for the length of a request; memory
        /// keeps sentences about the person on disk until they delete them. On
        /// by default *within* agent mode — the store only ever holds the
        /// owner's own words, every write is echoed in the chat, and `memories`
        /// / `forget` are one message away — but it switches off on its own.
        public var remembersOwner: Bool = true

        public var isConfigured: Bool { isEnabled && !apiKey.isEmpty }
        /// Agent mode needs everything single-shot needs, and to be switched on.
        public var isAgentConfigured: Bool { isConfigured && isAgentEnabled }

        public init() {}
    }

    // MARK: Init

    private let defaults: UserDefaults
    private let secrets: any SecretStore

    public init(
        environment: BatonEnvironment = .current,
        defaults: UserDefaults? = nil,
        secrets: (any SecretStore)? = nil
    ) {
        let store = defaults
            ?? (environment.isTesting ? UserDefaults(suiteName: "baton.remote.tests") : nil)
            ?? .standard
        let secretStore: any SecretStore = secrets
            ?? (environment.isTesting ? InMemorySecretStore() : KeychainSecretStore())
        self.defaults = store
        self.secrets = secretStore

        isEnabled = store.bool(forKey: Keys.enabled)

        // Read through the *local* bindings: `self` isn't fully initialized yet.
        // (Assignments in `init` don't fire `didSet`, so this doesn't write back.)
        func load(_ platform: RemotePlatform) -> PlatformConfig {
            PlatformConfig(
                isEnabled: store.bool(forKey: Keys.platformEnabled(platform)),
                token: secretStore.secret(for: platform.secretKey) ?? "",
                allowedSenders: Set(store.stringArray(forKey: Keys.allowedSenders(platform)) ?? []),
                allowedChannels: Set(store.stringArray(forKey: Keys.allowedChannels(platform)) ?? [])
            )
        }
        telegram = load(.telegram)
        discord = load(.discord)

        var nl = NaturalLanguageConfig()
        nl.isEnabled = store.bool(forKey: Keys.nlEnabled)
        nl.apiKey = secretStore.secret(for: Keys.nlAPIKey) ?? ""
        if let raw = store.string(forKey: Keys.nlProvider), let provider = LLMProvider(rawValue: raw) {
            nl.provider = provider
        }
        if let model = store.string(forKey: Keys.nlModel), !model.isEmpty { nl.model = model }
        if let base = store.string(forKey: Keys.nlBaseURL), !base.isEmpty { nl.baseURL = base }
        nl.isAgentEnabled = store.bool(forKey: Keys.nlAgentEnabled)
        nl.remembersOwner = store.object(forKey: Keys.nlRemembers) as? Bool ?? true
        naturalLanguage = nl
    }

    // MARK: Accessors

    public func config(for platform: RemotePlatform) -> PlatformConfig {
        switch platform {
        case .telegram: telegram
        case .discord: discord
        // The desktop has no token, no allowlist and no channels — it is the app itself.
        // `isAuthorized` short-circuits before reaching here; this is only so the type is
        // total, and an empty config authorizes nobody if that ever stops being true.
        case .desktop: PlatformConfig()
        }
    }

    public func setConfig(_ config: PlatformConfig, for platform: RemotePlatform) {
        switch platform {
        case .telegram: telegram = config
        case .discord: discord = config
        // Nothing to store. Deliberately not a crash: a caller iterating platforms and
        // writing config should quietly do nothing here rather than take the app down.
        case .desktop: break
        }
    }

    /// Authorize a sender id on `platform` and burn the current link code.
    public func authorize(sender: String, on platform: RemotePlatform) {
        var config = self.config(for: platform)
        config.allowedSenders.insert(sender)
        setConfig(config, for: platform)
        linkCode = Self.makeLinkCode()
        remoteLog.notice("Authorized a new \(platform.rawValue, privacy: .public) sender")
    }

    public func revoke(sender: String, on platform: RemotePlatform) {
        var config = self.config(for: platform)
        config.allowedSenders.remove(sender)
        setConfig(config, for: platform)
    }

    /// Constant-time-ish comparison of a submitted link code. Codes are short and
    /// single-use, but there's no reason to leak length/prefix through timing.
    public func matchesLinkCode(_ candidate: String) -> Bool {
        let a = Array(linkCode.utf8), b = Array(candidate.trimmingCharacters(in: .whitespaces).utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    public func regenerateLinkCode() { linkCode = Self.makeLinkCode() }

    // MARK: Persistence

    private func persist(_ config: PlatformConfig, platform: RemotePlatform) {
        defaults.set(config.isEnabled, forKey: Keys.platformEnabled(platform))
        defaults.set(Array(config.allowedSenders).sorted(), forKey: Keys.allowedSenders(platform))
        defaults.set(Array(config.allowedChannels).sorted(), forKey: Keys.allowedChannels(platform))
        secrets.setSecret(config.token.isEmpty ? nil : config.token, for: platform.secretKey)
    }

    private func persistNaturalLanguage() {
        defaults.set(naturalLanguage.isEnabled, forKey: Keys.nlEnabled)
        defaults.set(naturalLanguage.provider.rawValue, forKey: Keys.nlProvider)
        defaults.set(naturalLanguage.model, forKey: Keys.nlModel)
        defaults.set(naturalLanguage.baseURL, forKey: Keys.nlBaseURL)
        defaults.set(naturalLanguage.isAgentEnabled, forKey: Keys.nlAgentEnabled)
        defaults.set(naturalLanguage.remembersOwner, forKey: Keys.nlRemembers)
        secrets.setSecret(naturalLanguage.apiKey.isEmpty ? nil : naturalLanguage.apiKey, for: Keys.nlAPIKey)
    }

    private static func makeLinkCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    private enum Keys {
        public static let enabled = "baton.remote.enabled"
        public static let nlEnabled = "baton.remote.nl.enabled"
        public static let nlProvider = "baton.remote.nl.provider"
        public static let nlModel = "baton.remote.nl.model"
        public static let nlBaseURL = "baton.remote.nl.baseURL"
        public static let nlAgentEnabled = "baton.remote.nl.agentEnabled"
        public static let nlRemembers = "baton.remote.nl.remembersOwner"
        public static let nlAPIKey = "baton.remote.nl.apiKey"

        static func platformEnabled(_ p: RemotePlatform) -> String { "baton.remote.\(p.rawValue).enabled" }
        static func allowedSenders(_ p: RemotePlatform) -> String { "baton.remote.\(p.rawValue).allowedSenders" }
        static func allowedChannels(_ p: RemotePlatform) -> String { "baton.remote.\(p.rawValue).allowedChannels" }
    }
}
