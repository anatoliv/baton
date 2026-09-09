import BatonSubsonicKit
import SwiftUI

/// The appearance choice, applied to a whole window, live.
///
/// `AppearanceSetting` was written for exactly one bug, and its own doc-comment names it: the
/// Mac forced dark on its library window "while Settings and Help followed the system, so one
/// app had two answers". The fix then landed on the library window and nowhere else, so the
/// app still had two answers — and the half that was wrong was the half a new user sees first,
/// since the not-connected gate, Settings and Help are all reached before any music is.
///
/// Two details this exists to get right, both of which a bare `.batonAppearance(.current)` at
/// each scene gets wrong:
///
/// - **It has to be live.** `AppearanceSetting.current` is read once. Changing the setting is
///   something you do *in* one of these windows, so a value read at construction leaves the
///   window you changed it in looking the way it did before.
/// - **It has to read the right defaults.** `@AppStorage` resolves its store from the
///   environment, and every scene root sets `.defaultAppStorage(BatonStorage.defaults)`
///   *inside* itself — below where a modifier applied to the scene's root view sits. Naming
///   the store here means the order of the two modifiers cannot change the answer, and a
///   `-baton.defaultsSuite` probe reads the probe's setting rather than the owner's.
///
/// The player surfaces are deliberately not this: the artwork wash and the white-on-dark
/// transport are a fixed design rather than a preference, which `AppearanceSetting` also says.
struct BatonChrome: ViewModifier {
    @AppStorage(AppearanceSetting.key, store: BatonStorage.defaults)
    private var appearanceRaw = AppearanceSetting.dark.rawValue

    private var appearance: AppearanceSetting {
        AppearanceSetting(rawValue: appearanceRaw) ?? .dark
    }

    func body(content: Content) -> some View {
        content.batonAppearance(appearance)
    }
}

extension View {
    /// Applies the user's appearance choice to a window's chrome. See `BatonChrome`.
    func batonChrome() -> some View {
        modifier(BatonChrome())
    }
}
