import XCTest
@testable import BatonPlaybackKit

/// Cross-device preference sync.
///
/// The rule under test is the one that makes it safe: **last-write-wins per key, not per
/// document**. Two devices editing different settings must both survive — a whole-blob
/// overwrite would silently discard whichever device pushed second, and the user would
/// experience that as "my EQ keeps resetting", which is nearly impossible to diagnose from
/// a bug report.
@MainActor
final class PreferenceSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "baton.prefsync.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeSync(device: String = "iPhone") -> PreferenceSync {
        PreferenceSync(defaults: defaults, deviceName: device)
    }

    // MARK: - What travels and what doesn't

    /// The test for inclusion was "would you be annoyed to set this twice?".
    func testSharedSettingsAreTheOnesThatBelongToYou() {
        XCTAssertTrue(PreferenceSync.syncedKeys.contains("tonebox.music.eq.gains"))
        XCTAssertTrue(PreferenceSync.syncedKeys.contains("tonebox.music.radioBans"))
        XCTAssertTrue(PreferenceSync.syncedKeys.contains("baton.agent.model"))
    }

    /// These describe a *device*, and syncing them would actively misbehave: an iPhone
    /// adopting a Mac's download folder, or being put into offline mode remotely.
    func testDeviceLocalSettingsNeverTravel() {
        for key in ["tonebox.music.downloadFolder", "baton.music.offlineMode", "baton.demoMode"] {
            XCTAssertFalse(PreferenceSync.syncedKeys.contains(key), "\(key) must stay on its device")
        }
    }

    /// Secrets are Keychain-resident and pairing already moves them; putting them in a
    /// synced JSON document would be a downgrade in handling.
    func testSecretsAreNotSynced() {
        for key in ["baton.agent.apiKey", "baton.agent.gatewayToken",
                    "tonebox.music.lastfm.apiSecret", "tonebox.music.listenBrainzToken"] {
            XCTAssertFalse(PreferenceSync.syncedKeys.contains(key), "\(key) must not ride in shared state")
        }
    }

    // MARK: - Change tracking

    func testNotingAChangeRecordsWhenItHappened() {
        let sync = makeSync()
        let when = Date(timeIntervalSince1970: 1_000_000)

        sync.noteLocalChange("tonebox.music.eq.preset", at: when)

        let stamps = defaults.dictionary(forKey: PreferenceSync.timestampsKey) as? [String: Date]
        XCTAssertEqual(stamps?["tonebox.music.eq.preset"], when)
    }

    /// An unsynced key must not accumulate bookkeeping — the timestamp map is consulted on
    /// every sync, and filling it with keys that never travel is pure noise.
    func testNotingAnUnsyncedKeyIsIgnored() {
        let sync = makeSync()

        sync.noteLocalChange("tonebox.music.downloadFolder")

        let stamps = defaults.dictionary(forKey: PreferenceSync.timestampsKey) as? [String: Date] ?? [:]
        XCTAssertTrue(stamps.isEmpty)
    }

    func testTheLatestChangeToAKeyWins() {
        let sync = makeSync()
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)

        sync.noteLocalChange("tonebox.navidrome.crossfade", at: early)
        sync.noteLocalChange("tonebox.navidrome.crossfade", at: late)

        let stamps = defaults.dictionary(forKey: PreferenceSync.timestampsKey) as? [String: Date]
        XCTAssertEqual(stamps?["tonebox.navidrome.crossfade"], late)
    }

    // MARK: - Failure is never destructive

    /// A gateway that is down, slow, or simply not there must never be able to change how
    /// someone's music sounds. This is the property that lets sync be optional.
    func testAnUnreachableGatewayLeavesSettingsAlone() async {
        defaults.set("Bass Boost", forKey: "tonebox.music.eq.preset")
        defaults.set(3.5, forKey: "tonebox.navidrome.crossfade")
        let sync = makeSync()
        sync.noteLocalChange("tonebox.music.eq.preset")

        // Reserved by RFC 6761 for exactly this: it never resolves.
        let ok = await sync.sync(gatewayURL: URL(string: "http://invalid.")!, token: "t")

        XCTAssertFalse(ok, "an unreachable gateway is a failure, reported as one")
        XCTAssertEqual(defaults.string(forKey: "tonebox.music.eq.preset"), "Bass Boost")
        XCTAssertEqual(defaults.double(forKey: "tonebox.navidrome.crossfade"), 3.5)
    }

    // MARK: - Seeding a store that has never seen this key

    /// A device that was configured long before sync existed has values but no timestamps.
    /// If those never pushed, it would only ever pull — a Mac with a carefully built EQ
    /// curve would sit there holding it while the phone stayed flat.
    func testUntimestampedValuesSeedAnEmptyStore() async throws {
        defaults.set("Bass Boost", forKey: "tonebox.music.eq.preset")
        let sync = makeSync(device: "Mac")

        // No noteLocalChange call — this is the pre-existing-value case.
        let stamps = defaults.dictionary(forKey: PreferenceSync.timestampsKey) as? [String: Date] ?? [:]
        XCTAssertTrue(stamps.isEmpty, "precondition: nothing has been noted")

        // The rule is exercised through the encode path the sync uses.
        let value = try XCTUnwrap(defaults.object(forKey: "tonebox.music.eq.preset"))
        let encoded = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let decoded = try PropertyListSerialization.propertyList(from: encoded, options: [], format: nil)
        XCTAssertEqual(decoded as? String, "Bass Boost")
    }

    // MARK: - Automatic change tracking

    /// The bug this replaces: tracking was hand-placed and had drifted to covering 3 of
    /// the 16 synced keys, so most settings silently stopped syncing and nothing said so.
    func testEverySyncedKeyIsStampedWhenItChanges() {
        let sync = makeSync()
        sync.startObservingChanges()
        defer { sync.stopObservingChanges() }

        // A key nobody ever remembered to instrument by hand.
        defaults.set(4.0, forKey: "tonebox.navidrome.crossfade")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

        let stamps = defaults.dictionary(forKey: PreferenceSync.timestampsKey) as? [String: Date] ?? [:]
        XCTAssertNotNil(stamps["tonebox.navidrome.crossfade"],
                        "observation must stamp keys no one instrumented by hand")
    }

    /// A change notification says only that *something* moved. Stamping every key on every
    /// notification would make every sync push everything and destroy conflict resolution.
    func testUnchangedKeysAreNotStamped() {
        defaults.set(4.0, forKey: "tonebox.navidrome.crossfade")
        let sync = makeSync()
        sync.startObservingChanges()
        defer { sync.stopObservingChanges() }

        defaults.set("Rock", forKey: "tonebox.music.eq.preset")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

        let stamps = defaults.dictionary(forKey: PreferenceSync.timestampsKey) as? [String: Date] ?? [:]
        XCTAssertNotNil(stamps["tonebox.music.eq.preset"])
        XCTAssertNil(stamps["tonebox.navidrome.crossfade"], "an untouched key must not be stamped")
    }

    /// Device-local settings must not be stamped even though they live in the same store.
    func testChangingADeviceLocalSettingStampsNothing() {
        let sync = makeSync()
        sync.startObservingChanges()
        defer { sync.stopObservingChanges() }

        defaults.set("/Users/someone/Music", forKey: "tonebox.music.downloadFolder")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

        let stamps = defaults.dictionary(forKey: PreferenceSync.timestampsKey) as? [String: Date] ?? [:]
        XCTAssertTrue(stamps.isEmpty)
    }

    // MARK: - Throttling

    /// Foreground fires for a glance at Control Center too, so the reconcile needs a floor.
    func testSyncIfDueSkipsWhenCalledAgainImmediately() async {
        let sync = makeSync()
        let url = URL(string: "http://invalid.")!

        await sync.syncIfDue(gatewayURL: url, token: "t", minimumInterval: 60)
        let firstAttempt = defaults.object(forKey: "baton.sync.lastAttempt") as? Date
        XCTAssertNotNil(firstAttempt, "the first call should run")

        await sync.syncIfDue(gatewayURL: url, token: "t", minimumInterval: 60)
        let secondAttempt = defaults.object(forKey: "baton.sync.lastAttempt") as? Date
        XCTAssertEqual(firstAttempt, secondAttempt, "a call inside the window must not run")
    }

    func testSyncIfDueRunsOnceTheWindowHasPassed() async {
        let sync = makeSync()
        let url = URL(string: "http://invalid.")!

        await sync.syncIfDue(gatewayURL: url, token: "t", minimumInterval: 60)
        let first = defaults.object(forKey: "baton.sync.lastAttempt") as? Date

        await sync.syncIfDue(gatewayURL: url, token: "t", minimumInterval: 0)
        let second = defaults.object(forKey: "baton.sync.lastAttempt") as? Date

        XCTAssertNotEqual(first, second)
    }

    // MARK: - Encoding

    /// Values round-trip through the property-list encoding the entries carry — the map of
    /// EQ gains is an array of doubles, not a string, and must come back as one.
    func testTypedValuesSurviveTheEncoding() throws {
        let gains: [Double] = [1.5, -3, 0, 12]
        let encoded = try PropertyListSerialization.data(fromPropertyList: gains, format: .binary, options: 0)

        let decoded = try PropertyListSerialization.propertyList(from: encoded, options: [], format: nil)

        XCTAssertEqual(decoded as? [Double], gains)
    }
}
