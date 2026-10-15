import Foundation
import XCTest
@testable import BatonDocuments

/// G4: the cast sheet as the person corrects it, the book made with it, and what each voice reads.
final class DialogueCastEditingTests: XCTestCase {
    private let narrator = "kokoro:bf_isabella"
    private let voices = ["kokoro:bf_isabella", "kokoro:bf_emma", "kokoro:bm_george", "kokoro:bm_fable", "kokoro:bf_alice"]

    private let sheet = DialogueCast.CastSheet(characters: [
        DialogueCast.Character(name: "Mary", gender: "f", age: "old", aliases: ["his mother"]),
        DialogueCast.Character(name: "Tom", gender: "m", age: "young", aliases: ["her son"]),
        DialogueCast.Character(name: "Thomas", gender: "m", age: "young", aliases: ["the boy"]),
    ])

    private func doc(_ paragraphs: [String]) -> ImportedDocument {
        ImportedDocument(sourceSHA256: String(repeating: "cd", count: 32), sourceKind: .text, title: "The Room",
                         chapters: [DocumentChapter(index: 0, title: "One", paragraphs: paragraphs)])
    }

    /// One tagged line each, a line the boy says under his other name, and one nobody can place.
    private var exchange: ImportedDocument {
        doc([
            "Mary sat in her chair in the small room, and the bell rang twice.",
            "\u{201C}Who is it at this hour?\u{201D} said his mother.",
            "\u{201C}It is only me,\u{201D} said Tom.",
            "The light flickered. Somebody laughed in the corridor.",
            "\u{201C}Is anyone there?\u{201D}",
            "\u{201C}I came to see the surface,\u{201D} said the boy.",
        ])
    }

    private func casting() -> DialogueCast.Casting {
        DialogueCast.Casting(sheet: sheet, document: exchange, narrator: narrator, available: voices, source: "a test model")
    }

    // MARK: Editing

    func testAGeneratedSheetGetsLinesAndDistinctVoicesNeverTheNarrators() {
        let c = casting()
        XCTAssertEqual(c.speakers.map(\.name), ["Mary", "Tom", "Thomas"])
        XCTAssertEqual(c.speaker("Mary")?.lines, 1)
        XCTAssertEqual(c.speaker("Tom")?.lines, 1)
        XCTAssertEqual(c.speaker("Thomas")?.lines, 1)
        XCTAssertEqual(c.speaker("Mary")?.sample, "Who is it at this hour?")
        let assigned = c.speakers.compactMap(\.voice)
        XCTAssertEqual(assigned.count, 3)
        XCTAssertEqual(Set(assigned).count, 3, "one voice, one person")
        XCTAssertFalse(assigned.contains(narrator))
        XCTAssertEqual(c.speaker("Mary")?.voice.map(VoiceCatalogue.describe)?.gender, "female")
        XCTAssertEqual(c.speaker("Tom")?.voice.map(VoiceCatalogue.describe)?.gender, "male")
    }

    func testRenameKeepsTheOldNameAsAPhraseAndRefusesATakenName() {
        var c = casting()
        XCTAssertTrue(c.rename("Mary", to: "Mrs. Kuno"))
        XCTAssertEqual(c.speaker("Mary")?.name, "Mrs. Kuno")
        XCTAssertEqual(c.speaker("Mary")?.character.aliases, ["his mother", "mary"])
        XCTAssertFalse(c.rename("Tom", to: "thomas"), "another speaker's name is a merge, not a rename")
        XCTAssertFalse(c.rename("Tom", to: "  "))
        XCTAssertEqual(c.speaker("Tom")?.name, "Tom")
        // The renamed speaker's voice follows the new name.
        XCTAssertNotNil(c.voices(narrator: narrator)["Mrs. Kuno"])
        XCTAssertNil(c.voices(narrator: narrator)["Mary"])
    }

