import BatonSubsonicKit
import Foundation

/// Asks for an App Store rating, but only once Baton has earned one.
///
/// iOS throttles the system prompt to three per user per year *across every app they
/// own*, and gives no callback saying whether it was shown or what the answer was. So a
/// prompt spent badly — on first launch, or on the afternoon someone is still fighting a
/// server URL — is not a prompt that failed, it is a prompt that cannot be retried for
/// months. The gate is deliberately slow: three separate days on which the phone actually
/// played something, and never twice for the same app version.
///
/// The decision is a pure function over ``State`` so `ReviewPromptTests` can prove the gate
/// without StoreKit, a window scene, or a clock.
enum ReviewPrompt {
    /// Everything the gate reasons about. Persisted in `UserDefaults`, but the type knows
    /// nothing about that.
    struct State: Equatable {
        /// Day stamps (`yyyy-MM-dd`) on which real listening happened. Deduped, oldest
        /// first, and trimmed to the number the gate needs.
        var listeningDays: [String] = []
        /// Marketing version whose prompt has already been spent. Empty means none.
        var lastPromptedVersion: String = ""
    }

    /// Distinct days of listening before the app is allowed to ask.
    ///
    /// Days rather than plays: someone who queues an album has one good afternoon, not
    /// twelve endorsements, and coming back tomorrow is the signal worth waiting for.
    ///
    /// Overridable in DEBUG only, and the override is what makes the prompt *observable*.
    /// Three real days is unreachable from any test, so without this the screen it puts up
    /// could only ever be reasoned about, never seen — which is the exact failure this
    /// codebase keeps paying for (a grid whose cells all measured the same, an equalizer
    /// whose coefficients were never applied). `ReviewPromptUITests` sets it to 1.
    static var requiredListeningDays: Int {
        #if DEBUG
        let override = UserDefaults.standard.integer(forKey: "baton.review.requiredDays")
        if override > 0 { return override }
        #endif
        return 3
    }

    /// Whether a demo session may count towards the gate.
    ///
    /// It must not. The four bundled demo tracks are what someone plays *before* deciding
    /// whether the app is any good, and asking them to rate it spends one of the three
    /// prompts iOS allows per user per year on a session that has not connected to
    /// anything. Scrobbling and history already refuse demo mode for the same reason
    /// (`MobileModel`).
    ///
    /// Overridable in DEBUG only, and for one reason: the bundled library is the only
    /// playback a UI test can rely on, so without this seam `ReviewPromptUITests` could
    /// never reach the ask at all.
    ///
    /// A bare launch flag read straight off `ProcessInfo`, the way `-uitestBypassBiometrics`
    /// and `-baton.resetSession` are, rather than a `UserDefaults` key like the two numeric
    /// overrides above. `-baton.review.countInDemo YES` through the argument domain read
    /// back as false and cost a full UI-test run to find; the flag the rest of this app uses
    /// for a yes-or-no does not have that failure mode.
    static let countInDemoArgument = "-baton.review.countInDemo"

    static var countsInDemoMode: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(countInDemoArgument)
        #else
        return false
        #endif
    }

    /// Whether playback in this session should count as listening. Pure, so the demo rule
    /// can be proven without a player.
    static func counts(isDemoMode: Bool) -> Bool {
        !isDemoMode || countsInDemoMode
    }

    /// How long to let the music settle before interrupting it with the ask.
    static var settleDelay: Duration {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "baton.review.settleSeconds")
        if seconds > 0 { return .seconds(seconds) }
        #endif
        return .seconds(20)
    }

    // MARK: - The decision

    static func shouldAsk(_ state: State, version: String) -> Bool {
        state.listeningDays.count >= requiredListeningDays
            && state.lastPromptedVersion != version
    }

    /// `state` with `day` recorded. Re-recording a day already seen is a no-op, which is
    /// what makes "days" mean days rather than "times the user pressed play".
    static func recording(day: String, in state: State) -> State {
        guard !state.listeningDays.contains(day) else { return state }
        var next = state
        next.listeningDays.append(day)
        // Only the count is ever read, and an unbounded array in UserDefaults is a slow
        // leak on a device that may run this app for years.
        let excess = next.listeningDays.count - requiredListeningDays
        if excess > 0 { next.listeningDays.removeFirst(excess) }
        return next
    }

    /// `yyyy-MM-dd` in the user's own calendar, built by components rather than by
    /// `DateFormatter` so it cannot drift with locale or time zone formatting rules.
    static func dayStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Live storage

    private static let daysKey = "baton.review.listeningDays"
    private static let versionKey = "baton.review.lastPromptedVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static var stored: State {
        get {
            State(
                listeningDays: BatonStorage.defaults.stringArray(forKey: daysKey) ?? [],
                lastPromptedVersion: BatonStorage.defaults.string(forKey: versionKey) ?? ""
            )
        }
        set {
            BatonStorage.defaults.set(newValue.listeningDays, forKey: daysKey)
            BatonStorage.defaults.set(newValue.lastPromptedVersion, forKey: versionKey)
        }
    }

    /// Call when the phone has actually started playing something.
    static func recordListening(now: Date = .now) {
        stored = recording(day: dayStamp(now), in: stored)
    }

    /// Cheap read of the gate, for deciding whether it is even worth waiting for a calm
    /// moment. Does not spend the prompt.
    static var isEarned: Bool { shouldAsk(stored, version: currentVersion) }

    /// Spends this version's prompt and reports whether the caller should now ask.
    ///
    /// Marking *before* the prompt is deliberate. iOS may silently decline to show it, and
    /// tells us nothing either way, so the only safe reading of "we asked" is "we tried".
    /// The alternative — mark on success — has no success to observe and would re-ask on
    /// every play for the rest of the version's life.
    static func claimAsk() -> Bool {
        var state = stored
        guard shouldAsk(state, version: currentVersion) else { return false }
        state.lastPromptedVersion = currentVersion
        stored = state
        return true
    }

    #if DEBUG
    /// Test seam: `UserDefaults` is process-wide, so a test that touches the live keys
    /// must be able to put them back.
    static func resetForTesting() {
        BatonStorage.defaults.removeObject(forKey: daysKey)
        BatonStorage.defaults.removeObject(forKey: versionKey)
    }
    #endif
}
