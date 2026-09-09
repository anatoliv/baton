import BatonSubsonicKit
import XCTest
@testable import Baton

/// M-F6 / M-F18: a Keychain that will not answer must not be allowed to destroy the webhook
/// header secrets it cannot read, and a header removed from an action must not leave its
/// secret behind for ever.
///
/// The two belong in one file because doing the second without the first is worse than doing
/// neither: a diff computed over values that could not be read deletes everything.
///
/// These drive the real `KeychainSecretStore`, not `InMemorySecretStore`. Under XCTest
/// `NavidromeKeychain` routes itself to an in-memory dictionary, so the login Keychain
/// is never touched, and `simulatedReadFailure` is the supported way to make a read fail the
/// way a locked Keychain does. (`refusedAccounts`, which the card suggested, refuses *writes*;
/// a read of an absent in-memory account reports `missing`, which is a different state and the
/// one that is safe.)
@MainActor
final class WebhookSecretSurvivalTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    /// The status a locked login keychain actually reports.
    private static let locked: Int32 = -25293

    override func setUp() {
        super.setUp()
        suiteName = "WebhookSecretSurvival.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        NavidromeKeychain.inMemoryStore = [:]
    }

    override func tearDown() {
        NavidromeKeychain.simulatedReadFailure = nil
        NavidromeKeychain.inMemoryStore = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store() -> WebhookActionStore {
        WebhookActionStore(defaults: defaults, secrets: KeychainSecretStore(), send: { _ in 200 })
    }

    private func action(named name: String, headerValue: String) -> WebhookAction {
        var a = WebhookAction(name: name, urlTemplate: "https://hooks.example.com/x")
        a.headers = [.init(name: "Authorization", value: headerValue)]
        return a
    }

    private func secretKey(_ action: WebhookAction) -> String {
        "tonebox.webhook.header.\(action.headers[0].id.uuidString)"
    }

    /// The defect: `secret(for:)` returned nil, `?? ""` made the header empty, and the next
    /// `persist()` wrote the empty string back through a store that deletes on empty. Any edit
    /// to any action was enough to fire it.
    func testALockedKeychainDoesNotDestroyHeaderSecrets() {
        let a = action(named: "Notify", headerValue: "Bearer super-secret-token")
        store().upsert(a)
        let key = secretKey(a)
        XCTAssertEqual(NavidromeKeychain.secret(account: key), "Bearer super-secret-token")

        // The Keychain locks. A fresh store loads, cannot read, and the user renames an action.
        NavidromeKeychain.simulatedReadFailure = Self.locked
        let locked = store()
        XCTAssertEqual(locked.secretsUnreadable, Self.locked,
                       "the store must know the blank header values are ignorance, not emptiness")
        var renamed = locked.actions[0]
        renamed.name = "Notify (renamed)"
        locked.upsert(renamed)

        // The Keychain unlocks.
        NavidromeKeychain.simulatedReadFailure = nil
        XCTAssertEqual(NavidromeKeychain.secret(account: key), "Bearer super-secret-token",
                       "the secret was destroyed by an edit made while the Keychain was locked")
        XCTAssertNil(store().secretsUnreadable)
        XCTAssertEqual(store().actions.first?.headers.first?.value, "Bearer super-secret-token")
    }

    /// The other half: nothing is written at all while the store cannot read, so the rename
    /// above is not half-saved either. A list persisted with blanked headers over secrets that
    /// were never re-written is the same data loss by a longer route.
    func testNothingIsPersistedWhileTheKeychainIsUnreadable() {
        let a = action(named: "Notify", headerValue: "Bearer tok")
        store().upsert(a)

        NavidromeKeychain.simulatedReadFailure = Self.locked
        let locked = store()
        locked.upsert(action(named: "Second", headerValue: "Bearer other"))
        NavidromeKeychain.simulatedReadFailure = nil

        let reloaded = store()
        XCTAssertEqual(reloaded.actions.map(\.name), ["Notify"],
                       "an action added while the Keychain was locked was persisted anyway")
        XCTAssertEqual(reloaded.actions.first?.headers.first?.value, "Bearer tok")
    }

    /// M-F18. `delete(_:)` always cleaned up after itself; what leaked was a header removed
    /// from an action that stayed, because only `persist()` sees that.
    func testRemovingAHeaderDeletesItsStrandedSecret() {
        let a = action(named: "Notify", headerValue: "Bearer stranded")
        let s = store()
        s.upsert(a)
        let key = secretKey(a)
        XCTAssertNotNil(NavidromeKeychain.secret(account: key))

        var trimmed = a
        trimmed.headers = []
        s.upsert(trimmed)

        XCTAssertNil(NavidromeKeychain.secret(account: key),
                     "the removed header's Keychain item is unreachable from the app and stayed for ever")
    }

    /// Deleting the whole action still takes its secrets, now through the same diff rather
    /// than a second loop — one place that deletes Keychain items, downstream of the guard.
    func testDeletingAnActionStillRemovesItsHeaderSecret() {
        let a = action(named: "Notify", headerValue: "v")
        let s = store()
        s.upsert(a)
        let key = secretKey(a)
        XCTAssertNotNil(NavidromeKeychain.secret(account: key))
        s.delete(a)
        XCTAssertNil(NavidromeKeychain.secret(account: key))
    }

    /// And a delete attempted while the Keychain is locked takes nothing: the diff is the
    /// dangerous half of M-F18 and it has to sit behind the M-F6 guard, not beside it.
    func testALockedKeychainDeletesNothingOnDelete() {
        let a = action(named: "Notify", headerValue: "Bearer keep-me")
        store().upsert(a)
        let key = secretKey(a)

        NavidromeKeychain.simulatedReadFailure = Self.locked
        let locked = store()
        locked.delete(locked.actions[0])
        NavidromeKeychain.simulatedReadFailure = nil

        XCTAssertEqual(NavidromeKeychain.secret(account: key), "Bearer keep-me")
        XCTAssertEqual(store().actions.count, 1)
    }
}
