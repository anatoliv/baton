import BatonSubsonicKit
import SwiftUI

/// Shown when the Keychain will not hand over saved passwords — as opposed to there being none.
///
/// Those two states used to be one. `NavidromeKeychain.secret(account:)` returns `String?`, every
/// call site turned a failure into `""`, and the app then authenticated with an empty password and
/// rendered an empty library. The reason went to `os_log`, where nobody looks. That is how a locked
/// login Keychain presented, for four and a half hours, as "Baton did not start properly"
/// (TBX-5265 was the same lock seen from the signing side; TBX-5268 is this half).
///
/// The distinction is worth a banner rather than a better error string because the two states want
/// **opposite** things from the user. "No password saved" asks them to type one in. "Keychain
/// locked" has to tell them that typing it in again will not help — the write fails for the same
/// reason the read did — and point at the thing that will.
struct KeychainLockedBanner: View {
    /// The status the Keychain reported, shown so a support conversation has the number in it.
    let status: Int32

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Baton can't read your saved passwords")
                    .font(.headline)
                Text(Self.explanation(status: status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Baton can't read your saved passwords. \(Self.explanation(status: status))")
    }

    /// Reassures, then rules out the obvious wrong move, then gives the right one. Re-entering the
    /// password is what most people will try first, and it fails the same way the read did: on a
    /// device still holding a legacy plaintext copy it used to destroy the stored secret outright.
    /// Saying *why* it won't work is the part that stops someone trying it twice.
    static func explanation(status: Int32) -> String {
        let remedy: String
        #if os(macOS)
        remedy = "Unlock your login keychain in Keychain Access, then reopen this window."
        #else
        remedy = "Unlock your device, then reopen this screen."
        #endif
        return "Your servers are still saved. The problem is the keychain, not the password, "
            + "so typing it in again won't fix it. "
            + remedy
            + " (Keychain error \(status).)"
    }
}

#Preview {
    KeychainLockedBanner(status: -25293).padding()
}
