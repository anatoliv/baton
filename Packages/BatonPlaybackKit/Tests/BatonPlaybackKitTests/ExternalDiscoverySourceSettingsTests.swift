import BatonSubsonicKit
import XCTest
@testable import BatonPlaybackKit

/// Which sources get asked, and what the sheet says about the ones that don't.
///
/// The bug behind this: a source was "on" if and only if a key was present, so the phone —
/// which had no field to type a key into — showed two sources permanently off with no way to
/// change that, and there was no way at all to keep a key and switch its source off.
final class ExternalDiscoverySourceSettingsTests: XCTestCase {

    private let keys = ExternalDiscovery.Source.allCases.map { ExternalDiscovery.enabledKey(for: $0) }
        + [ExternalDiscovery.lastFMKeyKey, ExternalDiscovery.youTubeKeyKey,
           ExternalDiscovery.enabledKey]

    override func setUp() {
        super.setUp()
        // The API keys are Keychain-backed now, and reading one *migrates* any legacy
        // defaults value into the store. Without this stand-in these tests would write into
        // the developer's real login keychain — and did, once, leaking "a-key" into a
        // neighbouring test that had every right to expect an empty store.
        NavidromeKeychain.inMemoryStore = [:]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        NavidromeKeychain.inMemoryStore = nil
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    /// Existing installs must not change behaviour: nothing was ever switched off, so every
    /// source stays on until someone says otherwise.
    func testEverySourceIsOnUntilTurnedOff() {
        for source in ExternalDiscovery.Source.allCases {
            XCTAssertTrue(ExternalDiscovery.isEnabled(source), "\(source.label) defaulted to off")
        }
    }

    func testTurningASourceOffIsRememberedAndReported() {
        ExternalDiscovery.setEnabled(false, for: .listenBrainz)

        XCTAssertFalse(ExternalDiscovery.isEnabled(.listenBrainz))
        XCTAssertEqual(ExternalDiscovery.availability(of: .listenBrainz), .turnedOff)
        // The distinction that did not exist before: this is not a missing key.
        let status = ExternalDiscovery.sourceStatus().first { $0.source == .listenBrainz }
        XCTAssertEqual(status?.availability, .turnedOff)
        XCTAssertTrue(status?.detail.contains("switched this source off") == true,
                      "a deliberately disabled source must not be described as needing a key")
    }

    /// The two states the old single flag could not tell apart, now told apart.
    func testAKeylessSourceAndAKeyedOneReportDifferentReasonsForBeingOff() {
        XCTAssertEqual(ExternalDiscovery.availability(of: .lastFM), .needsKey)
        UserDefaults.standard.set("a-key", forKey: ExternalDiscovery.lastFMKeyKey)
        XCTAssertEqual(ExternalDiscovery.availability(of: .lastFM), .ready)

        // With a key *and* switched off, the reason is the switch — the case that used to be
        // unsayable, and the one where "add an API key" would be a lie.
        ExternalDiscovery.setEnabled(false, for: .lastFM)
        XCTAssertEqual(ExternalDiscovery.availability(of: .lastFM), .turnedOff)
        XCTAssertTrue(ExternalDiscovery.detail(for: .lastFM, availability: .turnedOff)
            .contains("switched this source off"))
    }

    /// A keyed source that is configured and switched on reads as ready, and a keyless one
    /// says so rather than pretending it has credentials.
    func testDetailStringsSayWhichKindOfSourceItIs() {
        XCTAssertEqual(ExternalDiscovery.detail(for: .musicBrainz, availability: .ready),
                       "No account needed.")
        UserDefaults.standard.set("a-key", forKey: ExternalDiscovery.youTubeKeyKey)
        XCTAssertEqual(ExternalDiscovery.detail(for: .youTube, availability: .ready), "Ready.")
    }

    /// A test result carries what to *do*, not just pass/fail — the whole reason it exists.
    func testATestResultDistinguishesAWrongKeyFromAServiceBeingDown() {
        XCTAssertTrue(ExternalDiscovery.TestResult.ready("fine").isReady)
        XCTAssertFalse(ExternalDiscovery.TestResult.keyRejected("bad key").isReady)
        XCTAssertFalse(ExternalDiscovery.TestResult.unreachable("down").isReady)
        XCTAssertEqual(ExternalDiscovery.TestResult.rateLimited("slow down").message, "slow down")
    }

    /// The master switch still outranks everything: with it off, no source is consulted no
    /// matter how it is configured.
    func testTheMasterSwitchStillDecidesWhetherAnythingLeavesTheMachine() async {
        UserDefaults.standard.set(false, forKey: ExternalDiscovery.enabledKey)
        do {
            _ = try await ExternalDiscovery.similar(toTitle: "t", artist: "a")
            XCTFail("the lookup ran with the master switch off")
        } catch {
            XCTAssertEqual(error as? ExternalDiscovery.Failure, .notEnabled)
        }
    }
}

/// The connection test against the **real** services.
///
/// Off unless `BATON_LIVE_DISCOVERY=1`, so the gate never depends on somebody else's uptime
/// — but a test that only checks "the field is not empty" is exactly what this feature
/// replaces, so the real request has to be runnable and this is how.
final class ExternalDiscoveryLiveTestTests: XCTestCase {
    private func skipUnlessOptedIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BATON_LIVE_DISCOVERY"] == "1",
                          "set BATON_LIVE_DISCOVERY=1 to test the real catalogues")
    }

    func testMusicBrainzAnswersATestLookup() async throws {
        try skipUnlessOptedIn()
        let result = await ExternalDiscovery.test(.musicBrainz)
        print("LIVE discovery test — MusicBrainz: \(result)")
        XCTAssertTrue(result.isReady, "MusicBrainz: \(result.message)")
    }

    func testListenBrainzAnswersATestLookup() async throws {
        try skipUnlessOptedIn()
        let result = await ExternalDiscovery.test(.listenBrainz)
        print("LIVE discovery test — ListenBrainz: \(result)")
        XCTAssertTrue(result.isReady, "ListenBrainz: \(result.message)")
    }

    /// A key that is definitely wrong must come back as *rejected*, not as "unreachable" and
    /// not as ready. This is the case the old UI could not tell you about at all.
    func testAWrongLastFMKeyIsReportedAsRejectedRatherThanQuiet() async throws {
        try skipUnlessOptedIn()
        let previous = UserDefaults.standard.string(forKey: ExternalDiscovery.lastFMKeyKey)
        UserDefaults.standard.set("definitely-not-a-real-key", forKey: ExternalDiscovery.lastFMKeyKey)
        defer { UserDefaults.standard.set(previous, forKey: ExternalDiscovery.lastFMKeyKey) }

        let result = await ExternalDiscovery.test(.lastFM)
        print("LIVE discovery test — Last.fm with a bad key: \(result)")
        guard case .keyRejected = result else {
            return XCTFail("a wrong key should be reported as rejected, got: \(result)")
        }
    }
}

