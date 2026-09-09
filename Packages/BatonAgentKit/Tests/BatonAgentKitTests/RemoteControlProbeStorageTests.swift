import BatonSubsonicKit
import XCTest
@testable import BatonAgentKit

/// The remote-control settings under a probe launch.
///
/// `RemoteControlSettings` was the third of the three stores that never got the probe branch
/// (M-F1), and the most sensitive of them: it holds the **authorized-sender list** for Telegram
/// and Discord. A probe read the owner's real allow-list — the review's screenshot has the
/// owner's Telegram and Discord ids visible in a throwaway build — and any settings write in the
/// probe replaced the real one.
///
/// It was also the one the earlier drift guards could not see. The other two say `return
/// .standard` after a `guard`; this said `?? .standard` at the end of a coalescing chain inside
/// `init`, which is a fourth spelling of the same mistake. That is why the guard in
/// `ProbeStorageTests` matches on the return type rather than on any of the spellings.
final class RemoteControlProbeStorageTests: XCTestCase {
    @MainActor func testTheRemoteControlStoreFollowsAProbeRedirect() {
        let suite = "io.tonebox.tests.probe.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = RemoteControlSettings.defaultStore(environment: .production,
                                                     redirect: .init(suiteName: suite))
        XCTAssertNotEqual(store, .standard,
                          "a probe must not read or write the owner's authorized-sender list")

        store.set(["1839246414"], forKey: "baton.tests.probeSenders")
        XCTAssertEqual(BatonStorage.resolvedDefaults(for: .init(suiteName: suite))
            .stringArray(forKey: "baton.tests.probeSenders"), ["1839246414"],
            "the probe suite is not the domain the resolver handed back")
    }

    /// Inert on a normal launch, which is every launch but a probe.
    @MainActor func testWithNoRedirectTheRemoteControlStoreIsTheRealDomain() {
        XCTAssertEqual(RemoteControlSettings.defaultStore(environment: .production, redirect: .none),
                       .standard)
    }

    /// And a test run still gets its own suite rather than the owner's domain, which is the
    /// behaviour the chain in `init` had before and must keep.
    @MainActor func testATestRunStillGetsItsOwnSuite() {
        let key = "baton.tests.remoteSuiteHandshake.\(UUID().uuidString)"
        let store = RemoteControlSettings.defaultStore(environment: .testing, redirect: .none)
        defer { UserDefaults(suiteName: "baton.remote.tests")?.removeObject(forKey: key) }

        XCTAssertNotEqual(store, .standard, "a test run must not write the owner's settings")
        store.set("here", forKey: key)
        // Written through, not compared by identity: two `UserDefaults` objects over one suite are
        // different objects, so an identity check passes and fails for reasons unrelated to the
        // domain either of them is over.
        XCTAssertEqual(UserDefaults(suiteName: "baton.remote.tests")?.string(forKey: key), "here",
                       "the shared test suite is no longer where a test run's settings land")
    }
}
