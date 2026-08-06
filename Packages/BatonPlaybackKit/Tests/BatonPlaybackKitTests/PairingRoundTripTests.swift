import XCTest
@testable import BatonPlaybackKit

/// The join between pairing and the settings format.
///
/// The two halves are developed independently — a Mac encrypts, a phone decrypts — and the
/// only thing that makes them agree is that both derive the same passphrase from the same
/// scanned key. If that derivation ever drifts, nothing fails to compile and nothing fails
/// to run: pairing simply stops working, on a code path that needs two devices and a person
/// holding one at the other to reproduce. So it is worth pinning here.
final class PairingRoundTripTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "baton.pairing.roundtrip.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// The whole point, end to end: what the Mac sends, the phone can open — using only
    /// what the QR carried.
    func testMacExportOpensWithThePassphraseThePhoneDerives() throws {
        defaults.set(true, forKey: "tonebox.navidrome.autoplay")
        defaults.set(2.5, forKey: "tonebox.navidrome.crossfade")

        let invitation = DevicePairing.Invitation.make(host: "192.168.3.26", port: 51_000)

        // Mac side. Goes through DevicePairing.makePayload, which is the only supported
        // way to build one — see the encryption guard below for why that matters.
        let payload = try DevicePairing.makePayload(for: invitation, defaults: defaults)

        // Phone side: the invitation came from parsing the scanned string, nothing else.
        let scanned = try XCTUnwrap(DevicePairing.parse(invitation.url))
        let target = UserDefaults(suiteName: "\(suiteName!).target")!
        defer { target.removePersistentDomain(forName: "\(suiteName!).target") }

        let result = try SettingsTransfer.applyImport(
            payload,
            passphrase: DevicePairing.payloadPassphrase(for: scanned),
            defaults: target
        )

        XCTAssertGreaterThan(result.preferenceCount, 0)
        XCTAssertEqual(target.bool(forKey: "tonebox.navidrome.autoplay"), true)
        XCTAssertEqual(target.double(forKey: "tonebox.navidrome.crossfade"), 2.5)
    }

    /// A payload intercepted on the network is useless without the code that was on screen.
    func testAnotherInvitationsKeyCannotOpenThePayload() throws {
        defaults.set(true, forKey: "tonebox.navidrome.autoplay")
        let real = DevicePairing.Invitation.make(host: "10.0.0.2", port: 51_001)
        let attacker = DevicePairing.Invitation.make(host: "10.0.0.2", port: 51_001)

        let payload = try DevicePairing.makePayload(for: real, defaults: defaults)

        let target = UserDefaults(suiteName: "\(suiteName!).attacker")!
        defer { target.removePersistentDomain(forName: "\(suiteName!).attacker") }

        XCTAssertThrowsError(
            try SettingsTransfer.applyImport(
                payload,
                passphrase: DevicePairing.payloadPassphrase(for: attacker),
                defaults: target
            ),
            "a payload must not open under a key that never saw the screen"
        )
    }

    /// The hazard this guards: `SettingsTransfer.makeExport(includeSecrets: false, …)`
    /// **ignores the passphrase and writes plain JSON**. That is right for "email yourself
    /// your preferences" and catastrophic for a socket on the LAN, so pairing payloads go
    /// through `DevicePairing.makePayload`, which always encrypts.
    func testAPairingPayloadIsNeverPlaintext() throws {
        defaults.set(true, forKey: "tonebox.navidrome.autoplay")
        let invitation = DevicePairing.Invitation.make(host: "10.0.0.3", port: 51_002)

        let payload = try DevicePairing.makePayload(for: invitation, defaults: defaults)

        // A readable export announces its own shape in cleartext JSON.
        let text = String(data: payload, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("tonebox.navidrome.autoplay"),
                       "a preference key visible in the payload means it went out in the clear")
        XCTAssertThrowsError(
            try SettingsTransfer.applyImport(payload, passphrase: nil, defaults: defaults),
            "an encrypted payload must not open without a passphrase"
        )
    }

    /// The encoded form is what actually crosses the gap — deriving from the parsed
    /// invitation must equal deriving from the original.
    func testPassphraseSurvivesTheQREncoding() throws {
        let invitation = DevicePairing.Invitation.make(host: "172.16.4.1", port: 49_152)
        let scanned = try XCTUnwrap(DevicePairing.parse(invitation.url))

        XCTAssertEqual(DevicePairing.payloadPassphrase(for: invitation),
                       DevicePairing.payloadPassphrase(for: scanned))
    }
}
