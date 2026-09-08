import XCTest
import BatonPlaybackKit
import BatonSubsonicKit
@testable import Baton

/// An import reports the secrets that are actually stored, not the ones it was handed
///.
///
/// The sheet could say "Imported 8 settings and 1 secret" and, in the same breath, that
/// there was nothing to connection-test — because the friend was not configured without the
/// key that had just been counted as applied. Both sentences were true. Together they
/// described something that had not happened.
final class ImportSecretHonestyTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "io.tonebox.tests.importhonesty.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        NavidromeKeychain.inMemoryStore = [:]
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        NavidromeKeychain.inMemoryStore = nil
        NavidromeKeychain.refusedAccounts = []
        NavidromeConfig.defaults = .standard
        super.tearDown()
    }

    private func exportCarryingASecret() throws -> Data {
        NavidromeConfig.defaults = suite
        NavidromeKeychain.setSecret("sk-from-the-mac", account: "baton.agent.apiKey")
        return try SettingsTransfer.makeExport(includeSecrets: true, passphrase: "pw",
                                               defaults: suite, documentsIn: nil).data
    }

    /// The ordinary case still counts, or the fix would have made the report useless.
    func testASecretThatLandsIsCounted() throws {
        let data = try exportCarryingASecret()
        NavidromeKeychain.inMemoryStore = [:]

        let result = try SettingsTransfer.applyImport(data, passphrase: "pw", defaults: suite,
                                                      documentsIn: nil)

        XCTAssertEqual(result.secretCount, 1)
        XCTAssertEqual(result.secretsRefused, 0)
        XCTAssertEqual(NavidromeKeychain.secret(account: "baton.agent.apiKey"), "sk-from-the-mac")
    }

    /// `setSecret` reports rather than swallowing. This is the seam the count now rests on;
    /// before, it returned Void and the caller could only assume.
    func testTheKeychainWriteReportsWhetherItStored() {
        XCTAssertTrue(NavidromeKeychain.setSecret("value", account: "baton.agent.apiKey"))
        XCTAssertEqual(NavidromeKeychain.secret(account: "baton.agent.apiKey"), "value")
    }

    /// Asking for absence is not a failure — an empty value deletes, and that is what was
    /// wanted, so it must not be reported as a refusal.
    func testClearingASecretIsNotARefusal() {
        NavidromeKeychain.setSecret("value", account: "baton.agent.apiKey")
        XCTAssertTrue(NavidromeKeychain.setSecret("", account: "baton.agent.apiKey"))
        XCTAssertNil(NavidromeKeychain.secret(account: "baton.agent.apiKey"))
    }

    /// **The assertion the whole card turns on.** A Keychain that refuses must be counted as
    /// a refusal, not as an applied secret. Without a way to make the in-memory store refuse,
    /// this branch had no coverage at all and a mutation restoring the old
    /// `appliedSecrets += 1` sailed through — which is how the bug existed in the first place.
    func testARefusedSecretIsCountedAsRefusedNotApplied() throws {
        let data = try exportCarryingASecret()
        NavidromeKeychain.inMemoryStore = [:]
        NavidromeKeychain.refusedAccounts = ["baton.agent.apiKey"]

        let result = try SettingsTransfer.applyImport(data, passphrase: "pw", defaults: suite,
                                                      documentsIn: nil)

        XCTAssertEqual(result.secretCount, 0, "it did not land, so it must not be counted")
        XCTAssertEqual(result.secretsRefused, 1, "and the refusal has to be reportable")
        XCTAssertNil(NavidromeKeychain.secret(account: "baton.agent.apiKey"),
                     "the premise: the secret really is not there")
    }

    func testAWriteThatIsRefusedSaysSo() {
        NavidromeKeychain.refusedAccounts = ["baton.agent.apiKey"]
        XCTAssertFalse(NavidromeKeychain.setSecret("value", account: "baton.agent.apiKey"))
    }
}
