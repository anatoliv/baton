import Foundation
import XCTest
@testable import BatonDocuments

final class SentenceSplitterTests: XCTestCase {
    func testSplitsAtSentenceEndsButNotAtAbbreviationsOrInitials() {
        let text = "It was written by E. M. Forster in 1909. Mr. Smith read it at St. Paul's, e.g. aloud! Did he? Yes."
        XCTAssertEqual(SentenceSplitter.sentences(text), [
            "It was written by E. M. Forster in 1909.",
            "Mr. Smith read it at St. Paul's, e.g. aloud!",
            "Did he?",
            "Yes.",
        ])
    }

    func testClosingQuotesStayWithTheirSentence() {
        let text = "\u{201C}Who is it?\u{201D} she called. \u{201C}Be quick!\u{201D} He smiled."
        XCTAssertEqual(SentenceSplitter.sentences(text), [
            "\u{201C}Who is it?\u{201D} she called.",
            "\u{201C}Be quick!\u{201D}",
            "He smiled.",
        ])
    }

    func testNoBreakBeforeALowercaseWord() {
        XCTAssertEqual(SentenceSplitter.sentences("He said \u{201C}no.\u{201D} and left. Then rain."),
                       ["He said \u{201C}no.\u{201D} and left.", "Then rain."])
    }

    func testChunksRespectTheLimitsAndKeepClausePunctuation() {
        let long = (1...30).map { "clause number \($0) goes here" }.joined(separator: ", ") + "."
        let chunks = SentenceSplitter.chunks(long)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= SentenceSplitter.maxChunkCharacters }, "\(chunks.map(\.count))")
        // Splitting at a comma keeps the comma, so the voice still pauses there.
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.hasSuffix(",") }, "\(chunks)")
        XCTAssertEqual(chunks.joined(separator: " "), long)
    }

    func testShortSentencesMergeAndNoChunkIsAStrayWord() {
        let chunks = SentenceSplitter.chunks("Yes. No. Perhaps it will rain later in the afternoon, they said. Fine.")
        XCTAssertEqual(chunks, ["Yes. No. Perhaps it will rain later in the afternoon, they said. Fine."])
    }

    func testPackingJoinsWholeSentencesUpToTheTarget() {
        let text = (1...8).map { "Sentence number \($0) is about forty characters." }.joined(separator: " ")
        let packed = SentenceSplitter.chunks(text, target: 120)
        XCTAssertTrue(packed.allSatisfy { $0.count <= 120 && $0.hasSuffix(".") }, "\(packed)")
        XCTAssertEqual(packed.count, 4)   // 44-character sentences: two fit in 120, three do not
        XCTAssertEqual(packed.joined(separator: " "), text)
        XCTAssertEqual(SentenceSplitter.chunks(text).count, 8, "unpacked stays one sentence per chunk")
    }

    func testAWordLongerThanTheLimitIsStillEmitted() {
        let chunks = SentenceSplitter.chunks(String(repeating: "a", count: 400))
        XCTAssertEqual(chunks.count, 1)
    }
}

final class DocumentSpeechTests: XCTestCase {
    private func document(_ paragraphs: [String], title: String = "The Cell", label: String? = "1") -> ImportedDocument {
        ImportedDocument(sourceSHA256: "abc", sourceKind: .pdf, title: "A Small Room", author: "A. N. Author",
                         chapters: [DocumentChapter(index: 0, title: title, paragraphs: paragraphs, label: label)])
    }

    func testHeadingThenParagraphsWithTheirPauses() {
        let book = DocumentSpeech.prepare(document([
            "Imagine a small room, shaped like the cell of a bee. It is lit by neither window nor lamp.",
            "An electric bell rang.",
        ]), voices: VoicePlan(narrator: "kokoro:bf_emma"))
        let segments = book.chapters[0].segments
        XCTAssertEqual(segments.map(\.kind), [.heading, .narration, .narration])
        XCTAssertEqual(segments[0].text, "Chapter 1. The Cell")
        XCTAssertEqual(segments.map(\.pauseBeforeMs), [0, 900, 650])
        XCTAssertEqual(segments.map(\.paragraph), [-1, 0, 1])
    }

