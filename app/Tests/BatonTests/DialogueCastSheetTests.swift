import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// "Voice the dialogue" on the import sheet (G4): off for the first book on a Mac and then as last
/// left, a cast that has not been checked is never used, and with the switch off the
/// book is the one it always was.
final class DialogueCastSheetTests: XCTestCase {
    private let narrator = "kokoro:bf_isabella"

    private var document: ImportedDocument {
        ImportedDocument(sourceSHA256: String(repeating: "ef", count: 32), sourceKind: .text, title: "Longbourn",
                         chapters: [DocumentChapter(index: 0, title: "Chapter I", paragraphs: [
                            "\u{201C}My dear Mr. Bennet,\u{201D} said his lady to him one day, \u{201C}have you heard?\u{201D}",
                            "Mr. Bennet replied that he had not.",
                            "\u{201C}You want to tell me, and I have no objection to hearing it,\u{201D} said her husband.",
                         ])])
    }

    private func casting(_ document: ImportedDocument? = nil) -> DialogueCast.Casting {
        DialogueCast.Casting(sheet: DialogueCast.CastSheet(characters: [
            DialogueCast.Character(name: "Mr. Bennet", gender: "m", age: "old", aliases: ["her husband"]),
            DialogueCast.Character(name: "Mrs. Bennet", gender: "f", age: "old", aliases: ["his lady"]),
        ]), document: document ?? self.document, narrator: narrator,
            available: ["kokoro:bf_isabella", "kokoro:bf_emma", "kokoro:bm_george"], source: "qwen3:8b on this Mac")
    }

    func testVoiceTheDialogueIsOffUntilSomeoneTurnsItOn() {
        let choice = DialogueCastChoice()
        XCTAssertFalse(choice.isOn)
        XCTAssertNil(choice.castingToUse)
        XCTAssertFalse(choice.holdsTheBook)
    }

    /// TBX-10916: off for the first book on a Mac, then each import starts as the person last
    /// left the switch on this Mac. The key stays on this Mac: it is not a synced preference.
    func testTheSwitchStartsAsThePersonLastLeftItOnThisMac() {
        let (name, defaults) = ThrowawayDefaults.suite("voice-the-dialogue")
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(DialogueCastChoice.remembered(in: defaults).isOn, "the first book on a Mac")
        DialogueCastChoice.remember(true, in: defaults)
        let next = DialogueCastChoice.remembered(in: defaults)
        XCTAssertTrue(next.isOn)
        XCTAssertEqual(next.phase, .idle, "remembered is only the switch: each book writes its own cast")
        XCTAssertFalse(next.reviewed)
        XCTAssertNil(next.castingToUse)
        XCTAssertFalse(next.holdsTheBook, "nothing is held until a cast is being written")
        DialogueCastChoice.remember(false, in: defaults)
        XCTAssertFalse(DialogueCastChoice.remembered(in: defaults).isOn)
        let synced = MainActor.assumeIsolated { PreferenceSync.syncedKeys }
        XCTAssertFalse(synced.contains(DialogueCastChoice.rememberedKey))
    }

    /// TBX-10916: with the voices the engine offers known, an English book starts with Heart, or
    /// Emma when it declared British English; without the list, or for another language, the
    /// configured default as before. The same shared rule the phone compiles.
    func testTheLanguageDefaultPrefersHeartOrEmmaWhenTheEngineHasThem() {
        var book = document
        book.language = "en"
        let voices = ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_george"]
        let configured = DocumentVoices.languageDefault(for: book)
        XCTAssertEqual(DocumentVoices.languageDefault(for: book, available: voices), "kokoro:af_heart")
        XCTAssertEqual(DocumentVoices.languageDefault(for: book, available: ["kokoro:bm_george"]), configured)
        book.languageRegion = "gb"
        XCTAssertEqual(DocumentVoices.languageDefault(for: book, available: voices), "kokoro:bf_emma")
        XCTAssertEqual(DocumentVoices.languageDefault(for: book, available: nil), configured)
        book.language = "fr"
        XCTAssertEqual(DocumentVoices.languageDefault(for: book, available: voices + ["kokoro:ff_siwis"]),
                       DocumentVoices.languageDefault(for: book))
    }

    func testWithTheSwitchOffTheBookIsTheNarratorOnlyBook() {
        var choice = DialogueCastChoice()
        choice.phase = .ready(casting())
        choice.reviewed = true
        let plan = VoicePlan.forBook(narrator: narrator)
        let made = DialogueCastEditing.book(document, plan: plan, choice: choice)
        XCTAssertEqual(made, DocumentSpeech.prepare(document, voices: plan))
        XCTAssertEqual(BookJob.id(for: made), BookJob.id(for: DocumentSpeech.prepare(document, voices: plan)))
    }

    func testACastNobodyCheckedHoldsTheBookAndIsNeverUsed() {
        var choice = DialogueCastChoice()
        choice.isOn = true
        choice.phase = .writing
        XCTAssertTrue(choice.holdsTheBook)
        choice.phase = .ready(casting())
        XCTAssertTrue(choice.holdsTheBook, "a generated sheet is checked before use")
        XCTAssertNil(choice.castingToUse)
        let plan = VoicePlan(narrator: narrator)
        XCTAssertEqual(DialogueCastEditing.book(document, plan: plan, choice: choice), DocumentSpeech.prepare(document, voices: plan))

        choice.reviewed = true
        XCTAssertFalse(choice.holdsTheBook)
        let cast = DialogueCastEditing.book(document, plan: plan, choice: choice)
        XCTAssertEqual(Set(cast.voices.characters.keys), ["Mr. Bennet", "Mrs. Bennet"])
        XCTAssertNotEqual(BookJob.id(for: cast), BookJob.id(for: DocumentSpeech.prepare(document, voices: plan)))
    }

