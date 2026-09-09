import XCTest
@testable import BatonSpeech

/// The pure half of `SpeechService`: how a host is judged private, and the message a
/// transport failure turns into. Both run on error paths, which is where a wrong answer is
/// most expensive and least likely to be noticed.
final class SpeechServiceTests: XCTestCase {
    // MARK: - Private addresses

    func testTheFourPrivateRangesAndLocalNamesAreRecognised() {
        for host in ["10.0.0.1", "10.255.255.254", "192.168.1.50", "172.16.0.1", "172.31.255.1",
                     "127.0.0.1", "localhost", "speech-box.local"] {
            XCTAssertTrue(SpeechService.isPrivateAddress(host), host)
        }
    }

    /// `172.16` through `172.31` only. The neighbours on either side are public space, and
    /// treating them as local would attach the Local Network advice to a real outage.
    func testTheSecondOctetBoundsOfTheOneSixteenRangeAreExact() {
        XCTAssertFalse(SpeechService.isPrivateAddress("172.15.0.1"))
        XCTAssertTrue(SpeechService.isPrivateAddress("172.16.0.1"))
        XCTAssertTrue(SpeechService.isPrivateAddress("172.31.0.1"))
        XCTAssertFalse(SpeechService.isPrivateAddress("172.32.0.1"))
    }

    func testPublicAddressesAndOrdinaryHostnamesAreNotPrivate() {
        for host in ["8.8.8.8", "203.0.113.9", "192.169.1.1", "api.example.com", "kokoro.example"] {
            XCTAssertFalse(SpeechService.isPrivateAddress(host), host)
        }
    }

    /// Deliberately literal-only: a name that *resolves* to a private address would need a
    /// lookup, and this runs on an error path where a second network call is the last thing
    /// wanted. Anything malformed falls back to the generic message, which is less helpful
    /// rather than wrong.
    func testMalformedAddressesAreNotGuessedAt() {
        for host in ["10.0.0", "10.0.0.1.1", "10.0.0.999", "10.0.0.a", "", "..."] {
            XCTAssertFalse(SpeechService.isPrivateAddress(host), host)
        }
    }

    // MARK: - Transport messages

    /// The case worth naming: macOS answers `-1009` when an app has been refused
    /// the Local Network grant, which reads as "there is no network" while every request to
    /// the internet keeps working. It was chased as a network fault, a sleeping host and a
    /// VPN before the grant was suspected.
    func testTheLocalNetworkGrantIsNamedRatherThanReportedAsNoNetwork() {
        let message = SpeechService.transportMessage(
            URLError(.notConnectedToInternet), engine: "kokoro", base: "http://10.0.0.5:8880")
        XCTAssertTrue(message.contains("Local Network"), message)
        XCTAssertTrue(message.contains("10.0.0.5"), "the message should name the host")
        XCTAssertTrue(message.contains("Privacy & Security"), "it should say where to go")
    }

    /// The same error code against a public host is an ordinary outage, and the Local Network
    /// advice would send somebody to the wrong settings pane.
    func testAPublicHostGetsTheGenericMessageForTheSameErrorCode() {
        let message = SpeechService.transportMessage(
            URLError(.notConnectedToInternet), engine: "kokoro", base: "https://api.example.com")
        XCTAssertTrue(message.hasPrefix("Couldn't reach the kokoro TTS service"), message)
        XCTAssertFalse(message.contains("Local Network"))
    }

    func testEveryOtherFailureAgainstAPrivateHostIsStillGeneric() {
        for code in [URLError.Code.cannotConnectToHost, .timedOut, .networkConnectionLost] {
            let message = SpeechService.transportMessage(
                URLError(code), engine: "chatterbox", base: "http://192.168.1.9:8004")
            XCTAssertFalse(message.contains("Local Network"), "\(code)")
            XCTAssertTrue(message.contains("192.168.1.9"), "\(code)")
        }
    }

    func testANonURLErrorIsGeneric() {
        struct Whatever: Error {}
        let message = SpeechService.transportMessage(
            Whatever(), engine: "kokoro", base: "http://10.0.0.5:8880")
        XCTAssertFalse(message.contains("Local Network"))
    }
}
