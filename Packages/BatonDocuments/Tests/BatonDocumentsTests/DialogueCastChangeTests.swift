import Foundation
import XCTest
@testable import BatonDocuments

/// Voice the dialogue in Change Voice…: a book already made, given a cast, its cast
/// edited, or its cast taken away, from the words it keeps.
final class DialogueCastChangeTests: XCTestCase {
    private let narrator = "kokoro:bf_isabella"
    private let voices = ["kokoro:bf_isabella", "kokoro:bf_emma", "kokoro:bm_george", "kokoro:bm_fable", "kokoro:bf_alice"]

    private let sheet = DialogueCast.CastSheet(characters: [
        DialogueCast.Character(name: "Mary", gender: "f", age: "old", aliases: ["his mother"]),
        DialogueCast.Character(name: "Tom", gender: "m", age: "young", aliases: ["her son"]),
        DialogueCast.Character(name: "Thomas", gender: "m", age: "young", aliases: ["the boy"]),
    ])

    /// Two chapters, one numbered ("Chapter 1. The Cell"), with an empty paragraph, a speech that
    /// runs over two paragraphs, a tagged line each, and a line nobody can place.
    private var document: ImportedDocument {
        ImportedDocument(sourceSHA256: String(repeating: "cd", count: 32), sourceKind: .epub, title: "The Room",
                         author: "E. M. Forster", language: "en", chapters: [
            DocumentChapter(index: 0, title: "The Cell", paragraphs: [
                "Mary sat in her chair in the small room, and the bell rang twice.",
                "",
                "\u{201C}Who is it at this hour?\u{201D} said his mother.",
                "\u{201C}It is only me,\u{201D} said Tom. \u{201C}I came up the long way,",
                "\u{201C}and the lights were out on every floor.\u{201D}",
                "The light flickered. Somebody laughed in the corridor.",
                "\u{201C}Is anyone there?\u{201D}",
                "\u{201C}I came to see the surface,\u{201D} said the boy.",
            ], label: "1"),
            DocumentChapter(index: 1, title: "The Surface", paragraphs: [
                "The air was thin and cold. \u{201C}Come back,\u{201D} said his mother, and nobody did.",
            ]),
        ])
    }

    private var plan: VoicePlan { VoicePlan(narrator: narrator) }

    private func casting() -> DialogueCast.Casting {
        DialogueCast.Casting(sheet: sheet, document: document, narrator: narrator, available: voices, source: "a test model")
    }

    private func segments(_ book: PreparedBook) -> [SpeechSegment] { book.chapters.flatMap(\.segments) }

    // MARK: The words

    /// The words a book keeps are the words it was made from: prepared again they give the same
    /// book, chunk for chunk, under the same id.
    func testABookMadeAgainFromItsOwnWordsIsTheSameBook() {
        var book = DocumentSpeech.prepare(document, voices: plan)
        book.lexicon = PronunciationLexicon(entries: [PronunciationLexicon.Entry(word: "Kuno", phonemes: "kˈunO", source: "person")])
        XCTAssertEqual(book.reprepared(plan: book.voices), book)
        XCTAssertEqual(BookJob.id(for: book.reprepared(plan: book.voices)), BookJob.id(for: book))
        XCTAssertEqual(book.spokenDocument.sourceSHA256, book.documentID)
        XCTAssertEqual(book.spokenDocument.chapters[0].paragraphs[1], "", "a paragraph that made nothing stays in its place")
    }

    // MARK: Turning a cast on

    /// A cast chosen in Change Voice gives the book the import sheet would have made with it.
    func testACastForABookAlreadyMadeIsTheCastTheImportWouldHaveMade() {
        let made = DocumentSpeech.prepare(document, voices: plan)
        let fill = DialogueCast.Fill(speakers: ["c1q4": "Thomas"], asked: 1, answered: 1, source: "a test model",
                                     setAside: 0, quotes: 6, placedByRules: 4)
        let cast = casting()
        let atImport = DialogueCast.prepare(document, plan: plan, casting: cast, fill: fill)
        let later = made.reprepared(plan: plan, casting: cast, fill: fill)
        XCTAssertTrue(later.hasCast)
        XCTAssertEqual(later.chapters, atImport.chapters)
        XCTAssertEqual(later.voices, atImport.voices)
        XCTAssertEqual(BookJob.id(for: later), BookJob.id(for: atImport))
        XCTAssertEqual(segments(later).first { $0.text.contains("surface") }?.speaker, "Thomas", "the line the model placed")
    }

    // MARK: Editing a cast

    private func castBook() -> PreparedBook {
        DialogueCast.prepare(document, plan: plan, casting: casting())
    }