    func testWithoutACastAQuoteAndItsTagStayOneChunk() {
        let book = DocumentSpeech.prepare(document(["\u{201C}Who is it?\u{201D} she called. Her voice was irritable."]),
                                          voices: VoicePlan(narrator: "kokoro:bf_emma"))
        let body = book.chapters[0].segments.dropFirst()
        XCTAssertEqual(body.map(\.text), ["\u{201C}Who is it?\u{201D} she called. Her voice was irritable."])
        XCTAssertTrue(body.allSatisfy { $0.speaker == nil })
    }

    func testWithACastSpeakersGetTheirOwnSegments() {
        let paragraphs = [
            "\u{201C}Who is it?\u{201D} she called. \u{201C}Be quick, Kuno.\u{201D}",
            "\u{201C}I want you to come and see me.\u{201D}",
        ]
        let cast: [Int: String] = [0: "Vashti", 1: "Vashti", 2: "Kuno"]
        let book = DocumentSpeech.prepare(document(paragraphs),
                                          voices: VoicePlan(narrator: "kokoro:bm_george",
                                                            characters: ["Vashti": "kokoro:bf_emma", "Kuno": "kokoro:bm_fable"]),
                                          attribution: { _, q in cast[q] })
        let body = Array(book.chapters[0].segments.dropFirst())
        XCTAssertEqual(body.map(\.speaker), ["Vashti", nil, "Vashti", "Kuno"])
        XCTAssertEqual(body.map { book.voices.voice(for: $0) },
                       ["kokoro:bf_emma", "kokoro:bm_george", "kokoro:bf_emma", "kokoro:bm_fable"])
        XCTAssertEqual(body.map(\.pauseBeforeMs), [900, 250, 250, 650])
    }

    func testAnUnattributedQuoteIsReadByTheNarrator() {
        let plan = VoicePlan(narrator: "kokoro:bm_george", characters: ["Kuno": "kokoro:bm_fable"])
        XCTAssertEqual(plan.voice(for: SpeechSegment(text: "Hm.", kind: .quote, speaker: nil, pauseBeforeMs: 0, paragraph: 0)),
                       "kokoro:bm_george")
        XCTAssertEqual(plan.voice(for: SpeechSegment(text: "Hm.", kind: .quote, speaker: "Nobody", pauseBeforeMs: 0, paragraph: 0)),
                       "kokoro:bm_george")
    }

    func testAQuoteRunningOverParagraphsKeepsItsQuoteState() {
        var open = false
        let first = DocumentSpeech.dialogueSpans("\u{201C}The four big stars are his shoulders.", continuingQuote: &open)
        XCTAssertTrue(open)
        let second = DocumentSpeech.dialogueSpans("The three in the middle are a belt.\u{201D} He paused.", continuingQuote: &open)
        XCTAssertFalse(open)
        XCTAssertEqual(first.map(\.isQuote), [true])
        XCTAssertEqual(second.map(\.isQuote), [true, false])
    }

    func testNormalizationNeverEmptiesText() {
        // Linux Foundation returns "" for an invalid ICU pattern where Darwin returns the input
        // unchanged, so a bad pattern here was invisible on the Mac and fatal on the gateway.
        let prose = "Some words that are speakable, at last."
        XCTAssertEqual(DocumentSpeech.normalize(prose), prose)
    }

    func testNormalizationTouchesTypographyOnly() {
        XCTAssertEqual(DocumentSpeech.normalize("The end[12] of it* -- and then...  more\u{2014}less"),
                       "The end of it \u{2014} and then\u{2026} more \u{2014} less")
    }

