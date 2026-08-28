import XCTest
@testable import BatonPlaybackKit

/// Which secrets a pairing code and an encrypted export carry.
///
/// Asserted as policy rather than round-tripped, deliberately: `SettingsTransfer` reads
/// secrets through `NavidromeKeychain`, so an end-to-end test would have to write real items
/// into the developer's login Keychain to prove something that is really a decision about a
/// list. The list is the thing worth pinning — a secret silently dropping off it is invisible
/// until someone pairs a phone and finds one feature asking to be set up again.
final class SettingsTransferSecretPolicyTests: XCTestCase {

    /// The regression this was written for. Pairing carried the server passwords, both
    /// scrobbling tokens, both discovery keys and the gateway token — and not the music
    /// friend's key, which is the one a user is most likely to notice missing, because
    /// everything around it had just worked.
    func testTheMusicFriendsAPIKeyTravels() {
        XCTAssertTrue(SettingsTransfer.fixedSecretAccounts.contains("baton.agent.apiKey"))
        XCTAssertTrue(SettingsTransfer.isImportableSecretAccount("baton.agent.apiKey"),
                      "exported but refused on import is worse than not exported")
    }

    /// Everything a paired device needs in order to work without being asked for anything.
    func testEverySecretAPairedDeviceNeedsIsCarried() {
        let required = [
            "tonebox.navidromeSecret",              // legacy single-server password
            "tonebox.music.lastfm.apiSecret",
            "tonebox.music.lastfm.sessionKey",
            "tonebox.music.listenBrainzToken",
            "baton.agent.gatewayToken",
            "baton.agent.apiKey",
            "baton.discovery.lastfm.key",
            "baton.discovery.youtube.key",
        ]
        for account in required {
            XCTAssertTrue(SettingsTransfer.fixedSecretAccounts.contains(account),
                          "\(account) no longer travels — a paired device will ask for it by hand")
        }
    }

    /// Per-server passwords are added from the server list rather than named here, so the
    /// namespace has to stay importable or a paired phone gets servers it cannot sign in to.
    func testPerServerPasswordsAreImportable() {
        XCTAssertTrue(SettingsTransfer.isImportableSecretAccount("tonebox.navidromeSecret.\(UUID().uuidString)"))
    }

    /// The other half of the policy: an import must not be able to write arbitrary Keychain
    /// items. A tampered file naming some other app's account has to be refused.
    func testATamperedFileCannotInjectArbitraryKeychainItems() {
        for account in ["com.apple.something", "baton.mcp.token", "", "baton.agent"] {
            XCTAssertFalse(SettingsTransfer.isImportableSecretAccount(account),
                           "\(account) should not be writable by an imported file")
        }
    }

    /// Deliberately absent, each for its own reason. Listed so that adding one is a decision
    /// someone makes on purpose rather than by pattern-matching the others.
    func testTheDeliberateOmissionsStayOmitted() {
        let omitted = [
            "baton.mcp.token",                 // regenerated per machine; authorises loopback on *that* Mac
            "baton.remote.telegram.token",     // a Mac-only bridge; the phone has no use for it
            "baton.remote.discord.token",
        ]
        for account in omitted {
            XCTAssertFalse(SettingsTransfer.fixedSecretAccounts.contains(account),
                           "\(account) is machine-specific and should not travel")
        }
    }
}
