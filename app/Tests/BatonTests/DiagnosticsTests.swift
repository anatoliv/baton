import XCTest
@testable import Baton

///  / DIST-11: the diagnostics log export must be readable AND privacy-safe — it redacts the
/// server address, IPs, `*.local` hosts, home paths, and Subsonic auth the same way crash reports do.
final class DiagnosticsTests: XCTestCase {
    private func line(_ msg: String) -> Diagnostics.LogLine {
        Diagnostics.LogLine(date: Date(timeIntervalSince1970: 1_700_000_000), level: "error", category: "net", message: msg)
    }

    func testFormatIncludesLevelCategoryAndCount() {
        let out = Diagnostics.format([line("hello"), line("world")])
        XCTAssertTrue(out.contains("2 log line(s)"))
        XCTAssertTrue(out.contains("[error] net: hello"))
        XCTAssertTrue(out.contains("[error] net: world"))
    }

    func testExportRedactsServerURLAndAuth() {
        let out = Diagnostics.format([line("GET https://music.myserver.com/rest/ping?u=joe&t=abc&s=xyz failed")])
        XCTAssertFalse(out.contains("music.myserver.com"), "the server host must be redacted")
        XCTAssertFalse(out.contains("t=abc"), "Subsonic auth params must be redacted")
        XCTAssertTrue(out.contains("<redacted-url>") || out.contains("<redacted"), "should show a redaction marker")
    }

    func testExportRedactsLANIPAndHomePath() {
        let out = Diagnostics.format([line("connect 192.0.2.6 wrote /Users/anatoli/Music/x.flac")])
        XCTAssertFalse(out.contains("192.0.2.6"))
        XCTAssertFalse(out.contains("/Users/anatoli"))
    }

    func testWriteExportProducesAReadableFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(Diagnostics.writeExport("body text", now: Date(timeIntervalSince1970: 1_700_000_000), directory: dir))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "body text")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("baton-diagnostics-"))
    }
}
