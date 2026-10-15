import Foundation
import XCTest
@testable import BatonDocuments

/// Recap and ask-the-book: the position is honoured exactly (rounded down), nothing after it
/// reaches a prompt, the reply is shaped for the ear, and retrieval finds the passage that
/// answers the question. Live tests with a real model and the real book are opt-in.
final class BookCompanionTests: XCTestCase {
    /// Three chapters; "the glass key" is introduced only in chapter 3, so any appearance of it
    /// before there is a spoiler.
    private func book() -> PreparedBook {
        let chapters = [
            DocumentChapter(index: 0, title: "The House", paragraphs: [
                "Ada lived alone in the tall house on the hill, with a cat called Moth.",
                "Every morning she wound the great clock in the hall, because her grandfather had told her it must never stop.",
                "Her brother Tobias wrote from the city once a month.",
            ]),
            DocumentChapter(index: 1, title: "The Letter", paragraphs: [
                "One winter a letter came that was not from Tobias.",
                "It said the clock was older than the house, and that Ada should not open its case.",
                "She read it twice by the fire and then put it in the drawer with the others.",
                "Moth watched her from the stairs.",
            ]),
            DocumentChapter(index: 2, title: "The Key", paragraphs: [
                "Inside the case of the clock, Ada found the glass key.",
                "Tobias arrived the next morning and would not say who had sent the letter.",
            ]),
        ]
        let doc = ImportedDocument(sourceSHA256: "c", sourceKind: .text, title: "The Clock", author: "A. Writer", chapters: chapters)
        return DocumentSpeech.prepare(doc, voices: VoicePlan(narrator: "kokoro:bf_emma"))
    }

    func testThePositionFromThePlayerRoundsDown() {
        let b = book()
        let chapter = b.chapters[1]
        let total = chapter.segments.reduce(0) { $0 + $1.text.count }
        let firstTwo = chapter.segments.prefix(2).reduce(0) { $0 + $1.text.count }
        // Just short of the end of the second segment: only one is heard.
        XCTAssertEqual(BookPosition(chapter: 1, fractionHeard: Double(firstTwo - 3) / Double(total), in: b).segment, 1)
        XCTAssertEqual(BookPosition(chapter: 1, fractionHeard: Double(firstTwo) / Double(total), in: b).segment, 2)
        XCTAssertEqual(BookPosition(chapter: 1, fractionHeard: 1, in: b).segment, chapter.segments.count)
        XCTAssertEqual(BookPosition(chapter: 9, fractionHeard: 0, in: b).chapter, 2, "clamped to the book")
        XCTAssertLessThan(BookPosition(chapter: 0, segment: 9), BookPosition(chapter: 1, segment: 0))
    }

    func testHeardTextStopsAtThePosition() {
        let b = book()
        let mid = BookPosition(chapter: 1, fractionHeard: 0.5, in: b)
        let heard = HeardText(b, upTo: mid)
        let text = heard.passages.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Moth"), "chapter 1 is heard")
        XCTAssertTrue(text.contains("not from Tobias"))
        XCTAssertFalse(text.contains("glass key"))
        XCTAssertFalse(text.contains("Moth watched"), "the end of chapter 2 is not heard yet")
        XCTAssertFalse(text.contains("The House"), "headings are not passages")
        XCTAssertEqual(heard.passages.first?.chapterTitle, "The House")
        XCTAssertTrue(HeardText(b, upTo: BookPosition(chapter: 0, segment: 0)).passages.isEmpty)
    }

    func testTheRecapPromptHoldsOnlyWhatWasHeard() {
        let b = book()
        let position = BookPosition(chapter: 1, segment: b.chapters[1].segments.count)
        let prompt = Recap.prompt(book: b, heard: HeardText(b, upTo: position), earlierNotes: [0: "Ada keeps the clock going.", 2: "SPOILER"])
        XCTAssertTrue(prompt.contains("Moth watched her from the stairs."), "ends where the listener stopped")
        XCTAssertFalse(prompt.contains("glass key"))
        XCTAssertFalse(prompt.contains("SPOILER"), "a note for a chapter not yet reached is never used")
        XCTAssertFalse(prompt.contains("Ada keeps the clock going."), "chapter 1 is in the recent text, so its note is not needed")
        XCTAssertFalse(prompt.contains("The Clock"), "the title is left out: it is the one piece of the future every book carries")
        XCTAssertTrue(prompt.hasPrefix("The most recent text heard"))
    }

