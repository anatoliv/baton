import BatonSubsonicKit
import XCTest
@testable import BatonPlaybackKit

/// The guard for a redirect that only moves half of what it claims to.
///
/// Three cards ended with an unrun Mac half of a sync walk because the Mac app is unsandboxed and
/// there was no safe way to point it at throwaway storage (TBX-3846, TBX-5123, TBX-5125).
/// `BatonStorage` is that way. The danger it introduces is specific and quiet: a probe launch that
/// redirects preferences but still writes the owner's real `remote-memory.json` — or the reverse —
/// would run a *clean-looking* walk over storage the feature is not actually using, report every
/// check green, and prove nothing. Nothing would throw and nothing would fail to compile.
///
/// So this file checks two different things, because one of them cannot catch the other:
///
/// 1. **The rules**, exercised directly — what a redirect accepts and refuses, and that both halves
///    of one redirect derive from the same suite name.
/// 2. **Drift**, by reading the sources — that no store has gone back to naming
///    `UserDefaults.standard` or building its own `Application Support/Baton` path. A future store
///    added next to these ones is exactly how the split would come back, and it would come back
///    silently.
final class ProbeStorageTests: XCTestCase {
    // MARK: - What a redirect accepts

    func testASuiteNameRedirectsBothPreferencesAndFiles() {
        let redirect = BatonStorage.redirect(from: ["Baton", "-baton.defaultsSuite", "walk-1"],
                                             appDomain: "io.tonebox.baton")
        XCTAssertEqual(redirect.suiteName, "walk-1")
        XCTAssertTrue(BatonStorage.directory(for: redirect).path.hasSuffix("Baton Probes/walk-1"),
                      "files must follow the suite without being asked for separately")
    }

    func testTheFileHalfCanBePointedSomewhereSpecific() {
        let redirect = BatonStorage.redirect(
            from: ["Baton", "-baton.defaultsSuite", "walk-1", "-baton.supportDirectory", "/tmp/probe-files"],
            appDomain: "io.tonebox.baton")
        XCTAssertEqual(redirect.suiteName, "walk-1")
        XCTAssertEqual(BatonStorage.directory(for: redirect).path, "/tmp/probe-files")
    }

    func testNoArgumentsIsTheRealAppUntouched() {
        let redirect = BatonStorage.redirect(from: ["Baton"], appDomain: "io.tonebox.baton")
        XCTAssertFalse(redirect.isActive)
        XCTAssertEqual(BatonStorage.resolvedDefaults(for: redirect), .standard)
        XCTAssertTrue(BatonStorage.directory(for: redirect).path.hasSuffix("/Baton"))
        XCTAssertFalse(BatonStorage.directory(for: redirect).path.contains("Baton Probes"))
    }

    // MARK: - What it refuses, and why each refusal is load-bearing

    /// The half-redirect, refused outright rather than half-applied. Redirecting files while
    /// preferences stay real is precisely the run that looks clean and tests nothing.
    func testASupportDirectoryWithNoSuiteIsRefusedEntirely() {
        let redirect = BatonStorage.redirect(
            from: ["Baton", "-baton.supportDirectory", "/tmp/probe-files"], appDomain: "io.tonebox.baton")
        XCTAssertFalse(redirect.isActive)
        XCTAssertNil(redirect.supportDirectory)
        XCTAssertTrue(BatonStorage.directory(for: redirect).path.hasSuffix("/Baton"),
                      "refusing must mean the real directory, not the requested one")
    }

    /// A suite equal to the app's own domain is not a redirect; it is the real domain wearing a
    /// flag, and it would make an unsafe run look like a safe one.
    func testASuiteEqualToTheAppsOwnDomainIsRefused() {
        let redirect = BatonStorage.redirect(from: ["Baton", "-baton.defaultsSuite", "io.tonebox.baton"],
                                             appDomain: "io.tonebox.baton")
        XCTAssertFalse(redirect.isActive)
    }

    func testAnUnusableSuiteNameIsRefused() {
        for bad in ["../escape", "has space", "sl/ash", String(repeating: "x", count: 65)] {
            let redirect = BatonStorage.redirect(from: ["Baton", "-baton.defaultsSuite", bad],
                                                 appDomain: "io.tonebox.baton")
            XCTAssertFalse(redirect.isActive, "'\(bad)' should not name a suite")
        }
    }

    /// `-baton.defaultsSuite` as the last argument, or followed by another flag, is a missing
    /// value. Reading the next flag as a suite name would silently isolate a run nobody asked to
    /// isolate — the mirror image of the failure above.
    func testAMissingValueIsNotASuiteName() {
        XCTAssertFalse(BatonStorage.redirect(from: ["Baton", "-baton.defaultsSuite"]).isActive)
        XCTAssertFalse(BatonStorage.redirect(from: ["Baton", "-baton.defaultsSuite", "-other"]).isActive)
        XCTAssertFalse(BatonStorage.redirect(from: ["Baton", "-baton.defaultsSuite", ""]).isActive)
    }

