#if DEBUG
import BatonAgentKit
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation

/// What this process actually resolved for storage, in one line a UI test can read.
///
/// A caution went onto the board — from reading the code, explicitly flagged as never run —
/// saying that under XCUITest the app process links XCTest, so `BatonEnvironment.current` is
/// `.testing`, `FriendLedgerStore.defaultDefaults()` hands back a random throwaway suite while
/// `PreferenceSync` keeps `.standard`, and **a UI test could therefore never see friend sync
/// work while reporting nothing wrong**.
///
/// That claim is either true or false and the difference decides whether a whole category of
/// test is possible, so it should not be settled by reading the same code again. This is the
/// thing that settles it, from inside the running app.
///
/// Three facts, because each rules out a different way of being wrong:
///
/// - `env` — what `BatonEnvironment.current` decided, which is the sniff the claim rests on.
/// - `xct` — the two halves of that sniff separately (`XCTestCase` linked / the environment
///   variable present), because in a UI test they need not agree and the claim assumed they do.
/// - `same` — the only one that matters in practice: whether a value written through the domain
///   `PreferenceSync` uses is readable through the domain the friend stores use. A handshake,
///   not an identity check: two `UserDefaults` objects over one suite are still two objects.
///
/// DEBUG only, and computed once. It writes a key under `baton.tests.` into whichever domain it
/// resolved and removes it again, so a probe run does not leave a crumb behind.
enum StorageReport {
    static let line: String = {
        let environment = BatonEnvironment.current
        let syncSide = BatonStorage.defaults
        let friendSide = FriendLedgerStore.defaultDefaults()

        let key = "baton.tests.storageHandshake"
        let token = UUID().uuidString
        syncSide.set(token, forKey: key)
        let sameDomain = friendSide.string(forKey: key) == token
        syncSide.removeObject(forKey: key)

        let linked = NSClassFromString("XCTestCase") != nil
        let configured = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        return "env=\(environment.isTesting ? "testing" : "production") "
            + "xct=\(linked ? "linked" : "not-linked"),\(configured ? "configured" : "not-configured") "
            + "probe=\(BatonStorage.isProbe ? "yes" : "no") "
            + "same=\(sameDomain ? "yes" : "no")"
    }()
}
#endif