    func testRecapsAreOfferedAfterABreakAndOnlyWithSomethingToRecap() {
        let b = book()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let all = HeardText(b, upTo: BookPosition(chapter: 2, segment: 99))
        XCTAssertLessThan(all.characterCount, Recap.minimumHeardCharacters, "this little book has too little to recap")
        let long = HeardText(DocumentSpeech.prepare(ImportedDocument(sourceSHA256: "l", sourceKind: .text, title: "L", chapters: [
            DocumentChapter(index: 0, title: "One", paragraphs: Array(repeating: "A sentence that goes on for a while, as sentences in books do.", count: 40)),
        ]), voices: VoicePlan(narrator: "kokoro:bf_emma")), upTo: BookPosition(chapter: 0, segment: 999))
        XCTAssertTrue(Recap.shouldOffer(lastPlayed: now.addingTimeInterval(-2 * 86_400), now: now, heard: long))
        XCTAssertFalse(Recap.shouldOffer(lastPlayed: now.addingTimeInterval(-3_600), now: now, heard: long))
        XCTAssertFalse(Recap.shouldOffer(lastPlayed: nil, now: now, heard: long))
        XCTAssertFalse(Recap.shouldOffer(lastPlayed: now.addingTimeInterval(-2 * 86_400), now: now, heard: all))
    }

    func testRecapRepliesAreShapedForTheEar() {
        XCTAssertEqual(Recap.clean("<think>hmm</think>\n## Recap\n**Previously**, Ada found a \"letter\" by the fire."),
                       "Previously, Ada found a letter by the fire.")
        XCTAssertEqual(Recap.clean("Ada wound the clock every single morning."), "Previously: Ada wound the clock every single morning.")
        XCTAssertNil(Recap.clean("OK."))
        let long = (0..<30).map { "Sentence \($0) has five words." }.joined(separator: " ")
        let cut = Recap.clean(long)!
        XCTAssertLessThanOrEqual(cut.split(separator: " ").count, Recap.maximumWords + 1)
        XCTAssertTrue(cut.hasSuffix("."))
    }

    func testRecapGoesThroughTheModelAndFallsSilentWithout() async {
        let b = DocumentSpeech.prepare(ImportedDocument(sourceSHA256: "l", sourceKind: .text, title: "L", chapters: [
            DocumentChapter(index: 0, title: "One", paragraphs: Array(repeating: "Ada wound the clock again, as she did every day.", count: 40)),
        ]), voices: VoicePlan(narrator: "kokoro:bf_emma"))
        let end = BookPosition(chapter: 0, segment: 999)
        let made = await Recap.make(book: b, position: end) { system, user in
            XCTAssertTrue(system.contains("Previously"))
            XCTAssertTrue(user.contains("Ada wound the clock"))
            return ("Previously, Ada kept winding the clock, every day without fail.", "test model")
        }
        XCTAssertEqual(made?.source, "test model")
        let silent = await Recap.make(book: b, position: end) { _, _ in throw ModelRouter.Failure(attempts: ["down"]) }
        XCTAssertNil(silent, "no model, no recap offered")
    }

    func testAskTheBookFindsTheAnsweringPassageAndNothingLater() {
        let b = book()
        let position = BookPosition(chapter: 1, segment: b.chapters[1].segments.count)
        let result = BookContext.lookUp("Who is Tobias again?", in: b, at: position, budget: 400)
        let texts = result.passages.map(\.text)
        XCTAssertTrue(texts.contains("Her brother Tobias wrote from the city once a month."), "\(texts)")
        XCTAssertEqual(texts.last, "Moth watched her from the stairs.", "the latest passage always comes, last")
        XCTAssertFalse(texts.joined().contains("glass key") || texts.joined().contains("arrived the next morning"))
        XCTAssertEqual(result.position, "Chapter 2 of 3, The Letter, at its end.")
        let tool = BookContext.toolText(result)
        XCTAssertTrue(tool.hasPrefix("Listener's position: Chapter 2 of 3"))
        XCTAssertTrue(tool.contains("[The House]") && tool.contains("[The Letter]"))

        // A name's first mention brings its neighbours, which say who it is.
        let intro = BookContext.lookUp("Who is Moth?", in: b, at: position, budget: 300)
        XCTAssertTrue(intro.passages.map(\.text).contains("Ada lived alone in the tall house on the hill, with a cat called Moth."))

        let early = BookContext.lookUp("Where did the key come from?", in: b, at: BookPosition(chapter: 0, segment: 0))
        XCTAssertTrue(early.passages.isEmpty)
        XCTAssertTrue(BookContext.toolText(early).hasPrefix("The listener has not heard any of the book yet."))
    }

