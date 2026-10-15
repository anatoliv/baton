import BatonSubsonicKit
import XCTest
@testable import BatonPlaybackKit

/// Pulling a setting is not editing it, and a fresh device has no deletions to report.
///
/// Both halves came from one afternoon: a simulator phone that had never synced before took part
/// in the owner's shared settings. It adopted every value the Mac had published, and the change
/// observer, which stamps whatever differs from its last snapshot, stamped each adopted key as the
/// phone's own edit; the next sync pushed the whole document back under the phone's name with
/// fresh timestamps. The same phone had written and removed a handful of keys at startup, which
/// left stamps with no values behind them, and those travelled as tombstones that cleared the
/// owner's agent settings on the Mac.
///
/// Same `FakeGateway` as the deletion tests: the real `/v1/state` contract, counting writes.
@MainActor
final class PreferenceSyncAdoptionTests: XCTestCase {
    private let key = "tonebox.music.eq.preset"
    private let gatewayURL = URL(string: "http://gateway.test")!

    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        FakeGateway.reset()
    }

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        FakeGateway.reset()
        super.tearDown()
    }

    private func device(_ name: String) -> (sync: PreferenceSync, defaults: UserDefaults) {
        let suite = ThrowawayDefaults.name("baton.prefsync.adoption.\(name)")
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGateway.self]
        let sync = PreferenceSync(defaults: defaults, deviceName: name,
                                  session: URLSession(configuration: configuration))
        return (sync, defaults)
    }

    private func syncs(_ device: (sync: PreferenceSync, defaults: UserDefaults),
                       file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await device.sync.sync(gatewayURL: gatewayURL, token: "t")
        XCTAssertTrue(ok, "the sync failed", file: file, line: line)
    }

    private func stamps(_ defaults: UserDefaults) -> [String: Date] {
        defaults.dictionary(forKey: PreferenceSync.timestampsKey) as? [String: Date] ?? [:]
    }

    /// A Mac with a few published settings, which is what the fresh phone below finds.
    private func publishedMac() async -> (sync: PreferenceSync, defaults: UserDefaults) {
        let mac = device("Mac")
        mac.defaults.set("Electronic", forKey: key)
        mac.defaults.set(true, forKey: "tonebox.music.eq.enabled")
        mac.defaults.set(15, forKey: "tonebox.filterHistorySize")
        for k in [key, "tonebox.music.eq.enabled", "tonebox.filterHistorySize"] {
            mac.sync.noteLocalChange(k, at: Date(timeIntervalSinceNow: -120))
        }
        await syncs(mac)
        return mac
    }

    // MARK: - Adopting is not editing

    /// The observer is live on the phone, as it is in the app, and the phone pulls the Mac's
    /// settings. Nothing about that is the phone's edit: no stamp, no push, and the document still
    /// says the Mac wrote every entry.
    func testAFreshDeviceThatAdoptsEverythingPublishesNothing() async throws {
        _ = await publishedMac()
        let writesByMac = FakeGateway.puts.count

        let phone = device("iPhone")
        phone.sync.startObservingChanges()
        defer { phone.sync.stopObservingChanges() }

        await syncs(phone)
        XCTAssertEqual(phone.defaults.string(forKey: key), "Electronic", "precondition: adopted")
        // Let the change notification, if it is delivered later, reach the observer.
        try await Task.sleep(nanoseconds: 50_000_000)
        await syncs(phone)

        XCTAssertTrue(stamps(phone.defaults).isEmpty, """
            Adopted keys were stamped as the phone's own edits: \(stamps(phone.defaults).keys.sorted())
            """)
        XCTAssertEqual(FakeGateway.puts.count, writesByMac,
                       "the phone pushed a document it had only read")
        let document = try FakeGateway.decodedDocument()
        XCTAssertEqual(document[key]?.device, "Mac", "the entry changed hands without an edit")
    }

    /// The device keeps its right to edit: a change it makes *after* adopting is stamped and
    /// travels, which is the half that must not be lost to the fix.
    func testAnEditMadeAfterAdoptingStillTravels() async throws {
        _ = await publishedMac()
        let phone = device("iPhone")
        phone.sync.startObservingChanges()
        defer { phone.sync.stopObservingChanges() }
        await syncs(phone)

        phone.defaults.set("Rock", forKey: key)
        phone.sync.noteLocalChange(key)
        await syncs(phone)

        let document = try FakeGateway.decodedDocument()
        XCTAssertEqual(document[key]?.device, "iPhone")
        let value = try XCTUnwrap(document[key]).value
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: value, options: [], format: nil) as? String,
                       "Rock")
    }

    // MARK: - A fresh device has no deletions to report

    /// Written and removed before the first sync, which is what a fresh install's startup does to a
    /// few keys. The stamp is there and the value is not; it must not become a tombstone that
    /// clears the Mac's setting.
    func testAKeyClearedBeforeTheFirstSyncIsNotAnnouncedAsDeleted() async throws {
        _ = await publishedMac()

        let phone = device("iPhone")
        phone.defaults.set("Flat", forKey: key)
        phone.sync.noteLocalChange(key)
        phone.defaults.removeObject(forKey: key)
        phone.sync.noteLocalChange(key)

        await syncs(phone)

        let entry = try XCTUnwrap(try FakeGateway.decodedDocument()[key])
        XCTAssertFalse(entry.isTombstone, "a key the phone never synced was announced as deleted")
        XCTAssertEqual(entry.device, "Mac")
    }

    /// The deletion the previous test refuses is still delivered once the device has synced the
    /// key: held at the last sync, then cleared, is a real clear.
    func testAKeyClearedAfterItWasSyncedIsAnnouncedAsDeleted() async throws {
        _ = await publishedMac()
        let phone = device("iPhone")
        await syncs(phone)
        XCTAssertEqual(phone.defaults.string(forKey: key), "Electronic", "precondition: adopted")

        phone.defaults.removeObject(forKey: key)
        phone.sync.noteLocalChange(key)
        await syncs(phone)

        let entry = try XCTUnwrap(try FakeGateway.decodedDocument()[key])
        XCTAssertTrue(entry.isTombstone, "a clear made after the key was synced did not travel")
        XCTAssertEqual(entry.device, "iPhone")
    }
}
