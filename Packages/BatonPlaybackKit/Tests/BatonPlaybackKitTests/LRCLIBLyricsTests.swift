import XCTest
@testable import BatonPlaybackKit

/// Parsing lyrics nobody wrote for us.
///
/// The LRC format is decades old and produced by dozens of tools, so the input is not
/// trustworthy — which makes the *failure* behaviour the interesting part: a malformed
/// timestamp must not delete its line, and metadata tags must not become lyrics.
final class LRCLIBLyricsTests: XCTestCase {
    func testSyncedLyricsCarryTheirTimestamps() throws {
        let lines = try XCTUnwrap(LRCLIBLyrics.parseLRC("""
        [00:12.00]First line
        [00:17.20]Second line
        [01:02.50]Third line
        """))
        XCTAssertEqual(lines.map(\.text), ["First line", "Second line", "Third line"])
        XCTAssertEqual(lines[0].start, 12)
        XCTAssertEqual(lines[1].start ?? 0, 17.2, accuracy: 0.001)
        XCTAssertEqual(lines[2].start ?? 0, 62.5, accuracy: 0.001)
    }

    /// `[ar: …]`, `[length: …]` and friends are metadata. Rendering them as the first two
    /// lines of a song is the classic LRC parsing bug.
    func testMetadataTagsAreNotLyrics() throws {
        let lines = try XCTUnwrap(LRCLIBLyrics.parseLRC("""
        [ar:Some Artist]
        [length:03:21]
        [00:10.00]Actual words
        """))
        XCTAssertEqual(lines.map(\.text), ["Actual words"])
    }

    func testPlainLyricsAreUsedWhenThereAreNoSyncedOnes() throws {
        let json = #"{"plainLyrics":"one\ntwo","syncedLyrics":null}"#.data(using: .utf8)!
        let parsed = try XCTUnwrap(LRCLIBLyrics.parse(json))
        XCTAssertFalse(parsed.synced)
        XCTAssertEqual(parsed.lines.map(\.text), ["one", "two"])
    }

    /// Synced beats plain when both are offered — the scroll-along is the point.
    func testSyncedIsPreferredOverPlain() throws {
        let json = #"{"plainLyrics":"flat","syncedLyrics":"[00:01.00]timed"}"#.data(using: .utf8)!
        let parsed = try XCTUnwrap(LRCLIBLyrics.parse(json))
        XCTAssertTrue(parsed.synced)
        XCTAssertEqual(parsed.lines.map(\.text), ["timed"])
    }

    func testAnEmptyOrUselessResponseIsNothingRatherThanBlankLyrics() {
        XCTAssertNil(LRCLIBLyrics.parse(#"{"plainLyrics":"","syncedLyrics":""}"#.data(using: .utf8)!))
        XCTAssertNil(LRCLIBLyrics.parse(Data("not json".utf8)))
    }

    /// Off unless asked for. This is the one lookup that leaves the user's own server.
    func testTheFallbackIsOptInByDefault() {
        UserDefaults.standard.removeObject(forKey: LRCLIBLyrics.enabledKey)
        XCTAssertFalse(LRCLIBLyrics.isEnabled)
    }
}
