import XCTest
@testable import Baton

/// `TranscriptionService` request shaping and response handling, against a stubbed transport —
/// the same idiom as `SpeechServiceTests`, for the same reason: no live GPU host in the gate.
/// See `specs/track-transcription.md`.
final class TranscriptionServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SpeechConfig.defaults = UserDefaults(suiteName: "transcribe-\(UUID().uuidString)")!
        SpeechConfig.whisperBaseURL = "https://asr.example.com"
    }

    override func tearDown() {
        NavidromeMockURLProtocol.handler = nil
        SpeechConfig.defaults = .standard
        super.tearDown()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func audioFile(bytes: Int = 32) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-test-\(UUID().uuidString).mp3")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private static let verboseJSON = """
    {"task":"transcribe","language":"en","duration":36.0,"text":"Welcome back. About storage.",
     "segments":[{"id":0,"start":0.0,"end":4.0,"text":" Welcome back."},
                 {"id":1,"start":4.0,"end":9.0,"text":" About storage."}]}
    """

    // MARK: - Transport

    func testTranscribePostsToTheTranscriptionsEndpointAndParsesSegments() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedContentType: String?
        NavidromeMockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedContentType = req.value(forHTTPHeaderField: "Content-Type")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data(Self.verboseJSON.utf8))
        }
        let file = try audioFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let transcript = try await TranscriptionService.transcribe(
            fileURL: file, trackID: "ep-1", session: mockSession()
        )

        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedPath, "/v1/audio/transcriptions", "OpenAI-schema ASR endpoint under the configured host")
        XCTAssertEqual(capturedContentType?.hasPrefix("multipart/form-data; boundary="), true)
        XCTAssertEqual(transcript.trackID, "ep-1")
        XCTAssertTrue(transcript.synced)
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments.first?.text, "Welcome back.", "segment text is trimmed")
        XCTAssertEqual(transcript.language, "en")
        XCTAssertEqual(transcript.duration, 36.0)
    }

    func testTranscribeMapsHTTPErrorToTranscribeError() async throws {
        NavidromeMockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("model loading".utf8))
        }
        let file = try audioFile()
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await TranscriptionService.transcribe(fileURL: file, trackID: "ep-1", session: mockSession())
            XCTFail("a 503 should throw")
        } catch let error as TranscriptionService.TranscribeError {
            XCTAssertTrue(error.message.contains("503"))
            XCTAssertFalse(error.isUnreachable, "the host answered, so this is a failure, not an absence")
        }
    }

    /// The distinction the whole "unavailable, not broken" UI rests on: a host that cannot be
    /// reached is flagged differently from one that answered badly.
    func testUnreachableHostIsFlaggedAsUnreachable() async throws {
        NavidromeMockURLProtocol.handler = nil // the stub fails the load
        let file = try audioFile()
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await TranscriptionService.transcribe(fileURL: file, trackID: "ep-1", session: mockSession())
            XCTFail("an unreachable host should throw")
        } catch let error as TranscriptionService.TranscribeError {
            XCTAssertTrue(error.isUnreachable)
        }
    }

    func testInvalidHostIsRejectedBeforeAnyUpload() async throws {
        SpeechConfig.whisperBaseURL = "not a url"
        let file = try audioFile()
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await TranscriptionService.transcribe(fileURL: file, trackID: "ep-1", session: mockSession())
            XCTFail("an unparseable host should throw")
        } catch let error as TranscriptionService.TranscribeError {
            XCTAssertTrue(error.message.contains("Settings"), "the error should say where to fix it: \(error.message)")
            XCTAssertFalse(error.isUnreachable)
        }
    }

    func testEmptyAudioFileIsRejected() async throws {
        let file = try audioFile(bytes: 0)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await TranscriptionService.transcribe(fileURL: file, trackID: "ep-1", session: mockSession())
            XCTFail("empty audio should throw")
        } catch let error as TranscriptionService.TranscribeError {
            XCTAssertTrue(error.message.contains("empty"))
        }
    }

    // MARK: - Body shaping (pure)

    func testMultipartBodyCarriesTheFieldsAndTheFileBytes() {
        let body = TranscriptionService.multipartBody(
            fields: [("model", "whisper-1"), ("response_format", "verbose_json")],
            fileName: "episode.mp3",
            fileData: Data("AUDIOBYTES".utf8),
            boundary: "BOUNDARY"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("--BOUNDARY\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"episode.mp3\""))
        XCTAssertTrue(text.contains("AUDIOBYTES"))
        XCTAssertTrue(text.hasSuffix("\r\n--BOUNDARY--\r\n"), "a multipart body must be closed by the terminating boundary")
    }

    // MARK: - Parsing (pure)

    /// A server that ignores `verbose_json` still gives readable text. Keep it, but never
    /// pretend it is timed — `synced` false is what stops the UI offering a seek that lies.
    func testPlainJSONWithoutSegmentsParsesAsUnsyncedSingleSegment() throws {
        let data = Data(#"{"text":"just the words","language":"en","duration":12.5}"#.utf8)
        let transcript = try TranscriptionService.parse(data, trackID: "ep-2", fallbackModel: "whisper-1")
        XCTAssertFalse(transcript.synced)
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments.first?.text, "just the words")
        XCTAssertEqual(transcript.model, "whisper-1")
        // And so nothing can be the *current* line: this is what "good text, no highlighting"
        // looks like from the parser's side, since the sheet keys the highlight and the
        // tap-to-seek off exactly this.
        XCTAssertNil(transcript.segmentIndex(at: 6), "no timings, so no line can be highlighted")
    }

    func testSegmentsAreSortedAndMalformedOnesDropped() throws {
        let data = Data("""
        {"segments":[{"start":9.0,"end":12.0,"text":"second"},
                     {"end":4.0,"text":"no start — dropped"},
                     {"start":0.0,"end":4.0,"text":"first"},
                     {"start":20.0,"end":21.0,"text":"   "}]}
        """.utf8)
        let transcript = try TranscriptionService.parse(data, trackID: "ep-3", fallbackModel: "whisper-1")
        XCTAssertEqual(transcript.segments.map(\.text), ["first", "second"])
    }

    func testEmptyTranscriptionThrowsRatherThanReturningNothing() {
        let data = Data(#"{"text":"   ","segments":[]}"#.utf8)
        XCTAssertThrowsError(try TranscriptionService.parse(data, trackID: "ep-4", fallbackModel: "whisper-1")) { error in
            XCTAssertEqual((error as? TranscriptionService.TranscribeError)?.isEmptyOfSpeech, true)
        }
    }

    func testNonJSONResponseThrows() {
        XCTAssertThrowsError(
            try TranscriptionService.parse(Data("<html>nope</html>".utf8), trackID: "ep-5", fallbackModel: "whisper-1")
        )
    }

    // MARK: - Real server shapes
    //
    // Both payloads below were captured from live servers running side by side on the same
    // machine, trimmed to two segments. They are here because a stub written from the OpenAI
    // spec agreed with only one of them, and the disagreement was invisible until real audio
    // went through: the WhisperX shape parsed as untimed text, silently costing the highlight,
    // tap-to-seek, and chunking on real boundaries.

    /// speaches / faster-whisper: OpenAI `verbose_json`, segments at the top level.
    func testParsesTheOpenAIVerboseJSONShape() throws {
        let data = Data("""
        {"task":"transcribe","language":"en","duration":7.554,
         "text":"Welcome back to the show. Today we are talking about storage.",
         "segments":[
           {"id":1,"start":0.0,"end":4.66,"text":" Welcome back to the show."},
           {"id":2,"start":5.18,"end":7.38,"text":" Later on, we get into off-site copies."}]}
        """.utf8)
        let transcript = try TranscriptionService.parse(data, trackID: "ep-1", fallbackModel: "whisper-1")

        XCTAssertTrue(transcript.synced)
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments.first?.start, 0.0)
        XCTAssertEqual(transcript.segments.first?.text, "Welcome back to the show.")
        XCTAssertEqual(transcript.segments.last?.end, 7.38)
        XCTAssertEqual(transcript.duration, 7.554)
        XCTAssertEqual(transcript.language, "en")
    }

    /// WhisperX: the segment array is nested under `segments.segments`, beside `word_segments`.
    func testParsesTheWhisperXNestedShape() throws {
        let data = Data("""
        {"language":"en",
         "text":"Welcome back to the show. Today we are talking about storage.",
         "segments":{
           "segments":[
             {"start":0.031,"end":1.034,"text":" Welcome back to the show."},
             {"start":1.396,"end":4.787,"text":"Today we are talking about storage."}],
           "word_segments":[{"word":"Welcome","start":0.031,"end":0.332,"score":0.931}]}}
        """.utf8)
        let transcript = try TranscriptionService.parse(data, trackID: "ep-1", fallbackModel: "large-v3")

        XCTAssertTrue(transcript.synced, "nested segments are still timed segments")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments.first?.start, 0.031)
        XCTAssertEqual(transcript.segments.last?.text, "Today we are talking about storage.")
        XCTAssertNil(transcript.duration, "WhisperX reports no duration, and one is not invented")
    }

    /// The regression guard for the bug this pair was written to catch: the nested shape must
    /// not degrade into one untimed blob.
    func testTheNestedShapeDoesNotDegradeIntoUntimedText() throws {
        let data = Data("""
        {"language":"en","text":"all of it as one lump",
         "segments":{"segments":[{"start":0.0,"end":2.0,"text":"first"}],"word_segments":[]}}
        """.utf8)
        let transcript = try TranscriptionService.parse(data, trackID: "x", fallbackModel: "m")
        XCTAssertTrue(transcript.synced)
        XCTAssertEqual(transcript.segments.map(\.text), ["first"])
        XCTAssertNotEqual(transcript.segments.first?.text, "all of it as one lump")
    }

    // MARK: - Whisper hallucinating over music

    /// The exact failure a user hit on "Riders on the Storm": a music track came back as the
    /// word "Yeah" repeated down the whole pane. Whisper does not fall silent over non-speech,
    /// it invents, and a wall of one word looks like the feature working.
    func testAWallOfOneRepeatedWordIsReportedAsNoSpeech() {
        let segments = (0 ..< 40).map { i in
            Transcript.Segment(start: Double(i) * 3, end: Double(i) * 3 + 3, text: "Yeah")
        }
        XCTAssertTrue(TranscriptionService.isDegenerate(segments))
    }

    func testTheRepetitionGuardSurfacesAsNoSpeechRatherThanAnError() {
        let segs = (0 ..< 40).map {
            #"{"start":\#(Double($0) * 3),"end":\#(Double($0) * 3 + 3),"text":" Yeah"}"#
        }.joined(separator: ",")
        let data = Data(#"{"language":"en","text":"Yeah","segments":[\#(segs)]}"#.utf8)

        XCTAssertThrowsError(try TranscriptionService.parse(data, trackID: "x", fallbackModel: "m")) { error in
            let e = error as? TranscriptionService.TranscribeError
            XCTAssertEqual(e?.isEmptyOfSpeech, true, "an instrumental is not a failure")
            XCTAssertFalse(e?.isUnreachable == true)
            XCTAssertTrue(e?.message.contains("No speech") == true, "got: \(e?.message ?? "nil")")
        }
    }

    /// Deliberately conservative. Real speech repeats, and a conversation of short agreements
    /// must still transcribe.
    func testGenuineSpeechThatRepeatsIsNotMistakenForALoop() {
        var segments = (0 ..< 30).map { i in
            Transcript.Segment(start: Double(i), end: Double(i) + 1, text: "Line \(i) with real content.")
        }
        segments.append(contentsOf: (0 ..< 6).map { i in
            Transcript.Segment(start: Double(40 + i), end: Double(41 + i), text: "Yeah")
        })
        XCTAssertFalse(TranscriptionService.isDegenerate(segments))
    }

    func testAShortTranscriptIsNeverJudgedDegenerate() {
        let segments = (0 ..< 6).map { i in
            Transcript.Segment(start: Double(i), end: Double(i) + 1, text: "Yeah")
        }
        XCTAssertFalse(TranscriptionService.isDegenerate(segments), "too little to conclude anything")
    }

    /// A repeated *long* line is far likelier a real refrain than a decoding loop.
    func testALongRepeatedLineIsLeftAlone() {
        let line = "And that is the whole point of running your own storage at home, really."
        let segments = (0 ..< 40).map { i in
            Transcript.Segment(start: Double(i), end: Double(i) + 1, text: line)
        }
        XCTAssertFalse(TranscriptionService.isDegenerate(segments))
    }

    func testEmptyTextIsReportedAsNoSpeechNotAsAFailure() {
        let data = Data(#"{"text":"   ","segments":[]}"#.utf8)
        XCTAssertThrowsError(try TranscriptionService.parse(data, trackID: "x", fallbackModel: "m")) { error in
            XCTAssertEqual((error as? TranscriptionService.TranscribeError)?.isEmptyOfSpeech, true)
        }
    }

    /// VAD is what stops the model inventing words over an instrumental in the first place.
    func testTheRequestAsksTheServerToSkipNonSpeechAudio() {
        let body = TranscriptionService.multipartBody(
            fields: [("model", "m"), ("response_format", "verbose_json"), ("vad_filter", "true")],
            fileName: "a.mp3", fileData: Data("x".utf8), boundary: "B"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"vad_filter\"\r\n\r\ntrue"))
    }

    // MARK: - Too little of the track to be a transcript of it

    /// The real artifact from "Riders on the Storm", read off disk: one segment of 1.7 s out
    /// of 7:15, reading "Do this as we're born" — a mangled line of the lyric. VAD did its
    /// job on the instrumental; what survived is a fragment, and showing it claims the track
    /// said one wrong sentence and nothing else.
    func testAFragmentOfASongIsNotATranscriptOfIt() {
        let segments = [Transcript.Segment(start: 55.6, end: 57.3, text: "Do this as we're born.")]
        XCTAssertTrue(TranscriptionService.isTooSparse(segments, duration: 434.73))
    }

    func testTheSparsenessGuardSurfacesAsNoSpeech() {
        let data = Data(#"""
        {"language":"en","duration":434.73,
         "segments":[{"start":55.6,"end":57.3,"text":" Do this as we're born."}]}
        """#.utf8)
        XCTAssertThrowsError(try TranscriptionService.parse(data, trackID: "x", fallbackModel: "m")) { error in
            XCTAssertEqual((error as? TranscriptionService.TranscribeError)?.isEmptyOfSpeech, true)
        }
    }

    /// Spoken word covers most of its running time, so the guard must not touch it. A 48-minute
    /// episode with 40 minutes of speech is 83% covered.
    func testAnOrdinaryEpisodeIsNeverJudgedTooSparse() {
        let segments = (0 ..< 400).map { i in
            Transcript.Segment(start: Double(i) * 7.2, end: Double(i) * 7.2 + 6.0, text: "talking")
        }
        XCTAssertFalse(TranscriptionService.isTooSparse(segments, duration: 2880))
    }

    /// Even an interview full of pauses stays far above a tenth.
    func testASparseButRealConversationSurvives() {
        // 20 minutes, speech in half of it.
        let segments = (0 ..< 60).map { i in
            Transcript.Segment(start: Double(i) * 20, end: Double(i) * 20 + 10, text: "a real answer")
        }
        XCTAssertFalse(TranscriptionService.isTooSparse(segments, duration: 1200))
    }

    func testShortClipsAreNotJudgedOnARatio() {
        let segments = [Transcript.Segment(start: 0, end: 1, text: "hi")]
        XCTAssertFalse(TranscriptionService.isTooSparse(segments, duration: 45),
                       "under a minute there is not enough to conclude anything")
        XCTAssertFalse(TranscriptionService.isTooSparse(segments, duration: nil),
                       "no duration, no ratio")
    }

    // MARK: - A song is transcribable; the invention around it is not

    /// The measured shape of "Riders on the Storm" from a pass with voice-activity detection
    /// off: 168 segments, of which 27 are the lyric and the rest are two decoding loops on the
    /// word "Yeah" — 12 segments over the instrumental break and 128 over the outro. Read off
    /// the real response, not invented. Music is no longer *sent* that way, but a recognizer
    /// loops over instrumental stretches with VAD on too, and this is the shape the stripper
    /// has to survive.
    private func ridersOnTheStormSegments() -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        var clock = 0.0
        func add(_ text: String, _ span: Double = 2, times: Int = 1) {
            for _ in 0 ..< times {
                segments.append(Transcript.Segment(start: clock, end: clock + span, text: text))
                clock += span
            }
        }
        add("Transcribed by ESO, translated by \u{2014}", 30)
        add("Riders on the Storm", 18)
        add("Riders on the Storm", 4)
        add("Into this house we\u{2019}re born", 6)
        add("Into this world we\u{2019}re thrown", 4)
        add("Like a dog without a bone", 4)
        add("An actor out alone", 2)
        add("Take him by the hand", 4, times: 4)     // sung four times, and meant
        add("There\u{2019}s a killer on the road", 4)
        add("Yeah", 2.5, times: 12)                  // the instrumental break
        add("Girl you gotta love your man", 10)
        add("Make him understand", 2)
        add("Yeah", 2.2, times: 128)                 // the outro, and the rain
        return segments
    }

    /// The threshold that matters. Both loops go; the fourfold real repeat stays.
    func testASongsLyricSurvivesWhileTheDecodingLoopsAreRemoved() {
        let kept = Transcript.strippingHallucinations(ridersOnTheStormSegments())
        let lines = kept.map(\.text)

        XCTAssertFalse(lines.contains("Yeah"), "140 segments of \"Yeah\" are a decoding loop, not a lyric")
        XCTAssertEqual(lines.filter { $0 == "Take him by the hand" }.count, 4,
                       "a line the song really does sing four times must survive")
        XCTAssertTrue(lines.contains("Into this house we\u{2019}re born"),
                      "the line VAD mangled into \"Do this as we\u{2019}re born\" is the one this is all for")
        XCTAssertFalse(lines.contains { $0.contains("Transcribed by") },
                       "subtitle boilerplate is not something the track said")
    }

    /// Four is a real repeat and six is a loop, and that is the whole reason for the number:
    /// a threshold of four would throw away "Take him by the hand" to catch nothing extra.
    func testAFourfoldRepeatIsKeptAndASixfoldOneIsNot() {
        let four = (0 ..< 4).map { Transcript.Segment(start: Double($0), end: Double($0) + 1, text: "Take him by the hand") }
        let six = (0 ..< 6).map { Transcript.Segment(start: Double($0), end: Double($0) + 1, text: "Yeah") }
        XCTAssertEqual(Transcript.strippingHallucinations(four).count, 4)
        XCTAssertEqual(Transcript.strippingHallucinations(six).count, 0)
    }

    /// A long repeated line is a refrain, not a loop, however often it comes round.
    func testALongRepeatedLineIsNeverStripped() {
        let line = "And that is the whole point of running your own storage at home, really."
        let segments = (0 ..< 40).map { Transcript.Segment(start: Double($0), end: Double($0) + 1, text: line) }
        XCTAssertEqual(Transcript.strippingHallucinations(segments).count, 40)
    }

    /// End to end: the song that prompted all of this now produces a transcript instead of a
    /// refusal, and it is a quarter of the running time rather than four tenths of one per cent.
    func testTheSongThatPromptedThisNowTranscribes() throws {
        let segments = ridersOnTheStormSegments()
        let body: [String: Any] = [
            "language": "en",
            "duration": 434.73,
            "segments": segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] },
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let transcript = try TranscriptionService.parse(data, trackID: "riders", fallbackModel: "m")

        XCTAssertTrue(transcript.plainText.contains("Into this house"))
        XCTAssertFalse(transcript.plainText.contains("Yeah"))
        XCTAssertFalse(transcript.looksLikeNothingWasSaid)
    }

    /// The other measured artifact, and the reason voice-activity detection stays on for
    /// music too. Ace of Base, "Donnie", 272 s and sung end to end, sent to
    /// faster-whisper-large-v3-turbo *without* VAD: 132 segments, every one of them the single
    /// word "I". The stripper is right to remove all of it and the pane is right to say no
    /// speech was found — the mistake is upstream, in sending the request that way. Sung
    /// vocals are where that recognizer falls apart; WhisperX reads the same file as fourteen
    /// segments of real lyric.
    func testTheMeasuredNoVADResponseForASungTrackIsNotATranscript() throws {
        let segments = (0 ..< 132).map {
            Transcript.Segment(start: Double($0) * 2, end: Double($0) * 2 + 2, text: "I")
        }
        XCTAssertTrue(Transcript.strippingHallucinations(segments).isEmpty,
                      "132 segments of one word is a decoding loop, whatever the track")

        let body: [String: Any] = [
            "duration": 272.92,
            "text": String(repeating: "I ", count: 132),
            "segments": segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] },
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        XCTAssertThrowsError(try TranscriptionService.parse(data, trackID: "donnie", fallbackModel: "m")) { error in
            XCTAssertEqual((error as? TranscriptionService.TranscribeError)?.isEmptyOfSpeech, true)
        }
    }

    /// The trap in doing this at parse time: `text` still holds every invented word, so a
    /// response stripped to nothing must report no speech rather than fall through to it.
    func testATrackStrippedToNothingDoesNotFallBackToTheInventedText() throws {
        let body: [String: Any] = [
            "duration": 300.0,
            "text": String(repeating: "Yeah. ", count: 40),
            "segments": (0 ..< 40).map { ["start": Double($0) * 5, "end": Double($0) * 5 + 5, "text": "Yeah"] },
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        XCTAssertThrowsError(try TranscriptionService.parse(data, trackID: "x", fallbackModel: "m")) { error in
            XCTAssertEqual((error as? TranscriptionService.TranscribeError)?.isEmptyOfSpeech, true)
        }
    }

    // MARK: - Timed lines are what the highlight runs on

    /// The nested shape WhisperX really returns, and the property the sheet keys off.
    ///
    /// Both "highlight the line that is playing" and "tap a line to seek there" are gated on
    /// the same thing: `Transcript.synced`, through `segmentIndex(at:)`. A transcript that
    /// parses into text but not into *timings* renders every line identically and ignores
    /// taps, which reads as the feature being absent rather than the timings being absent.
    ///
    /// So this asserts the whole chain on the real thing: WhisperX's `segments.segments`
    /// (which is not where OpenAI puts them), parsed, marked synced, and asked which line is
    /// playing at a given moment.
    func testWhisperXsNestedShapeYieldsTimedLinesTheSheetCanHighlight() throws {
        let body: [String: Any] = [
            "language": "en",
            "segments": ["segments": [
                ["start": 36.7, "end": 61.7, "text": "Riders on the storm"],
                ["start": 64.1, "end": 66.5, "text": "There\u{2019}s a killer on the road."],
                ["start": 68.6, "end": 71.2, "text": "His brain is squirming like a toad."],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let transcript = try TranscriptionService.parse(data, trackID: "riders", fallbackModel: "m")

        XCTAssertTrue(transcript.synced, "without this the sheet has nothing to highlight and taps do nothing")
        XCTAssertEqual(transcript.segments.count, 3)
        XCTAssertEqual(transcript.segmentIndex(at: 65), 1, "the line playing at 65 s is the second one")
        XCTAssertEqual(transcript.segmentIndex(at: 0), nil, "before the first line, nothing is highlighted")
        XCTAssertEqual(transcript.segmentIndex(at: 300), 2, "past the end, the last line stays current")
    }

    // MARK: - Model list shapes

    func testReadsBothModelListShapes() {
        let openAI = Data(#"{"data":[{"id":"large-v3-turbo"},{"id":"base"}]}"#.utf8)
        XCTAssertEqual(TranscriptionService.modelIDs(in: openAI)?.sorted(), ["base", "large-v3-turbo"])

        // WhisperX
        let plain = Data(#"{"models":["large-v3"]}"#.utf8)
        XCTAssertEqual(TranscriptionService.modelIDs(in: plain), ["large-v3"])

        XCTAssertNil(TranscriptionService.modelIDs(in: Data(#"{"nothing":true}"#.utf8)))
        XCTAssertNil(TranscriptionService.modelIDs(in: Data(#"{"models":[]}"#.utf8)))
    }

    /// A server that 404s the OpenAI route but serves `/models/list` is working, not missing.
    func testTheProbeFallsBackWhenTheOpenAIModelRouteIsAbsent() async throws {
        nonisolated(unsafe) var paths: [String] = []
        NavidromeMockURLProtocol.handler = { req in
            paths.append(req.url?.path ?? "")
            if req.url?.path == "/v1/models" {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (resp, Data(#"{"detail":"Not Found"}"#.utf8))
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"models":["large-v3"]}"#.utf8))
        }

        let models = try await TranscriptionService.availableModels(session: mockSession())

        XCTAssertEqual(models, ["large-v3"])
        XCTAssertEqual(paths, ["/v1/models", "/models/list"], "tries the OpenAI route first")
    }

    // MARK: - Config

    func testTranscriptionIsOffUntilExplicitlyEnabled() {
        XCTAssertFalse(SpeechConfig.transcriptionEnabled, "shipping audio to a server is opt-in")
        XCTAssertFalse(SpeechConfig.isTranscriptionConfigured)
        SpeechConfig.transcriptionEnabled = true
        XCTAssertTrue(SpeechConfig.isTranscriptionConfigured)
    }

    func testEnabledButUnparseableHostIsNotConsideredConfigured() {
        SpeechConfig.transcriptionEnabled = true
        SpeechConfig.whisperBaseURL = "whatever"
        XCTAssertFalse(SpeechConfig.isTranscriptionConfigured, "an enabled feature with no reachable address is not configured")
    }

    func testWhisperModelFallsBackWhenBlank() {
        XCTAssertEqual(SpeechConfig.whisperModel, "whisper-1")
        SpeechConfig.whisperModel = ""
        XCTAssertEqual(SpeechConfig.whisperModel, "whisper-1", "a cleared field must not send an empty model id")
        SpeechConfig.whisperModel = "large-v3"
        XCTAssertEqual(SpeechConfig.whisperModel, "large-v3")
    }

    func testAvailableModelsParsesTheOpenAIModelList() async throws {
        NavidromeMockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/v1/models")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data(#"{"data":[{"id":"large-v3"},{"id":"base"}]}"#.utf8))
        }
        let models = try await TranscriptionService.availableModels(session: mockSession())
        XCTAssertEqual(models, ["base", "large-v3"])
    }
}
