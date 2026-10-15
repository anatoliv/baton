import Foundation
import XCTest
@testable import BatonDocuments

/// TBX-10902: who speaks a line is part of the job. A cast book made again with the same voices
/// but different attribution (the rules alone, then the rules and the model's fill, or after the
/// cast sheet is corrected) is a different reading, so it is a different job, here and on the
/// home server. A narrator-only book keeps the id it always had.
final class CastJobIDTests: XCTestCase {
    private let narrator = "kokoro:bf_isabella"
    private let cast = [
        DialogueCast.Character(name: "Mary", gender: "f", age: "old", aliases: ["his mother"]),
        DialogueCast.Character(name: "Tom", gender: "m", age: "young", aliases: ["her son"]),
    ]

    /// One tagged line, two the rules cannot place, then a tagged one (the TBX-10894 fixture).
    private var room: ImportedDocument {
        ImportedDocument(sourceSHA256: String(repeating: "ef", count: 32), sourceKind: .text, title: "The Room",
                         chapters: [DocumentChapter(index: 0, title: "Chapter 1", paragraphs: [
                             "Mary sat in her chair in the small room, and the bell rang twice.",
                             "\u{201C}Who is it at this hour?\u{201D} said his mother.",
                             "The door opened slowly and a long while passed in the corridor before anything else happened at all, and the cold came in with it.",
                             "\u{201C}Only me.\u{201D}",
                             "\u{201C}Come in, then.\u{201D}",
                             "\u{201C}I came to see the surface,\u{201D} said Tom.",
                         ])])
    }

    private var casting: DialogueCast.Casting {
        DialogueCast.Casting(speakers: [
            .init(id: "Mary", character: cast[0], voice: "kokoro:bf_emma", isNarrator: false, lines: 1, sample: nil),
            .init(id: "Tom", character: cast[1], voice: "kokoro:bm_george", isNarrator: false, lines: 1, sample: nil),
        ])
    }

    /// The rules alone, and the rules with the model placing the two lines they left.
    private var rulesOnly: PreparedBook {
        DialogueCast.prepare(room, plan: VoicePlan(narrator: narrator), casting: casting)
    }

    private var withFill: PreparedBook {
        DialogueCast.prepare(room, plan: VoicePlan(narrator: narrator), casting: casting,
                             fill: DialogueCast.Fill(speakers: ["c1q2": "Tom", "c1q3": "Mary"]))
    }

    // MARK: Golden ids

    /// Ids recorded from the code before TBX-10902 (main af3f9d67). A narrator-only book on a
    /// Mac or the home server must be found under exactly these.
    func testNarratorOnlyBooksKeepTheirIdsByteForByte() {
        XCTAssertEqual(BookJob.id(for: sampleBook()), "972375478d97a53a2d1be67bd3bc457d73afb7727d68c95678816bb50542236b")
        XCTAssertEqual(BookJob.id(for: sampleBook(narrator: "kokoro:bm_george", chapters: 3)), "8465ce7b0bd2b2312f1be8c1c056332c37de4fc90521f6bca7eda0f2dccd1a33")

        var styled = PreparedBook(documentID: String(repeating: "12", count: 32), title: "Styled", author: nil, language: "en",
                                  voices: VoicePlan(narrator: "chatterbox:Emily.wav", speed: 1.1, style: SpeechStyle.forTone("dramatic")),
                                  chapters: [PreparedChapter(index: 0, title: "One", segments: [
                                      SpeechSegment(text: "Hello there.", kind: .narration, pauseBeforeMs: 0, paragraph: 0),
                                      SpeechSegment(text: "\u{201C}Who?\u{201D}", kind: .quote, pauseBeforeMs: 250, paragraph: 1),
                                  ])])
        styled.lexicon = PronunciationLexicon(entries: [.init(word: "Kuno", phonemes: "kˈunO", source: "person")])
        XCTAssertEqual(BookJob.id(for: styled), "96ef74bb3c3f7a685947f5e54c2341f413d3a1915ff645dbb5789e3f07c67f56")

        // A cast sheet that voices nobody is the narrator-only book, and its id.
        var silent = casting
        for s in silent.speakers { silent.setVoice(s.id, nil) }
        let unvoiced = DialogueCast.prepare(room, plan: VoicePlan(narrator: narrator), casting: silent)
        XCTAssertEqual(unvoiced, DocumentSpeech.prepare(room, voices: VoicePlan(narrator: narrator)))
        XCTAssertEqual(BookJob.id(for: unvoiced), "78731d808c9d98159f96fa4fedf08f528b59a0bd6bdcbc022cb16a2281247a75")
    }

