import Foundation

/// Configuration for Baton's spoken-summary feature (the `speak_summary` MCP tool):
/// where the TTS services live, how task categories map to voices, and how a summary is
/// delivered. Third leaf of the W-51 module-boundary split (after BatonDSP + BatonSubsonicModels):
/// the TTS config + synthesis layer, extracted so it has no dependency on the app. The playback
/// engine + notifier stay in the app (they tie into MusicModel); this is the pure part.
///
/// Mirrors `NavidromeConfig`'s shape — a caseless `enum` over `UserDefaults` (injectable
/// for tests), with `tonebox.*` keys. Hosts default to a harmless localhost placeholder;
/// the real LAN host is set at runtime (Settings / `defaults write`) so no private LAN IP
/// is ever committed to source (the publish guard blocks `192.168.*`).
public enum SpeechConfig {
    // MARK: - Keys
    static let kokoroHostKey = "tonebox.speech.kokoroBaseURL"
    static let chatterboxHostKey = "tonebox.speech.chatterboxBaseURL"
    static let voiceMapKey = "tonebox.speech.voiceMap"
    static let fallbackEnabledKey = "tonebox.speech.fallbackEnabled"
    static let allowAutoPlayKey = "tonebox.speech.allowAutoPlay"
    static let announceImmediatelyKey = "tonebox.speech.announceImmediately"
    static let alertNotificationKey = "tonebox.speech.alertNotification"
    static let alertBannerKey = "tonebox.speech.alertBanner"
    /// Maximum characters accepted by speak_summary — a summary, not an essay. Beyond this
    /// the tool errors rather than reading a 50 KB blob aloud (SPEECH-06). (W-19)
    public static let maxSummaryChars = 2000

    /// Overridable in tests; `.standard` in production.
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    // MARK: - Engine + resolved voice
    public enum Engine: String, Sendable { case kokoro, chatterbox }

    /// A resolved voice: which engine to call and the voice id to send.
    public struct Voice: Equatable, Sendable {
        public var engine: Engine
        public var voice: String

        public init(engine: Engine, voice: String) {
            self.engine = engine
            self.voice = voice
        }
    }

    // MARK: - Hosts
    public static var kokoroBaseURL: String {
        get { defaults.string(forKey: kokoroHostKey) ?? "http://127.0.0.1:8880" }
        set { defaults.set(newValue, forKey: kokoroHostKey) }
    }
    public static var chatterboxBaseURL: String {
        get { defaults.string(forKey: chatterboxHostKey) ?? "http://127.0.0.1:8004" }
        set { defaults.set(newValue, forKey: chatterboxHostKey) }
    }

    public static func baseURL(for engine: Engine) -> String {
        switch engine {
        case .kokoro: return kokoroBaseURL
        case .chatterbox: return chatterboxBaseURL
        }
    }

    /// When a self-hosted TTS host is unreachable, fall back to the built-in macOS voice
    /// (`AVSpeechSynthesizer`) so a summary is always spoken. On by default.
    public static var fallbackEnabled: Bool {
        get { defaults.object(forKey: fallbackEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: fallbackEnabledKey) }
    }

    /// Whether an agent may make speech play immediately (`mode:"auto"`) without a
    /// confirmation. Off by default: an auto-play summary is otherwise an audio-spam /
    /// social-engineering vector if the MCP token leaks (SEC-12). When off, `auto` is
    /// downgraded to a banner. (W-19)
    public static var allowAutoPlay: Bool {
        get { defaults.object(forKey: allowAutoPlayKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: allowAutoPlayKey) }
    }

    // MARK: - Delivery

    /// The concrete set of actions to take for one spoken summary. More than one can be true —
    /// e.g. speak immediately AND post a notification so there's a record you can replay. This
    /// is why delivery is modelled as independent surfaces, not one mutually-exclusive mode.
    public struct DeliveryPlan: Equatable, Sendable {
        /// Play the audio right away, without waiting for a Play tap.
        public var speakNow: Bool
        /// Post a macOS notification with a Play action.
        public var notify: Bool
        /// Show an in-app banner with a Play button.
        public var banner: Bool

        public init(speakNow: Bool, notify: Bool, banner: Bool) {
            self.speakNow = speakNow
            self.notify = notify
            self.banner = banner
        }
    }

    /// **Primary** timing choice. `false` (default) = *let the agent decide* — a summary waits
    /// and reaches you through your chosen alert surfaces, and the agent may speak it immediately
    /// only if `allowAutoPlay` is on. `true` = *announce immediately* — always speak it as soon
    /// as the audio is ready (your own opt-in, so it isn't subject to the auto-play gate).
    public static var announceImmediately: Bool {
        get { defaults.object(forKey: announceImmediatelyKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: announceImmediatelyKey) }
    }

    /// Alert surface (applies under **either** primary): post a macOS notification with a Play
    /// action. On by default — this matches the old default delivery of `notify`.
    public static var alertWithNotification: Bool {
        get { defaults.object(forKey: alertNotificationKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: alertNotificationKey) }
    }

