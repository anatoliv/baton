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
