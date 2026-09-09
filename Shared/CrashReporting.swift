import BatonSubsonicKit
import Foundation
import OSLog
import Sentry

/// Opt-in remote crash and error reporting to Crashbox through the Sentry SDK.
///
/// Reporting stays dormant unless the user opted in and packaging supplied one
/// complete Crashbox configuration. The process starts at most one SDK client and
/// has no runtime failover or dual-send path. Public builds contain no provider
/// configuration; when Crashbox is absent or unhealthy, reporting is simply off.
enum CrashReporting {
    static let enabledKey = "baton.crashUploadEnabled"
    static let perLaunchBudget = 20
    static let requestTimeout: TimeInterval = 2
    static let resourceTimeout: TimeInterval = 5

    private static let log = Logger(subsystem: "io.tonebox.baton", category: "crash-reporting")
    private static let attemptGate = ReportingAttemptGate()
    private static let budget = ReportingBudget(limit: perLaunchBudget)
    private static let queue = DispatchQueue(
        label: "io.tonebox.baton.crash-reporting",
        qos: .utility
    )

    /// Whether the user has opted in. Absent key means `false`.
    static var isEnabled: Bool {
        BatonStorage.defaults.bool(forKey: enabledKey)
    }

    /// The Settings toggle is disabled unless this exact artifact has a complete,
    /// valid configuration and immutable source identity.
    static var isConfigured: Bool { configuration != nil }

    /// Launch never waits for SDK or network work.
    static func startIfEnabled() {
        guard isEnabled, let configuration else { return }
        queue.async {
            guard isEnabled else { return }
            startSDKOnce(configuration)
        }
    }

    /// A preference change never waits for SDK shutdown or initialization.
    static func apply(enabled: Bool) {
        if enabled {
            guard let configuration else { return }
            queue.async { startSDKOnce(configuration) }
        } else {
            queue.async {
                SentrySDK.close()
                attemptGate.resetAfterExplicitDisable()
                log.notice("Remote crash reporting disabled by user")
            }
        }
    }

    // MARK: - Artifact configuration

    struct Configuration: Equatable, Sendable {
        let dsn: String
        let provider: String
        let release: String
        let environment: String
    }

