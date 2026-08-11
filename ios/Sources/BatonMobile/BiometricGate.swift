import LocalAuthentication

/// Face ID / Touch ID in front of the few things worth protecting.
///
/// Ported from KeepFloat's gate, keeping its three judgement calls — each of which is easy
/// to get wrong in the other direction:
///
/// 1. **`.deviceOwnerAuthentication`, not `…WithBiometrics`** — passcode fallback comes for
///    free, so a wet thumb or a mask doesn't lock you out of your own settings.
/// 2. **Nothing enrolled ⇒ allow.** A phone with no passcode has no way to prove anything;
///    refusing would deny someone access to their own key with no route to recover it.
/// 3. **A DEBUG launch-arg bypass**, because the simulator cannot perform a biometric match
///    and a gate you can't drive is a gate you can't test.
///
/// Deliberately **not** an app-wide lock. KeepFloat locks its whole shell because it holds
/// invoices; Baton is a music player, and prompting every time someone returns to skip a
/// track would be the most annoying feature in the app. This guards secrets, nothing else.
@MainActor
enum BiometricGate {
    /// Launch argument that satisfies the gate in DEBUG builds, for UI tests and simulator
    /// runs. Never compiled into release.
    static let bypassArgument = "-uitestBypassBiometrics"

    /// Prompts for biometrics (with device-passcode fallback). Returns whether to proceed.
    static func authenticate(reason: String) async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(bypassArgument) { return true }
        #endif

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics and no passcode — see (2) above.
            return true
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }

    /// Whether the device can actually challenge — drives whether a screen bothers to show
    /// "protected by Face ID" affordances.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}