    /// TBX-10894: once the cast is checked a model places the lines the rules leave. Make
    /// Audiobook waits while it does; its answers go into the book; with none, the rules' book.
    func testTheLinesTheRulesLeaveArePlacedBeforeTheBookIsMade() {
        // The three lines above are placed by their tags; a fourth, untagged, is left.
        var talk = document
        talk.chapters[0].paragraphs.append("\u{201C}Then I shall tell you.\u{201D}")
        var choice = DialogueCastChoice()
        choice.isOn = true
        choice.phase = .ready(casting(talk))
        choice.reviewed = true
        choice.placing = .placing(done: 1, of: 3)
        XCTAssertTrue(choice.holdsTheBook, "Make Audiobook waits for the placing")
        XCTAssertNil(choice.fillToUse)

        let plan = VoicePlan(narrator: narrator)
        let rulesOnly = DialogueCastEditing.book(talk, plan: plan, choice: choice)
        XCTAssertEqual(rulesOnly.chapters[0].segments.compactMap(\.speaker).count, 3, "the fourth line is the narrator's")
        let fill = DialogueCast.Fill(speakers: ["c1q4": "Mrs. Bennet"], asked: 1, answered: 1, source: "chat on the home server",
                                     quotes: 4, placedByRules: 3)
        choice.placing = .placed(fill, line: DialogueCastEditing.placedLine(fill))
        XCTAssertFalse(choice.holdsTheBook)
        XCTAssertEqual(choice.fillToUse, fill)
        let placed = DialogueCastEditing.book(talk, plan: plan, choice: choice)
        XCTAssertEqual(placed.chapters[0].segments.last?.speaker, "Mrs. Bennet")
        XCTAssertNotEqual(placed, rulesOnly)
        choice.placing = .placed(DialogueCast.Fill(), line: DialogueCastEditing.placedLine(DialogueCast.Fill()))
        XCTAssertEqual(DialogueCastEditing.book(talk, plan: plan, choice: choice), rulesOnly, "no answers: the rules' book")

        choice.isOn = false
        XCTAssertNil(choice.fillToUse, "switched off: no cast, no answers")
    }

    func testThePlacingLinesArePlain() {
        let fill = DialogueCast.Fill(speakers: ["c1q2": "Tom", "c1q5": "Mary"], asked: 2, answered: 2,
                                     source: "chat on the home server", quotes: 10, placedByRules: 4)
        XCTAssertEqual(DialogueCastEditing.placedLine(fill),
                       "chat on the home server placed 2 more lines, so 6 of 10 lines have a speaker. The narrator reads the rest.")
        XCTAssertEqual(DialogueCastEditing.placedLine(DialogueCast.Fill(quotes: 10, placedByRules: 4)),
                       "No model answered for the lines without a speech tag, so the narrator reads those.")
        XCTAssertEqual(DialogueCastEditing.noFillLine(router: ModelRouter(sources: [])),
                       "No model on this Mac or the Baton server can place the lines without a speech tag, so the narrator reads those.")
        let cloud = ModelSource(name: "Anthropic", provider: .anthropic, baseURL: "https://api.anthropic.com", model: "m", contextTokens: 200_000)
        var excerptsOnly = ModelConsent()
        excerptsOnly.grant(cloud, .excerpt)
        XCTAssertTrue(DialogueCastEditing.noFillLine(router: ModelRouter(sources: [cloud], consent: excerptsOnly))
            .contains("sending chapters to Anthropic is not allowed"), "chapter content, like the recap")
        for line in [DialogueCastEditing.placedLine(fill), DialogueCastEditing.noFillLine(router: ModelRouter(sources: [cloud]))] {
            XCTAssertFalse(line.contains("\u{2014}"), "no em dashes")
        }
    }

    func testNoModelMeansTheNarratorReadsEveryLineAndSaysWhy() {
        var choice = DialogueCastChoice()
        choice.isOn = true
        choice.phase = .unavailable(DialogueCastEditing.noModelLine(router: ModelRouter(sources: [])))
        XCTAssertFalse(choice.holdsTheBook)
        XCTAssertNil(choice.castingToUse)
        XCTAssertEqual(DialogueCastEditing.noModelLine(router: ModelRouter(sources: [])),
                       "No model on this Mac or the Baton server can write a cast list, so the narrator reads every line.")
        let cloud = ModelSource(name: "Anthropic", provider: .anthropic, baseURL: "https://api.anthropic.com", model: "m", contextTokens: 200_000)
        XCTAssertTrue(DialogueCastEditing.noModelLine(router: ModelRouter(sources: [cloud]))
            .contains("sending excerpts to Anthropic is not allowed"))
        XCTAssertNotNil(DialogueCastEditing.narratorLine("chatterbox:Emily.wav"))
        XCTAssertNil(DialogueCastEditing.narratorLine(narrator))
    }
}
