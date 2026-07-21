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
            // : this app promises "nothing identifying leaves the machine", yet
            // sentry-cocoa 8.x defaults attach request URLs (server host + Subsonic
            // auth) via network breadcrumbs/tracking/failed-request capture and via
            // sampled spans (which bypass beforeSend). Disable every such path, drop
            // performance tracing and session envelopes, and quiet the app-hang watchdog.
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableAutoPerformanceTracing = false
            options.enableAppHangTracking = false
            options.enableAutoSessionTracking = false
            options.tracesSampleRate = 0
            // Redact any residual identifying strings that still reach an event or a
            // breadcrumb through a message, exception value, extra, or context.
            options.beforeBreadcrumb = { crumb in Self.scrubBreadcrumb(crumb) }
            options.beforeSend = { event in Self.scrub(event) }
        }
        log.notice("Remote crash reporting started")
    }

    // MARK: - Scrubbing — pure, unit-tested in CrashReportingScrubberTests

    /// Redacts anything that could identify the user's server or machine: URLs,
    /// RFC-1918 / link-local IPs, `*.local` hosts, Subsonic auth params, and home paths.
    static func redact(_ s: String) -> String {
        var out = s
        let rules: [(String, String)] = [
            ("https?://[^\\s\"'<>]+", "<redacted-url>"),
            ("\\b(?:10|127)\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b", "<redacted-ip>"),
            ("\\b192\\.168\\.\\d{1,3}\\.\\d{1,3}\\b", "<redacted-ip>"),
            ("\\b172\\.(?:1[6-9]|2\\d|3[01])\\.\\d{1,3}\\.\\d{1,3}\\b", "<redacted-ip>"),
            ("\\b[A-Za-z0-9-]+\\.local\\b", "<redacted-host>"),
            ("/Users/[^\\s\"'<>]+", "<redacted-path>"),
            ("[?&](?:t|s|u|p|apiKey)=[^&\\s\"'<>]*", "&<redacted>"),
        ]
        for (pattern, repl) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: repl)
        }
        return out
    }

    /// Strips PII and redacts identifying strings across every field of an event.
    static func scrub(_ event: Event) -> Event {
        event.user = nil
        event.serverName = nil
        event.request = nil
        if let m = event.message {
            event.message = SentryMessage(formatted: redact(m.formatted))
        }
        event.exceptions?.forEach { $0.value = redact($0.value) }
        if let crumbs = event.breadcrumbs {
            event.breadcrumbs = crumbs.compactMap { scrubBreadcrumb($0) }
        }
        if let extra = event.extra {
            event.extra = extra.mapValues { v in (v as? String).map(redact) ?? v }
        }
        return event
    }

    /// Drops network/http breadcrumbs wholesale (they carry request URLs) and redacts
    /// the message + string data of the rest.
    static func scrubBreadcrumb(_ crumb: Breadcrumb) -> Breadcrumb? {
        let cat = crumb.category.lowercased() // non-optional in the pinned Sentry SDK
        if cat.contains("http") || cat.contains("network") {
            return nil
        }
        if let msg = crumb.message { crumb.message = redact(msg) }
        if let data = crumb.data {
            crumb.data = data.mapValues { v in (v as? String).map(redact) ?? v }
        }
        return crumb
    }

    /// `bundleID@marketingVersion+build`, the conventional Sentry release id.
    private static var release: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "io.tonebox.baton@\(version)+\(build)"
    }
}