    // MARK: - The two halves land in the same place

    /// The assertion the card asked for: what `PreferenceSync` writes and what the friend stores
    /// read are the same domain under a redirect, not two domains that happen to agree today.
    ///
    /// Checked by *writing through one and reading through the other*, because comparing two
    /// `UserDefaults` instances for identity would pass even if they were separate objects over
    /// separate suites.
    func testPreferenceSyncAndTheFriendStoresShareOneDomainUnderARedirect() throws {
        let suite = "io.tonebox.tests.probe.\(UUID().uuidString)"
        let redirect = BatonStorage.Redirect(suiteName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let syncSide = BatonStorage.resolvedDefaults(for: redirect)
        let friendSide = FriendLedgerStoreProbe.defaults(redirect: redirect)

        XCTAssertNotEqual(syncSide, .standard, "the probe domain must not be the real one")
        XCTAssertNotEqual(friendSide, .standard, "the probe domain must not be the real one")

        syncSide.set("written by the sync side", forKey: "baton.tests.probeHandshake")
        XCTAssertEqual(friendSide.string(forKey: "baton.tests.probeHandshake"),
                       "written by the sync side",
                       "the friend stores are reading a different domain from the one sync writes")
    }

    /// And with no redirect, both are the real domain — the flag being inert is as load-bearing as
    /// the flag working, since every normal launch takes this path.
    func testWithNoRedirectBothHalvesAreTheRealDomain() {
        XCTAssertEqual(BatonStorage.resolvedDefaults(for: .none), .standard)
        XCTAssertEqual(FriendLedgerStoreProbe.defaults(redirect: .none, environment: .production), .standard)
    }

    // MARK: - Drift: nobody quietly goes back to naming the real thing

    /// The repo, with symlinks resolved.
    ///
    /// `resolvingSymlinksInPath()` is not tidiness. `#filePath` records the path the compiler was
    /// given, while `FileManager.enumerator` hands back resolved ones — so in a checkout under
    /// `/tmp` (which is a symlink to `/private/tmp`, and which is where a release worktree lives)
    /// the two disagree, the prefix strip below fails, and every exempt file is reported as a
    /// violation. That is not hypothetical: it turned this guard red in the middle of a
    /// TestFlight release while the tree was perfectly clean, and it was green on every dev run
    /// because those happen in a directory nothing symlinks.
    ///
    /// **A check whose answer depends on where the checkout lives is not a check.**
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    /// Sources allowed to say `UserDefaults.standard`, each with the reason.
    ///
    /// The three phone entries are not laziness: `UserDefaults(suiteName:)` has **no argument
    /// domain**, so a value passed as `-baton.railMinimum 5` at launch is readable only through
    /// `.standard`. Those three read launch arguments, not stored state, and moving them would
    /// break every UI test that sets them while looking like a tidy-up.
    private static let mayNameTheRealDomain: [String: String] = [
        "Packages/BatonSubsonicKit/Sources/BatonSubsonicKit/BatonStorage.swift":
            "the one place that decides; everyone else asks it",
        "ios/Sources/BatonMobile/AlphabetIndexRail.swift":
            "reads `-baton.railMinimum` from the argument domain, which a suite does not have",
        "ios/Sources/BatonMobile/ReviewPrompt.swift":
            "reads `-baton.review.*` from the argument domain (DEBUG only)",
        "ios/Sources/BatonMobile/MobileModel.swift":
            "reads `-uitestServer/User/Secret` from the argument domain (DEBUG only)",
    ]

    func testNoStoreNamesTheRealDefaultsDomainDirectly() throws {
        let offenders = try sourcesMatching("UserDefaults.standard")
            .filter { Self.mayNameTheRealDomain[$0] == nil }
        XCTAssertEqual(offenders.sorted(), [], """
            These read or write `UserDefaults.standard` directly. Use `BatonStorage.defaults`, or \
            add the file to `mayNameTheRealDomain` with the reason. A probe launch cannot redirect \
            what names the real domain by hand, and the run would still report passes.
            """)
    }

    /// The same rule for the spelling that actually caused this — and which the check above
    /// misses, because `UserDefaults = .standard` and `UserDefaults.standard` are different
    /// strings.
    ///
    /// `defaults: UserDefaults = .standard` is an injection point, which reads as safe: a caller
    /// *can* pass something else. But every caller that takes the default gets the owner's real
    /// domain, and almost all of them do. That is exactly the shape `PreferenceSync` had while
    /// `FriendLedgerStore` consulted the environment — one half of a sync feature deciding for
    /// itself — and writing the first version of this guard without it missed 30 of these,
    /// `NavidromeConfig.defaults` among them, which holds the owner's server credentials.
    func testNoStoreDefaultsAParameterToTheRealDefaultsDomain() throws {
        let offenders = try sourcesMatching("UserDefaults = .standard")
            .filter { Self.mayNameTheRealDomain[$0] == nil }
        XCTAssertEqual(offenders.sorted(), [], """
            These default an injected `UserDefaults` to the real domain. Default it to \
            `BatonStorage.defaults` instead: callers that inject are unaffected, and callers that \
            take the default follow the process rather than the owner's preferences.
            """)
    }

    /// Same rule for files. `Application Support/Baton` assembled by hand is a store that a probe
    /// launch will not move.
    func testNoStoreBuildsTheRealSupportDirectoryByHand() throws {
        let allowed = [
            "Packages/BatonSubsonicKit/Sources/BatonSubsonicKit/BatonStorage.swift",
            // The download cache is `Application Support/Tonebox/music-cache`, shared with Tonebox
            // and predating the split; it consults `BatonStorage.isProbe` on the line above.
            "Packages/BatonPlaybackKit/Sources/BatonPlaybackKit/MusicDownloadStore.swift",
        ]
        let offenders = try sourcesMatching(".applicationSupportDirectory")
            .filter { !allowed.contains($0) }
        XCTAssertEqual(offenders.sorted(), [], """
            These build a support path themselves. Use `BatonStorage.supportDirectory()` or \
            `supportSubdirectory(_:)` so a probe launch moves them with everything else.
            """)
    }

    /// Every product source in both apps and the shared packages. Tests are excluded on purpose:
    /// a test naming `.standard` is a test that owns its own domain, which is not this rule.
    private func sourcesMatching(_ needle: String) throws -> [String] {
        let roots = ["app/Sources", "ios/Sources", "Shared", "Packages"]
        var hits: [String] = []
        for root in roots {
            let base = repoRoot.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let resolved = url.resolvingSymlinksInPath().path
                let relative = resolved.replacingOccurrences(of: repoRoot.path + "/", with: "")
                // If the strip failed, every exemption lookup below silently misses and this
                // guard reports the whole tree as violations — a mess that reads exactly like a
                // real finding. Say which of the two jobs failed instead of printing the other
                // one's output.
                guard !relative.hasPrefix("/") else {
                    throw DriftScanFailure.pathOutsideRepo(file: resolved, root: repoRoot.path)
                }
                if relative.contains("/Tests/") || relative.contains(".build/") { continue }
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                // Ignore mentions inside comments — several of these files explain the rule.
                let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                if code.contains(needle) { hits.append(relative) }
            }
        }
        return hits
    }

