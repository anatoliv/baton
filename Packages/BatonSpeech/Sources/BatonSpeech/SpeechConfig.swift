import Foundation

/// Configuration for Baton's self-hosted speech services: the TTS side (`speak_summary` — where
/// the voices live, how task categories map to them, how a summary is delivered) and the ASR side
/// (track transcription — where Whisper lives and whether it may be used at all).
///
/// Third leaf of the  module-boundary split (after BatonDSP + BatonSubsonicModels): the
/// speech config + service layer, extracted so it has no dependency on the app. The playback
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
    static let whisperHostKey = "tonebox.speech.whisperBaseURL"
    static let whisperModelKey = "tonebox.speech.whisperModel"
    static let transcriptionEnabledKey = "tonebox.speech.transcriptionEnabled"
    static let voiceMapKey = "tonebox.speech.voiceMap"
    static let fallbackEnabledKey = "tonebox.speech.fallbackEnabled"
    static let allowAutoPlayKey = "tonebox.speech.allowAutoPlay"
    static let announceImmediatelyKey = "tonebox.speech.announceImmediately"
    static let alertNotificationKey = "tonebox.speech.alertNotification"
    static let alertBannerKey = "tonebox.speech.alertBanner"
    static let bluetoothWarmupKey = "tonebox.speech.bluetoothWarmup"
    static let engineLingerKey = "tonebox.speech.engineLinger"
    static let favouriteVoicesKey = "tonebox.speech.favouriteVoices"
    static let sessionVoicesKey = "tonebox.speech.sessionVoices"
    /// Maximum characters accepted by speak_summary — a summary, not an essay. Beyond this
    /// the tool errors rather than reading a 50 KB blob aloud.
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

    // MARK: - Transcription (ASR)

    /// Where the self-hosted Whisper lives. Same localhost-placeholder rule as the TTS hosts:
    /// the real LAN address is set at runtime, never committed (the publish guard blocks
    /// `192.168.*`).
    public static var whisperBaseURL: String {
        get { defaults.string(forKey: whisperHostKey) ?? "http://127.0.0.1:8001" }
        set { defaults.set(newValue, forKey: whisperHostKey) }
    }

    /// Model id sent with each transcription request. Servers differ — `faster-whisper`
    /// deployments commonly answer to `whisper-1` for OpenAI compatibility, but a host may
    /// expose `large-v3` directly, so this is a setting rather than a constant.
    public static var whisperModel: String {
        get {
            let stored = defaults.string(forKey: whisperModelKey) ?? ""
            return stored.isEmpty ? "whisper-1" : stored
        }
        set { defaults.set(newValue, forKey: whisperModelKey) }
    }

    /// Whether Baton may transcribe at all. **Off by default**, and deliberately not inferred
    /// from "a host happens to be set": transcription ships audio off the device to a server,
    /// which is a different promise from playing it, and the person makes that call once,
    /// explicitly.
    public static var transcriptionEnabled: Bool {
        get { defaults.object(forKey: transcriptionEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: transcriptionEnabledKey) }
    }

    /// True when transcription is switched on *and* pointed somewhere real. The UI asks this
    /// rather than the two flags separately, so an enabled-but-unconfigured state can't offer
    /// a button that always fails.
    public static var isTranscriptionConfigured: Bool {
        guard transcriptionEnabled else { return false }
        let host = whisperBaseURL.trimmingCharacters(in: .whitespaces)
        guard let comps = URLComponents(string: host), comps.host != nil else { return false }
        return true
    }

    /// When a self-hosted TTS host is unreachable, fall back to the built-in macOS voice
    /// (`AVSpeechSynthesizer`) so a summary is always spoken. On by default.
    public static var fallbackEnabled: Bool {
        get { defaults.object(forKey: fallbackEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: fallbackEnabledKey) }
    }

    // MARK: - Bluetooth wake-up

    /// Seconds of near-silence held before an utterance when the output is **Bluetooth** and
    /// the audio graph was cold.
    ///
    /// A Bluetooth link drops to standby with nothing playing, and takes a moment to come
    /// back — which is otherwise spent eating the first word of the summary. The padding is
    /// scheduled ahead of the speech on the same player node, so it is consumed only once the
    /// device is genuinely rendering: this is "first render **plus** a floor", not a blind
    /// sleep. The floor exists because CoreAudio reports a device as running before the
    /// speaker's amplifier has unmuted, and that last part is invisible from the Mac.
    ///
    /// A setting rather than a constant because speakers differ by more than a factor of two.
    /// Zero disables the padding. `speechLog` reports the measured wake-up after each cold
    /// Bluetooth start, so this can be set from evidence instead of taste.
    public static var bluetoothWarmup: TimeInterval {
        get {
            guard defaults.object(forKey: bluetoothWarmupKey) != nil else { return 0.7 }
            return min(max(defaults.double(forKey: bluetoothWarmupKey), 0), 5)
        }
        set { defaults.set(min(max(newValue, 0), 5), forKey: bluetoothWarmupKey) }
    }

    /// Seconds to leave the speech graph running after an utterance ends, **Bluetooth only**.
    ///
    /// Speech has its own engine precisely so nothing renders between summaries, and on wired
    /// or built-in output that stays true — there is no wake-up to amortise, so the linger is
    /// not applied at all. Over Bluetooth the trade reverses: tearing the graph down returns
    /// the link to standby, so a burst of summaries (a turn ending, then a permission prompt)
    /// would pay the wake-up once each. Holding the graph for a short window pays it once.
    ///
    /// Zero restores the original always-teardown behaviour.
    public static var engineLinger: TimeInterval {
        get {
            guard defaults.object(forKey: engineLingerKey) != nil else { return 25 }
            return min(max(defaults.double(forKey: engineLingerKey), 0), 300)
        }
        set { defaults.set(min(max(newValue, 0), 300), forKey: engineLingerKey) }
    }

    /// Whether an agent may make speech play immediately (`mode:"auto"`) without a
    /// confirmation. Off by default: an auto-play summary is otherwise an audio-spam /
    /// social-engineering vector if the MCP token leaks. When off, `auto` is
    /// downgraded to a banner.
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
    ///   `allowAutoPlay` is on — otherwise the summary waits; either way it surfaces
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

    // MARK: - Favourite voices, and one per session

    /// How many favourites the pool holds. Five is enough to tell a handful of agents apart
    /// and few enough to stay recognisable: past about this many, "which voice was that?" is
    /// a harder question than the one the voices were meant to answer.
    public static let favouriteVoiceCount = 5

    /// The starting pool. Deliberately spread across timbres rather than picked for beauty —
    /// two similar female voices are worse than one, because the whole job is telling them
    /// apart in one word heard from another room.
    static let defaultFavouriteVoices: [String] = [
        "kokoro:af_bella",    // clear US female
        "kokoro:am_michael",  // steady US male
        "kokoro:af_nova",     // bright US female
        "kokoro:am_fenrir",   // deeper US male
        "kokoro:bf_emma",     // UK female
    ]

    /// The pool sessions draw from, always exactly `favouriteVoiceCount` long: a short stored
    /// list is padded from the defaults rather than trusted, so a half-written setting can
    /// never make `assignedVoice(for:)` index out of bounds.
    public static func favouriteVoices() -> [String] {
        let stored = (defaults.array(forKey: favouriteVoicesKey) as? [String]) ?? []
        var pool = stored.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if pool.count < favouriteVoiceCount {
            pool += defaultFavouriteVoices[pool.count ..< favouriteVoiceCount]
        }
        return Array(pool.prefix(favouriteVoiceCount))
    }

    public static func setFavouriteVoices(_ voices: [String]) {
        defaults.set(Array(voices.prefix(favouriteVoiceCount)), forKey: favouriteVoicesKey)
    }

    /// Session label → an explicit voice spec, for breaking a collision by hand.
    public static func sessionVoices() -> [String: String] {
        (defaults.dictionary(forKey: sessionVoicesKey) as? [String: String]) ?? [:]
    }

    public static func setSessionVoices(_ map: [String: String]) {
        defaults.set(map, forKey: sessionVoicesKey)
    }

    /// Which favourite a session lands on: **stable**, derived from the name alone.
    ///
    /// Handing voices out in arrival order would be simpler and worse — a project would sound
    /// different from run to run, so the voice would tell you "a different agent" rather than
    /// "which agent", and the second is the whole point. Deriving it from the name means no
    /// state to keep, nothing to migrate, and the same voice on another machine.
    ///
    /// **The hash must be our own.** Swift's `Hasher` is seeded randomly per process, so
    /// `"baton".hashValue` differs between launches: using it would have produced a voice that
    /// looked stable within one run and silently reshuffled on every restart. This is FNV-1a
    /// over the UTF-8 bytes, which is small and the same everywhere forever.
    ///
    /// **The fold before the modulo is not decoration.** `hash % 5` only ever looks at the low
    /// bits, and measured over twenty realistic project names it never produced slot 0 at all:
    /// one of the five voices was dead. Folding the high half down first spreads them across
    /// all five.
    ///
    /// What this deliberately does *not* promise is that your projects avoid each other. Five
    /// names into five slots land all-distinct only about 4% of the time, so sharing is the
    /// normal case for any hash, not a flaw in this one. That is what pinning is for, and the
    /// Speech pane shows which sessions share a voice so it is visible rather than something
    /// you work out by ear.
    public static func favouriteSlot(for session: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in session.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        hash ^= hash >> 32
        return Int(hash % UInt64(favouriteVoiceCount))
    }

    /// The voice a session speaks in: a hand-pinned override if it has one, else its
    /// stable slot in the pool.
    public static func assignedVoice(for session: String) -> String? {
        let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let pinned = sessionVoices()[trimmed], !pinned.isEmpty { return pinned }
        return favouriteVoices()[favouriteSlot(for: trimmed)]
    }

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
        defaults.removeObject(forKey: transcriptionEnabledKey)
        defaults.removeObject(forKey: whisperModelKey)
        defaults.removeObject(forKey: bluetoothWarmupKey)
        defaults.removeObject(forKey: engineLingerKey)
        defaults.removeObject(forKey: favouriteVoicesKey)
        defaults.removeObject(forKey: sessionVoicesKey)
        if includeHosts {
            defaults.removeObject(forKey: kokoroHostKey)
            defaults.removeObject(forKey: chatterboxHostKey)
            defaults.removeObject(forKey: whisperHostKey)
        }
    }

    // MARK: - Resolution
    /// Resolve a request to a concrete `Voice`.
    ///
    /// Precedence, most specific first:
    ///
    /// 1. An explicit `voice` argument. The agent asked for one by name; nothing overrides that.
    /// 2. The **session's** voice, so two agents running at once are told apart by ear rather
    ///    than by reading a name off a window. A pinned override first, else its stable slot
    ///    in the favourites pool (`assignedVoice(for:)`).
    /// 3. The `category` map, falling back to its "default" row.
    ///
    /// Session beats category deliberately, and it is the one ordering choice here worth
    /// arguing about. Category says what *kind* of thing is being said; session says *who* is
    /// saying it. With several agents running, two of them reporting a deploy is the case you
    /// most need to separate, and a category-wins order gives them the same voice at exactly
    /// that moment. An agent that genuinely wants a specific sound per message still has
    /// `voice`, which outranks both.
    ///
    /// An `engineOverride` (the tool's `engine` arg) then forces the engine regardless.
    public static func resolve(
        category: String?,
        explicitVoice: String?,
        engineOverride: Engine?,
        session: String? = nil
    ) -> Voice {
        if let explicitVoice, !explicitVoice.isEmpty {
            var v = parse(explicitVoice, fallbackEngine: engineOverride ?? .kokoro)
            if let engineOverride { v.engine = engineOverride }
            return v
        }
        if let session, let assigned = assignedVoice(for: session), !assigned.isEmpty {
            var v = parse(assigned, fallbackEngine: engineOverride ?? .kokoro)
            if let engineOverride { v.engine = engineOverride }
            return v
        }
        let map = voiceMap()
        // Case-insensitive category lookup so "Ops"/"OPS" resolve like "ops" instead of
        // silently falling through to "default".
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
