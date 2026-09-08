import Foundation
import OSLog

private let storageLog = Logger(subsystem: "io.tonebox.baton", category: "BatonStorage")

/// Where this process keeps its preferences and its files — one answer, asked once.
///
/// The Mac app is unsandboxed, so its `UserDefaults` *is* the owner's real `io.tonebox.baton`
/// domain and its stores *are* the owner's real `~/Library/Application Support/Baton`. That made
/// the Mac half of a sync walk impossible to run: launching a probe build would write probe keys
/// into the owner's preferences and publish their real friend memory to whatever gateway the probe
/// was pointed at. Three cards ended with an unrun Mac half for that reason (TBX-3846, TBX-5123,
/// TBX-5125) — not because anyone was lazy, but because the safe version of the action did not
/// exist. This is that version.
///
/// ## One flag, because half a redirect is worse than none
///
/// `-baton.defaultsSuite <name>` moves **both** halves together: preferences go to the named
/// suite, and files go to `Application Support/Baton Probes/<name>`. There is deliberately no way
/// to move one without the other. A probe that redirected its preferences but still wrote the
/// owner's real `remote-memory.json` would report a clean walk while testing nothing, which is the
/// failure this type is shaped to make impossible rather than merely discouraged.
///
/// `-baton.supportDirectory <path>` may point the file half somewhere specific — a scratch
/// directory outside Application Support, say. On its own, with no suite, it is **refused**: that
/// is exactly the half-redirect above.
///
/// ## Why this is not a `BatonEnvironment` case
///
/// `BatonEnvironment.testing` means "a unit-test run": no system Now Playing, no network
/// monitoring, isolated everything. A probe launch is the opposite — it is the **shipping** app,
/// with every real side effect intact, pointed at throwaway storage. Making it a third environment
/// case would switch off the behaviour the walk exists to observe. So the two are orthogonal:
/// `BatonEnvironment` says *what kind of run this is*, `BatonStorage` says *where its state lives*.
///
/// ## Inert unless asked for
///
/// With no arguments this returns `UserDefaults.standard` and the real Application Support
/// directory, byte for byte what every call site did before. A user cannot trip into it: the
/// arguments are namespaced, absent from every menu and settings pane, and a suite name that would
/// collide with the app's own domain is refused. A probe launch says so in the log, loudly, once.
///
/// ## What it does not cover, measured rather than assumed
///
/// A probe keeps the app's **bundle identifier**, so anything the *system frameworks* write on the
/// app's behalf still lands in the real domain. Running the walk this was built for showed exactly
/// one such key move: `NSStatusItem VisibleCC Item-0`, AppKit's own menu-bar item bookkeeping. No
/// Baton key crossed, and `~/Library/Application Support/Baton` came out byte-identical. Window
/// frame autosaves are the other family of the same kind. They are cosmetic, they are not in the
/// sync contract, and closing the gap would mean re-signing a copy of the bundle under a different
/// identifier — worth it only if a walk ever turns on one of them.
///
/// The **Keychain** is covered, but by a different mechanism: `NavidromeKeychain.service` takes a
/// per-probe name, so a throwaway device starts with no credentials and cannot overwrite the
/// owner's. That one is named there rather than here because it is a change to that type.
public enum BatonStorage {
    // MARK: - The arguments

    public static let defaultsSuiteArgument = "-baton.defaultsSuite"
    public static let supportDirectoryArgument = "-baton.supportDirectory"

    /// A parsed, validated redirect. `nil` fields mean "use the real thing".
    public struct Redirect: Equatable, Sendable {
        public var suiteName: String?
        public var supportDirectory: URL?

        public init(suiteName: String? = nil, supportDirectory: URL? = nil) {
            self.suiteName = suiteName
            self.supportDirectory = supportDirectory
        }

        public var isActive: Bool { suiteName != nil }
        public static let none = Redirect()
    }

    // MARK: - Parsing