    func testMergeMakesTwoEntriesOnePerson() {
        var c = casting()
        let tomVoice = c.speaker("Tom")?.voice
        c.merge("Thomas", into: "Tom")
        XCTAssertEqual(c.speakers.map(\.name), ["Mary", "Tom"])
        XCTAssertEqual(c.speaker("Tom")?.character.aliases, ["her son", "thomas", "the boy"])
        XCTAssertEqual(c.speaker("Tom")?.lines, 2)
        XCTAssertEqual(c.speaker("Tom")?.voice, tomVoice, "the target keeps its voice")
        c.merge("Tom", into: "Tom")
        XCTAssertEqual(c.speakers.count, 2, "merging into itself changes nothing")
    }

    func testOneNarratorAtATimeAndTheNarratorHasNoVoiceOfTheirOwn() {
        var c = casting()
        c.setNarrator("Tom", true)
        c.setNarrator("Mary", true)
        XCTAssertEqual(c.speakers.filter(\.isNarrator).map(\.id), ["Mary"])
        XCTAssertNil(c.voices(narrator: narrator)["Mary"])
        XCTAssertNotNil(c.voices(narrator: narrator)["Tom"])
        c.setNarrator("Mary", false)
        XCTAssertNotNil(c.voices(narrator: narrator)["Mary"])
    }

    func testVoicesAreChosenPerSpeakerAndOnlyOnTheNarratorsEngine() {
        var c = casting()
        c.setVoice("Tom", "kokoro:bm_fable")
        c.setVoice("Mary", "chatterbox:Emily.wav")
        c.setVoice("Thomas", nil)
        let plan = c.voices(narrator: narrator)
        XCTAssertEqual(plan["Tom"], "kokoro:bm_fable")
        XCTAssertNil(plan["Mary"], "a Chatterbox clip cannot be joined with Kokoro narration")
        XCTAssertNil(plan["Thomas"], "no voice: the narrator reads")
    }

    func testAliasesTakePhrasesNotPronouns() {
        var c = casting()
        c.setAliases("Mary", " His Mother, she, the woman,, mary , the woman")
        XCTAssertEqual(c.speaker("Mary")?.character.aliases, ["his mother", "the woman"])
        c.remove("Thomas")
        XCTAssertNil(c.speaker("Thomas"))
    }

    // MARK: The plan

    func testNarrationAndUnplacedQuotesStayWithTheNarratorAndEachQuoteGetsItsSpeaker() throws {
        var c = casting()
        c.setVoice("Mary", "kokoro:bf_emma")
        c.setVoice("Tom", "kokoro:bm_george")
        c.merge("Thomas", into: "Tom")
        let book = DialogueCast.prepare(exchange, plan: VoicePlan(narrator: narrator), casting: c)
        XCTAssertEqual(book.voices.narrator, narrator)
        XCTAssertEqual(book.voices.characters, ["Mary": "kokoro:bf_emma", "Tom": "kokoro:bm_george"])

        let segments = try XCTUnwrap(book.chapters.first?.segments)
        func voice(_ fragment: String) -> String? {
            segments.first { $0.text.contains(fragment) }.map(book.voices.voice(for:))
        }
        XCTAssertEqual(voice("Who is it at this hour?"), "kokoro:bf_emma")
        XCTAssertEqual(voice("It is only me"), "kokoro:bm_george")
        XCTAssertEqual(voice("I came to see the surface"), "kokoro:bm_george", "the merged name finds the boy's line")
        XCTAssertEqual(voice("Is anyone there?"), narrator, "nobody can say who asks: the narrator reads it")
        XCTAssertEqual(voice("The light flickered"), narrator)
        XCTAssertEqual(voice("said his mother"), narrator, "the speech tag is narration")
        XCTAssertEqual(voice("One"), narrator)
        for s in segments where s.kind != .quote { XCTAssertNil(s.speaker, s.text) }
    }

    func testANarratorSpeakersLinesAreTheNarratorOnlyBook() {
        var c = casting()
        c.setNarrator("Mary", true)
        c.setVoice("Tom", nil)
        c.setVoice("Thomas", nil)
        let plan = VoicePlan(narrator: narrator)
        XCTAssertEqual(DialogueCast.prepare(exchange, plan: plan, casting: c), DocumentSpeech.prepare(exchange, voices: plan))
    }

    // MARK: Ids and keys

