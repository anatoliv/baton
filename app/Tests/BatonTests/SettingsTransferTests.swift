import XCTest
@testable import Baton

/// Round-trip coverage for `SettingsTransfer` — the settings export/import used to move a setup
/// between Macs. Isolated: a throwaway `UserDefaults` suite and the in-memory Keychain backing,
/// so nothing touches the real app's prefs or the login Keychain.
final class SettingsTransferTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "io.tonebox.tests.settingstransfer.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        NavidromeKeychain.inMemoryStore = [:]
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        NavidromeKeychain.inMemoryStore = nil
        NavidromeConfig.defaults = .standard
        super.tearDown()
    }

    private func freshSuite() -> UserDefaults {
        let name = "io.tonebox.tests.settingstransfer.dest.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    func testPlainRoundTripRestoresPreferencesAndDropsExcludedAndSession() throws {
        suite.set(45.0, forKey: "tonebox.navidrome.stallTimeout")
        suite.set(true, forKey: "tonebox.music.eq.enabled")
        suite.set(true, forKey: "baton.music.offlineMode")
        suite.set(Data([1, 2, 3]), forKey: "tonebox.webhookActions")
        // Excluded: a machine path and transient session state must NOT travel.
        suite.set("/Users/someone/Music", forKey: "tonebox.music.downloadFolder")
        suite.set(Data([9, 9]), forKey: "tonebox.navidrome.queue")

        let export = try SettingsTransfer.makeExport(includeSecrets: false, passphrase: nil, defaults: suite)
        XCTAssertFalse(export.encrypted)
        XCTAssertEqual(export.secretCount, 0)
        XCTAssertFalse(try SettingsTransfer.inspect(export.data).encrypted)

        let dest = freshSuite()
        let result = try SettingsTransfer.applyImport(export.data, passphrase: nil, defaults: dest)

        XCTAssertEqual(dest.double(forKey: "tonebox.navidrome.stallTimeout"), 45.0)
        XCTAssertTrue(dest.bool(forKey: "tonebox.music.eq.enabled"))
        XCTAssertTrue(dest.bool(forKey: "baton.music.offlineMode"))
        XCTAssertEqual(dest.data(forKey: "tonebox.webhookActions"), Data([1, 2, 3]))
        XCTAssertNil(dest.string(forKey: "tonebox.music.downloadFolder"), "the download folder path must not travel")
        XCTAssertNil(dest.data(forKey: "tonebox.navidrome.queue"), "session state must not travel")
        XCTAssertEqual(result.secretCount, 0)
        XCTAssertGreaterThanOrEqual(result.preferenceCount, 4)
    }

    func testEncryptedRoundTripRestoresSecrets() throws {
        suite.set(30.0, forKey: "tonebox.navidrome.stallTimeout")
        NavidromeConfig.defaults = suite               // so secretAccounts() sees this suite's (empty) server list
        NavidromeKeychain.setSecret("lb-token-xyz", account: "tonebox.music.listenBrainzToken")
        NavidromeKeychain.setSecret("lastfm-session", account: "tonebox.music.lastfm.sessionKey")

        let export = try SettingsTransfer.makeExport(includeSecrets: true, passphrase: "correct horse", defaults: suite)
        XCTAssertTrue(export.encrypted)
        XCTAssertEqual(export.secretCount, 2)
        XCTAssertTrue(try SettingsTransfer.inspect(export.data).encrypted)

        // Wipe the Keychain + prefs, then restore from the encrypted backup.
        NavidromeKeychain.inMemoryStore = [:]
        let dest = freshSuite()
        let result = try SettingsTransfer.applyImport(export.data, passphrase: "correct horse", defaults: dest)

        XCTAssertEqual(dest.double(forKey: "tonebox.navidrome.stallTimeout"), 30.0)
        XCTAssertEqual(NavidromeKeychain.secret(account: "tonebox.music.listenBrainzToken"), "lb-token-xyz")
        XCTAssertEqual(NavidromeKeychain.secret(account: "tonebox.music.lastfm.sessionKey"), "lastfm-session")
        XCTAssertEqual(result.secretCount, 2)
    }

    func testWrongPassphraseFails() throws {
        NavidromeConfig.defaults = suite
        NavidromeKeychain.setSecret("secret", account: "tonebox.music.listenBrainzToken")
        let export = try SettingsTransfer.makeExport(includeSecrets: true, passphrase: "right", defaults: suite)

        XCTAssertThrowsError(try SettingsTransfer.applyImport(export.data, passphrase: "wrong", defaults: freshSuite())) { error in
            guard case SettingsTransfer.TransferError.wrongPassphrase = error else {
                return XCTFail("expected wrongPassphrase, got \(error)")
            }
        }
    }

    func testEncryptedImportWithoutPassphraseIsRejected() throws {
        NavidromeConfig.defaults = suite
        NavidromeKeychain.setSecret("secret", account: "tonebox.music.listenBrainzToken")
        let export = try SettingsTransfer.makeExport(includeSecrets: true, passphrase: "pw", defaults: suite)

        XCTAssertThrowsError(try SettingsTransfer.applyImport(export.data, passphrase: nil, defaults: freshSuite())) { error in
            guard case SettingsTransfer.TransferError.passphraseRequired = error else {
                return XCTFail("expected passphraseRequired, got \(error)")
            }
        }
    }

    func testForeignFileRejected() {
        let junk = try! JSONSerialization.data(withJSONObject: ["hello": "world"])
        XCTAssertThrowsError(try SettingsTransfer.inspect(junk)) { error in
            guard case SettingsTransfer.TransferError.notABatonBackup = error else {
                return XCTFail("expected notABatonBackup, got \(error)")
            }
        }
        XCTAssertThrowsError(try SettingsTransfer.applyImport(junk, passphrase: nil, defaults: suite)) { error in
            guard case SettingsTransfer.TransferError.notABatonBackup = error else {
                return XCTFail("expected notABatonBackup, got \(error)")
            }
        }
    }

    func testPlainExportNeverCarriesSecretsEvenIfPresent() throws {
        NavidromeConfig.defaults = suite
        NavidromeKeychain.setSecret("do-not-export", account: "tonebox.music.listenBrainzToken")

        let export = try SettingsTransfer.makeExport(includeSecrets: false, passphrase: nil, defaults: suite)
        // The plain file is inspectable JSON; the secret string must not appear anywhere in it.
        let asString = String(data: export.data, encoding: .utf8) ?? ""
        XCTAssertFalse(asString.contains("do-not-export"), "a preferences-only export must never contain a Keychain secret")
        XCTAssertEqual(export.secretCount, 0)
    }
}