    /// Read a redirect out of a command line. Pure, so the rules can be tested without a process
    /// — which matters more than usual here, since the only other way to check them is to launch
    /// the app and look at where it wrote.
    ///
    /// Rejects, and says why:
    /// - a missing or empty value after either argument;
    /// - a suite name outside `[A-Za-z0-9._-]`, or longer than 64 characters, since it becomes a
    ///   preferences domain and a path component;
    /// - a suite name equal to the app's own bundle identifier, which would redirect the owner's
    ///   real domain onto itself and quietly defeat the whole point;
    /// - `-baton.supportDirectory` with no `-baton.defaultsSuite`, the half-redirect.
    public static func redirect(from arguments: [String],
                                appDomain: String? = Bundle.main.bundleIdentifier) -> Redirect {
        let suite = value(of: defaultsSuiteArgument, in: arguments)
        let directory = value(of: supportDirectoryArgument, in: arguments)

        guard let suite else {
            if directory != nil {
                storageLog.error("""
                    \(supportDirectoryArgument, privacy: .public) was given without \
                    \(defaultsSuiteArgument, privacy: .public). Redirecting files but not \
                    preferences tests nothing; ignoring both.
                    """)
            }
            return .none
        }

        guard isUsableSuiteName(suite) else {
            storageLog.error("ignoring unusable defaults suite name '\(suite, privacy: .public)'")
            return .none
        }
        guard suite != appDomain else {
            storageLog.error("""
                refusing a defaults suite equal to the app's own domain \
                ('\(suite, privacy: .public)') — that is not a redirect.
                """)
            return .none
        }

        return Redirect(suiteName: suite,
                        supportDirectory: directory.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    private static func value(of argument: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argument),
              arguments.index(after: index) < arguments.endIndex else { return nil }
        let raw = arguments[arguments.index(after: index)]
        // A following argument is a missing value, not a value. `-a -b` should not name a suite "-b".
        guard !raw.isEmpty, !raw.hasPrefix("-") else { return nil }
        return raw
    }

    private static func isUsableSuiteName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz"
            + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - This process

    /// The redirect this process was launched with. Resolved once: a command line does not change,
    /// and re-reading it per call would invite two answers to one question.
    public static let current: Redirect = {
        let resolved = redirect(from: ProcessInfo.processInfo.arguments)
        if let suite = resolved.suiteName {
            storageLog.notice("""
                PROBE LAUNCH — preferences in suite '\(suite, privacy: .public)', files under \
                '\(directory(for: resolved).path, privacy: .public)'. The owner's own domain and \
                Application Support are not being touched.
                """)
        }
        return resolved
    }()

    /// True when this process is running against throwaway storage.
    public static var isProbe: Bool { current.isActive }

    /// **The** preferences domain for this app's own settings.
    ///
    /// Every direct `UserDefaults.standard` in Baton's own code should be this instead, and views
    /// get it through `.defaultAppStorage(BatonStorage.defaults)` at the root of each scene, so
    /// `@AppStorage` moves with everything else. Without a redirect it *is* `.standard`.
    public nonisolated(unsafe) static let defaults: UserDefaults = resolvedDefaults(for: current)

    /// The domain a given redirect names. Separate from `defaults` so a test can resolve a probe
    /// redirect without being launched as one — `current` is fixed for the life of a process, and
    /// a rule that can only be checked by launching the app is a rule nothing checks.
    public static func resolvedDefaults(for redirect: Redirect) -> UserDefaults {
        guard let suite = redirect.suiteName else { return .standard }
        guard let redirected = UserDefaults(suiteName: suite) else {
            // Falling back to `.standard` here would be the silent half-redirect this type exists
            // to prevent, so it is at least said out loud.
            storageLog.error("""
                could not open defaults suite '\(suite, privacy: .public)'; falling back to the \
                real domain. Do NOT treat this run as isolated.
                """)
            return .standard
        }
        carryTheArgumentDomain(into: redirected)
        return redirected
    }

    /// Give the redirected suite the launch arguments the real domain would have had.
    ///
    /// `UserDefaults.standard` merges an **argument domain** — `-baton.railMinimum 5` on the
    /// command line is readable as a default — and `UserDefaults(suiteName:)` does not. Without
    /// this, turning on a probe would silently switch off every launch-argument affordance in the
    /// app at once: `-uitestServer`, `-baton.demoMode`, `-baton.agent.baseURL`, the review-prompt
    /// overrides. Each of those exists because some screen was otherwise unreachable from a test,
    /// so a flag that quietly disables them while claiming to isolate storage would take away the
    /// very thing it was added to enable.
    ///
    /// Registered rather than written: the registration domain is a read-time fallback, so these
    /// values behave exactly as they do on `.standard` — visible to reads, overridden by anything
    /// actually stored, and never persisted to the suite's plist.
    private static func carryTheArgumentDomain(into defaults: UserDefaults) {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard !arguments.isEmpty else { return }
        defaults.register(defaults: arguments)
    }

    /// **The** directory for Baton's own files — `~/Library/Application Support/Baton`, or the
    /// probe's directory. Created if it does not exist; falls back to a temporary directory only
    /// when Application Support itself is unreachable, which is what every call site did before.
    public static func supportDirectory() -> URL {
        let url = directory(for: current)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A named subdirectory of the above — `Baton/Transcripts`, `Baton/Clippings`.
    public static func supportSubdirectory(_ name: String) -> URL {
        let url = supportDirectory().appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Resolution without the side effect of creating anything, so `current`'s log line can name
    /// the directory before anyone has asked for it — and so a test can ask where a redirect
    /// *would* put its files.
    public static func directory(for redirect: Redirect) -> URL {
        if let explicit = redirect.supportDirectory { return explicit }
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        guard let suite = redirect.suiteName else {
            return base.appendingPathComponent("Baton", isDirectory: true)
        }
        return base
            .appendingPathComponent("Baton Probes", isDirectory: true)
            .appendingPathComponent(suite, isDirectory: true)
    }
}
