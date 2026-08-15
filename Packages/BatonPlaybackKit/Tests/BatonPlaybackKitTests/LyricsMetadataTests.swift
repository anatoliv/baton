import BatonSubsonicModels
import XCTest
@testable import BatonPlaybackKit

/// An LRC file carries a header about itself, and none of it is something the song says.
///
/// Reported with a screenshot: the Lyrics sheet for "Riders on the Storm" opened with
/// `[offset:-47682]` sitting above the first verse. Navidrome serves whatever is embedded in
/// the file, and `getLyricsBySongId` splits an LRC blob into lines, so the header arrived as
/// lines like any other. LRCLIB's synced parser skipped these on the way past; nothing did for
/// plain lyrics, or for a server's.
///
/// The offset is the interesting one. Dropping it silently discards a real timing correction,
/// and on that file it was 47 seconds — enough to scroll the whole sheet against the wrong
/// part of the song.
final class LyricsMetadataTests: XCTestCase {
    // MARK: - Telling a header tag from a lyric

    func testTheKnownHeaderTagsAreRecognised() {
        for line in ["[offset:-47682]", "[ar: The Doors]", "[ti:Riders on the Storm]",
                     "[al:L.A. Woman]", "[by:someone]", "[length:07:09]", "[tool:lrcedit]"] {
            XCTAssertNotNil(NavidromeLyrics.metadataTag(in: line), "\(line) is file plumbing, not a lyric")
        }
    }

    /// The line that would be lost by a looser rule. People write section markers in lyric
    /// sheets, and a bracket in the middle of a line is just a bracket.
    func testSectionMarkersAndOrdinaryLinesAreNotHeaderTags() {
        for line in ["[Chorus]", "[Verse 2]", "Riders on the storm",
                     "Into this house we're born [x2]", "[unknownkey:value]", "[]", ""] {
            XCTAssertNil(NavidromeLyrics.metadataTag(in: line), "\(line) must survive as a lyric")
        }
    }

    // MARK: - The reported artifact

    /// The shape Navidrome returned: unsynced lines, the header among them.
    func testTheHeaderIsNotShownAsTheFirstLineOfTheSong() {
        let served = NavidromeLyrics(synced: false, lines: [
            .init(text: "[offset:-47682]"),
            .init(text: ""),
            .init(text: "Riders on the storm"),
            .init(text: "Into this house we're born"),
        ])
        let cleaned = served.normalizingLRCMetadata()
        XCTAssertEqual(cleaned.lines.map(\.text), ["", "Riders on the storm", "Into this house we're born"])
        XCTAssertFalse(cleaned.lines.contains { $0.text.contains("offset") })
    }

    /// Synced lyrics keep their timings, shifted by the offset. LRC signs it so that a
    /// negative value means the words come earlier, so it is subtracted.
    func testTheOffsetShiftsTheTimingsRatherThanBeingDiscarded() {
        let synced = NavidromeLyrics(synced: true, lines: [
            .init(text: "[offset:-2000]"),
            .init(start: 60, text: "Riders on the storm"),
            .init(start: 64, text: "Into this house we're born"),
        ])
        let cleaned = synced.normalizingLRCMetadata()
        XCTAssertEqual(cleaned.lines.count, 2)
        XCTAssertEqual(cleaned.lines[0].start ?? 0, 62, accuracy: 0.001)
        XCTAssertEqual(cleaned.lines[1].start ?? 0, 66, accuracy: 0.001)
    }

    /// A large negative offset can push the opening lines before the start of the track, and a
    /// line that wants to highlight at -3 s never highlights at all.
    func testAnOffsetCannotPushALineBeforeTheStartOfTheTrack() {
        let cleaned = NavidromeLyrics(synced: true, lines: [
            .init(text: "[offset:5000]"),
            .init(start: 1, text: "first"),
            .init(start: 30, text: "later"),
        ]).normalizingLRCMetadata()
        XCTAssertEqual(cleaned.lines[0].start, 0)
        XCTAssertEqual(cleaned.lines[1].start ?? 0, 25, accuracy: 0.001)
    }

    func testLyricsWithNoHeaderAreLeftExactlyAsTheyAre() {
        let plain = NavidromeLyrics(synced: false, lines: [.init(text: "a"), .init(text: "b")])
        XCTAssertEqual(plain.normalizingLRCMetadata(), plain)
    }

    // MARK: - Through the two parsers that build lyrics

    /// LRCLIB's plain field. It was never filtered at all, so a header pasted in there was
    /// shown verbatim as the opening lines of the song.
    func testPlainLyricsFromLRCLIBLoseTheirHeader() {
        let lyrics = LRCLIBLyrics.lyrics(
            synced: nil,
            plain: "[ar: The Doors]\n[offset:-47682]\nRiders on the storm\nInto this house we're born"
        )
        XCTAssertEqual(lyrics?.lines.map(\.text), ["Riders on the storm", "Into this house we're born"])
        XCTAssertEqual(lyrics?.synced, false)
    }

    /// And the synced field, where the offset has to survive the parse to be applied.
    func testSyncedLyricsFromLRCLIBApplyTheirOffset() {
        let lyrics = LRCLIBLyrics.lyrics(
            synced: "[ti:Riders on the Storm]\n[offset:-1500]\n[01:00.00] Riders on the storm\n[01:04.00] Into this house we're born",
            plain: nil
        )
        XCTAssertEqual(lyrics?.synced, true)
        XCTAssertEqual(lyrics?.lines.map(\.text), ["Riders on the storm", "Into this house we're born"])
        XCTAssertEqual(lyrics?.lines.first?.start ?? 0, 61.5, accuracy: 0.001)
    }

    /// A file that is nothing but a header is not a lyric sheet. It must fall through to the
    /// plain field rather than returning an empty one, which would read as "no lyrics found"
    /// while a perfectly good plain copy sat unused.
    func testAHeaderOnlySyncedFieldFallsThroughToPlain() {
        let lyrics = LRCLIBLyrics.lyrics(synced: "[ar: The Doors]\n[offset:0]", plain: "Riders on the storm")
        XCTAssertEqual(lyrics?.lines.map(\.text), ["Riders on the storm"])
        XCTAssertEqual(lyrics?.synced, false)
    }

    /// Unchanged behaviour: a bracketed line that is neither a stamp nor a known tag still
    /// disappears rather than being shown as a lyric.
    func testAMalformedStampIsStillDropped() {
        let lyrics = LRCLIBLyrics.lyrics(synced: "[99:99x] nonsense\n[01:00.00] real line", plain: nil)
        XCTAssertEqual(lyrics?.lines.map(\.text), ["real line"])
    }
}