    func testSecretsNeverReachASegment() {
        let key = "sk-" + "abcdefghijklmnopqrstuvwxyz012345"
        let book = DocumentSpeech.prepare(document(["Paste \(key) into the box and wait for it."]),
                                          voices: VoicePlan(narrator: "kokoro:bf_emma"))
        let all = book.chapters.flatMap(\.segments).map(\.text).joined(separator: " ")
        XCTAssertFalse(all.contains(key))
        XCTAssertTrue(all.contains("a redacted token"))
    }

    func testCacheKeyDependsOnVoiceSpeedAndTextOnly() {
        let a = SpeechSegment(text: "Hello there, it is me.", kind: .narration, pauseBeforeMs: 0, paragraph: 0)
        var b = a
        b.pauseBeforeMs = 650
        b.paragraph = 9
        XCTAssertEqual(a.cacheKey(voice: "kokoro:bf_emma", speed: nil), b.cacheKey(voice: "kokoro:bf_emma", speed: nil))
        XCTAssertNotEqual(a.cacheKey(voice: "kokoro:bf_emma", speed: nil), a.cacheKey(voice: "kokoro:bm_george", speed: nil))
        XCTAssertNotEqual(a.cacheKey(voice: "kokoro:bf_emma", speed: nil), a.cacheKey(voice: "kokoro:bf_emma", speed: 0.9))
        XCTAssertEqual(a.cacheKey(voice: "kokoro:bf_emma", speed: nil).count, 64)
    }

    func testPreparedBookRoundTripsAndRefusesAFutureSchema() throws {
        let book = DocumentSpeech.prepare(document(["Some text here, long enough to be a chunk of its own."]),
                                          voices: VoicePlan(narrator: "kokoro:bf_emma", speed: 0.95))
        let data = try book.encoded()
        XCTAssertEqual(try PreparedBook.decode(data), book)

        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        future["schemaVersion"] = PreparedBook.currentSchemaVersion + 1
        let futureData = try JSONSerialization.data(withJSONObject: future)
        XCTAssertThrowsError(try PreparedBook.decode(futureData)) { error in
            XCTAssertEqual(error as? PreparedBookError, .unsupportedSchema(PreparedBook.currentSchemaVersion + 1))
        }
    }

    func testChaptersWithOnlyAHeadingAreDropped() {
        let doc = ImportedDocument(sourceSHA256: "x", sourceKind: .text, title: "T", chapters: [
            DocumentChapter(index: 0, title: "Empty", paragraphs: []),
            DocumentChapter(index: 1, title: "Full", paragraphs: ["Some words that are speakable, at last."]),
        ])
        XCTAssertEqual(DocumentSpeech.prepare(doc, voices: VoicePlan(narrator: "kokoro:af_heart")).chapters.map(\.title), ["Full"])
    }
}

final class SecretRedactorTests: XCTestCase {
    // The same fixtures as read-aloud's `SpeakableTextTests`, assembled at runtime for the same
    // reason: they must look like real credentials, and the public mirror's scanner cannot tell
    // a fixture from a leak.
    private let githubPAT = "ghp" + "_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"
    private let githubOAuth = "gho" + "_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"
    private let slackToken = "xoxb" + "-1234567890-abcdefghij"
    private let awsKeyID = "AKIA" + "IOSFODNN7EXAMPLE"
    private let privateKeyHeader = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
    private let privateKeyFooter = "-----END OPENSSH " + "PRIVATE KEY-----"

