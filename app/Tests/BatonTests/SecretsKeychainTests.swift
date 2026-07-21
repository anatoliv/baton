import XCTest
@testable import Baton

/// : account-controlling secrets live in the Keychain, migrated transparently from any
/// legacy plaintext UserDefaults copy, and never written back to UserDefaults.
@MainActor
final class SecretsKeychainTests: XCTestCase {
    override func setUp() { NavidromeKeychain.inMemoryStore = [:] }
    override func tearDown() {
        NavidromeKeychain.inMemoryStore = nil
        UserDefaults.standard.removeObject(forKey: MusicScrobbler.tokenKey)
        UserDefaults.standard.removeObject(forKey: MusicLastFM.secretKey)
    }

    func testListenBrainzTokenMigratesFromUserDefaults() {
        UserDefaults.standard.set("lb-legacy", forKey: MusicScrobbler.tokenKey)
        let s = MusicScrobbler()
        XCTAssertEqual(s.token, "lb-legacy")
        XCTAssertNil(UserDefaults.standard.string(forKey: MusicScrobbler.tokenKey), "plaintext copy dropped")
        XCTAssertEqual(NavidromeKeychain.secret(account: MusicScrobbler.tokenKey), "lb-legacy")
    }

    func testListenBrainzTokenPersistsToKeychainNotDefaults() {
        let s = MusicScrobbler()
        s.token = "lb-new"
        XCTAssertNil(UserDefaults.standard.string(forKey: MusicScrobbler.tokenKey))
        XCTAssertEqual(NavidromeKeychain.secret(account: MusicScrobbler.tokenKey), "lb-new")
    }

    func testLastFMSecretAndSessionKeyUseKeychain() {
        let fm = MusicLastFM()
        fm.apiSecret = "sekret"
        XCTAssertNil(UserDefaults.standard.string(forKey: MusicLastFM.secretKey))
        XCTAssertEqual(NavidromeKeychain.secret(account: MusicLastFM.secretKey), "sekret")
    }
}
