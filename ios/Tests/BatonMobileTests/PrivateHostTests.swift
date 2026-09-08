import XCTest
import BatonPlaybackKit
@testable import BatonMobile

/// One rule about what counts as a private host, asked through both doors.
///
/// There used to be two implementations. They agreed on everything except loopback: the
/// shared one in BatonAgentKit had `127.`, the iPhone's did not. So `http://127.0.0.1:8799`
/// was private to the Mac's agent and "a public host" to the phone's, which refused to send
/// a key to it — while the same app ships `http://127.0.0.1:8001` as its default Whisper
/// host two screens away.
///
/// These assert through **both** call sites deliberately. A test that only exercised the
/// shared function would have passed on the day the copies disagreed, which is the whole
/// reason the bug survived.
final class PrivateHostTests: XCTestCase {

    private func bothAgree(_ host: String, isPrivate expected: Bool, _ why: String) {
        XCTAssertEqual(AgentClient.isPrivateHost(host), expected, "phone: \(why)")
        XCTAssertEqual(RemoteNaturalLanguage.isPrivate(host), expected, "shared: \(why)")
    }

    /// The case that was actually broken.
    func testLoopbackIsPrivateThroughBothDoors() {
        bothAgree("127.0.0.1", isPrivate: true, "loopback is the least public host there is")
        bothAgree("127.0.0.53", isPrivate: true, "all of 127.0.0.0/8 is loopback")
        bothAgree("localhost", isPrivate: true, "the name for the same thing")
    }

    /// IPv6 loopback arrives bare or bracketed depending on who parsed the URL, and neither
    /// form starts with `127.`.
    func testIPv6LoopbackIsPrivateInBothSpellings() {
        bothAgree("::1", isPrivate: true, "bare")
        bothAgree("[::1]", isPrivate: true, "bracketed, as a URL host component")
    }

    func testRFC1918RangesArePrivate() {
        bothAgree("192.168.1.5", isPrivate: true, "the commonest home LAN")
        bothAgree("10.0.0.9", isPrivate: true, "10/8")
        bothAgree("172.16.0.1", isPrivate: true, "bottom of 172.16/12")
        bothAgree("172.31.255.254", isPrivate: true, "top of 172.16/12")
        bothAgree("baton.local", isPrivate: true, "the names macOS treats as local")
    }

    /// The refusal has to keep working — this guard exists because Subsonic and provider
    /// keys travel in these requests, and plain HTTP to a real host would leak them.
    func testGenuinelyPublicHostsAreStillRefused() {
        bothAgree("api.anthropic.com", isPrivate: false, "a real host")
        bothAgree("172.32.0.1", isPrivate: false, "just above 172.16/12")
        bothAgree("172.15.0.1", isPrivate: false, "just below 172.16/12")
        bothAgree("11.0.0.1", isPrivate: false, "adjacent to 10/8 but public")
        bothAgree("127.example.com", isPrivate: false,
                  "a hostname that merely starts with the loopback digits")
    }

    /// Case-insensitivity was the second, quieter difference: the phone's copy compared the
    /// raw host, so `Baton.LOCAL` was public to it and private to the shared rule.
    func testTheAnswerDoesNotDependOnCase() {
        bothAgree("LOCALHOST", isPrivate: true, "uppercased")
        bothAgree("Baton.Local", isPrivate: true, "mixed case suffix")
    }

    /// The point of the card: not that each is right, but that they cannot diverge again.
    func testBothDoorsAgreeAcrossTheWholeSet() {
        let hosts = ["127.0.0.1", "::1", "[::1]", "localhost", "LOCALHOST", "baton.local",
                     "192.168.1.5", "10.0.0.9", "172.16.0.1", "172.31.255.254",
                     "172.32.0.1", "172.15.0.1", "11.0.0.1", "api.anthropic.com",
                     "127.example.com", ""]
        for host in hosts {
            XCTAssertEqual(AgentClient.isPrivateHost(host), RemoteNaturalLanguage.isPrivate(host),
                           "the two call sites disagree about \(host.isEmpty ? "(empty)" : host)")
        }
    }
}
