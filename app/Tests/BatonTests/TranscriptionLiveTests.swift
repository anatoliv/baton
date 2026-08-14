import XCTest
@testable import Baton

/// Real audio, a real recognizer, end to end. **Skipped unless configured.**
///
/// Every other transcription test runs against a stubbed transport, which proves the request
/// shaping and the parsing but cannot answer the question that actually mattered: does a real
/// server return the shape this code was written against? It did not. `speaches` returns
/// OpenAI `verbose_json` with segments at the top level; WhisperX nests them under
/// `segments.segments`, and against that the parser quietly produced one untimed blob. Both
/// were running on the same machine. A stub written from a spec agrees with the spec.
///
/// Enable it by writing `~/.baton-live-asr.json`, then deleting it afterwards:
///
///     umask 077 && cat > ~/.baton-live-asr.json <<EOF
///     {"base":"http://127.0.0.1:8181","model":"deepdml/faster-whisper-large-v3-turbo-ct2"}
///     EOF
///     ./scripts/test.sh -only-testing:BatonTests/TranscriptionLiveTests
///     rm -f ~/.baton-live-asr.json
///
/// A file rather than an environment variable, for the reason `RemoteAgentLiveTests` gives:
/// environment variables do not reach an app-hosted test process. The host stays out of the
/// repo either way, which the publish guard requires.
///
/// The skip is the same judgement the conversation eval makes about its model host: an
/// environment that cannot give a measurement is *not measurable*, not broken.
@MainActor
final class TranscriptionLiveTests: XCTestCase {
    private struct Live {
        var base: String
        var model: String
    }

    private func live() throws -> Live {
        let path = NSHomeDirectory() + "/.baton-live-asr.json"
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: path),
            "live recognizer not configured — see this file's doc comment"
        )
        guard let data = FileManager.default.contents(atPath: path),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let base = json["base"]
        else { throw XCTSkip("live config at \(path) is unreadable or missing base") }
        return Live(base: base, model: json["model"] ?? "whisper-1")
    }

    override func setUp() {
        super.setUp()
        SpeechConfig.defaults = UserDefaults(suiteName: "asr-live-\(UUID().uuidString)")!
    }

    override func tearDown() {
        SpeechConfig.defaults = .standard
        super.tearDown()
    }

    /// A short spoken clip, synthesized on the fly so the suite carries no audio fixture.
    /// Returns nil when the platform can't produce one, which is a skip rather than a failure.
    private func spokenClip() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let aiff = dir.appendingPathComponent("baton-live-asr-\(UUID().uuidString).aiff")
        let wav = dir.appendingPathComponent("baton-live-asr-\(UUID().uuidString).wav")

        func run(_ launchPath: String, _ args: [String]) -> Int32 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: launchPath)
            task.arguments = args
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return -1 }
            task.waitUntilExit()
            return task.terminationStatus
        }

        let phrase = "Welcome back to the show. Today we are talking about storage, "
            + "and why RAID is not a backup."
        try XCTSkipIf(run("/usr/bin/say", ["-o", aiff.path, phrase]) != 0, "`say` unavailable")
        try XCTSkipIf(
            run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]) != 0,
            "`afconvert` unavailable"
        )
        try? FileManager.default.removeItem(at: aiff)
        return wav
    }

    /// The whole path: spoken audio in, a timed `Transcript` out.
    func testTranscribesRealAudioIntoTimedSegments() async throws {
        let live = try live()
        SpeechConfig.whisperBaseURL = live.base
        SpeechConfig.whisperModel = live.model
        SpeechConfig.transcriptionEnabled = true

        let clip = try spokenClip()
        defer { try? FileManager.default.removeItem(at: clip) }

        let transcript: Transcript
        do {
            transcript = try await TranscriptionService.transcribe(fileURL: clip, trackID: "live-1")
        } catch let error as TranscriptionService.TranscribeError where error.isUnreachable {
            throw XCTSkip("recognizer at \(live.base) isn't answering — not measurable, not broken")
        }

        XCTAssertFalse(transcript.isEmpty, "a spoken clip must produce segments")
        XCTAssertEqual(transcript.trackID, "live-1")

        // The words. Recognizers differ on casing and punctuation, so match on content.
        let text = transcript.plainText.lowercased()
        XCTAssertTrue(text.contains("storage"), "expected the spoken words back, got: \(transcript.plainText)")
        XCTAssertTrue(text.contains("backup"), "expected the spoken words back, got: \(transcript.plainText)")

        // The timings. This is the assertion that would have caught the WhisperX shape: text
        // alone parses fine either way, and only `synced` and real starts tell them apart.
        XCTAssertTrue(transcript.synced, "a verbose_json response must yield timed segments")
        XCTAssertGreaterThan(transcript.segments.count, 0)
        let last = try XCTUnwrap(transcript.segments.last)
        XCTAssertGreaterThan(last.end, 0, "segments must carry real end times")
        XCTAssertEqual(transcript.segments.map(\.start), transcript.segments.map(\.start).sorted())

        // And it must be usable by the two things built on top of it.
        XCTAssertNotNil(transcript.segmentIndex(at: last.start), "the highlight must resolve")
        XCTAssertFalse(TranscriptSummarizer.chunks(from: transcript).isEmpty, "the summarizer must chunk it")
    }

    /// The Settings "Test connection" button, against whatever the host actually serves.
    func testTheHostReportsItsModels() async throws {
        let live = try live()
        SpeechConfig.whisperBaseURL = live.base

        let models: [String]
        do {
            models = try await TranscriptionService.availableModels()
        } catch let error as TranscriptionService.TranscribeError where error.isUnreachable {
            throw XCTSkip("recognizer at \(live.base) isn't answering")
        }
        XCTAssertFalse(models.isEmpty, "a reachable recognizer should name at least one model")
    }
}
