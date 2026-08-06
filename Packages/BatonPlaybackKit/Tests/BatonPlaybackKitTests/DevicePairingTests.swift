import XCTest
@testable import BatonPlaybackKit

/// The pairing wire format and its proof.
///
/// This is the one place in Baton where a mistake hands someone else your server
/// credentials, so the tests are about what must be *refused* at least as much as what
/// must work: a code from a different session, a tampered proof, a payload key that
/// equals the proof key.
final class DevicePairingTests: XCTestCase {
    private func invitation() -> DevicePairing.Invitation {
        .make(host: "192.168.4.21", port: 54_321)
    }

    // MARK: - Round trip

    func testInvitationSurvivesEncodingAndParsing() {
        let original = invitation()

        let parsed = DevicePairing.parse(original.url)

        XCTAssertEqual(parsed, original, "a code the Mac drew must be the code the phone reads")
    }

    func testKeyIs256Bits() {
        XCTAssertEqual(invitation().key.count, 32)
    }

    /// Two invitations must never collide — the key is the only secret in the exchange.
    func testEachInvitationHasItsOwnKeyAndID() {
        let a = invitation(), b = invitation()
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertNotEqual(a.pairingID, b.pairingID)
    }

    // MARK: - What the scanner must refuse

    func testRefusesAnUnrelatedQRCode() {
        XCTAssertNil(DevicePairing.parse("https://example.com"))
        XCTAssertNil(DevicePairing.parse("WIFI:S:home;T:WPA;P:hunter2;;"))
        XCTAssertNil(DevicePairing.parse(""))
    }

    /// A code from a future Baton is refused rather than guessed at: a partially understood
    /// payload is how a phone ends up connecting somewhere unintended.
    func testRefusesAnUnknownVersion() {
        let future = invitation().url.replacingOccurrences(of: ":v1?", with: ":v99?")
        XCTAssertNil(DevicePairing.parse(future))
    }

    func testRefusesATruncatedKey() {
        let short = "baton-pair:v1?h=1.2.3.4&p=100&i=abc&k=\(Data([1, 2, 3]).base64URLEncoded)"
        XCTAssertNil(DevicePairing.parse(short), "a 3-byte key is not a 256-bit secret")
    }

    func testRefusesMissingFields() {
        XCTAssertNil(DevicePairing.parse("baton-pair:v1?h=1.2.3.4&p=100"))
        XCTAssertNil(DevicePairing.parse("baton-pair:v1?p=100&i=abc&k=xx"))
    }

    // MARK: - Proof of possession

    func testAHelloFromThisInvitationIsAccepted() {
        let invite = invitation()
        let hello = DevicePairing.hello(for: invite, deviceName: "Anatoli's iPhone")

        XCTAssertTrue(DevicePairing.isValid(hello, for: invite))
    }

    /// The listener is open on the LAN. Something that merely reached it, without seeing
    /// the screen, must get nothing.
    func testAHelloWithoutTheKeyIsRejected() {
        let invite = invitation()
        let attacker = DevicePairing.Invitation(
            host: invite.host, port: invite.port, pairingID: invite.pairingID,
            key: Data(repeating: 0, count: 32)
        )
        let forged = DevicePairing.hello(for: attacker, deviceName: "Someone Else's Phone")

        XCTAssertFalse(DevicePairing.isValid(forged, for: invite))
    }

    func testAHelloForADifferentSessionIsRejected() {
        let invite = invitation()
        let other = invitation()
        let hello = DevicePairing.hello(for: other, deviceName: "iPhone")

        XCTAssertFalse(DevicePairing.isValid(hello, for: invite),
                       "a proof from another pairing must not unlock this one")
    }

    func testATamperedProofIsRejected() {
        let invite = invitation()
        var hello = DevicePairing.hello(for: invite, deviceName: "iPhone")
        var bytes = hello.proof
        bytes[0] ^= 0xFF
        hello = DevicePairing.Hello(pairingID: hello.pairingID, deviceName: hello.deviceName, proof: bytes)

        XCTAssertFalse(DevicePairing.isValid(hello, for: invite))
    }

    // MARK: - Key separation

    /// The proof travels in the clear. If it were computed with the same key that encrypts
    /// the payload, watching one pairing would leak material for the other half.
    func testProofKeyAndPayloadKeyAreDifferent() {
        let invite = invitation()
        let proof = DevicePairing.proof(pairingID: invite.pairingID, key: invite.key)
        let passphrase = DevicePairing.payloadPassphrase(for: invite)

        XCTAssertNotEqual(proof.base64URLEncoded, passphrase)
        XCTAssertNotEqual(invite.key.base64URLEncoded, passphrase,
                          "the payload passphrase must be derived, not the raw QR key")
    }

    func testPayloadPassphraseIsStableForOneInvitation() {
        let invite = invitation()
        XCTAssertEqual(DevicePairing.payloadPassphrase(for: invite),
                       DevicePairing.payloadPassphrase(for: invite),
                       "both sides derive it independently and must agree")
    }

    func testPayloadPassphraseDiffersBetweenInvitations() {
        XCTAssertNotEqual(DevicePairing.payloadPassphrase(for: invitation()),
                          DevicePairing.payloadPassphrase(for: invitation()))
    }

    // MARK: - The expiry covers the dangerous state

    /// The window that matters. Once a device has passed the proof check, the Mac holds an
    /// open socket to something that demonstrably saw the code — and an unanswered prompt
    /// used to keep that alive indefinitely, because the timeout only guarded
    /// `.advertising`. That is the state where a timeout is doing real work.
    func testAnUnansweredApprovalExpires() {
        let outcome = PairingHost.expiryOutcome(for: .awaitingApproval(deviceName: "iPhone"))

        guard case let .failed(message)? = outcome else {
            return XCTFail("an unanswered approval must not hold the connection open")
        }
        XCTAssertTrue(message.contains("approve"), "the message should say what wasn't done: \(message)")
    }

    func testAnUnscannedCodeExpires() {
        let outcome = PairingHost.expiryOutcome(for: .advertising(.make(host: "1.2.3.4", port: 1234)))

        guard case .failed? = outcome else { return XCTFail("an unscanned code must expire") }
    }

    /// A completed link must survive its own timer — expiring it would report failure for
    /// something that worked.
    func testACompletedLinkDoesNotExpire() {
        XCTAssertNil(PairingHost.expiryOutcome(for: .linked(deviceName: "iPhone")))
    }

    func testIdleAndAlreadyFailedStatesAreLeftAlone() {
        XCTAssertNil(PairingHost.expiryOutcome(for: .idle))
        XCTAssertNil(PairingHost.expiryOutcome(for: .failed("earlier problem")))
    }

    // MARK: - base64url

    func testBase64URLSurvivesBytesThatWouldBreakAURL() {
        // 0x3E/0x3F encode to '+' and '/' in standard base64 — both illegal unescaped in a
        // query, which is exactly why the QR uses the URL-safe alphabet.
        let raw = Data([0xFB, 0xEF, 0xBE, 0x3E, 0x3F])
        let encoded = raw.base64URLEncoded

        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Data(base64URLEncoded: encoded), raw)
    }
}
