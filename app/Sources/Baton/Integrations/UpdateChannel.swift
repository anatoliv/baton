import Foundation

/// Whether Baton has a *real, usable* Sparkle update channel.
///
/// Until we publish signed releases, `SUPublicEDKey` in the bundle is still
/// the build-time placeholder and the appcast host isn't stood up, so
/// "Check for Updates" could only ever fail (Sparkle refuses downloads
/// without a valid EdDSA key). This lets the Updates UI say so plainly and
/// disable the check, instead of firing a request that silently errors.
enum UpdateChannel {
    /// The literal placeholder shipped in `project.yml`'s `SUPublicEDKey`
    /// until a real EdDSA key is generated for a release. The check below
    /// treats this exact value (and an empty/missing key) as "not configured".
    static let publicKeyPlaceholder = "REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY"

    /// True only when the channel is genuinely shippable:
    ///  - the signing key is a real (non-placeholder, non-empty) value,
    ///  - the feed is a valid https URL with a host, AND
    ///  - automatic checks are enabled.
    ///
    /// The last condition is the deliberate "the appcast is actually live"
    /// switch: the release runbook flips `SUEnableAutomaticChecks` to true
    /// only once the feed host is stood up. So generating the signing key
    /// alone does NOT make the UI claim "Ready" while the feed is still
    /// unreachable. Pure for testing.
    static func isConfigured(publicKey: String?, feedURL: String?, autoChecksEnabled: Bool) -> Bool {
        let key = (publicKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != publicKeyPlaceholder else { return false }
        let feed = (feedURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: feed),
              url.scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return autoChecksEnabled
    }

    /// Reads the values baked into the running bundle's Info.plist.
    static var isConfiguredFromBundle: Bool {
        let auto = (Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool) ?? false
        return isConfigured(
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            autoChecksEnabled: auto
        )
    }

    /// The feed URL baked into the bundle, for display.
    static var feedURLFromBundle: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "—"
    }
}