    /// Alert surface (applies under **either** primary): show an in-app banner with a Play button.
    public static var alertWithBanner: Bool {
        get { defaults.object(forKey: alertBannerKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: alertBannerKey) }
    }

    /// Resolve the concrete delivery plan for one summary from the primary timing choice, the
    /// auto-play gate, and the two alert surfaces. The two surfaces apply under **both** primaries
    /// (as a live alert while waiting, or a replayable record after immediate playback):
    ///
    /// - **Announce immediately**: speak now; plus any checked alert surfaces.
    /// - **Let the agent decide**: the agent may speak now only if it asked (`mode:"auto"`) *and*
    ///   `allowAutoPlay` is on (SEC-12) — otherwise the summary waits; either way it surfaces
    ///   through the checked alerts. The agent's notify-vs-banner choice defers to the user's
    ///   surfaces: the agent owns *timing*, the user owns *where it shows*.
    ///
    /// One invariant: a summary must always be reachable, so if nothing would surface it, a
    /// banner is kept on. Pure + unit-tested.
    public static func deliveryPlan(
        announceImmediately: Bool,
        allowAgentAutoPlay: Bool,
        notification: Bool,
        banner: Bool,
        requestedMode: String
    ) -> DeliveryPlan {
        // Speak now if the user forces it, or the agent asked to and is permitted to.
        let speakNow = announceImmediately || (requestedMode == "auto" && allowAgentAutoPlay)
        var plan = DeliveryPlan(speakNow: speakNow, notify: notification, banner: banner)
        if !plan.speakNow, !plan.notify, !plan.banner { plan.banner = true } // keep it reachable
        return plan
    }

    // MARK: - Category → voice map
    /// Values are `"engine:voice"` specs (e.g. `"kokoro:af_bella"`, `"chatterbox:Emily.wav"`).
    /// Ships with sensible defaults; a stored map (edited in Settings) overrides.
    static let defaultVoiceMap: [String: String] = [
        "default": "kokoro:af_heart",    // warm US female — the everyday voice
        "research": "kokoro:af_bella",   // clear US female
        "deploy": "kokoro:am_michael",   // steady US male
        "ops": "kokoro:am_fenrir",       // deeper US male
        "alert": "kokoro:af_nova",       // bright US female — cuts through
        "premium": "chatterbox:Emily.wav", // natural, cloned-quality
        "es": "kokoro:ef_dora",          // Spanish female
    ]

    public static func voiceMap() -> [String: String] {
        if let data = defaults.data(forKey: voiceMapKey),
           let map = try? JSONDecoder().decode([String: String].self, from: data),
           !map.isEmpty {
            return map
        }
        return defaultVoiceMap
    }

    public static func setVoiceMap(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: voiceMapKey) }
    }

    /// Restore the voice map and fallback toggle to their built-in defaults. Hosts are left
    /// alone — they're your servers, not a shippable default. Pass `includeHosts: true` to
    /// also clear them back to the localhost placeholder.
    public static func resetToDefaults(includeHosts: Bool = false) {
        defaults.removeObject(forKey: voiceMapKey)
        defaults.removeObject(forKey: fallbackEnabledKey)
        defaults.removeObject(forKey: allowAutoPlayKey)
        defaults.removeObject(forKey: announceImmediatelyKey)
        defaults.removeObject(forKey: alertNotificationKey)
        defaults.removeObject(forKey: alertBannerKey)
        if includeHosts {
            defaults.removeObject(forKey: kokoroHostKey)
            defaults.removeObject(forKey: chatterboxHostKey)
        }
    }

    // MARK: - Resolution
    /// Resolve a request to a concrete `Voice`. Precedence: an explicit `voice` wins; else the
    /// `category` is looked up in the map (falling back to "default"); an `engineOverride`
    /// (from the tool's `engine` arg) then forces the engine regardless.
    public static func resolve(category: String?, explicitVoice: String?, engineOverride: Engine?) -> Voice {
        if let explicitVoice, !explicitVoice.isEmpty {
            var v = parse(explicitVoice, fallbackEngine: engineOverride ?? .kokoro)
            if let engineOverride { v.engine = engineOverride }
            return v
        }
        let map = voiceMap()
        // Case-insensitive category lookup so "Ops"/"OPS" resolve like "ops" instead of
        // silently falling through to "default". (W-19 / SPEECH-09)
        let key = (category?.isEmpty == false) ? category!.lowercased() : "default"
        let lowered = Dictionary(map.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let spec = lowered[key] ?? lowered["default"] ?? "kokoro:af_heart"
        var v = parse(spec, fallbackEngine: .kokoro)
        if let engineOverride { v.engine = engineOverride }
        return v
    }

    /// Parse an `"engine:voice"` spec; a bare value uses `fallbackEngine`.
    private static func parse(_ spec: String, fallbackEngine: Engine) -> Voice {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let engine = Engine(rawValue: parts[0].lowercased()) {
            return Voice(engine: engine, voice: parts[1])
        }
        return Voice(engine: fallbackEngine, voice: spec)
    }
}
