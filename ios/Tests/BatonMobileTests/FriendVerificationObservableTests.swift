import XCTest
import BatonSubsonicKit
@testable import BatonMobile

/// Passing a connection test has to be *visible*, not merely true.
///
/// The Friend tab's only condition is `AgentConfig.isReady`, and `isReady` used to read the
/// verification straight out of `UserDefaults` through a `private let`. The Observation macro
/// does not instrument a `let`, so `markVerified()` changed the answer and published nothing:
/// the value was correct and no view had any reason to look at it again. A test that only
/// asserts `isReady == true` passes against that bug, which is why these assert on the
/// *stored* property Observation can actually track.
@MainActor
final class FriendVerificationObservableTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Shared across instances on purpose: the Keychain survives a relaunch, so a test that
    /// gave the "second launch" a fresh store would be simulating a wiped device instead.
    private var secrets: InMemorySecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "baton.agentconfig.observable.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = InMemorySecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        secrets = nil
        super.tearDown()
    }

    private func configured() -> AgentConfig {
        let config = AgentConfig(defaults: defaults, secrets: secrets)
        config.route = .direct
        config.apiKey = "sk-ant-test"
        config.model = "claude-haiku-4-5-20251001"
        config.baseURL = "https://api.anthropic.com"
        return config
    }

    /// The assertion that fails against the bug: the value a view can observe must move.
    func testPassingATestMovesAnObservableProperty() {
        let config = configured()
        XCTAssertNil(config.verifiedFingerprint)

        config.markVerified()

        XCTAssertEqual(config.verifiedFingerprint, config.fingerprint,
                       "the Friend tab observes this; a UserDefaults-only write is invisible to it")
        XCTAssertTrue(config.isReady)
    }

    func testInvalidatingClearsTheObservableProperty() {
        let config = configured()
        config.markVerified()

        config.model = "something-else"

        XCTAssertNil(config.verifiedFingerprint, "an edit must clear what the tab is watching")
        XCTAssertFalse(config.isReady)
    }

    /// It still has to survive a relaunch, so the persistence cannot be dropped in favour of
    /// the in-memory copy.
    func testVerificationSurvivesANewInstance() {
        let first = configured()
        first.markVerified()
        let fingerprint = first.fingerprint

        // A relaunch: same defaults, same Keychain, nothing re-typed. It must come back
        // already verified, or every launch would hide the Friend tab until retested.
        let second = AgentConfig(defaults: defaults, secrets: secrets)

        XCTAssertEqual(second.verifiedFingerprint, fingerprint)
        XCTAssertEqual(second.fingerprint, fingerprint, "and it must recognise the same config")
        XCTAssertTrue(second.isReady)
    }

    /// And a `reload()` — the after-import path — must bring it back rather than leaving a
    /// device that was verified before the import looking unverified afterwards.
    func testReloadRestoresTheObservableVerification() {
        let config = configured()
        config.markVerified()
        let expected = config.fingerprint

        config.reload()

        XCTAssertEqual(config.verifiedFingerprint, expected)
        XCTAssertTrue(config.isReady)
    }

    // MARK: - The other half: the check must not be keyed on live text fields

    /// Every input to `fingerprint` is two-way bound to a field on the Music Friend screen,
    /// so keying an auto-test on it spent one real model request per keystroke — up to 40 for
    /// a pasted API key, at a paid provider. This pins the property that made that a bug, so
    /// nobody keys a probe on it again without noticing.
    func testTheFingerprintChangesOnEveryKeystrokeOfAnEditableField() {
        let config = configured()
        var seen = Set<String>()
        for partial in ["s", "sk", "sk-", "sk-a", "sk-an", "sk-ant"] {
            config.apiKey = partial
            seen.insert(config.fingerprint)
        }
        XCTAssertEqual(seen.count, 6,
                       "each keystroke yields a distinct fingerprint — anything keyed on it "
                       + "runs once per character typed")
    }
}