    /// Validate the built bundle independently of the release script. A partial,
    /// insecure, mutable, or malformed configuration fails closed.
    static func configuration(from info: [String: Any]) -> Configuration? {
        func value(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // xcconfig values are deliberately schemeless because `//` begins a
        // comment there. Requiring that form also excludes a plaintext HTTP DSN.
        guard let rawDSN = value("CrashReportingDSN"),
              !rawDSN.contains("//"),
              let components = URLComponents(string: "https://\(rawDSN)"),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user?.isEmpty == false,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              !components.path.isEmpty,
              components.path != "/",
              let provider = value("CrashReportingProvider"),
              provider == "crashbox",
              let commit = validatedCommit(value("BatonSourceCommit")),
              let version = value("CFBundleShortVersionString"),
              let build = value("CFBundleVersion"),
              let environment = value("CrashReportingEnvironment"),
              environment.range(
                  of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#,
                  options: .regularExpression
              ) != nil else { return nil }

        return Configuration(
            dsn: "https://\(rawDSN)",
            provider: provider,
            release: releaseName(version: version, build: build, commit: commit),
            environment: environment
        )
    }

    private static var configuration: Configuration? {
        configuration(from: Bundle.main.infoDictionary ?? [:])
    }

    // MARK: - Bounded, event-only SDK policy

    /// The SDK's only network client. A slow or wedged provider gets a bounded
    /// request/resource window and never waits for connectivity.
    static func transportSession() -> URLSession {
        let settings = URLSessionConfiguration.ephemeral
        settings.waitsForConnectivity = false
        settings.timeoutIntervalForRequest = requestTimeout
        settings.timeoutIntervalForResource = resourceTimeout
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.urlCredentialStorage = nil
        return URLSession(configuration: settings)
    }

    /// Apply the deliberately small envelope surface Crashbox accepts. This is
    /// internal so policy tests inspect it without starting the singleton SDK.
    static func configure(_ options: Options, configuration: Configuration) {
        options.dsn = configuration.dsn
        options.releaseName = configuration.release
        options.environment = configuration.environment
        options.sendDefaultPii = false
        options.shutdownTimeInterval = 0
        options.sampleRate = 1
        options.maxCacheItems = UInt(perLaunchBudget)
        options.maxBreadcrumbs = 0
        options.sendClientReports = false
        options.enableAutoSessionTracking = false
        options.enableWatchdogTerminationTracking = false
        options.enableAppHangTracking = false
        options.enableAutoPerformanceTracing = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableFileIOTracing = false
        options.enableCoreDataTracing = false
        options.enableTimeToFullDisplayTracing = false
        options.enableAutoBreadcrumbTracking = false
        #if os(iOS)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.reportAccessibilityIdentifier = false
        #endif
        options.tracesSampleRate = 0
        options.configureProfiling = { profile in
            profile.lifecycle = .manual
            profile.sessionSampleRate = 0
            profile.profileAppStarts = false
        }
        options.urlSession = transportSession()
        options.beforeBreadcrumb = { Self.scrubBreadcrumb($0) }
        options.beforeSend = { event in
            guard budget.admit() else { return nil }
            return Self.scrub(event)
        }
    }

    /// Runs only on the private utility queue. A failed attempt fuses retries
    /// until the user explicitly disables and re-enables reporting.
    private static func startSDKOnce(_ configuration: Configuration) {
        let outcome = attemptGate.runOnce {
            SentrySDK.start { options in Self.configure(options, configuration: configuration) }
        }
        switch outcome {
        case .started: log.notice("Remote crash reporting started")
        case .failed: log.error("Remote crash reporting unavailable; Baton continues")
        case .idle: break
        }
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

    /// A filesystem path reduced to its last component, then redacted.
    ///
    /// For the binary and source paths inside a stack trace. `/Users/<name>/Library/Developer/
    /// Xcode/DerivedData/…/Baton.app/Contents/MacOS/Baton` becomes `Baton`, which keeps the
    /// frame readable and stable for grouping while removing the account name and everything
    /// else about the machine. Redacting the whole string to `<redacted-path>` instead would
    /// make every frame in every image identical, and Sentry groups on these.
    static func redactPath(_ s: String) -> String {
        let last = (s as NSString).lastPathComponent
        return redact(last.isEmpty ? s : last)
    }

    /// Every string anywhere inside a nested container, redacted.
    ///
    /// The old `mapValues` handled the top level only, so `["response": ["url": "https://…"]]`
    /// went out untouched. Depth-bounded because these come from callers, and an event is not
    /// worth a stack overflow.
    static func redactDeep(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 8 else { return "<redacted-too-deep>" }
        if let s = value as? String { return redact(s) }
        if let d = value as? [String: Any] { return d.mapValues { redactDeep($0, depth: depth + 1) } }
        if let a = value as? [Any] { return a.map { redactDeep($0, depth: depth + 1) } }
        return value
    }

    /// The frames of one stack trace, in place.
    ///
    /// `instructionAddress`, `imageAddress` and `symbolAddress` are kept exactly: they are what
    /// Crashbox's symbolication worker resolves against the dSYM, and a redacted address is an
    /// unsymbolicatable crash. `function` and `module` are symbol names from the binary, not
    /// user data, and Sentry groups on them. What goes is the free-form material: source and
    /// binary paths reduced to their last component, and the source-context and local-variable
    /// fields dropped outright, since those can hold anything the program was holding.
    static func scrubFrames(_ trace: SentryStacktrace?) {
        guard let trace else { return }
        for frame in trace.frames {
            frame.fileName = frame.fileName.map(redactPath)
            frame.package = frame.package.map(redactPath)
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
        }
    }

    /// Strips PII and redacts identifying strings across every field of an event.
    ///
    /// **Deny by default.** This used to name seven fields and leave the rest of `SentryEvent`
    /// alone, which is the wrong shape for a privacy filter: `context`, `tags`, `fingerprint`,
    /// `threads`, `debugMeta` and every `stacktrace` went out unread, `extra` was redacted one
    /// level deep, and the executable path in the debug images carried the account name of
    /// whoever was running the build. A scrubber has to enumerate what may leave. (S-F5)
    ///
    /// Every property of `SentryEvent` is accounted for below. The ones not mentioned are left
    /// deliberately, and each is either ours or a machine value with nothing personal in it:
    /// `eventId`, `timestamp`, `startTimestamp`, `level`, `platform`, `type`, `releaseName`,
    /// `dist`, `environment` and `sdk`. `releaseName` in particular must survive untouched:
    /// Crashbox keys the dSYM to it.
    ///
    /// **What Crashbox needs, and therefore what is not removed.** `debugMeta` is kept, not
    /// nulled. Its images carry the Mach-O UUID and load address that
    /// `AppleSymbolicationWorker` resolves a frame against; `crashbox.artifact_uuids` is keyed
    /// on `(project_id, debug_id)`, so dropping the images makes every native crash permanently
    /// unsymbolicated. See `~/Projects/crashbox/docs/apple-symbolication-worker.md`. Only the
    /// two path fields on each image are cut down. Likewise `threads` stays: that doc says the
    /// Cocoa SDK puts the stacks of any non-fatal capture under `threads` rather than
    /// `exceptions`, so an event with its threads removed is most of a crash report missing.
    static func scrub(_ event: Event) -> Event {
        // Dropped whole. `user` is the identity, `request` is a URL with its query, and
        // `serverName` is the machine's hostname.
        event.user = nil
        event.serverName = nil
        event.request = nil

        // Free-text and caller-supplied fields.
        if let m = event.message {
            event.message = SentryMessage(formatted: redact(m.formatted))
        }
        event.logger = event.logger.map(redact)
        event.transaction = event.transaction.map(redact)
        event.fingerprint = event.fingerprint?.map(redact)
        event.tags = event.tags?.mapValues(redact)
        event.modules = event.modules?.mapValues(redact)
        if let extra = event.extra {
            event.extra = extra.mapValues { redactDeep($0) }
        }
        // `context` is a dictionary of dictionaries the SDK fills in: device, os, app, culture.
        // Redacting each string rather than dropping the section keeps the model, OS version and
        // memory figures that make a report triageable, and takes out the app bundle path, which
        // is where the account name reaches the wire.
        if let context = event.context {
            event.context = context.mapValues { section in
                section.mapValues { redactDeep($0) }
            }
        }

        // Exceptions, their mechanisms and their stacks.
        event.exceptions?.forEach { exception in
            exception.value = redact(exception.value)
            exception.module = exception.module.map(redact)
            if let mechanism = exception.mechanism {
                mechanism.desc = mechanism.desc.map(redact)
                mechanism.helpLink = mechanism.helpLink.map(redact)
                if let data = mechanism.data {
                    mechanism.data = data.mapValues { redactDeep($0) }
                }
            }
            scrubFrames(exception.stacktrace)
        }
        event.threads?.forEach { thread in
            thread.name = thread.name.map(redact)
            scrubFrames(thread.stacktrace)
        }
        scrubFrames(event.stacktrace)

        // Debug images: keep the identity, cut the path.
        event.debugMeta?.forEach { image in
            image.name = image.name.map(redactPath)
            image.codeFile = image.codeFile.map(redactPath)
        }

        if let crumbs = event.breadcrumbs {
            event.breadcrumbs = crumbs.compactMap { scrubBreadcrumb($0) }
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
            // Recursive for the same reason `extra` is: a breadcrumb's data is a caller's
            // dictionary, and a URL one level down used to leave untouched.
            crumb.data = data.mapValues { redactDeep($0) }
        }
        return crumb
    }

    // MARK: - Release identity — pure, unit-tested in CrashReportingReleaseTests

    /// The exact source revision this build was compiled from, or `nil` when the
    /// build carries no usable one.
    ///
    /// Both release scripts stamp this from `git rev-parse HEAD`. Historical and
    /// development builds remain honestly unconfigured instead of claiming a guess.
    static var sourceCommit: String? { validatedCommit(Bundle.main.object(forInfoDictionaryKey: "BatonSourceCommit") as? String) }

    /// Accepts exactly 40 lowercase hex characters and nothing else.
    ///
    /// Every other shape is a false identity rather than a partial one, and a false
    /// identity is worse because it gets believed: an unexpanded `$(BATON_SOURCE_COMMIT)`
    /// template looks like a populated key, an abbreviated hash gets more ambiguous as
    /// the repo grows, and an uppercase spelling compares unequal to the lowercase one
    /// git prints. Anything but the canonical form is treated as no identity at all.
    static func validatedCommit(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(trimmed.utf8)
        guard bytes.count == 40 else { return nil }
        guard bytes.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }) else { return nil }
        return trimmed
    }

    /// The Sentry release id: `bundleID@marketingVersion+build`, with the source
    /// commit appended when the build has one.
    ///
    /// Sentry groups issues, regressions and dSYMs by this string, so on its own the
    /// version pair says only which numbers were typed into project.yml — two different
    /// commits can produce the same release id, and a crash in one is filed against the
    /// other. Appending the commit makes the release name itself the map from a report
    /// back to the source that produced it. Builds without a commit keep the old id
    /// exactly, so existing releases are not re-keyed.
    static func releaseName(version: String, build: String, commit: String?) -> String {
        let base = "io.tonebox.baton@\(version)+\(build)"
        guard let commit else { return base }
        return "\(base).\(commit)"
    }

}