/// Moving the API keys out of the plain defaults domain and into the Keychain.
///
/// Hermetic: `NavidromeKeychain.inMemoryStore` stands in for the real Keychain, so this can
/// assert on the migration without touching the developer's login keychain or prompting.
final class ExternalDiscoveryKeyStorageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NavidromeKeychain.inMemoryStore = [:]
        UserDefaults.standard.removeObject(forKey: ExternalDiscovery.lastFMKeyKey)
    }

    override func tearDown() {
        NavidromeKeychain.inMemoryStore = nil
        UserDefaults.standard.removeObject(forKey: ExternalDiscovery.lastFMKeyKey)
        super.tearDown()
    }

    func testAKeyWrittenHereIsReadableAndNeverTouchesUserDefaults() {
        ExternalDiscovery.setKey("abc123", for: .lastFM)

        XCTAssertEqual(ExternalDiscovery.key(for: .lastFM), "abc123")
        XCTAssertEqual(ExternalDiscovery.availability(of: .lastFM), .ready)
        XCTAssertNil(UserDefaults.standard.string(forKey: ExternalDiscovery.lastFMKeyKey),
                     "a credential must not be written to the defaults domain")
    }

    /// The upgrade path: someone already had a key typed into the old settings field.
    func testALegacyDefaultsKeyIsMovedIntoTheKeychainAndThePlaintextRemoved() {
        UserDefaults.standard.set("legacy-key", forKey: ExternalDiscovery.lastFMKeyKey)

        XCTAssertEqual(ExternalDiscovery.key(for: .lastFM), "legacy-key", "the old key must survive the move")
        XCTAssertNil(UserDefaults.standard.string(forKey: ExternalDiscovery.lastFMKeyKey),
                     "the plaintext copy must be gone, or the move only added a second place to leak from")
        XCTAssertEqual(NavidromeKeychain.inMemoryStore?[ExternalDiscovery.lastFMKeyKey],
                       Data("legacy-key".utf8))
    }

    /// Both apps run this, and a second launch must be a no-op rather than a second move.
    func testTheMigrationIsIdempotent() {
        UserDefaults.standard.set("legacy-key", forKey: ExternalDiscovery.lastFMKeyKey)
        XCTAssertEqual(ExternalDiscovery.key(for: .lastFM), "legacy-key")

        // Second and third reads: same answer, nothing re-migrated, no plaintext resurrected.
        XCTAssertEqual(ExternalDiscovery.key(for: .lastFM), "legacy-key")
        XCTAssertEqual(ExternalDiscovery.key(for: .lastFM), "legacy-key")
        XCTAssertNil(UserDefaults.standard.string(forKey: ExternalDiscovery.lastFMKeyKey))
    }

    /// Clearing the field must delete the item, not store an empty secret that reads as
    /// "configured" and then fails every request.
    func testClearingTheFieldRemovesTheStoredKey() {
        ExternalDiscovery.setKey("abc123", for: .lastFM)
        ExternalDiscovery.setKey("", for: .lastFM)

        XCTAssertEqual(ExternalDiscovery.key(for: .lastFM), "")
        XCTAssertEqual(ExternalDiscovery.availability(of: .lastFM), .needsKey)
    }
}
