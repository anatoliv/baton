import XCTest
import BatonSubsonicKit
@testable import Baton

/// The connect sheet opens filled in with the active server, so reconnecting (a changed
/// password, an expired API key) is "type the secret, press Connect". That appended a second
/// entry for the same server every time, each with its own Keychain secret, and Settings listed
/// the server twice. The same server, account and sign-in now update the
/// entry they already have.
///
/// Hermetic, as `MultiServerTests` is: a throwaway defaults suite and the in-memory Keychain.
final class ConnectSheetSaveTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var savedDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = ThrowawayDefaults.name("ConnectSheetSaveTests")
        defaults = UserDefaults(suiteName: suiteName)
        savedDefaults = NavidromeConfig.defaults
        NavidromeConfig.defaults = defaults
        NavidromeKeychain.inMemoryStore = [:]
    }

    override func tearDown() {
        NavidromeConfig.defaults = savedDefaults
        NavidromeKeychain.inMemoryStore = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testReconnectingTheSameServerUpdatesItsEntryRatherThanAddingAnother() {
        let first = NavidromeConfig.addServer(displayName: "Home", urlString: "https://music.example.com",
                                              username: "joe", secret: "old", authMode: .tokenSalt)

        let again = BatonConnectSheet.saveConnection(urlString: "https://music.example.com/", username: "joe",
                                                     secret: "new", authMode: .tokenSalt)

        XCTAssertEqual(NavidromeConfig.servers().count, 1, "reconnecting added a duplicate server")
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(NavidromeConfig.servers().first?.displayName, "Home", "the name the user gave it is kept")
        XCTAssertEqual(NavidromeConfig.secret, "new", "the new secret is the one used")
    }

    func testADifferentAccountOrServerIsStillAdded() {
        NavidromeConfig.addServer(displayName: "Home", urlString: "https://music.example.com",
                                  username: "joe", secret: "s", authMode: .tokenSalt)

        BatonConnectSheet.saveConnection(urlString: "https://music.example.com", username: "ann",
                                         secret: "s", authMode: .tokenSalt)
        BatonConnectSheet.saveConnection(urlString: "https://other.example.com", username: "joe",
                                         secret: "s", authMode: .tokenSalt)

        XCTAssertEqual(NavidromeConfig.servers().count, 3)
    }

    private func secret(of entry: NavidromeServerEntry) -> String? {
        NavidromeKeychain.secret(account: NavidromeConfig.keychainAccount(for: entry.id))
    }

    /// Someone the old bug already gave two copies of a server reconnects: the active copy is the
    /// one updated. Updating the other made `selectServer` see a server change and clear the queue,
    /// and left the active copy on its old secret.
    func testWithDuplicatesAlreadySavedTheActiveCopyIsTheOneUpdated() {
        let older = NavidromeConfig.addServer(displayName: "Home", urlString: "https://music.example.com",
                                              username: "joe", secret: "old", authMode: .tokenSalt)
        let active = NavidromeConfig.addServer(displayName: "Home", urlString: "https://music.example.com",
                                               username: "joe", secret: "old", authMode: .tokenSalt)
        NavidromeConfig.setActiveServer(id: active.id)

        let saved = BatonConnectSheet.saveConnection(urlString: "https://music.example.com", username: "joe",
                                                     secret: "new", authMode: .tokenSalt)

        XCTAssertEqual(saved.id, active.id, "the older copy was updated instead of the active one")
        XCTAssertEqual(secret(of: active), "new")
        XCTAssertEqual(secret(of: older), "old")
        XCTAssertEqual(NavidromeConfig.servers().count, 2)
    }

    /// API-key sign-in needs no username, so two accounts on one server can both have a blank one.
    /// A blank username identifies nobody: connecting the second account must not overwrite the
    /// first one's key.
    func testAPIKeyAccountsWithNoUsernameAreNeverMerged() {
        let first = NavidromeConfig.addServer(displayName: "Mine", urlString: "https://music.example.com",
                                              username: "", secret: "key-one", authMode: .apiKey)

        let second = BatonConnectSheet.saveConnection(urlString: "https://music.example.com", username: " ",
                                                      secret: "key-two", authMode: .apiKey)

        XCTAssertNotEqual(second.id, first.id, "a second API-key account overwrote the first")
        XCTAssertEqual(secret(of: first), "key-one")
        XCTAssertEqual(NavidromeConfig.servers().count, 2)
    }
}