    // MARK: - Live, opt-in

    private func sample() throws -> PreparedBook {
        guard let path = ProcessInfo.processInfo.environment["BATON_DOCS_SAMPLE"] else {
            throw XCTSkip("set BATON_DOCS_SAMPLE for the real book")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let r = LayoutTextImporter().extract(pages: text.components(separatedBy: "\u{0C}"))
        let doc = ImportedDocument(sourceSHA256: "sample", sourceKind: .pdf, title: r.title ?? "", author: r.author,
                                   language: "en", chapters: r.chapters, frontMatter: r.frontMatter)
        return DocumentSpeech.prepare(doc, voices: VoicePlan(narrator: "kokoro:bf_emma"))
    }

    private func liveComplete() async throws -> VoiceCaster.Complete {
        guard let model = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_MODEL"] else {
            throw XCTSkip("set BATON_LIVE_OLLAMA_MODEL to run against a real model")
        }
        let base = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_URL"] ?? "http://127.0.0.1:11434"
        let source = ModelSource(name: "\(model) (live)", provider: .ollama, baseURL: base, model: model, contextTokens: 8_192)
        let executor = HTTPModelClient.executor(apiKey: { _ in nil })
        guard let answer = try? await executor(source, "Answer with one word.", "Say OK."), answer.lowercased().contains("ok") else {
            throw XCTSkip("\(model) at \(base) did not answer a trivial prompt; not measurable")
        }
        let router = ModelRouter(sources: [source])
        return { system, user in try await router.complete(.recap, system: system, user: user, executor: executor) }
    }

    /// At the end of chapter 1 of *The Machine Stops*. Chapter 2's Wessex, the worms of the
    /// Mending Apparatus and the respirators of Kuno's climb are canaries: in the recap they
    /// could only come from a spoiler.
    func testALiveRecapOfTheSample() async throws {
        let b = try sample()
        let complete = try await liveComplete()
        let end1 = BookPosition(chapter: 0, segment: b.chapters[0].segments.count)
        let prompt = Recap.prompt(book: b, heard: HeardText(b, upTo: end1))
        for canary in ["Wessex", "worm", "Mending Apparatus"] { XCTAssertFalse(prompt.contains(canary), canary) }
        let started = Date()
        let made = await Recap.make(book: b, position: end1, complete: complete)
        let recap = try XCTUnwrap(made)
        print("LIVE recap in \(String(format: "%.1f", Date().timeIntervalSince(started))) s by \(recap.source): \(recap.text)")
        XCTAssertTrue(recap.text.hasPrefix("Previously"))
        XCTAssertLessThanOrEqual(recap.text.split(separator: " ").count, Recap.maximumWords + 2)
        for canary in ["Wessex", "worm", "Mending", "Machine stopped", "Machine stops"] { XCTAssertFalse(recap.text.contains(canary), canary) }
    }

    /// "Who is Kuno?" a little way into the sample, answered from the looked-up passages.
    func testALiveAnswerFromTheSample() async throws {
        let b = try sample()
        let complete = try await liveComplete()
        let position = BookPosition(chapter: 0, fractionHeard: 0.3, in: b)
        let context = BookContext.lookUp("Who is Kuno?", in: b, at: position)
        XCTAssertTrue(context.passages.contains { $0.text.contains("Kuno") })
        XCTAssertTrue(context.passages.contains { $0.text.contains("the image of her son") }, "the introduction, which does not name him")
        let system = "You answer a listener's question about the audiobook they are hearing. " + BookContext.toolDescription
            + " Answer in one or two spoken sentences."
        let reply = try await complete(system, "Question: Who is Kuno?\n\n" + BookContext.toolText(context))
        print("LIVE answer by \(reply.source): \(ModelReply.stripThinking(reply.text))")
        XCTAssertTrue(reply.text.lowercased().contains("son"), "Kuno is Vashti's son, which the opening says")
    }
}
