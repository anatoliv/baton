import BatonSubsonicModels
import XCTest
@testable import BatonSpeech

/// The response-reading half of `TranscriptionService`: which shape of `verbose_json` the
/// segments were found in, what the recognizer returning nothing useful means, and what a
/// model list looks like from two servers that disagree about its shape.
///
/// **The multipart body builder is deliberately not here.** `multipartBody` and
/// `writeMultipartBody` are being changed under TBX-5351 at the same time as this card, and
/// two suites asserting the same wire format byte for byte, written an hour apart, is how
/// one of them ends up merged as a stale contradiction of the other. The wire format is
/// already asserted in the macOS target's `TranscriptionServiceTests`; that card owns it.
final class TranscriptionResponseTests: XCTestCase {
    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func segments(count: Int, text: String, each seconds: Double = 5) -> [[String: Any]] {
        (0 ..< count).map { index in
            ["start": Double(index) * seconds, "end": Double(index + 1) * seconds, "text": text]
        }
    }

    // MARK: - Which shape the segments arrived in

    /// OpenAI's `verbose_json` puts the array at the top level.
    func testFlatSegmentsAreFound() throws {
        let found = try XCTUnwrap(TranscriptionService.segmentArray(in: [
            "segments": [["start": 0, "end": 1, "text": "hello"]],
        ]))
        XCTAssertEqual(found.count, 1)
    }

    /// WhisperX nests it a level deeper, alongside a `word_segments` sibling. Both were seen
    /// on the same machine, so this reads the shape rather than the vendor: without it a
    /// WhisperX server falls through to the plain-text branch and every timing is silently
    /// lost, which costs the highlight, tap-to-seek and summarizing on real boundaries.
    func testNestedWhisperXSegmentsAreFound() throws {
        let found = try XCTUnwrap(TranscriptionService.segmentArray(in: [
            "segments": ["segments": [["start": 0, "end": 1, "text": "hello"]],
                         "word_segments": []],
        ]))
        XCTAssertEqual(found.count, 1)
    }

    func testAResponseWithNoSegmentsAtAllReportsNone() {
        XCTAssertNil(TranscriptionService.segmentArray(in: ["text": "hello"]))
        XCTAssertNil(TranscriptionService.segmentArray(in: ["segments": "not an array"]))
    }

    // MARK: - Parsing

    func testATimedResponseParsesSyncedAndInOrder() throws {
        let data = json([
            "language": "en", "duration": 30.0, "model": "large-v3",
            "segments": [["start": 10.0, "end": 12.0, "text": " the second thing "],
                         ["start": 0.0, "end": 4.0, "text": "the first thing"]],
        ])
        let transcript = try TranscriptionService.parse(data, trackID: "t-1", fallbackModel: "whisper-1")
        XCTAssertTrue(transcript.synced)
        XCTAssertEqual(transcript.trackID, "t-1")
        XCTAssertEqual(transcript.language, "en")
        XCTAssertEqual(transcript.model, "large-v3", "the server's own model name wins")
        XCTAssertEqual(transcript.segments.map(\.start), [0.0, 10.0], "segments come back in time order")
        XCTAssertEqual(transcript.segments.first?.text, "the first thing", "text is trimmed")
    }

    func testTheFallbackModelIsUsedWhenTheServerNamesNone() throws {
        let data = json(["duration": 20.0, "segments": [["start": 0.0, "end": 8.0, "text": "words"]]])
        let transcript = try TranscriptionService.parse(data, trackID: "t", fallbackModel: "whisper-1")
        XCTAssertEqual(transcript.model, "whisper-1")
    }

    /// A segment with no `start` has no timing, and an invented one would seek to the wrong
    /// place and look like a bug in the player.
    func testSegmentsWithNoStartAreDropped() throws {
        let data = json([
            "duration": 20.0,
            "segments": [["end": 4.0, "text": "no start"], ["start": 0.0, "end": 8.0, "text": "kept"]],
        ])
        let transcript = try TranscriptionService.parse(data, trackID: "t", fallbackModel: "m")
        XCTAssertEqual(transcript.segments.map(\.text), ["kept"])
    }

