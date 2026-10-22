import XCTest
@testable import Baton

/// C-26: addresses the scrubber let through. A Baton share link's `#key`, a
/// Tailscale (CGNAT) or IPv6 address, a link-local address, and a host named without a scheme.
final class CrashReportingRedactionGapTests: XCTestCase {
    func testOtherSchemesCGNATIPv6AndSchemeLessHostsAreRedacted() {
        let cases: [(String, String)] = [
            ("open baton://share/s/abcdefghijklmnopqrstuv#synthetic-key-material failed", "synthetic-key-material"),
            ("open baton://share/s/abcdefghijklmnopqrstuv#synthetic-key-material failed", "abcdefghijklmnopqrstuv"),
            ("dial 100.101.102.103 timed out", "100.101.102.103"),
            ("dial 169.254.10.20 timed out", "169.254.10.20"),
            ("connect [fd7a:115c:a1e0::1a2b]:4533 refused", "fd7a:115c:a1e0::1a2b"),
            ("connect fe80::1c2d:3e4f:5a6b:7c8d%en0 refused", "fe80::1c2d:3e4f:5a6b:7c8d"),
            ("connect 2001:db8:85a3:0:0:8a2e:370:7334 refused", "2001:db8:85a3:0:0:8a2e:370:7334"),
            ("server music.example.com:4533 refused", "music.example.com"),
            ("server navidrome.home.arpa refused", "navidrome.home.arpa"),
            ("server nas.lan refused", "nas.lan"),
            ("server box.tail1234.ts.net refused", "box.tail1234.ts.net"),
        ]
        for (input, leaked) in cases {
            let out = CrashReporting.redact(input)
            XCTAssertFalse(out.contains(leaked), "\(input) -> \(out)")
        }
    }

    func testTimesSymbolsAndVersionsAreLeftAlone() {
        for text in [
            "stalled at 10:45:00 after 3 retries",
            "std::__1::basic_string failed in Player.swift:120",
            "Baton 0.20.14 (build 412) on macOS 26.1",
            "Foundation.URLSession task 12 cancelled",
        ] {
            XCTAssertEqual(CrashReporting.redact(text), text)
        }
    }
}