    func testTheCastOfABookIsReadBackWithItsLinesAndVoices() throws {
        let book = castBook()
        let c = try XCTUnwrap(book.casting)
        XCTAssertEqual(Set(c.speakers.map(\.name)), Set(book.voices.characters.keys))
        let mary = try XCTUnwrap(c.speaker("Mary"))
        XCTAssertEqual(mary.voice, book.voices.characters["Mary"])
        XCTAssertEqual(mary.lines, segments(book).filter { $0.speaker == "Mary" }.count)
        XCTAssertEqual(mary.sample, "Who is it at this hour?", "a line of theirs to hear, without its marks")
        XCTAssertEqual(mary.character.gender, "f", "from the voice: the sheet itself is not kept with the book")
        XCTAssertNil(DocumentSpeech.prepare(document, voices: plan).casting, "a book with no cast has none to edit")
    }

    /// Rename, revoice, merge and remove change who speaks the lines already placed, and nothing
    /// else: no line moves to someone it was not given to, narration is untouched.
    func testEditingACastKeepsEveryLineWithItsSpeaker() throws {
        let book = castBook()
        var c = try XCTUnwrap(book.casting)
        XCTAssertTrue(c.rename("Mary", to: "Mrs. Kuno"))
        c.setVoice("Tom", "kokoro:bm_fable")
        c.merge("Thomas", into: "Tom")
        let edited = book.recast(c)

        XCTAssertEqual(edited.voices.characters, ["Mrs. Kuno": book.voices.characters["Mary"]!, "Tom": "kokoro:bm_fable"])
        for (before, after) in zip(segments(book), segments(edited)) {
            XCTAssertEqual(before.text, after.text)
            switch before.speaker {
            case "Mary": XCTAssertEqual(after.speaker, "Mrs. Kuno")
            case "Tom", "Thomas": XCTAssertEqual(after.speaker, "Tom", "Thomas merged into Tom speaks as Tom")
            default: XCTAssertNil(after.speaker)
            }
        }
        XCTAssertEqual(edited.voices.narrator, narrator)

        // Not a speaker, and the narrator: their lines go to the narrator.
        var fewer = try XCTUnwrap(edited.casting)
        fewer.remove("Tom")
        let less = edited.recast(fewer)
        XCTAssertEqual(less.voices.characters, ["Mrs. Kuno": book.voices.characters["Mary"]!])
        XCTAssertFalse(segments(less).contains { $0.speaker == "Tom" })
    }

    /// A speaker left without a voice of their own, or every speaker removed: with nobody voiced
    /// the book is the narrator-only book, chunk for chunk.
    func testACastEditedDownToNobodyIsTheNarratorOnlyBook() throws {
        let book = castBook()
        var c = try XCTUnwrap(book.casting)
        for speaker in c.speakers { c.setNarrator(speaker.id, false); c.setVoice(speaker.id, nil) }
        XCTAssertEqual(book.recast(c), DocumentSpeech.prepare(document, voices: plan))
    }

    // MARK: Turning it off, and the narrator

    func testTurningTheCastOffGivesTheNarratorOnlyBook() {
        let book = castBook()
        XCTAssertTrue(book.hasCast)
        let off = book.withoutCast()
        XCTAssertFalse(off.hasCast)
        XCTAssertEqual(off, DocumentSpeech.prepare(document, voices: plan))
        XCTAssertEqual(DocumentSpeech.prepare(document, voices: plan).withoutCast(), DocumentSpeech.prepare(document, voices: plan))
    }

    /// Changing the narrator keeps the cast, and the cast can still be edited after.
    func testANewNarratorKeepsTheCast() throws {
        let book = castBook().inVoice("kokoro:af_heart")
        XCTAssertTrue(book.hasCast)
        XCTAssertEqual(book.voices.narrator, "kokoro:af_heart")
        var c = try XCTUnwrap(book.casting)
        c.setVoice("Mary", "kokoro:bf_alice")
        XCTAssertEqual(book.recast(c).voices.characters["Mary"], "kokoro:bf_alice")
        XCTAssertEqual(book.recast(c).voices.narrator, "kokoro:af_heart")
    }
}

/// What Change Voice… makes again, from the switch and the cast.
final class DialogueCastFlowChangeTests: XCTestCase {
    private let narrator = "kokoro:bf_isabella"
    private let voices = ["kokoro:bf_isabella", "kokoro:bf_emma", "kokoro:bm_george", "kokoro:bm_fable", "kokoro:bf_alice"]
    private let sheet = DialogueCast.CastSheet(characters: [
        DialogueCast.Character(name: "Mary", gender: "f", age: "old", aliases: ["his mother"]),
        DialogueCast.Character(name: "Tom", gender: "m", age: "young", aliases: ["her son"]),
    ])
    private var document: ImportedDocument {
        ImportedDocument(sourceSHA256: String(repeating: "ef", count: 32), sourceKind: .text, title: "Talk", author: nil,
                         language: "en", chapters: [DocumentChapter(index: 0, title: "One", paragraphs: [
                            "\u{201C}Who is it?\u{201D} said his mother.",
                            "\u{201C}Only me,\u{201D} said Tom.",
                         ])])
    }
    private var plain: PreparedBook { DocumentSpeech.prepare(document, voices: VoicePlan(narrator: narrator)) }
    private var casting: DialogueCast.Casting {
        DialogueCast.Casting(sheet: sheet, document: document, narrator: narrator, available: voices, source: "a test model")
    }
    private var cast: PreparedBook { DialogueCast.prepare(document, plan: VoicePlan(narrator: narrator), casting: casting) }

