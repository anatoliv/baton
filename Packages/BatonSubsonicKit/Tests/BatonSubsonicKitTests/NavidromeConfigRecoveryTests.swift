import XCTest
@testable import BatonSubsonicKit
import BatonSubsonicModels

/// What survives a bad byte, and what a locked Keychain is allowed to say.
///
/// Every test here runs against its own `UserDefaults` suite and the Keychain's in-memory
/// store, so nothing touches the machine this runs on.
final class NavidromeConfigRecoveryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var realDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "io.tonebox.baton.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        realDefaults = NavidromeConfig.defaults
        NavidromeConfig.defaults = defaults
        NavidromeKeychain.inMemoryStore = [:]
        NavidromeKeychain.refusedAccounts = []
        NavidromeKeychain.simulatedReadFailure = nil
    }

    override func tearDown() {
        NavidromeConfig.defaults = realDefaults
        NavidromeKeychain.inMemoryStore = nil
        NavidromeKeychain.refusedAccounts = []
        NavidromeKeychain.simulatedReadFailure = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - S-F10: one bad byte used to delete every configured server

    /// The realistic trigger is a schema change: a new non-optional field, or an auth mode a
    /// downgrade does not know. The array decoded all or nothing, so one bad element dropped
    /// every server the person had.
    func testAnUnknownElementDoesNotTakeTheOtherServersWithIt() {
        let good = #"{"id":"\#(UUID().uuidString)","displayName":"Home","urlString":"https://a.example","username":"joe","authMode":"tokenSalt"}"#
        let futureShaped = #"{"id":"\#(UUID().uuidString)","displayName":"Later","urlString":"https://b.example","username":"joe","authMode":"someModeFromTheFuture"}"#
        defaults.set(Data("[\(good),\(futureShaped)]".utf8), forKey: NavidromeConfig.serversKey)

        let list = NavidromeConfig.servers()
        XCTAssertEqual(list.map(\.displayName), ["Home"],
                       "the entry that decoded should survive the one that did not")
    }

    /// A blob damaged at the JSON level cannot be decoded at all, so the only way its entries
    /// survive is for the next write to keep the bytes instead of overwriting them.
    func testATruncatedServerListIsKeptBeforeAnythingOverwritesIt() {
        let truncated = Data(#"[{"id":"3B1D0A2C-0000-4000-A000-000000000001","displayName":"Ho"#.utf8)
        defaults.set(truncated, forKey: NavidromeConfig.serversKey)

        NavidromeConfig.addServer(displayName: "New", urlString: "https://c.example",
                                  username: "joe", secret: "sesame", authMode: .tokenSalt)

        XCTAssertEqual(defaults.data(forKey: NavidromeConfig.unreadableServersKey), truncated,
                       "the unreadable bytes must still be recoverable after the overwrite")
        XCTAssertEqual(NavidromeConfig.servers().map(\.displayName), ["New"],
                       "and the write must still go through: refusing would leave the app unable to persist")
    }

    /// Preserved once, not on every write, or an ordinary later write would overwrite the
    /// preserved copy with a healthy list and lose it anyway.
    func testTheKeptCopyIsNotOverwrittenByALaterWrite() {
        let truncated = Data(#"[{"id":"3B1D0A2C"#.utf8)
        defaults.set(truncated, forKey: NavidromeConfig.serversKey)

        NavidromeConfig.addServer(displayName: "One", urlString: "https://c.example",
                                  username: "joe", secret: "s", authMode: .tokenSalt)
        NavidromeConfig.addServer(displayName: "Two", urlString: "https://d.example",
                                  username: "joe", secret: "s", authMode: .tokenSalt)

        XCTAssertEqual(defaults.data(forKey: NavidromeConfig.unreadableServersKey), truncated)
        XCTAssertEqual(NavidromeConfig.servers().count, 2)
    }

    // MARK: - S-F15: a locked Keychain is not "you never set one up"

    func testARefusedKeychainReadThrowsCredentialsUnreadable() throws {
        let entry = NavidromeConfig.addServer(displayName: "Home", urlString: "https://a.example",
                                              username: "joe", secret: "sesame", authMode: .tokenSalt)
        XCTAssertEqual(NavidromeConfig.activeServerID(), entry.id)
        XCTAssertNoThrow(try NavidromeConfig.makeClient(), "a healthy Keychain builds a client")

        NavidromeKeychain.simulatedReadFailure = -25308   // errSecInteractionNotAllowed
        do {
            _ = try NavidromeConfig.makeClient()
            XCTFail("expected .credentialsUnreadable")
        } catch let error as NavidromeError {
            guard case let .credentialsUnreadable(status) = error else {
                return XCTFail("a locked Keychain must not read as \(error)")
            }
            XCTAssertEqual(status, -25308)
        }
    }

    /// With no server on file at all, the honest answer is still "not configured".
    func testNoServerStillReadsAsNotConfigured() {
        do {
            _ = try NavidromeConfig.makeClient()
            XCTFail("expected .notConfigured")
        } catch let error as NavidromeError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTheTwoStatesReadDifferentlyToAPerson() {
        let unreadable = NavidromeError.credentialsUnreadable(status: -25308).errorDescription ?? ""
        let missing = NavidromeError.notConfigured.errorDescription ?? ""
        XCTAssertNotEqual(unreadable, missing)
        XCTAssertTrue(unreadable.lowercased().contains("keychain"),
                      "the message has to name the keychain, or retyping the password looks like the fix")
        XCTAssertFalse(missing.contains("Music."),
                       "the pane is Servers on the Mac and Server on the phone; there has never been a Music pane")
    }

    func testBothStatesCountAsAnAuthFailureRatherThanAnUnreachableServer() {
        XCTAssertTrue(NavidromeError.credentialsUnreadable(status: -25308).isAuthFailure)
        XCTAssertTrue(NavidromeError.notConfigured.isAuthFailure)
        XCTAssertTrue(NavidromeError.unauthorized.isAuthFailure)
        XCTAssertTrue(NavidromeError.subsonic(code: 40, message: "x").isAuthFailure)
        XCTAssertTrue(NavidromeError.http(status: 401).isAuthFailure)
        XCTAssertFalse(NavidromeError.transport("offline").isAuthFailure,
                       "a blip must not raise a credentials banner from a background prefetch")
        XCTAssertFalse(NavidromeError.http(status: 500).isAuthFailure)
    }

    // MARK: - S-F15: a refused write must not delete the last copy

    /// The same bug TBX-5268 fixed on the read path. On a device still holding a legacy
    /// plaintext value, a `SecItemAdd` refused under `errSecInteractionNotAllowed` used to
    /// remove the only surviving copy of the credential.
    func testARefusedWriteLeavesTheLegacyPlaintextCopyReadable() {
        let account = "tonebox.navidrome.secret.legacytest"
        BatonStorage.defaults.set("old-password", forKey: account)
        defer { BatonStorage.defaults.removeObject(forKey: account) }

        NavidromeKeychain.refusedAccounts = [account]
        let stored = NavidromeKeychain.setSecret("new-password", account: account)

        XCTAssertFalse(stored, "the write was refused")
        XCTAssertEqual(BatonStorage.defaults.string(forKey: account), "old-password",
                       "the only surviving copy of the credential must still be there")
    }

    func testASuccessfulWriteStillClearsTheLegacyPlaintextCopy() {
        let account = "tonebox.navidrome.secret.legacytest2"
        BatonStorage.defaults.set("old-password", forKey: account)
        defer { BatonStorage.defaults.removeObject(forKey: account) }

        XCTAssertTrue(NavidromeKeychain.setSecret("new-password", account: account))
        XCTAssertNil(BatonStorage.defaults.string(forKey: account),
                     "once the Keychain holds it, the plaintext copy should go")
    }
}
