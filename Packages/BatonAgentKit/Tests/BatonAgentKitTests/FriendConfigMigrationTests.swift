import XCTest
import BatonSubsonicKit
@testable import BatonAgentKit

/// The Mac's music-friend settings moving onto the key names it shares with the iPhone.
///
/// Worth pinning because the failure this fixes was silent in both directions: the Mac wrote
/// `baton.remote.nl.*`, the sync contract carried `baton.agent.*`, and neither end had any way
/// to notice. A migration that half-works would be the same kind of quiet — a provider that
/// arrives while the model doesn't looks like a sync bug rather than a migration bug.
@MainActor
final class FriendConfigMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var secrets: InMemorySecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "baton.friendconfig.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = InMemorySecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        secrets = nil
        super.tearDown()
    }

    private func seedLegacyMac() {
        defaults.set("openAICompatible", forKey: RemoteControlSettings.migrationLegacyProviderKey)
        defaults.set("llama-3.3-70b", forKey: RemoteControlSettings.migrationLegacyModelKey)
        defaults.set("http://192.0.2.10:8000/v1", forKey: RemoteControlSettings.migrationLegacyBaseURLKey)
        secrets.setSecret("sk-legacy", for: RemoteControlSettings.migrationLegacyAPIKeyAccount)
    }

    /// The whole point: a Mac configured before the two apps agreed keeps its setup.
    func testAConfiguredMacKeepsItsFriendSetup() {
        seedLegacyMac()

        FriendConfigMigration.run(defaults: defaults, secrets: secrets)

        XCTAssertEqual(defaults.string(forKey: RemoteControlSettings.migrationProviderKey), "openAICompatible")
        XCTAssertEqual(defaults.string(forKey: RemoteControlSettings.migrationModelKey), "llama-3.3-70b")
        XCTAssertEqual(defaults.string(forKey: RemoteControlSettings.migrationBaseURLKey), "http://192.0.2.10:8000/v1")
        XCTAssertEqual(secrets.secret(for: RemoteControlSettings.migrationAPIKeyAccount), "sk-legacy")
    }

    /// And reading it back through the real type is what a user actually experiences.
    func testTheSettingsTypeReadsTheMigratedValues() {
        seedLegacyMac()

        let settings = RemoteControlSettings(defaults: defaults, secrets: secrets)

        XCTAssertEqual(settings.naturalLanguage.provider, .openAICompatible)
        XCTAssertEqual(settings.naturalLanguage.model, "llama-3.3-70b")
        XCTAssertEqual(settings.naturalLanguage.baseURL, "http://192.0.2.10:8000/v1")
        XCTAssertEqual(settings.naturalLanguage.apiKey, "sk-legacy")
    }

    /// Copies, never moves — a rollback to a previous build must find its settings.
    func testTheOldKeysAreLeftInPlace() {
        seedLegacyMac()

        FriendConfigMigration.run(defaults: defaults, secrets: secrets)

        XCTAssertEqual(defaults.string(forKey: RemoteControlSettings.migrationLegacyProviderKey), "openAICompatible")
        XCTAssertEqual(secrets.secret(for: RemoteControlSettings.migrationLegacyAPIKeyAccount), "sk-legacy")
    }

    /// A value already under the shared name came from the phone, from a pairing transfer, or
    /// from an earlier run. All three are newer than whatever the legacy key still holds.
    func testItNeverOverwritesAValueThatIsAlreadyThere() {
        seedLegacyMac()
        defaults.set("anthropic", forKey: RemoteControlSettings.migrationProviderKey)
        secrets.setSecret("sk-from-the-phone", for: RemoteControlSettings.migrationAPIKeyAccount)

        FriendConfigMigration.run(defaults: defaults, secrets: secrets)

        XCTAssertEqual(defaults.string(forKey: RemoteControlSettings.migrationProviderKey), "anthropic")
        XCTAssertEqual(secrets.secret(for: RemoteControlSettings.migrationAPIKeyAccount), "sk-from-the-phone")
        // The ones that weren't already set still come across.
        XCTAssertEqual(defaults.string(forKey: RemoteControlSettings.migrationModelKey), "llama-3.3-70b")
    }

    /// Deliberately clearing a setting must not have the old value copied back on next launch.
    func testItDoesNotRunTwice() {
        seedLegacyMac()
        FriendConfigMigration.run(defaults: defaults, secrets: secrets)

        defaults.removeObject(forKey: RemoteControlSettings.migrationModelKey)
        FriendConfigMigration.run(defaults: defaults, secrets: secrets)

        XCTAssertNil(defaults.string(forKey: RemoteControlSettings.migrationModelKey),
                     "a cleared setting was resurrected by a second migration pass")
    }

    /// A fresh install has nothing to migrate and must not invent defaults.
    func testAFreshInstallIsUntouched() {
        FriendConfigMigration.run(defaults: defaults, secrets: secrets)

        XCTAssertNil(defaults.string(forKey: RemoteControlSettings.migrationProviderKey))
        XCTAssertNil(secrets.secret(for: RemoteControlSettings.migrationAPIKeyAccount))
        XCTAssertTrue(defaults.bool(forKey: FriendConfigMigration.completedKey))
    }

    /// An empty legacy secret is not a secret. Copying "" would leave the new account looking
    /// configured while holding nothing.
    func testAnEmptyLegacyKeyIsNotCopied() {
        secrets.setSecret("", for: RemoteControlSettings.migrationLegacyAPIKeyAccount)

        FriendConfigMigration.run(defaults: defaults, secrets: secrets)

        XCTAssertTrue((secrets.secret(for: RemoteControlSettings.migrationAPIKeyAccount) ?? "").isEmpty)
    }

    /// The names themselves are the contract with the phone. If one drifts, sync stops without
    /// anything failing to build — which is exactly how this went unnoticed the first time.
    func testTheSharedKeyNamesAreTheOnesThePhoneUses() {
        XCTAssertEqual(RemoteControlSettings.migrationProviderKey, "baton.agent.provider")
        XCTAssertEqual(RemoteControlSettings.migrationModelKey, "baton.agent.model")
        XCTAssertEqual(RemoteControlSettings.migrationBaseURLKey, "baton.agent.baseURL")
        XCTAssertEqual(RemoteControlSettings.migrationAPIKeyAccount, "baton.agent.apiKey")
    }
}
