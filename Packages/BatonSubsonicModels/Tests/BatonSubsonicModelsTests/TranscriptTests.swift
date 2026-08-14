import XCTest
@testable import BatonSubsonicModels

/// The `Transcript` model's three load-bearing behaviours: it renders as timed text for the
/// lyrics views, it windows so an agent never receives an hour of prose, and it resolves the
/// karaoke highlight. See `specs/track-transcription.md`.
final class TranscriptTests: XCTestCase {
    private func sample() -> Transcript {
        Transcript(
            trackID: "ep-1",
            segments: [
                .init(start: 0, end: 4, text: "Welcome back to the show."),
                .init(start: 4, end: 9, text: "Today we're talking about storage."),
                .init(start: 30, end: 36, text: "Which brings us to backups."),
            ],
            language: "en",
            model: "whisper-1",
            duration: 36
        )
    }

    func testRendersAsSyncedTimedText() {
        let lyrics = sample().asLyrics
        XCTAssertTrue(lyrics.synced)
        XCTAssertEqual(lyrics.lines.count, 3)
        XCTAssertEqual(lyrics.lines[1].start, 4)
        XCTAssertEqual(lyrics.lines[1].text, "Today we're talking about storage.")
    }

    /// An unsynced transcript must not hand out timings it doesn't have: a fabricated start
    /// would seek to the wrong place and read as a player bug rather than a missing timestamp.
    func testUnsyncedTranscriptCarriesNoLineTimings() {
        var transcript = sample()
        transcript.synced = false
        let lyrics = transcript.asLyrics
        XCTAssertFalse(lyrics.synced)
        XCTAssertTrue(lyrics.lines.allSatisfy { $0.start == nil })
    }

    func testWindowKeepsSegmentsStraddlingTheBoundary() {
        // 4...9 starts before the window and ends inside it — cutting the sentence in half to
        // satisfy the interval would help nobody, so it comes back whole.
        let window = sample().segments(from: 6, to: 31)
        XCTAssertEqual(window.count, 2)
        XCTAssertEqual(window.first?.start, 4)
        XCTAssertEqual(window.last?.start, 30)
    }

    func testWindowWithInvertedRangeIsEmptyRatherThanEverything() {
        XCTAssertTrue(sample().segments(from: 40, to: 10).isEmpty)
    }

    /// The highlight holds through the gap between segments (9s → 30s here) instead of
    /// blinking off, which is why this tracks "last segment started" not "segment containing".
    func testHighlightHoldsThroughTheGapBetweenSegments() {
        let transcript = sample()
        XCTAssertEqual(transcript.segmentIndex(at: 0), 0)
        XCTAssertEqual(transcript.segmentIndex(at: 5), 1)
        XCTAssertEqual(transcript.segmentIndex(at: 20), 1, "still on line 2 during the silence")
        XCTAssertEqual(transcript.segmentIndex(at: 31), 2)
    }

    func testHighlightIsAbsentBeforeTheFirstSegmentAndWhenUnsynced() {
        var transcript = sample()
        transcript.segments[0].start = 2
        XCTAssertNil(transcript.segmentIndex(at: 1))

        transcript.synced = false
        XCTAssertNil(transcript.segmentIndex(at: 40))
    }

    func testRoundTripsThroughCodableWithItsSummary() throws {
        var transcript = sample()
        transcript.summary = Summary(
            overview: "A show about storage.",
            sections: [.init(start: 0, end: 30, title: "Intro", text: "Hellos.")],
            model: "chat"
        )
        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(decoded.segments, transcript.segments)
        XCTAssertEqual(decoded.summary?.sections.first?.title, "Intro")
        XCTAssertEqual(decoded.trackID, "ep-1")
    }

    func testPlainTextJoinsSegmentsForTheSummarizer() {
        XCTAssertEqual(
            sample().plainText,
            "Welcome back to the show. Today we're talking about storage. Which brings us to backups."
        )
    }
}