    func testRedactsEveryKnownCredentialShape() {
        let cases: [(String, String)] = [
            ("export KEY=sk-abcdefghijklmnopqrstuvwxyz012345", "sk-abcdefghijklmnopqrstuvwxyz012345"),
            ("clone with \(githubPAT)", githubPAT),
            ("token \(githubOAuth)", githubOAuth),
            ("SENTRY_AUTH_TOKEN is sntrys_abcdefghijklmnopqrs.tuvwxyz", "sntrys_abcdefghijklmnopqrs.tuvwxyz"),
            ("hook \(slackToken)", slackToken),
            ("id \(awsKeyID) here", awsKeyID),
            ("key AIzaSyA1234567890abcdefghijklmnopqrstuvw done", "AIzaSyA1234567890abcdefghijklmnopqrstuvw"),
            ("auth eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk", "eyJhbGciOiJIUzI1NiJ9"),
            ("Authorization: Bearer abcdef1234567890XYZ", "abcdef1234567890XYZ"),
            ("password=hunter2", "hunter2"),
        ]
        for (input, secret) in cases {
            XCTAssertFalse(SecretRedactor.redact(input).contains(secret), input)
        }
        let block = [privateKeyHeader, "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ", privateKeyFooter].joined(separator: "\n")
        XCTAssertEqual(SecretRedactor.redact("before \(block) after"), "before a redacted private key after")
    }

    /// The placeholders are what read-aloud speaks, so they are pinned word for word. A change
    /// here is a change a listener hears, and should be a decision rather than a side effect.
    func testSpokenPlaceholdersAreExact() {
        let cases: [(String, String)] = [
            ("export KEY=sk-abcdefghijklmnopqrstuvwxyz012345", "export KEY=a redacted token"),
            ("clone with \(githubPAT)", "clone with a redacted token"),
            ("hook \(slackToken)", "hook a redacted token"),
            ("id \(awsKeyID) here", "id a redacted key here"),
            ("key AIzaSyA1234567890abcdefghijklmnopqrstuvw done", "key a redacted key done"),
            ("Authorization: Bearer abcdef1234567890XYZ", "Authorization: bearer, a redacted token"),
            ("password=hunter2", "password, a redacted value"),
            ("API_KEY: abc123def", "API_KEY, a redacted value"),
            ("auth = zzzzzzzz", "auth, a redacted value"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SecretRedactor.redact(input), expected, input)
        }
    }

    func testLeavesProseAndHashesAloneAndIsIdempotent() {
        let prose = "The password reset flow needs a test, says commit b7818ff6a1c2d3e4f5061728394a5b6c7d8e9f01."
        XCTAssertEqual(SecretRedactor.redact(prose), prose)
        let once = SecretRedactor.redact("key sk-abcdefghijklmnopqrstuvwxyz012345 and \(githubPAT)")
        XCTAssertEqual(SecretRedactor.redact(once), once)
    }
}

final class SupportTypesTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Digest.portableHex(of: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.portableHex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.portableHex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(SHA256Digest.portableHex(of: million),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        // Whichever implementation `hex` uses on this platform agrees with the portable one.
        for sample in [Data(), Data("abc".utf8), million] {
            XCTAssertEqual(SHA256Digest.hex(of: sample), SHA256Digest.portableHex(of: sample))
        }
    }

    func testListeningEstimateForTheSample() {
        // The sample: 12,338 words. At 175 wpm that is 70.5 minutes, at 48 kbps about 25.4 MB.
        // The real render on the Mac (2026-10-03) was 70.4 minutes and 25.8 MB: inside 2%.
        let e = ListeningEstimate(words: 12_338)
        XCTAssertEqual(e.durationText, "1 h 11 m")
        XCTAssertEqual(e.sizeText, "25 MB")
        XCTAssertEqual(abs(Double(e.bytes) - 25_805_090) / 25_805_090, 0, accuracy: 0.15,
                       "the acceptance criterion: within 15% of what was actually made")
        XCTAssertEqual(ListeningEstimate(words: 50).durationText, "under a minute")
        XCTAssertEqual(ListeningEstimate(words: 12_338, speed: 1.25).durationText, "56 m")
    }

    func testRedactingWithAMarkerKeepsTheFieldName() {
        let out = SecretRedactor.redact("token: abc123def456 and sk-abcdefghijklmnopqrst", placeholder: "<redacted-secret>")
        XCTAssertEqual(out, "token=<redacted-secret> and <redacted-secret>")
        XCTAssertEqual(SecretRedactor.redact(out, placeholder: "<redacted-secret>"), out, "idempotent")
    }
}
