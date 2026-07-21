import XCTest
import Sentry
@testable import Baton

/// : the Sentry scrubber is a shipped privacy promise ("your server address and
/// credentials are never attached"). It must strip the server host, Subsonic auth,
/// LAN IPs, and home paths from every field of an event — not just the top-level user.
final class CrashReportingScrubberTests: XCTestCase {

    // MARK: redact() — the core

    func testRedactStripsURLAuthIPAndPath() {
        let s = "GET https://music.example.com/rest/stream?u=bob&t=abc&s=xyz failed on 192.168.1.50 for /Users/bob/Music/x.flac"
        let r = CrashReporting.redact(s)
        XCTAssertFalse(r.contains("music.example.com"), r)
        XCTAssertFalse(r.contains("192.168.1.50"), r)
        XCTAssertFalse(r.contains("/Users/bob"), r)
        XCTAssertFalse(r.contains("t=abc"), r)
        XCTAssertFalse(r.contains("u=bob"), r)
    }

    func testRedactLocalHostAndPrivateRanges() {
        XCTAssertFalse(CrashReporting.redact("host navidrome.local:4533").contains("navidrome.local"))
        XCTAssertFalse(CrashReporting.redact("dial 10.0.0.5").contains("10.0.0.5"))
        XCTAssertFalse(CrashReporting.redact("dial 172.16.9.9").contains("172.16.9.9"))
    }

    // MARK: scrub(event:) — all fields

    func testScrubEventCoversMessageExceptionExtraAndUser() {
        let event = Event()
        event.message = SentryMessage(formatted: "boom at https://192.168.1.50:4533/rest/ping?u=a&t=b&s=c")
        event.exceptions = [Sentry.Exception(value: "transport(https://nas.local/rest/x)", type: "Err")]
        event.extra = ["endpoint": "https://music.example.com/rest/getAlbumList2"]
        _ = CrashReporting.scrub(event)
        XCTAssertFalse((event.message?.formatted ?? "").contains("192.168.1.50"))
        XCTAssertFalse((event.exceptions?.first?.value ?? "").contains("nas.local"))
        XCTAssertFalse(((event.extra?["endpoint"] as? String) ?? "").contains("music.example.com"))
        XCTAssertNil(event.user)
    }

    // MARK: scrubBreadcrumb()

    func testHttpBreadcrumbIsDropped() {
        let crumb = Breadcrumb()
        crumb.category = "http"
        crumb.message = "GET https://music.example.com/rest/stream"
        XCTAssertNil(CrashReporting.scrubBreadcrumb(crumb))
    }

    func testNonHttpBreadcrumbIsRedactedNotDropped() {
        let crumb = Breadcrumb()
        crumb.category = "app.lifecycle"
        crumb.message = "loaded config from https://nas.local/x"
        let out = CrashReporting.scrubBreadcrumb(crumb)
        XCTAssertNotNil(out)
        XCTAssertFalse((out?.message ?? "").contains("nas.local"))
    }
}
