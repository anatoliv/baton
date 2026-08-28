import BatonSpeech
import Foundation

/// User defaults for read-aloud.
///
/// Deliberately in the **app target**, not in the shared `BatonSpeech` package, even though
/// `SpeechConfig` lives there and would be the obvious home. Read-aloud is macOS-only — iOS
/// cannot read another app's screen — so putting these keys in a shared package would drag the
/// iPhone target into a feature it can never have, and this repo's gate exists precisely because
/// a shared-package change once broke the phone while the Mac suite stayed green.
enum ReadAloudSettings {

    /// Overridable so tests do not write to the real domain, matching `SpeechConfig.defaults`
    /// — including its `nonisolated(unsafe)`, since this is a test seam written once at setup
    /// rather than shared mutable state under contention.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    // MARK: - Hotkey

    private static let hotKeyCodeKey = "baton.readAloud.hotKey.code"
    private static let hotKeyModifiersKey = "baton.readAloud.hotKey.modifiers"

    /// The bound hotkey, or `nil` when unbound.
    ///
    /// **Unbound is the default and the shipped state** (decision 2). Nothing is registered
    /// system-wide until the user picks a key, so a fresh install cannot collide with a
    /// shortcut they already use in another app — and the Services entry means the feature is
    /// usable before they ever bind one.
    static var hotKey: (keyCode: UInt32, modifiers: UInt32)? {
        get {
            guard defaults.object(forKey: hotKeyCodeKey) != nil else { return nil }
            let code = UInt32(defaults.integer(forKey: hotKeyCodeKey))
            let mods = UInt32(defaults.integer(forKey: hotKeyModifiersKey))
            return (code, mods)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: hotKeyCodeKey)
                defaults.removeObject(forKey: hotKeyModifiersKey)
                return
            }
            defaults.set(Int(newValue.keyCode), forKey: hotKeyCodeKey)
            defaults.set(Int(newValue.modifiers), forKey: hotKeyModifiersKey)
        }
    }

    // MARK: - Voices

    private static let perSourceVoicesKey = "baton.readAloud.perSourceVoices"

    /// Whether a reading picks its voice from where the text came from — Chrome in one voice,
    /// a terminal in another.
    ///
    /// **Off by default** (decision 3). The cue is genuinely useful, but a voice that changes
    /// on its own reads as a bug until you know the feature exists, so it is one toggle away
    /// rather than a surprise on first use.
    static var perSourceVoices: Bool {
        get { defaults.bool(forKey: perSourceVoicesKey) }
        set { defaults.set(newValue, forKey: perSourceVoicesKey) }
    }

    // MARK: - Clipboard fallback

    private static let allowClipboardFallbackKey = "baton.readAloud.allowClipboardFallback"

    /// Whether the hotkey may fall back to a synthetic ⌘C when the accessibility read returns
    /// nothing.
    ///
    /// **On by default, and load-bearing rather than an edge case.** Phase 0 measured that
    /// Chrome's `AXWebArea` does not implement `AXSelectedText` at all, so in the single most
    /// common source application this fallback *is* the hotkey path. It briefly replaces the
    /// clipboard, which is why it is a switch the user can find and turn off.
    static var allowClipboardFallback: Bool {
        get {
            guard defaults.object(forKey: allowClipboardFallbackKey) != nil else { return true }
            return defaults.bool(forKey: allowClipboardFallbackKey)
        }
        set { defaults.set(newValue, forKey: allowClipboardFallbackKey) }
    }

    // MARK: - OCR

    private static let ocrEnabledKey = "baton.readAloud.ocrEnabled"

    /// Whether the Option chord may capture the focused window and read the pixels.
    ///
    /// **Off by default**, and the only read-aloud capability that is. It is the heaviest thing
    /// the feature can ask for — Screen Recording — and a screen capture that a user did not
    /// deliberately switch on is exactly the sort of surprise that costs an app its trust, even
    /// when every capture is user-initiated.
    static var ocrEnabled: Bool {
        get { defaults.bool(forKey: ocrEnabledKey) }
        set { defaults.set(newValue, forKey: ocrEnabledKey) }
    }

    // MARK: - Voice-map seeding

    /// Add `browser` and `terminal` to the user's category → voice map if they are not there.
    ///
    /// Done here, on the Mac, rather than in `SpeechConfig.defaultVoiceMap` — that map is in the
    /// shared package, and seeding it there would show two macOS-only categories in the iPhone's
    /// voice settings, where read-aloud does not and cannot exist.
    ///
    /// Seeded with voices *distinct from the default*, so turning per-source voices on actually
    /// does something audible rather than appearing to be broken.
    static func seedVoiceCategoriesIfNeeded() {
        var map = SpeechConfig.voiceMap()
        var changed = false
        for (category, voice) in [("browser", "kokoro:af_bella"), ("terminal", "kokoro:am_fenrir")]
        where map[category] == nil {
            map[category] = voice
            changed = true
        }
        if changed { SpeechConfig.setVoiceMap(map) }
    }
}
