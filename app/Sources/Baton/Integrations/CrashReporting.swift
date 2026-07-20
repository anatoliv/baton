import Foundation
import OSLog
import Sentry

/// Opt-in remote crash & error reporting via Sentry.
///
/// Baton's default posture is "nothing is uploaded" — the app is
/// self-hosted and doesn't phone home. This reporter stays dormant unless
/// **both** are true:
///
///  1. the user has opted in (Settings, About → Diagnostics, default OFF), and
///  2. a non-empty DSN is baked into the build (the `SentryDSN` Info.plist
///     key, fed by `Config/Sentry.local.xcconfig`, which is gitignored).
///
/// Public / repo builds ship with an empty DSN, so remote reporting is
/// impossible in them even if the toggle is flipped. No PII is collected
/// (`sendDefaultPii = false`), and a `beforeSend` hook strips anything that
/// could carry a server address or account identity. Your music library,
/// track titles, server URL, and credentials are never attached.
enum CrashReporting {
    /// UserDefaults / `@AppStorage` key for the opt-in toggle. Absent or
    /// `false` means reporting stays off.
    static let enabledKey = "baton.crashUploadEnabled"

    private static let log = Logger(subsystem: "io.tonebox.baton", category: "crash-reporting")

    /// Whether the user has opted in. Absent key means `false`.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Whether this build can report at all (a DSN is baked in). The
    /// Settings toggle is disabled when this is `false`.
    static var isConfigured: Bool { dsn != nil }

    /// Start the SDK at launch if the user has opted in. No-op otherwise.
    static func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    /// React to the user flipping the Settings toggle at runtime.
    static func apply(enabled: Bool) {
        if enabled {
            start()
        } else {
            SentrySDK.close()
            log.notice("Remote crash reporting disabled by user")
        }
    }

    // MARK: - Internals

    /// DSN baked into the build, or `nil` when empty/absent.
    ///
    /// The DSN is stored in the xcconfig **without** its `https://` scheme:
    /// xcconfig treats `//` as a comment, so a full `https://…` value gets
    /// truncated during substitution. The rest of a DSN has no `//`, so we
    /// store the schemeless form and re-add the scheme here.
    private static var dsn: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private static func start() {
        guard let dsn else {
            log.notice("Crash reporting opted in, but no DSN baked into this build — staying off")
            return
        }
        SentrySDK.start { options in
            options.dsn = dsn
            // Privacy: never attach IP, user identifiers, or request bodies.
            options.sendDefaultPii = false
            options.releaseName = release
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "release"
            #endif
            // Modest performance sampling.
            options.tracesSampleRate = 0.2
            // Belt-and-braces scrubbing: strip anything that could carry the
            // user's server address or identity before an event leaves the Mac.
            options.beforeSend = { event in
                event.user = nil
                event.serverName = nil
                event.request = nil
                return event
            }
        }
        log.notice("Remote crash reporting started")
    }

    /// `bundleID@marketingVersion+build`, the conventional Sentry release id.
    private static var release: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "io.tonebox.baton@\(version)+\(build)"
    }
}
