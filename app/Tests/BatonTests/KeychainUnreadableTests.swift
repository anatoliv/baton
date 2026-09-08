import XCTest
import BatonSubsonicKit
@testable import Baton

/// TBX-5268: "the Keychain will not answer" and "no password was ever saved" are different
/// states, and the app used to have no way to tell them apart — every call site turned both
/// into `""`. These cover the seam that separates them, and the data-loss path found while
/// building it.
final class KeychainUnreadableTests: XCTestCase {
    private let account = "tonebox.tests.unreadable"

    override func setUp() {
        super.setUp()
        NavidromeKeychain.inMemoryStore = [:]
        NavidromeKeychain.simulatedReadFailure = nil
        NavidromeKeychain.refusedAccounts = []
        UserDefaults.standard.removeObject(forKey: account)
    }

    override func tearDown() {
        NavidromeKeychain.inMemoryStore = nil
        NavidromeKeychain.simulatedReadFailure = nil
        NavidromeKeychain.refusedAccounts = []
        UserDefaults.standard.removeObject(forKey: account)
        super.tearDown()
    }

    // MARK: - The three states are distinguishable

    func testNothingSavedReadsAsMissing() {
        XCTAssertEqual(NavidromeKeychain.availability(account: account), .missing)
    }

    func testASavedSecretReadsAsPresent() {
        NavidromeKeychain.setSecret("hunter2", account: account)
        XCTAssertEqual(NavidromeKeychain.availability(account: account), .present)
    }

    func testAnUnreadableKeychainIsNotReportedAsMissing() {
        NavidromeKeychain.setSecret("hunter2", account: account)
        NavidromeKeychain.simulatedReadFailure = -25293 // errSecAuthFailed, the locked case

        XCTAssertEqual(NavidromeKeychain.availability(account: account), .unreadable(status: -25293))
        XCTAssertNotEqual(
            NavidromeKeychain.availability(account: account), .missing,
            "the whole point: a locked Keychain must not look like an empty one")
    }

    /// The old contract, unchanged. Callers holding `String?` keep behaving exactly as before;
    /// this fix adds a way to ask *why*, it does not change what `secret` hands back.
    func testSecretStillReturnsNilWhenUnreadable() {
        NavidromeKeychain.setSecret("hunter2", account: account)
        NavidromeKeychain.simulatedReadFailure = -25293
        XCTAssertNil(NavidromeKeychain.secret(account: account))
    }

    // MARK: - The store-wide probe

    func testStoreReadFailureIsNilWhenTheKeychainAnswers() {
        XCTAssertNil(NavidromeKeychain.storeReadFailure())
        XCTAssertTrue(NavidromeKeychain.storeIsReadable())
    }

    /// Account-independent by construction: nothing has ever been written under the probe
    /// account, so a store that answers reports "readable" rather than "missing a password".
    func testStoreReadFailureReportsTheStatusWhenItDoesNot() {
        NavidromeKeychain.simulatedReadFailure = -25308 // errSecInteractionNotAllowed
        XCTAssertEqual(NavidromeKeychain.storeReadFailure(), -25308)
        XCTAssertFalse(NavidromeKeychain.storeIsReadable())
    }

    // MARK: - The data-loss path

    /// The regression this fix exists to prevent. Migrate-on-read used to write the legacy
    /// plaintext value into the Keychain, discard the result, and delete the plaintext copy
    /// regardless. Against a locked Keychain the write failed and the delete succeeded, so the
    /// only surviving copy of the password was destroyed by reading it.
    func testALegacyPlaintextSecretSurvivesAnUnreadableKeychain() {
        UserDefaults.standard.set("legacy-password", forKey: account)
        NavidromeKeychain.simulatedReadFailure = -25293

        XCTAssertEqual(NavidromeKeychain.secret(account: account), "legacy-password",
                       "the value is still usable — a lock costs a retry, not the password")
        XCTAssertEqual(UserDefaults.standard.string(forKey: account), "legacy-password",
                       "and the only copy of it is still there")
    }

    /// The same guard, reached through a failing *write* rather than a failing read, so the
    /// two halves of the old bug are both covered.
    func testALegacyPlaintextSecretSurvivesARefusedWrite() {
        UserDefaults.standard.set("legacy-password", forKey: account)
        NavidromeKeychain.refusedAccounts = [account]

        XCTAssertEqual(NavidromeKeychain.secret(account: account), "legacy-password")
        XCTAssertEqual(UserDefaults.standard.string(forKey: account), "legacy-password",
                       "nothing else holds it, so dropping it here would lose it outright")
    }

    /// The behaviour that must NOT change: when the Keychain accepts the migration, the
    /// plaintext copy still goes. Otherwise this fix would quietly leave passwords in
    /// UserDefaults forever, which is the thing the migration was written to end.
    func testASuccessfulMigrationStillDropsThePlaintextCopy() {
        UserDefaults.standard.set("legacy-password", forKey: account)

        XCTAssertEqual(NavidromeKeychain.secret(account: account), "legacy-password")
        XCTAssertNil(UserDefaults.standard.string(forKey: account), "plaintext copy dropped")
        XCTAssertEqual(NavidromeKeychain.secret(account: account), "legacy-password",
                       "and it reads back from the Keychain afterwards")
    }
}
