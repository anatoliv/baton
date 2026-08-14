import XCTest
@testable import BatonAgentKit
import BatonSubsonicModels

/// The summarizer's three jobs: chunk without losing anything, refuse to ship a transcript to
/// a stranger, and survive a small model that ignores the reply format.
/// See `specs/track-transcription.md`.
final class TranscriptSummarizerTests: XCTestCase {
    // MARK: - Chunking

    /// A synthetic hour, sized like real speech (~150 words/min), against the 8k-context
    /// budget the local models actually have. This is the acceptance criterion that the
    /// chunking is real rather than aspirational.
    private func hourLongTranscript() -> Transcript {
        // 360 segments of ten seconds each = 3600s. ~25 words per segment ≈ 150 wpm.
        let words = "and so the thing about running your own storage is that nobody else is going "
            + "to come and fix it for you at two in the morning when it breaks"
        let segments = (0 ..< 360).map { index in
            Transcript.Segment(start: Double(index) * 10, end: Double(index) * 10 + 10, text: words)
        }
        return Transcript(trackID: "ep-hour", segments: segments, duration: 3600)
    }

    func testAnHourChunksIntoWindowsThatFitASmallContext() {
        let transcript = hourLongTranscript()
        let chunks = TranscriptSummarizer.chunks(from: transcript)

        XCTAssertGreaterThanOrEqual(chunks.count, 6, "an hour must not be one call")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(
                chunk.text.count,
                TranscriptSummarizer.defaultMaxCharacters + 200,
                "a window must fit the budget (one oversized segment aside)"
            )
        }
        // Nothing lost: every segment's text is accounted for across the windows.
        let rejoined = chunks.map(\.text).joined(separator: " ")
        XCTAssertEqual(rejoined.count, transcript.plainText.count)
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertEqual(chunks.last?.end, 3600)
    }

    func testWindowsAreContiguousAndOrdered() {
        let chunks = TranscriptSummarizer.chunks(from: hourLongTranscript())
        for (earlier, later) in zip(chunks, chunks.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.end, later.start + 0.001, "windows must not overlap")
            XCTAssertLessThan(earlier.start, later.start)
        }
    }

    /// Never mid-segment: a sentence cut in half summarizes badly and its timestamps stop
    /// meaning anything.
    func testChunksSplitOnSegmentBoundariesOnly() {
        let transcript = Transcript(trackID: "x", segments: [
            .init(start: 0, end: 5, text: "alpha"),
            .init(start: 5, end: 10, text: "bravo"),
            .init(start: 10, end: 15, text: "charlie"),
        ])
        // A 10s window fits two 5s segments exactly; the third would push past it.
        let chunks = TranscriptSummarizer.chunks(from: transcript, windowSeconds: 10, maxCharacters: 10_000)
        XCTAssertEqual(chunks.map(\.text), ["alpha bravo", "charlie"])
        XCTAssertEqual(chunks.first?.end, 10, "a window ends where its last segment ends")
    }

    /// The window is a ceiling, not a target: a segment that would push past it starts the
    /// next window instead of overflowing this one. With 5s segments and a 7s window that
    /// means one segment each — short windows, but never a window that overruns its budget.
    func testAWindowIsNeverExceededEvenWhenThatMakesItShort() {
        let transcript = Transcript(trackID: "x", segments: [
            .init(start: 0, end: 5, text: "alpha"),
            .init(start: 5, end: 10, text: "bravo"),
        ])
        let chunks = TranscriptSummarizer.chunks(from: transcript, windowSeconds: 7, maxCharacters: 10_000)
        XCTAssertEqual(chunks.map(\.text), ["alpha", "bravo"])
    }

    /// Dropping content silently would be worse than one oversized call.
    func testASingleOversizedSegmentIsEmittedRatherThanDropped() {
        let huge = String(repeating: "x", count: 9_000)
        let transcript = Transcript(trackID: "x", segments: [
            .init(start: 0, end: 5, text: "small"),
            .init(start: 5, end: 600, text: huge),
        ])
        let chunks = TranscriptSummarizer.chunks(from: transcript, maxCharacters: 100)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.last?.text, huge)
    }

    func testAnEmptyTranscriptChunksToNothing() {
        XCTAssertTrue(TranscriptSummarizer.chunks(from: Transcript(trackID: "x", segments: [])).isEmpty)
    }

    // MARK: - Consent gate

    private func config(baseURL: String, provider: RemoteControlSettings.LLMProvider = .openAICompatible)
        -> RemoteControlSettings.NaturalLanguageConfig
    {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.provider = provider
        config.baseURL = baseURL
        config.model = "chat"
        config.apiKey = "k"
        return config
    }

    func testALANEndpointNeedsNoConsent() {
        XCTAssertTrue(TranscriptSummarizer.isLocalEndpoint(config(baseURL: "http://192.168.4.21:8000/v1")))
        XCTAssertTrue(TranscriptSummarizer.isLocalEndpoint(config(baseURL: "http://localhost:8000/v1")))
        XCTAssertTrue(TranscriptSummarizer.isLocalEndpoint(config(baseURL: "http://mediabox.local:8000/v1")))
    }

    func testAHostedEndpointIsNotLocal() {
        XCTAssertFalse(TranscriptSummarizer.isLocalEndpoint(config(baseURL: "https://api.anthropic.com")))
        XCTAssertFalse(TranscriptSummarizer.isLocalEndpoint(config(baseURL: "https://api.openai.com/v1")))
    }

    /// A transcript is the full content of what someone listened to. It does not leave the
    /// network on the strength of a setting made for something else.
    func testSummarizingToAHostedEndpointWithoutConsentIsRefused() async {
        let transcript = Transcript(trackID: "x", segments: [.init(start: 0, end: 5, text: "hello")])
        do {
            _ = try await TranscriptSummarizer.summarize(
                transcript, config: config(baseURL: "https://api.anthropic.com", provider: .anthropic)
            )
            XCTFail("a hosted endpoint without consent should be refused")
        } catch let error as TranscriptSummarizer.SummaryError {
            XCTAssertTrue(error.needsConsent)
            XCTAssertTrue(error.message.contains("isn't on your network"), "got: \(error.message)")
        } catch {
            XCTFail("expected SummaryError, got \(error)")
        }
    }

    func testSummarizingAnEmptyTranscriptFailsBeforeAnyNetworkCall() async {
        do {
            _ = try await TranscriptSummarizer.summarize(
                Transcript(trackID: "x", segments: []), config: config(baseURL: "http://127.0.0.1:8000/v1")
            )
            XCTFail("nothing to summarize should throw")
        } catch let error as TranscriptSummarizer.SummaryError {
            XCTAssertFalse(error.needsConsent)
        } catch {
            XCTFail("expected SummaryError, got \(error)")
        }
    }

    func testSummarizingWithNoModelConfiguredSaysWhereToSetOneUp() async {
        var unconfigured = config(baseURL: "http://127.0.0.1:8000/v1")
        unconfigured.isEnabled = false
        let transcript = Transcript(trackID: "x", segments: [.init(start: 0, end: 5, text: "hello")])
        do {
            _ = try await TranscriptSummarizer.summarize(transcript, config: unconfigured)
            XCTFail("an unconfigured model should throw")
        } catch let error as TranscriptSummarizer.SummaryError {
            XCTAssertTrue(error.message.contains("Settings"), "got: \(error.message)")
        } catch {
            XCTFail("expected SummaryError, got \(error)")
        }
    }

    // MARK: - Reply parsing

    func testParsesTheTitleAndBodyOutOfAWellFormedReply() {
        let (title, text) = TranscriptSummarizer.parseSection("""
        TITLE: Why RAID is not a backup
        They walk through a disk failure that took the array with it. The fix was an offsite copy.
        """)
        XCTAssertEqual(title, "Why RAID is not a backup")
        XCTAssertTrue(text.hasPrefix("They walk through"))
    }

    /// A small model will not always honour the shape. A section with a dull name beats a hole
    /// in the chapter list.
    func testAReplyWithoutATitleKeepsItsTextAndGetsAPlaceholder() {
        let (title, text) = TranscriptSummarizer.parseSection("Just some prose with no title line.")
        XCTAssertEqual(title, "Untitled section")
        XCTAssertEqual(text, "Just some prose with no title line.")
    }

    func testATitleOnlyReplyStillProducesAUsableSection() {
        let (title, text) = TranscriptSummarizer.parseSection("TITLE: Backups\n")
        XCTAssertEqual(title, "Backups")
        XCTAssertEqual(text, "Backups", "a section must never render blank")
    }

    // MARK: - Response extraction

    func testExtractsTextFromAnOpenAICompatibleReply() {
        let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"hello there"}}]}"#.utf8)
        XCTAssertEqual(TranscriptSummarizer.extractText(data, provider: .openAICompatible), "hello there")
    }

    func testExtractsTextFromAnAnthropicReply() {
        let data = Data(#"{"content":[{"type":"text","text":"hello"},{"type":"text","text":" there"}]}"#.utf8)
        XCTAssertEqual(TranscriptSummarizer.extractText(data, provider: .anthropic), "hello there")
    }

    func testExtractsNothingFromAnEmptyOrWrongShapedReply() {
        XCTAssertNil(TranscriptSummarizer.extractText(Data(#"{"choices":[]}"#.utf8), provider: .openAICompatible))
        XCTAssertNil(TranscriptSummarizer.extractText(Data("nonsense".utf8), provider: .anthropic))
    }

    // MARK: - Timestamps

    func testTimestampsReadTheWayAPersonReadsAPositionInAnEpisode() {
        XCTAssertEqual(TranscriptSummarizer.timestamp(0), "0:00")
        XCTAssertEqual(TranscriptSummarizer.timestamp(75), "1:15")
        XCTAssertEqual(TranscriptSummarizer.timestamp(3600), "1:00:00")
        XCTAssertEqual(TranscriptSummarizer.timestamp(3725), "1:02:05")
    }
}