    func testOpeningChangesNothing() {
        for book in [plain, cast] {
            let change = DialogueCastFlow.Change(book)
            XCTAssertEqual(change.choice.isOn, book.hasCast, "the switch shows whether the book has a cast")
            XCTAssertFalse(change.changes(narrator: narrator))
            XCTAssertFalse(change.holdsTheBook)
            XCTAssertEqual(change.book(narrator: narrator), book)
        }
    }

    func testANewNarratorKeepsTheCast() {
        let change = DialogueCastFlow.Change(cast)
        XCTAssertTrue(change.changes(narrator: "kokoro:af_heart"))
        XCTAssertEqual(change.book(narrator: "kokoro:af_heart"), cast.inVoice("kokoro:af_heart"))
        XCTAssertEqual(change.book(narrator: "kokoro:af_heart").voices.characters, cast.voices.characters)
    }

    func testTurningOnWaitsForTheCheckedCast() {
        var change = DialogueCastFlow.Change(plain)
        change.choice.isOn = true
        change.choice.phase = .writing
        XCTAssertTrue(change.holdsTheBook)
        XCTAssertFalse(change.changes(narrator: narrator), "nothing to make until the cast is checked")
        change.choice.phase = .ready(casting)
        XCTAssertTrue(change.holdsTheBook, "not checked yet")
        change.choice.reviewed = true
        change.choice.placing = .placed(DialogueCast.Fill(), line: DialogueCastFlow.skippedLine)
        XCTAssertFalse(change.holdsTheBook)
        XCTAssertTrue(change.changes(narrator: narrator))
        XCTAssertEqual(change.book(narrator: narrator), cast)
    }

    /// No model answered: said plainly, and the book keeps one narrator.
    func testWithNoModelTheBookKeepsOneNarrator() async {
        var change = DialogueCastFlow.Change(plain)
        change.choice.isOn = true
        let result = await DialogueCastFlow.propose(for: plain.spokenDocument, narrator: narrator, router: ModelRouter(sources: []),
                                                    executor: { _, _, _ in "" }, voices: { [] },
                                                    noModel: DialogueCastFlow.noCastLine(device: "this iPhone"))
        change.choice.phase = result.phase
        XCTAssertEqual(result.phase, .unavailable("No model on this iPhone or the Baton server can write a cast list, so the narrator reads every line."))
        XCTAssertFalse(change.holdsTheBook)
        XCTAssertFalse(change.changes(narrator: narrator))
        XCTAssertEqual(change.book(narrator: "kokoro:af_heart"), plain.inVoice("kokoro:af_heart"))
    }

    /// Every engine's voices for a speaker, and one from another engine stays through an edit
    /// (TBX-11141: a chapter's clips are converted to one format as it is joined).
    func testASpeakerCanHaveAnotherEnginesVoice() throws {
        let offered = ["kokoro:bf_emma", "openai:Ryan", "chatterbox:Emily.wav"]
        XCTAssertEqual(Array(DialogueCastFlow.speakerVoices(narrator: narrator, offered: offered, casting: casting).prefix(3)), offered,
                       "every engine's voices, then any the cast already has")
        var change = DialogueCastFlow.Change(cast)
        var edited = try XCTUnwrap(change.edited)
        edited.setVoice("Tom", "openai:Ryan")
        change.edited = edited
        let book = change.book(narrator: narrator)
        XCTAssertEqual(book.voices.characters["Tom"], "openai:Ryan")
        XCTAssertTrue(book.chapters.flatMap(\.segments).contains { $0.speaker == "Tom" })
        XCTAssertEqual(book.voices.voice(for: book.chapters.flatMap(\.segments).first { $0.speaker == "Tom" }!), "openai:Ryan")
    }

    func testEditingAndTurningOffACast() throws {
        var change = DialogueCastFlow.Change(cast)
        var edited = try XCTUnwrap(change.edited)
        let other = try XCTUnwrap(["kokoro:bm_george", "kokoro:bm_fable"].first { $0 != edited.speaker("Tom")?.voice })
        edited.setVoice("Tom", other)
        change.edited = edited
        XCTAssertTrue(change.changes(narrator: narrator))
        XCTAssertEqual(change.book(narrator: narrator).voices.characters["Tom"], other)
        change.choice.isOn = false
        XCTAssertEqual(change.book(narrator: narrator), plain)
        XCTAssertEqual(change.book(narrator: "kokoro:af_heart"), plain.inVoice("kokoro:af_heart"))
    }
}
