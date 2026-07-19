import Foundation

/// Configuration for Baton's spoken-summary feature (the `speak_summary` MCP tool):
/// where the TTS services live and how task categories map to voices.
///
/// Mirrors `NavidromeConfig`'s shape — a caseless `enum` over `UserDefaults` (injectable
/// for tests), with `tonebox.*` keys. Hosts default to a harmless localhost placeholder;
/// the real LAN host is set at runtime (Settings / `defaults write`) so no private LAN IP
/// is ever committed to source (the publish guard blocks `192.168.*`).
enum SpeechConfig {
    // MARK: - Keys
    static let kokoroHostKey = "tonebox.speech.kokoroBaseURL"
    static let chatterboxHostKey = "tonebox.speech.chatterboxBaseURL"
    static let voiceMapKey = "tonebox.speech.voiceMap"
    static let fallbackEnabledKey = "tonebox.speech.fallbackEnabled"

    /// Overridable in tests; `.standard` in production.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    // MARK: - Engine + resolved voice
    enum Engine: String { case kokoro, chatterbox }

    /// A resolved voice: which engine to call and the voice id to send.
    struct Voice: Equatable {
        var engine: Engine
        var voice: String
    }

    // MARK: - Hosts
    static var kokoroBaseURL: String {
        get { defaults.string(forKey: kokoroHostKey) ?? "http://127.0.0.1:8880" }
        set { defaults.set(newValue, forKey: kokoroHostKey) }
    }
    static var chatterboxBaseURL: String {
        get { defaults.string(forKey: chatterboxHostKey) ?? "http://127.0.0.1:8004" }
        set { defaults.set(newValue, forKey: chatterboxHostKey) }
    }

    static func baseURL(for engine: Engine) -> String {
        switch engine {
        case .kokoro: return kokoroBaseURL
        case .chatterbox: return chatterboxBaseURL
        }
    }

    /// When a self-hosted TTS host is unreachable, fall back to the built-in macOS voice
    /// (`AVSpeechSynthesizer`) so a summary is always spoken. On by default.
    static var fallbackEnabled: Bool {
        get { defaults.object(forKey: fallbackEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: fallbackEnabledKey) }
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

    static func voiceMap() -> [String: String] {
        if let data = defaults.data(forKey: voiceMapKey),
           let map = try? JSONDecoder().decode([String: String].self, from: data),
           !map.isEmpty {
            return map
        }
        return defaultVoiceMap
    }

    static func setVoiceMap(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: voiceMapKey) }
    }

    /// Restore the voice map and fallback toggle to their built-in defaults. Hosts are left
    /// alone — they're your servers, not a shippable default. Pass `includeHosts: true` to
    /// also clear them back to the localhost placeholder.
    static func resetToDefaults(includeHosts: Bool = false) {
        defaults.removeObject(forKey: voiceMapKey)
        defaults.removeObject(forKey: fallbackEnabledKey)
        if includeHosts {
            defaults.removeObject(forKey: kokoroHostKey)
            defaults.removeObject(forKey: chatterboxHostKey)
        }
    }

    // MARK: - Resolution
    /// Resolve a request to a concrete `Voice`. Precedence: an explicit `voice` wins; else the
    /// `category` is looked up in the map (falling back to "default"); an `engineOverride`
    /// (from the tool's `engine` arg) then forces the engine regardless.
    static func resolve(category: String?, explicitVoice: String?, engineOverride: Engine?) -> Voice {
        if let explicitVoice, !explicitVoice.isEmpty {
            var v = parse(explicitVoice, fallbackEngine: engineOverride ?? .kokoro)
            if let engineOverride { v.engine = engineOverride }
            return v
        }
        let map = voiceMap()
        let key = (category?.isEmpty == false) ? category! : "default"
        let spec = map[key] ?? map["default"] ?? "kokoro:af_heart"
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
