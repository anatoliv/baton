import XCTest
@testable import Baton

/// Multi-server support for `NavidromeConfig`: add/remove/switch, legacy migration,
/// and that the historical single-server accessors (`credentials`, `isConfigured`,
/// `secret`, `serverURLString`, `username`, `authMode`) reflect the ACTIVE server.
///
/// Fully hermetic: a temp `UserDefaults` suite (never `.standard`) plus the
/// in-memory Keychain backing, so nothing touches the user's real config or the
/// login Keychain. Both are installed in `setUp` and torn down after each test.
final class MultiServerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var savedDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MultiServerTests.\(UUID().uuidString)"
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

    // MARK: - Empty state

    func testEmptyStateHasNoServersOrActive() {
        XCTAssertTrue(NavidromeConfig.servers().isEmpty)
        XCTAssertNil(NavidromeConfig.activeServerID())
        XCTAssertNil(NavidromeConfig.activeServer())
        XCTAssertFalse(NavidromeConfig.isConfigured)
        XCTAssertNil(NavidromeConfig.credentials())
        XCTAssertEqual(NavidromeConfig.serverURLString, "")
        XCTAssertEqual(NavidromeConfig.username, "")
        XCTAssertEqual(NavidromeConfig.secret, "")
    }

    // MARK: - Add / active

    func testAddServerBecomesActiveAndStoresSecret() {
        let entry = NavidromeConfig.addServer(
            displayName: "Home",
            urlString: "https://home.example.com",
            username: "joe",
            secret: "sesame",
            authMode: .tokenSalt
        )
        XCTAssertEqual(NavidromeConfig.servers().map(\.id), [entry.id])
        XCTAssertEqual(NavidromeConfig.activeServerID(), entry.id)
        XCTAssertEqual(NavidromeConfig.serverURLString, "https://home.example.com")
        XCTAssertEqual(NavidromeConfig.username, "joe")
        XCTAssertEqual(NavidromeConfig.authMode, .tokenSalt)
        XCTAssertEqual(NavidromeConfig.secret, "sesame")
        XCTAssertTrue(NavidromeConfig.isConfigured)
        let creds = NavidromeConfig.credentials()
        XCTAssertEqual(creds?.baseURL, URL(string: "https://home.example.com"))
        XCTAssertEqual(creds?.username, "joe")
        XCTAssertEqual(creds?.secret, "sesame")
    }

    func testSecondServerDoesNotStealActive() {
        let first = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        let second = NavidromeConfig.addServer(
            displayName: "B", urlString: "https://b.example.com", username: "b", secret: "pb", authMode: .tokenSalt)
        XCTAssertEqual(NavidromeConfig.servers().count, 2)
        // First one stays active; the second is added but not auto-activated.
        XCTAssertEqual(NavidromeConfig.activeServerID(), first.id)
        XCTAssertNotEqual(NavidromeConfig.activeServerID(), second.id)
    }

    // MARK: - Switch active reflects everything

    func testSwitchActiveChangesCredentialsAndSecret() {
        _ = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "alice", secret: "pa", authMode: .tokenSalt)
        let second = NavidromeConfig.addServer(
            displayName: "B", urlString: "https://b.example.com", username: "", secret: "KEY-B", authMode: .apiKey)

        NavidromeConfig.setActiveServer(id: second.id)
        XCTAssertEqual(NavidromeConfig.activeServerID(), second.id)
        XCTAssertEqual(NavidromeConfig.serverURLString, "https://b.example.com")
        XCTAssertEqual(NavidromeConfig.username, "")
        XCTAssertEqual(NavidromeConfig.authMode, .apiKey)
        XCTAssertEqual(NavidromeConfig.secret, "KEY-B")
        // apiKey mode is configured without a username.
        XCTAssertTrue(NavidromeConfig.isConfigured)
        XCTAssertEqual(NavidromeConfig.credentials()?.authMode, .apiKey)
        XCTAssertEqual(NavidromeConfig.credentials()?.secret, "KEY-B")
    }

    func testSetActiveIgnoresUnknownID() {
        let a = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        NavidromeConfig.setActiveServer(id: UUID())
        XCTAssertEqual(NavidromeConfig.activeServerID(), a.id) // unchanged
    }

    // MARK: - Remove

    func testRemoveActiveFallsBackToRemaining() {
        let a = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        let b = NavidromeConfig.addServer(
            displayName: "B", urlString: "https://b.example.com", username: "b", secret: "pb", authMode: .tokenSalt)
        XCTAssertEqual(NavidromeConfig.activeServerID(), a.id)

        NavidromeConfig.removeServer(id: a.id)
        XCTAssertEqual(NavidromeConfig.servers().map(\.id), [b.id])
        XCTAssertEqual(NavidromeConfig.activeServerID(), b.id) // fell back
        XCTAssertEqual(NavidromeConfig.secret, "pb")
        // Removed server's secret is gone from the Keychain.
        XCTAssertNil(NavidromeKeychain.secret(account: NavidromeConfig.keychainAccount(for: a.id)))
    }

    func testRemoveLastServerClearsActive() {
        let a = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        NavidromeConfig.removeServer(id: a.id)
        XCTAssertTrue(NavidromeConfig.servers().isEmpty)
        XCTAssertNil(NavidromeConfig.activeServerID())
        XCTAssertFalse(NavidromeConfig.isConfigured)
    }

    func testRemoveNonActiveKeepsActive() {
        let a = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        let b = NavidromeConfig.addServer(
            displayName: "B", urlString: "https://b.example.com", username: "b", secret: "pb", authMode: .tokenSalt)
        NavidromeConfig.removeServer(id: b.id)
        XCTAssertEqual(NavidromeConfig.servers().map(\.id), [a.id])
        XCTAssertEqual(NavidromeConfig.activeServerID(), a.id)
    }

    // MARK: - Update

    func testUpdateServerChangesMetadataAndSecret() {
        let a = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        NavidromeConfig.updateServer(
            id: a.id, displayName: "Renamed", urlString: "https://new.example.com",
            username: "newuser", authMode: .tokenSalt, secret: "newpass")
        let entry = NavidromeConfig.servers().first { $0.id == a.id }
        XCTAssertEqual(entry?.displayName, "Renamed")
        XCTAssertEqual(entry?.urlString, "https://new.example.com")
        XCTAssertEqual(entry?.username, "newuser")
        XCTAssertEqual(NavidromeConfig.secret, "newpass")
    }

    func testUpdateServerNilSecretKeepsExisting() {
        let a = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        NavidromeConfig.updateServer(
            id: a.id, displayName: "A2", urlString: "https://a.example.com",
            username: "a", authMode: .tokenSalt, secret: nil)
        XCTAssertEqual(NavidromeConfig.secret, "pa") // unchanged
    }

    // MARK: - Legacy migration

    func testLegacyConfigMigratesIntoList() {
        // Seed a legacy single-server config directly: metadata in the temp suite,
        // secret under the historical Keychain account.
        defaults.set("https://legacy.example.com", forKey: NavidromeConfig.urlKey)
        defaults.set("legacyuser", forKey: NavidromeConfig.usernameKey)
        defaults.set(NavidromeAuthMode.tokenSalt.rawValue, forKey: NavidromeConfig.authModeKey)
        NavidromeKeychain.setSecret("legacysecret", account: NavidromeConfig.secretKey)

        // First access triggers migration.
        let servers = NavidromeConfig.servers()
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.urlString, "https://legacy.example.com")
        XCTAssertEqual(servers.first?.username, "legacyuser")
        XCTAssertEqual(NavidromeConfig.activeServerID(), servers.first?.id)

        // Active accessors reflect the migrated server, secret reused (no re-entry).
        XCTAssertEqual(NavidromeConfig.serverURLString, "https://legacy.example.com")
        XCTAssertEqual(NavidromeConfig.username, "legacyuser")
        XCTAssertEqual(NavidromeConfig.secret, "legacysecret")
        XCTAssertTrue(NavidromeConfig.isConfigured)

        // Legacy metadata keys are cleaned up after migration.
        XCTAssertNil(defaults.string(forKey: NavidromeConfig.urlKey))
        XCTAssertNil(defaults.string(forKey: NavidromeConfig.usernameKey))
    }

    func testMigrationIsIdempotentAndPreservesActiveChoice() {
        _ = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        let b = NavidromeConfig.addServer(
            displayName: "B", urlString: "https://b.example.com", username: "b", secret: "pb", authMode: .tokenSalt)
        NavidromeConfig.setActiveServer(id: b.id)
        // Re-reading must not re-run migration or reset the active choice.
        XCTAssertEqual(NavidromeConfig.servers().count, 2)
        XCTAssertEqual(NavidromeConfig.activeServerID(), b.id)
    }

    func testNoLegacyConfigYieldsEmptyList() {
        // No seeded legacy keys → migration writes an empty list, not a ghost server.
        XCTAssertTrue(NavidromeConfig.servers().isEmpty)
        XCTAssertNil(NavidromeConfig.activeServer())
    }

    // MARK: - save()/clear() single-slot compatibility

    func testSaveWithNoActiveAddsServer() {
        NavidromeConfig.save(
            urlString: "https://s.example.com", username: "u", secret: "p", authMode: .tokenSalt)
        XCTAssertEqual(NavidromeConfig.servers().count, 1)
        XCTAssertTrue(NavidromeConfig.isConfigured)
        XCTAssertEqual(NavidromeConfig.secret, "p")
    }

    func testSaveWithActiveUpdatesInPlace() {
        let a = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        NavidromeConfig.save(
            urlString: "https://a2.example.com", username: "a2", secret: "pa2", authMode: .tokenSalt)
        XCTAssertEqual(NavidromeConfig.servers().count, 1) // updated, not appended
        XCTAssertEqual(NavidromeConfig.activeServerID(), a.id)
        XCTAssertEqual(NavidromeConfig.serverURLString, "https://a2.example.com")
        XCTAssertEqual(NavidromeConfig.secret, "pa2")
    }

    func testClearRemovesActiveServer() {
        _ = NavidromeConfig.addServer(
            displayName: "A", urlString: "https://a.example.com", username: "a", secret: "pa", authMode: .tokenSalt)
        NavidromeConfig.clear()
        XCTAssertTrue(NavidromeConfig.servers().isEmpty)
        XCTAssertFalse(NavidromeConfig.isConfigured)
    }
}
