import XCTest
@testable import BatonPlaybackKit

/// The migration must be safe, idempotent, and must not touch what it must not touch.
final class LegacyKeyMigrationTests: XCTestCase {
    private func store() -> UserDefaults {
        UserDefaults(suiteName: "legacy.migration.\(UUID().uuidString)")!
    }

    func testAnOldValueIsCopiedToItsNewKey() {
        let defaults = store()
        defaults.set(true, forKey: "tonebox.music.railCollapsed")
        LegacyKeyMigration.run(defaults)
        XCTAssertEqual(defaults.bool(forKey: "baton.music.railCollapsed"), true)
    }

    /// A user who turns a migrated setting back off must not find it back on next launch.
    func testItRunsOnceAndDoesNotResurrectAChangedValue() {
        let defaults = store()
        defaults.set(true, forKey: "tonebox.music.railCollapsed")
        LegacyKeyMigration.run(defaults)
        defaults.set(false, forKey: "baton.music.railCollapsed")
        LegacyKeyMigration.run(defaults)
        XCTAssertEqual(defaults.bool(forKey: "baton.music.railCollapsed"), false,
                       "the migration overwrote a value the user had changed since")
    }

    /// Rolling back to a previous build should find its settings where it left them.
    func testTheOldKeyIsLeftInPlace() {
        let defaults = store()
        defaults.set(true, forKey: "tonebox.music.railCollapsed")
        LegacyKeyMigration.run(defaults)
        XCTAssertNotNil(defaults.object(forKey: "tonebox.music.railCollapsed"))
    }

    /// The guard rail. Renaming a synced key breaks sync between an updated device and one
    /// that has not updated yet — silently, and in a way neither end can report.
    @MainActor
    func testNoSyncedKeyIsMigrated() {
        let synced = PreferenceSync.syncedKeys
        for old in LegacyKeyMigration.inertKeys.keys {
            XCTAssertFalse(synced.contains(old),
                           "\(old) is synced between devices and must not be renamed unilaterally")
        }
    }

    /// Credentials, server config and user data are explicitly out of scope: a missed key
    /// there is not a reset preference, it is something the user cannot get back.
    func testNoCredentialOrDataKeyIsMigrated() {
        let forbidden = [
            "tonebox.navidromeSecret", "tonebox.navidrome.servers", "tonebox.navidrome.url",
            "tonebox.navidrome.username", "tonebox.music.lastfm.sessionKey",
            "tonebox.music.listenBrainzToken", "tonebox.music.playHistory",
            "tonebox.music.scrobbleQueue",
        ]
        for key in forbidden {
            XCTAssertNil(LegacyKeyMigration.inertKeys[key],
                         "\(key) carries data a user cannot recreate — not part of a cosmetic rename")
        }
    }
}
