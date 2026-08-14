import XCTest
@testable import Baton
import BatonSubsonicModels

/// The transcript MCP tools. Their job is to give an agent what was said *without* handing it
/// an hour of prose, and to keep "never transcribed" distinguishable from "the host is down".
/// See `specs/track-transcription.md`.
@MainActor
final class MCPTranscriptToolsTests: XCTestCase {
    private var directory: URL!
    private var savedStore: TranscriptStore!
    private var savedCoordinator: TranscriptionCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-mcp-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The tools reach the shared instances by design; point those at a temp directory so
        // the suite never touches the real transcripts.
        savedStore = TranscriptStore.shared
        savedCoordinator = TranscriptionCoordinator.shared
        TranscriptStore.shared = TranscriptStore(directory: directory)
        TranscriptionCoordinator.shared = TranscriptionCoordinator(store: .shared)
    }

    override func tearDown() async throws {
        TranscriptStore.shared = savedStore
        TranscriptionCoordinator.shared = savedCoordinator
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func longTranscript(id: String = "ep-1", segments count: Int = 300) -> Transcript {
        Transcript(
            trackID: id,
            segments: (0 ..< count).map { index in
                .init(start: Double(index) * 10, end: Double(index) * 10 + 10, text: "line \(index)")
            },
            language: "en",
            model: "whisper-1",
            duration: Double(count) * 10
        )
    }

    // MARK: - Schema

    func testBothToolsAreCallableWithNoArguments() throws {
        let catalog = BatonMCPToolCatalog.definitions()
            .reduce(into: [String: [String: Any]]()) { out, def in
                if let name = def["name"] as? String { out[name] = def }
            }
        for name in ["music_transcript", "music_summarize_track"] {
            let tool = try XCTUnwrap(catalog[name], "\(name) is missing from the catalog")
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let required = schema["required"] as? [String] ?? []
            XCTAssertTrue(required.isEmpty, "\(name) should default to the current track")
        }
    }

    /// `music_summarize_track` with `create: true` spends model calls and writes to the store,
    /// so it must not claim to be read-only.
    func testOnlyTheReadingToolClaimsReadOnly() throws {
        let catalog = BatonMCPToolCatalog.definitions()
            .reduce(into: [String: [String: Any]]()) { out, def in
                if let name = def["name"] as? String { out[name] = def }
            }
        let read = (catalog["music_transcript"]?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool
        let write = (catalog["music_summarize_track"]?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool
        XCTAssertEqual(read, true)
        XCTAssertNotEqual(write, true, "create:true writes a summary")
    }

    // MARK: - music_transcript

    func testAnUntranscribedTrackSaysSoRatherThanReturningNothing() throws {
        let music = MusicModel(environment: .testing)
        let text = try BatonMCPTranscriptTools.transcript(["song_id": "never-seen"], music)
        let out = try json(text)

        XCTAssertEqual(out["transcribed"] as? Bool, false)
        XCTAssertEqual(out["reason"] as? String, "not_transcribed")
    }

    /// An agent that conflates "no transcript" with "the host is down" will tell someone their
    /// episode has no speech in it.
    func testAnUnreachableHostIsReportedAsUnavailableNotAsAnAbsence() throws {
        let music = MusicModel(environment: .testing)
        TranscriptStore.shared.finishWork(
            on: "ep-down", failure: .init(message: "Couldn't reach the transcription service", isUnavailable: true)
        )

        let out = try json(try BatonMCPTranscriptTools.transcript(["song_id": "ep-down"], music))

        XCTAssertEqual(out["transcribed"] as? Bool, false)
        XCTAssertEqual(out["reason"] as? String, "unavailable")
        XCTAssertTrue((out["detail"] as? String)?.contains("reach") == true)
    }

    func testATranscriptComesBackWindowedAndTimestamped() throws {
        let music = MusicModel(environment: .testing)
        TranscriptStore.shared.save(longTranscript())

        let out = try json(try BatonMCPTranscriptTools.transcript(
            ["song_id": "ep-1", "from_seconds": 100.0, "to_seconds": 160.0], music
        ))

        XCTAssertEqual(out["transcribed"] as? Bool, true)
        XCTAssertEqual(out["segment_count"] as? Int, 300)
        let lines = try XCTUnwrap(out["lines"] as? [[String: Any]])
        // Eight, not seven: line 9 runs 90–100s and so straddles the near edge, which the
        // window keeps deliberately rather than cutting a sentence in half.
        XCTAssertEqual(lines.count, 8)
        XCTAssertEqual(lines.first?["text"] as? String, "line 9")
        XCTAssertEqual(lines.first?["timestamp"] as? String, "1:30")
        XCTAssertEqual(lines.last?["text"] as? String, "line 16")
    }

    /// The cap must announce itself: a window that quietly stops is how an agent concludes a
    /// topic was never mentioned again.
    func testAnOversizedWindowIsCappedAndSaysSo() throws {
        let music = MusicModel(environment: .testing)
        TranscriptStore.shared.save(longTranscript())

        let out = try json(try BatonMCPTranscriptTools.transcript(["song_id": "ep-1"], music))

        let lines = try XCTUnwrap(out["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, BatonMCPTranscriptTools.maxSegments)
        XCTAssertEqual(out["truncated"] as? Bool, true)
        XCTAssertTrue((out["truncated_note"] as? String)?.contains("300") == true)
    }

    func testWithNothingPlayingAndNoSongIDTheToolAsksForOne() {
        let music = MusicModel(environment: .testing)
        XCTAssertThrowsError(try BatonMCPTranscriptTools.transcript([:], music)) { error in
            XCTAssertTrue((error as? BatonMCPToolError)?.message.contains("song_id") == true)
        }
    }

    // MARK: - music_summarize_track

    func testSummarizingAnUntranscribedTrackReportsThatFirst() async throws {
        let music = MusicModel(environment: .testing)
        let out = try json(try await BatonMCPTranscriptTools.summarize(
            ["song_id": "never-seen"], music, naturalLanguage: nil
        ))
        XCTAssertEqual(out["summarized"] as? Bool, false)
        XCTAssertEqual(out["reason"] as? String, "not_transcribed")
    }

    /// Writing a summary costs several model calls, so it never happens as a side effect of
    /// asking whether one exists.
    func testAMissingSummaryIsNotWrittenWithoutCreate() async throws {
        let music = MusicModel(environment: .testing)
        TranscriptStore.shared.save(longTranscript(segments: 3))

        let out = try json(try await BatonMCPTranscriptTools.summarize(
            ["song_id": "ep-1"], music, naturalLanguage: nil
        ))

        XCTAssertEqual(out["summarized"] as? Bool, false)
        XCTAssertEqual(out["reason"] as? String, "no_summary")
        XCTAssertTrue((out["detail"] as? String)?.contains("create: true") == true)
    }

    func testAnExistingSummaryComesBackAsTimestampedSections() async throws {
        let music = MusicModel(environment: .testing)
        var transcript = longTranscript(segments: 3)
        transcript.summary = Summary(
            overview: "Storage, mostly.",
            sections: [
                .init(start: 0, end: 60, title: "Intro", text: "Hellos."),
                .init(start: 3600, end: 3660, title: "Backups", text: "RAID is not one."),
            ],
            model: "chat"
        )
        TranscriptStore.shared.save(transcript)

        let out = try json(try await BatonMCPTranscriptTools.summarize(
            ["song_id": "ep-1"], music, naturalLanguage: nil
        ))

        XCTAssertEqual(out["summarized"] as? Bool, true)
        XCTAssertEqual(out["overview"] as? String, "Storage, mostly.")
        let sections = try XCTUnwrap(out["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.last?["timestamp"] as? String, "1:00:00")
        XCTAssertEqual(sections.last?["title"] as? String, "Backups")
    }

    func testCreatingASummaryWithNoModelConfiguredSaysSo() async throws {
        let music = MusicModel(environment: .testing)
        TranscriptStore.shared.save(longTranscript(segments: 3))

        let out = try json(try await BatonMCPTranscriptTools.summarize(
            ["song_id": "ep-1", "create": true], music, naturalLanguage: nil
        ))

        XCTAssertEqual(out["summarized"] as? Bool, false)
        XCTAssertEqual(out["reason"] as? String, "no_model")
    }
}
