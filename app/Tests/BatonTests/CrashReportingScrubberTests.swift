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

    // MARK: scrub(event:) — the fields the allowlist never reached (S-F5)
    //
    // Five cases stood here and none of them named `context`, `tags`, `stacktrace`,
    // `fingerprint`, `threads` or `debugMeta`, which is exactly why an allowlist scrubber
    // looked correct for as long as it did. One per field, each red against the old scrub.

    func testScrubRedactsContextRecursively() {
        let event = Event()
        event.context = [
            "app": [
                "app_identifier": "io.tonebox.baton",
                "app_path": "/Users/someone/Library/Developer/Xcode/DerivedData/Baton-abc/Build/Products/Debug/Baton.app",
            ],
            "device": ["model": "Mac16,6", "host": "navidrome.local"],
        ]
        _ = CrashReporting.scrub(event)
        let app = event.context?["app"] ?? [:]
        let device = event.context?["device"] ?? [:]
        XCTAssertFalse("\(app["app_path"] ?? "")".contains("/Users/someone"), "\(app)")
        XCTAssertFalse("\(device["host"] ?? "")".contains("navidrome.local"), "\(device)")
        // And the triage value survives: redacting the section wholesale would be easy and
        // would take the device model and bundle id with it.
        XCTAssertEqual(device["model"] as? String, "Mac16,6")
        XCTAssertEqual(app["app_identifier"] as? String, "io.tonebox.baton")
    }

    func testScrubRedactsTags() {
        let event = Event()
        event.tags = ["server": "https://music.example.com", "kind": "playback"]
        _ = CrashReporting.scrub(event)
        XCTAssertFalse((event.tags?["server"] ?? "").contains("music.example.com"), "\(event.tags ?? [:])")
        XCTAssertEqual(event.tags?["kind"], "playback")
    }

    func testScrubRedactsFingerprint() {
        let event = Event()
        event.fingerprint = ["transport", "https://nas.local/rest/ping"]
        _ = CrashReporting.scrub(event)
        XCTAssertFalse((event.fingerprint ?? []).joined().contains("nas.local"), "\(event.fingerprint ?? [])")
    }

    func testScrubRedactsExceptionStacktraceFrames() {
        let event = Event()
        let frame = Frame()
        frame.fileName = "/Users/someone/Projects/baton/Packages/BatonPlaybackKit/Sources/Player.swift"
        frame.package = "/Users/someone/Library/Developer/Xcode/DerivedData/Baton-abc/Build/Products/Debug/Baton.app/Contents/MacOS/Baton"
        frame.function = "resolveStreamURL(songID:)"
        frame.instructionAddress = "0x1044c8e10"
        frame.imageAddress = "0x104000000"
        frame.contextLine = "let url = URL(string: \"https://music.example.com\")!"
        frame.vars = ["token": "s3cr3t"]
        let exception = Sentry.Exception(value: "boom", type: "Err")
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.exceptions = [exception]

        _ = CrashReporting.scrub(event)
        let out = event.exceptions?.first?.stacktrace?.frames.first
        XCTAssertEqual(out?.fileName, "Player.swift")
        XCTAssertEqual(out?.package, "Baton")
        XCTAssertNil(out?.contextLine)
        XCTAssertNil(out?.vars)
        // The two fields Crashbox symbolicates against must survive exactly.
        XCTAssertEqual(out?.instructionAddress, "0x1044c8e10")
        XCTAssertEqual(out?.imageAddress, "0x104000000")
        XCTAssertEqual(out?.function, "resolveStreamURL(songID:)")
    }

    func testScrubRedactsThreadStacktraceFrames() {
        // The Cocoa SDK puts the stacks of any non-fatal capture under `threads`, not
        // `exceptions`, so this is where most real events carry their frames at all.
        let event = Event()
        let frame = Frame()
        frame.fileName = "/Users/someone/Projects/baton/app/Sources/Baton/AppDelegate.swift"
        let thread = SentryThread(threadId: 0)
        thread.name = "queue at https://nas.local"
        thread.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.threads = [thread]

        _ = CrashReporting.scrub(event)
        XCTAssertEqual(event.threads?.first?.stacktrace?.frames.first?.fileName, "AppDelegate.swift")
        XCTAssertFalse((event.threads?.first?.name ?? "").contains("nas.local"))
    }

    func testScrubKeepsDebugImageIdentityAndCutsThePath() {
        // Nulling debugMeta would be the easy answer and it would make every native crash
        // permanently unsymbolicated: Crashbox's artifact catalog is keyed on the image's
        // debug id, per ~/Projects/crashbox/docs/apple-symbolication-worker.md.
        let event = Event()
        let image = DebugMeta()
        image.debugID = "8CB4A2C1-3A9E-3D0A-9E22-0B7E4F0A1111"
        image.imageAddress = "0x104000000"
        image.imageSize = 262144
        image.type = "macho"
        image.name = "/Users/someone/Library/Developer/Xcode/DerivedData/Baton-abc/Build/Products/Debug/Baton.app/Contents/MacOS/Baton"
        image.codeFile = "/Users/someone/Downloads/Baton.app/Contents/MacOS/Baton"
        event.debugMeta = [image]

        _ = CrashReporting.scrub(event)
        let out = event.debugMeta?.first
        XCTAssertFalse((out?.name ?? "").contains("/Users/someone"), "\(out?.name ?? "")")
        XCTAssertFalse((out?.codeFile ?? "").contains("/Users/someone"), "\(out?.codeFile ?? "")")
        XCTAssertEqual(out?.name, "Baton")
        XCTAssertEqual(out?.debugID, "8CB4A2C1-3A9E-3D0A-9E22-0B7E4F0A1111")
        XCTAssertEqual(out?.imageAddress, "0x104000000")
        XCTAssertEqual(out?.imageSize, 262144)
    }

    func testScrubRedactsNestedExtraNotJustTheTopLevel() {
        let event = Event()
        event.extra = ["response": ["url": "https://music.example.com/rest/ping?u=bob&t=abc",
                                    "status": 500]]
        _ = CrashReporting.scrub(event)
        let nested = event.extra?["response"] as? [String: Any] ?? [:]
        XCTAssertFalse("\(nested["url"] ?? "")".contains("music.example.com"), "\(nested)")
        XCTAssertFalse("\(nested["url"] ?? "")".contains("u=bob"), "\(nested)")
        XCTAssertEqual(nested["status"] as? Int, 500)
    }

    func testScrubRedactsMechanismData() {
        let event = Event()
        let exception = Sentry.Exception(value: "boom", type: "Err")
        let mechanism = Mechanism(type: "NSError")
        mechanism.desc = "failed talking to https://nas.local"
        mechanism.data = ["NSFilePath": "/Users/someone/Music/x.flac"]
        exception.mechanism = mechanism
        event.exceptions = [exception]
        _ = CrashReporting.scrub(event)
        let out = event.exceptions?.first?.mechanism
        XCTAssertFalse((out?.desc ?? "").contains("nas.local"), "\(out?.desc ?? "")")
        XCTAssertFalse("\(out?.data?["NSFilePath"] ?? "")".contains("/Users/someone"), "\(out?.data ?? [:])")
    }

    func testScrubLeavesTheReleaseIdentityAlone() {
        // Crashbox keys the dSYM to the release name. A scrubber that rewrote it would make
        // every report unsymbolicatable while looking like it was being careful.
        let event = Event()
        event.releaseName = "io.tonebox.baton@0.19.0+100.0123456789abcdef0123456789abcdef01234567"
        event.environment = "production"
        event.dist = "100"
        _ = CrashReporting.scrub(event)
        XCTAssertEqual(event.releaseName, "io.tonebox.baton@0.19.0+100.0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(event.environment, "production")
        XCTAssertEqual(event.dist, "100")
    }

    // MARK: scrubBreadcrumb()

    func testNestedBreadcrumbDataIsRedacted() {
        let crumb = Breadcrumb()
        crumb.category = "app.lifecycle"
        crumb.data = ["request": ["url": "https://nas.local/rest/ping"]]
        let out = CrashReporting.scrubBreadcrumb(crumb)
        let nested = out?.data?["request"] as? [String: Any] ?? [:]
        XCTAssertFalse("\(nested["url"] ?? "")".contains("nas.local"), "\(nested)")
    }

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
