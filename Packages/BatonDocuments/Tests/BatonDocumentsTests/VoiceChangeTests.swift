import Foundation
import XCTest
@testable import BatonDocuments

/// Change Voice: a book made again in another narrator's voice keeps everything
/// else that makes it this reading. A cast book changes its narrator only, every character
/// keeping its voice; the pronunciations and the words stay; and the job id follows the voice,
/// so the renderer (here or on the home server) makes it afresh rather than finding the old one.
final class VoiceChangeTests: XCTestCase {
    private let cast = [
        DialogueCast.Character(name: "Mary", gender: "f", age: "old", aliases: ["his mother"]),
        DialogueCast.Character(name: "Tom", gender: "m", age: "young", aliases: ["her son"]),
    ]

    private var room: ImportedDocument {
        ImportedDocument(sourceSHA256: String(repeating: "ab", count: 32), sourceKind: .text, title: "The Room",
                         chapters: [DocumentChapter(index: 0, title: "Chapter 1", paragraphs: [
                             "Mary sat in her chair in the small room, and the bell rang twice.",
                             "\u{201C}Who is it at this hour?\u{201D} said Mary.",
                             "\u{201C}I came to see the surface,\u{201D} said Tom.",
                         ])])
    }

    private func castBook() -> PreparedBook {
        let casting = DialogueCast.Casting(speakers: [
            .init(id: "Mary", character: cast[0], voice: "kokoro:bf_emma", isNarrator: false, lines: 1, sample: nil),
            .init(id: "Tom", character: cast[1], voice: "kokoro:bm_george", isNarrator: false, lines: 1, sample: nil),
        ])
        var book = DialogueCast.prepare(room, plan: VoicePlan(narrator: "kokoro:af_heart", speed: 1.1), casting: casting)
        book.lexicon = PronunciationLexicon(entries: [.init(word: "Mary", phonemes: "mˈɛɹi", source: "person")])
        return book
    }

    func testACastBookChangesItsNarratorOnlyAndKeepsItsCastAndPronunciations() throws {
        let before = castBook()
        XCTAssertTrue(before.hasCast, "the fixture voices its dialogue")
        let after = before.inVoice("kokoro:af_sky")

        XCTAssertEqual(after.voices.narrator, "kokoro:af_sky")
        XCTAssertEqual(after.voices.characters, before.voices.characters, "every character keeps its voice")
        XCTAssertEqual(after.voices.characters["Mary"], "kokoro:bf_emma")
        XCTAssertTrue(after.hasCast)
        XCTAssertEqual(after.lexicon, before.lexicon, "the pronunciations carry over")
        XCTAssertEqual(after.chapters, before.chapters, "the words and who says them are kept")
        XCTAssertEqual(after.documentID, before.documentID, "the same book, so the place in it is kept")
        XCTAssertNil(after.voices.speed, "the suggested speed belonged to the old narrator")
        XCTAssertNotEqual(BookJob.id(for: after), BookJob.id(for: before), "a new voice is a new job")

        // Who reads each line: the narration in the new voice, each quote still its speaker's.
        let segments = after.chapters.flatMap(\.segments)
        let narration = try XCTUnwrap(segments.first { $0.speaker == nil && $0.kind == .narration })
        XCTAssertEqual(after.request(for: narration).voice, "kokoro:af_sky")
        for quote in segments where quote.speaker != nil {
            XCTAssertEqual(after.request(for: quote).voice, before.request(for: quote).voice)
            XCTAssertNotEqual(after.request(for: quote).voice, "kokoro:af_sky")
        }
    }

    func testTheSameNarratorChangesNothingAndAChatterboxNarratorKeepsTheBooksTone() {
        let book = castBook()
        XCTAssertEqual(book.inVoice("kokoro:af_heart"), book)
        XCTAssertEqual(BookJob.id(for: book.inVoice("kokoro:af_heart")), BookJob.id(for: book))

        let styled = VoicePlan(narrator: "chatterbox:Emily.wav", style: SpeechStyle.forTone("dramatic"))
        XCTAssertEqual(styled.withNarrator("chatterbox:Abigail.wav").style, styled.style)
        XCTAssertNil(styled.withNarrator("kokoro:af_sky").style, "a Kokoro narrator takes no style")
        XCTAssertFalse(DocumentSpeech.prepare(room, voices: VoicePlan(narrator: "kokoro:af_heart")).hasCast)
    }
}

/// A book paused because its voice cannot be had is made again in another voice at once
///. The renderer makes one book at a time, and a voice that keeps failing is
/// retried until it answers; cancelling the paused job only marked it, so its retry went on and
/// the book in the new voice waited behind it until a relaunch. A voice server that is down, or
/// an engine that refuses the voice, is the usual reason to change it, so this was the common case.
final class VoiceChangeWhilePausedTests: XCTestCase {
    /// Refuses one voice as unreachable, every time; reads any other.
    private final class OneDeadVoice: SpeechSynthesizing, @unchecked Sendable {
        let dead: String
        private let lock = NSLock()
        private var _attempts = 0
        init(dead: String) { self.dead = dead }
        var attempts: Int { lock.withLock { _attempts } }
        func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
            if voice == dead {
                lock.withLock { _attempts += 1 }
                throw SynthesisError.transient("kokoro did not answer: connection refused")
            }
            return FakeSynthesizer.tone(seconds: 0.05)
        }
    }

    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testCancellingAPausedBookLetsTheBookInItsNewVoiceBeMade() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = OneDeadVoice(dead: "kokoro:bf_emma")
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        // The Mac's renderer makes one book at a time; the backoff is long enough that a retry
        // asleep when the job is cancelled would hold the next book up past the wait below.
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"),
                                    synthesizer: synth, muxer: CopyMuxer(), concurrency: 1,
                                    retry: .init(initialDelay: 30, maximumDelay: 60))
        let old = sampleBook(narrator: "kokoro:bf_emma")
        let oldID = BookJob.id(for: old)
        _ = try await renderer.submit(old, id: oldID)
        await waitFor(5) { store.load(oldID)?.status == .paused }
        XCTAssertEqual(store.load(oldID)?.status, .paused, "the old voice cannot be had")

        // Change Voice: the paused job goes, the book is submitted in a voice that works.
        await renderer.cancel(oldID)
        var new = old
        new.voices.narrator = "kokoro:af_sky"
        let newID = BookJob.id(for: new)
        XCTAssertNotEqual(newID, oldID)
        _ = try await renderer.submit(new, id: newID)
        await waitFor(5) { store.load(newID)?.status == .ready }
        XCTAssertEqual(store.load(newID)?.status, .ready, "the book in its new voice is made without a relaunch")
        let attempts = synth.attempts
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(synth.attempts, attempts, "the cancelled job asks for nothing more")
        await renderer.stop()
    }
}