    /// The scan could not do its job, as distinct from finding nothing.
    private enum DriftScanFailure: Error, CustomStringConvertible {
        case pathOutsideRepo(file: String, root: String)

        var description: String {
            switch self {
            case let .pathOutsideRepo(file, root):
                return """
                    the drift scan could not place a source inside the repo, so its exemption \
                    list cannot be applied and its result means nothing. This is a bug in the \
                    test, not a violation in the tree.
                      file: \(file)
                      root: \(root)
                    """
            }
        }
    }
}

/// A stand-in for `FriendLedgerStore`, which lives in `BatonAgentKit` — a package this test target
/// cannot see, and which sits *above* this one in the dependency graph. It resolves storage the
/// same way, and `testTheFriendStoresResolveStorageTheSameWayThisStandInDoes` below is what keeps
/// the two honest rather than a comment asking nicely.
private enum FriendLedgerStoreProbe {
    static func defaults(redirect: BatonStorage.Redirect,
                         environment: BatonEnvironment = .current) -> UserDefaults {
        if redirect.isActive { return BatonStorage.resolvedDefaults(for: redirect) }
        guard environment.isTesting else { return .standard }
        return UserDefaults(suiteName: "io.tonebox.tests.friendledger.\(UUID().uuidString)") ?? .standard
    }
}

extension ProbeStorageTests {
    /// The stand-in above is only worth anything if it says what the real one says. This reads the
    /// real `FriendLedgerStore` and fails if its probe branch is gone or spelled differently —
    /// which is the way this whole guarantee would rot without anything going red.
    func testTheFriendStoresResolveStorageTheSameWayThisStandInDoes() throws {
        let url = repoRoot.appendingPathComponent(
            "Packages/BatonAgentKit/Sources/BatonAgentKit/RemoteMemoryStore.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("if redirect.isActive { return BatonStorage.resolvedDefaults(for: redirect) }"),
                      "FriendLedgerStore no longer routes its probe branch through BatonStorage")
    }
}