    func testANarratorOnlyBookKeepsItsIdAndKeysAndACastBookGetsItsOwn() throws {
        let plan = VoicePlan.forBook(narrator: narrator)
        let narratorOnly = DocumentSpeech.prepare(exchange, voices: plan)
        // A cast that voices nobody is the narrator-only book, byte for byte.
        var silent = casting()
        for s in silent.speakers { silent.setVoice(s.id, nil) }
        let unchanged = DialogueCast.prepare(exchange, plan: plan, casting: silent)
        XCTAssertEqual(try unchanged.encoded(), try narratorOnly.encoded())
        XCTAssertEqual(BookJob.id(for: unchanged), BookJob.id(for: narratorOnly))
        // The id the narrator-only plan always had: no characters key change, no new field.
        XCTAssertEqual(try String(decoding: BookJSON.sortedKeys.encode(plan), as: UTF8.self),
                       #"{"characters":{},"narrator":"kokoro:bf_isabella"}"#)

        let cast = DialogueCast.prepare(exchange, plan: plan, casting: casting())
        XCTAssertNotEqual(BookJob.id(for: cast), BookJob.id(for: narratorOnly))
        // A different voice for one person is a different job too.
        var other = casting()
        let tomNow = other.speaker("Tom")?.voice
        other.setVoice("Tom", tomNow == "kokoro:bm_fable" ? "kokoro:bm_george" : "kokoro:bm_fable")
        XCTAssertNotEqual(BookJob.id(for: DialogueCast.prepare(exchange, plan: plan, casting: other)), BookJob.id(for: cast))

        // Narration the two books share is the same chunk in the same voice: one cache entry.
        let keys = { (book: PreparedBook) in Set(book.chapters.flatMap(\.segments).map { book.request(for: $0).cacheKey }) }
        let shared = narratorOnly.chapters[0].segments.first { $0.text.hasPrefix("The light flickered") }!
        XCTAssertTrue(keys(cast).contains(narratorOnly.request(for: shared).cacheKey))
        // A quote in a character's voice is a key the narrator-only book never had.
        XCTAssertFalse(keys(cast).subtracting(keys(narratorOnly)).isEmpty)
    }

    /// The home server is handed the book as JSON and renders what it is given: the speakers
    /// and the character voices survive the trip.
    func testACastBookSurvivesTheTripToTheHomeServer() throws {
        let book = DialogueCast.prepare(exchange, plan: VoicePlan(narrator: narrator), casting: casting())
        let decoded = try PreparedBook.decode(try book.encoded())
        XCTAssertEqual(decoded, book)
        XCTAssertEqual(BookJob.id(for: decoded), BookJob.id(for: book))
        XCTAssertFalse(decoded.voices.characters.isEmpty)
    }

    // MARK: Rendering

    func testTheRendererSpeaksEachSegmentInItsSpeakersVoice() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = casting()
        c.setVoice("Mary", "kokoro:bf_emma")
        c.setVoice("Tom", "kokoro:bm_george")
        c.setVoice("Thomas", "kokoro:bm_fable")
        let book = DialogueCast.prepare(exchange, plan: VoicePlan(narrator: narrator), casting: c)
        let synth = FakeSynthesizer()
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: synth,
                                    muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let id = BookJob.id(for: book)
        _ = try await renderer.submit(book, id: id)
        await renderer.waitUntilIdle()
        XCTAssertEqual(store.load(id)?.status, .ready)

        let spoken = synth.calls
        XCTAssertEqual(spoken.count, book.segmentCount)
        func who(_ fragment: String) -> [String] { spoken.filter { $0.text.contains(fragment) }.map(\.voice) }
        XCTAssertEqual(who("Who is it at this hour?"), ["kokoro:bf_emma"])
        XCTAssertEqual(who("It is only me"), ["kokoro:bm_george"])
        XCTAssertEqual(who("I came to see the surface"), ["kokoro:bm_fable"])
        XCTAssertEqual(who("Is anyone there?"), [narrator])
        XCTAssertEqual(who("Mary sat in her chair"), [narrator])
        XCTAssertEqual(who("said Tom"), [narrator])
        XCTAssertEqual(Set(spoken.map(\.voice)), [narrator, "kokoro:bf_emma", "kokoro:bm_george", "kokoro:bm_fable"])
    }
}