    /// A server returning plain `json` gives text and no timings. Worth reading, so it is
    /// kept, but marked `synced: false` so nothing downstream pretends to a timing it lacks.
    func testAPlainTextResponseIsKeptAsOneUnsyncedSegment() throws {
        let transcript = try TranscriptionService.parse(
            json(["text": "  the whole thing  ", "duration": 42.0]),
            trackID: "t", fallbackModel: "whisper-1")
        XCTAssertFalse(transcript.synced)
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments.first?.text, "the whole thing")
        XCTAssertEqual(transcript.segments.first?.end, 42.0, "the one segment spans the track")
    }

    /// A response that parsed and was then stripped to nothing is a track with no speech in
    /// it, and must not fall through to `text`: that field still holds every invented word.
    func testAResponseStrippedToNothingDoesNotFallBackToTheInventedText() {
        let data = json([
            "duration": 45.0,
            "text": "Yeah. Yeah. Yeah. Yeah. Yeah. Yeah.",
            "segments": segments(count: 12, text: "Yeah.", each: 3),
        ])
        XCTAssertThrowsError(try TranscriptionService.parse(data, trackID: "t", fallbackModel: "m")) {
            let error = $0 as? TranscriptionService.TranscribeError
            XCTAssertEqual(error?.isEmptyOfSpeech, true, "no speech is not a fault")
            XCTAssertEqual(error?.isUnreachable, false)
        }
    }

    /// An empty `text` and no segments is the same answer, reported the same way.
    func testAnEmptyResponseIsEmptyOfSpeechRatherThanAFailure() {
        XCTAssertThrowsError(try TranscriptionService.parse(
            json(["text": "   "]), trackID: "t", fallbackModel: "m")) {
            XCTAssertEqual(($0 as? TranscriptionService.TranscribeError)?.isEmptyOfSpeech, true)
        }
    }

    /// A single 1.7-second fragment of a seven-minute song is not a transcript of it. The
    /// rule is a tenth of the running time, and only for tracks over a minute.
    func testATinySliceOfALongTrackIsRefusedAsTooSparse() {
        let data = json([
            "duration": 420.0,
            "segments": [["start": 12.0, "end": 13.7, "text": "riders on the storm"]],
        ])
        XCTAssertThrowsError(try TranscriptionService.parse(data, trackID: "t", fallbackModel: "m")) {
            XCTAssertEqual(($0 as? TranscriptionService.TranscribeError)?.isEmptyOfSpeech, true)
        }
    }

    /// The same slice on a short clip is fine: a ratio is not a judgement anybody can make
    /// about ten seconds of audio.
    func testAShortClipIsNotJudgedOnTheSparsenessRatio() throws {
        let data = json(["duration": 30.0, "segments": [["start": 1.0, "end": 2.0, "text": "hello"]]])
        let transcript = try TranscriptionService.parse(data, trackID: "t", fallbackModel: "m")
        XCTAssertTrue(transcript.synced)
    }

    func testSomethingThatIsNotJSONIsAPlainFailureNotAnEmptyTrack() {
        XCTAssertThrowsError(try TranscriptionService.parse(
            Data("<html>502</html>".utf8), trackID: "t", fallbackModel: "m")) {
            let error = $0 as? TranscriptionService.TranscribeError
            XCTAssertEqual(error?.isEmptyOfSpeech, false)
            XCTAssertEqual(error?.isUnreachable, false)
        }
    }

    /// The recognizer-facing names delegate to the rules on `Transcript`, which is the only
    /// place both the parser and the store can reach. If they ever stop agreeing, one of the
    /// two callers is quietly using a different definition of "nothing was said".
    func testTheSparseAndDegenerateHelpersAgreeWithTheModelsOwnRules() {
        let looping = (0 ..< 12).map { Transcript.Segment(start: Double($0), end: Double($0) + 1, text: "I") }
        XCTAssertEqual(TranscriptionService.isDegenerate(looping),
                       Transcript.isDegenerate(looping))
        XCTAssertTrue(TranscriptionService.isDegenerate(looping))

        let thin = [Transcript.Segment(start: 0, end: 2, text: "a line")]
        XCTAssertEqual(TranscriptionService.isTooSparse(thin, duration: 300),
                       Transcript.isTooSparse(thin, duration: 300))
        XCTAssertTrue(TranscriptionService.isTooSparse(thin, duration: 300))
        XCTAssertFalse(TranscriptionService.isTooSparse(thin, duration: nil),
                       "with no duration there is no ratio to judge")
    }

    // MARK: - Model lists

    /// OpenAI returns `{"data":[{"id":…}]}`; WhisperX returns `{"models":["large-v3"]}`.
    func testBothModelListShapesAreRead() throws {
        let openAI = try XCTUnwrap(TranscriptionService.modelIDs(
            in: json(["data": [["id": "whisper-1"], ["id": "large-v3"]]])))
        XCTAssertEqual(openAI.sorted(), ["large-v3", "whisper-1"])

        let plain = try XCTUnwrap(TranscriptionService.modelIDs(
            in: json(["models": ["large-v3", "medium"]])))
        XCTAssertEqual(plain.sorted(), ["large-v3", "medium"])
    }

    func testAnEntryNamedRatherThanIdentifiedIsStillAModel() throws {
        let ids = try XCTUnwrap(TranscriptionService.modelIDs(in: json(["models": [["name": "large-v3"]]])))
        XCTAssertEqual(ids, ["large-v3"])
    }

    /// Nil rather than an empty array, because the caller uses that to decide whether to try
    /// the second path (`/models/list`) before giving up on the host.
    func testAnUnrecognisedOrEmptyListReportsNilSoTheOtherPathIsTried() {
        XCTAssertNil(TranscriptionService.modelIDs(in: json(["ok": true])))
        XCTAssertNil(TranscriptionService.modelIDs(in: json(["models": []])))
        XCTAssertNil(TranscriptionService.modelIDs(in: json(["models": [42, ["no": "id"]]])))
        XCTAssertNil(TranscriptionService.modelIDs(in: Data("not json".utf8)))
    }

    // MARK: - Error shape

    /// Three states, and the UI says something different for each: "unavailable" for an
    /// off-network phone, "no speech" for an instrumental, "failed" for everything else.
    func testTheThreeErrorStatesAreDistinguishable() {
        let plain = TranscriptionService.TranscribeError(message: "boom")
        XCTAssertFalse(plain.isUnreachable)
        XCTAssertFalse(plain.isEmptyOfSpeech)
        XCTAssertEqual(plain.errorDescription, "boom")
        XCTAssertEqual(plain.localizedDescription, "boom")

        XCTAssertTrue(TranscriptionService.TranscribeError(message: "x", isUnreachable: true).isUnreachable)
        XCTAssertTrue(TranscriptionService.TranscribeError(message: "x", isEmptyOfSpeech: true).isEmptyOfSpeech)
    }

    /// Generous on purpose: a 90-minute episode is a large upload followed by a GPU pass.
    func testTheRequestTimeoutIsTheOneChosenForALongEpisode() {
        XCTAssertEqual(TranscriptionService.requestTimeout, 900, accuracy: 0.0001)
    }
}