    // MARK: Attribution

    func testTheSameVoicesWithDifferentAttributionAreDifferentJobs() {
        let a = rulesOnly, b = withFill
        XCTAssertEqual(a.voices, b.voices, "the same cast in the same voices")
        XCTAssertNotEqual(a.chapters.flatMap(\.segments).map(\.speaker), b.chapters.flatMap(\.segments).map(\.speaker))
        XCTAssertNotEqual(BookJob.id(for: a), BookJob.id(for: b))
        // Still a pure function of the book: the same attribution twice is the same job.
        XCTAssertEqual(BookJob.id(for: a), BookJob.id(for: rulesOnly))
        XCTAssertEqual(BookJob.id(for: b), BookJob.id(for: try! PreparedBook.decode(try! b.encoded())))
    }

    // MARK: Chunks and rendering

    /// A chunk's key carries the voice its line is read in, so a line given to someone else is a
    /// new chunk and every line still read in the same voice is the same chunk.
    func testAReattributedLineIsANewChunkAndTheRestAreShared() {
        let a = rulesOnly, b = withFill
        let segA = a.chapters.flatMap(\.segments), segB = b.chapters.flatMap(\.segments)
        XCTAssertEqual(segA.map(\.text), segB.map(\.text), "the same lines")
        var changed: [String] = []
        for (x, y) in zip(segA, segB) {
            let kx = a.request(for: x).cacheKey, ky = b.request(for: y).cacheKey
            if a.voices.voice(for: x) == b.voices.voice(for: y) {
                XCTAssertEqual(kx, ky, x.text)
            } else {
                XCTAssertNotEqual(kx, ky, x.text)
                changed.append(y.text)
            }
        }
        XCTAssertEqual(changed.count, 2, "\(changed)")
        XCTAssertTrue(changed.contains { $0.contains("Only me.") })
        XCTAssertTrue(changed.contains { $0.contains("Come in, then.") })
    }

    /// The bug: the second attribution found the first job and its chapters. Now it is a job of
    /// its own, and the renderer voices exactly the lines that moved; the rest come from the cache.
    func testTheRendererMakesAReattributedBookAgainRatherThanReusingItsChapters() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = FakeSynthesizer()
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: synth,
                                    muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let first = rulesOnly, second = withFill
        let firstID = BookJob.id(for: first), secondID = BookJob.id(for: second)
        _ = try await renderer.submit(first, id: firstID)
        await renderer.waitUntilIdle()
        XCTAssertEqual(store.load(firstID)?.status, .ready)
        let before = synth.calls.count
        XCTAssertEqual(before, first.segmentCount)

        guard case .created = try await renderer.submit(second, id: secondID) else {
            return XCTFail("the re-attributed book found the earlier job instead of being made")
        }
        await renderer.waitUntilIdle()
        let job = try XCTUnwrap(store.load(secondID))
        XCTAssertEqual(job.status, .ready)
        XCTAssertEqual(job.book, second)
        let voiced = synth.calls.dropFirst(before).map { "\($0.voice) \($0.text)" }
        XCTAssertEqual(voiced.count, 2, "\(voiced)")
        XCTAssertTrue(voiced.contains { $0.hasPrefix("kokoro:bm_george") && $0.contains("Only me.") }, "\(voiced)")
        XCTAssertTrue(voiced.contains { $0.hasPrefix("kokoro:bf_emma") && $0.contains("Come in, then.") }, "\(voiced)")
        // The first reading is still there, untouched.
        XCTAssertEqual(store.load(firstID)?.book, first)
    }
}

