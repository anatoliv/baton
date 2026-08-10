import SwiftUI

/// Light, dark, or whatever the system says.
///
/// Both apps hardcoded `.preferredColorScheme(.dark)` — the Mac on its library window (while
/// Settings and Help followed the system, so one app had two answers) and the phone on its
/// entire tab view. The reason was real: the artwork wash is built for a dark ground, and
/// near-black text over a warm wash is unreadable. But "the player needs dark" is not the
/// same claim as "you may not use this app in light mode", and nothing offered a way out.
///
/// So this is the way out, defaulting to Dark: nobody's app changes today, and the people
/// for whom a permanently dark window is a problem have an answer that does not involve
/// giving up the app.
public enum AppearanceSetting: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// What to hand `.preferredColorScheme`. Nil means "don't force anything", which is
    /// what `.system` has to be — passing `.light` for system would override the very
    /// thing it is deferring to.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// One key, both apps. Not in `PreferenceSync.syncedKeys`: like the browse layouts,
    /// this describes the screen you are looking at rather than you — a Mac in a bright
    /// room and a phone in bed genuinely want different answers.
    public static let key = "baton.appearance"

    public static var current: AppearanceSetting {
        AppearanceSetting(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark
    }
}

public extension View {
    /// Applies the user's appearance choice.
    ///
    /// Player surfaces should NOT use this — they stay dark unconditionally, because the
    /// artwork wash and the white-on-dark transport are a fixed design rather than a
    /// preference. This is for the library, browse and settings chrome around them.
    func batonAppearance(_ setting: AppearanceSetting) -> some View {
        preferredColorScheme(setting.colorScheme)
    }
}
