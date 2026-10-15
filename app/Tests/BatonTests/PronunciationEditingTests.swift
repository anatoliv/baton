import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// The lexicon editor on the Mac (M8.6): a field per word, a correction becomes the person's
/// word in Kokoro's spelling, and saving re-makes exactly the chapters whose text changes.
@MainActor
final class PronunciationEditingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-lexicon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func book(narrator: String = "kokoro:bf_emma") throws -> PreparedBook {
        let url = root.appendingPathComponent("book.md")
        try """
        # The Machine Stops

        ## The Air-Ship

        Vashti sat in her room. The bell rang and she touched a switch.

        ## The Mending Apparatus

        Kuno called from the other side of the earth. Vashti did not want to come.
        """.write(to: url, atomically: true, encoding: .utf8)
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: narrator))
    }

    func testEditsBecomeThePersonsWordsAndEmptiedFieldsDropTheWord() {
        var proposed = PronunciationLexicon()
        proposed.set("Vashti", ipa: "ˈvæʃti", source: "model")
        proposed.set("Kuno", ipa: "ˈkjuːnoʊ", source: "model")
        var rows = PronunciationEditing.rows(proposed)
        XCTAssertEqual(rows.map(\.word), ["Kuno", "Vashti"])
        XCTAssertEqual(rows.map(\.sourceText), ["proposed by a model", "proposed by a model"])

        rows[0].phonemes = "kˈuːnoʊ"      // corrected, in IPA
        rows[1].phonemes = ""             // dropped
        rows.append(.init(word: "Himalayas", phonemes: "hɪməˈleɪəz", source: "person"))
        rows.append(.init(word: "Bad", phonemes: "@@", source: "person"))   // not phonemes: ignored
        let edited = PronunciationEditing.lexicon(from: rows, original: proposed)
        XCTAssertEqual(edited?.entries.map(\.word), ["Himalayas", "Kuno"])
        XCTAssertEqual(edited?.entries.map(\.phonemes), ["hɪməˈlAəz", "kˈuːnO"], "IPA is converted to Kokoro's spelling")
        XCTAssertEqual(edited?.entries.map(\.source), ["person", "person"])

        let untouched = PronunciationEditing.lexicon(from: PronunciationEditing.rows(proposed), original: proposed)
        XCTAssertEqual(untouched, proposed, "unchanged rows keep the model's word, untouched")
        XCTAssertNil(PronunciationEditing.lexicon(from: [], original: proposed), "nothing left: no lexicon")
    }

    func testOnlyTheChaptersThatSayTheWordAreAffectedAndOnlyForKokoro() throws {
        let plain = try book()
        var kuno = plain
        kuno.lexicon = PronunciationLexicon()
        kuno.lexicon?.set("Kuno", ipa: "kˈuːnoʊ")
        XCTAssertEqual(PronunciationEditing.affectedChapters(from: plain, to: kuno), [1], "Kuno is only in chapter 2")
        var vashti = plain
        vashti.lexicon = PronunciationLexicon()
        vashti.lexicon?.set("Vashti", ipa: "ˈvæʃti")
        XCTAssertEqual(PronunciationEditing.affectedChapters(from: plain, to: vashti), [0, 1])
        var nobody = plain
        nobody.lexicon = PronunciationLexicon()
        nobody.lexicon?.set("Himalayas", ipa: "hɪməˈleɪəz")
        XCTAssertEqual(PronunciationEditing.affectedChapters(from: plain, to: nobody), [], "a word the book never says")

        let chatterbox = try book(narrator: "chatterbox:Emily.wav")
        var marked = chatterbox
        marked.lexicon = kuno.lexicon
        XCTAssertEqual(PronunciationEditing.affectedChapters(from: chatterbox, to: marked), [], "another engine would read the brackets aloud, so none are sent")
    }

    /// Answers with a fifth of a second of silence and keeps every text it was asked for.
    actor RecordingKokoro: SpeechSynthesizing {
        private(set) var texts: [String] = []
        func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
            texts.append(text)
            let pcm = Data(count: 24_000 / 5 * 2)
            return WAV.header(format: .init(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16), dataBytes: pcm.count) + pcm
        }
    }

    private func eventually(_ library: DocumentLibrary, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            library.refresh()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out")
    }

    func testSavingACorrectionRemakesJustTheChaptersThatSayTheWord() async throws {
        let kokoro = RecordingKokoro()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("lexicon"))
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: kokoro, retry: .init(initialDelay: 0.02, maximumDelay: 0.05),
                                      refreshInterval: .milliseconds(50))
        library.start(force: true)
        let book = try book()
        try await library.submit(book)
        try await eventually(library) { clippings.chapters(ofDocument: book.documentID).count == 2 }
        let chapterOne = try XCTUnwrap(clippings.item(documentID: book.documentID, chapterIndex: 0))
        let chapterTwo = try XCTUnwrap(clippings.item(documentID: book.documentID, chapterIndex: 1))
        let askedBefore = await kokoro.texts.count
        let shelf = try XCTUnwrap(BookShelf.entries(items: clippings.items, jobs: library.jobs, ledger: clippings.ledger)
            .compactMap { if case let .book(b) = $0 { b } else { nil } }.first)

        // A word the book never says: saved, nothing re-made.
        var nobody = PronunciationLexicon()
        nobody.set("Himalayas", ipa: "hɪməˈleɪəz")
        let none = try await library.applyLexicon(nobody, to: shelf, clippings: clippings)
        XCTAssertEqual(none, [])
        let job = try XCTUnwrap(library.job(forDocument: book.documentID))
        XCTAssertEqual(library.store.load(job.id)?.book.lexicon, nobody)
        XCTAssertEqual(clippings.item(documentID: book.documentID, chapterIndex: 1)?.id, chapterTwo.id)
        let askedAfterNoop = await kokoro.texts.count
        XCTAssertEqual(askedAfterNoop, askedBefore)

        // Kuno, said in chapter 2 only: chapter 2 is re-made with the markup, chapter 1 stays.
        var kuno = nobody
        kuno.set("Kuno", ipa: "kˈuːnoʊ")
        let remade = try await library.applyLexicon(kuno, to: shelf, clippings: clippings)
        XCTAssertEqual(remade, [1])
        try await eventually(library) {
            if let item = clippings.item(documentID: book.documentID, chapterIndex: 1) { return item.id != chapterTwo.id }
            return false
        }
        XCTAssertEqual(clippings.item(documentID: book.documentID, chapterIndex: 0)?.id, chapterOne.id, "chapter 1 was not touched")
        let newJob = try XCTUnwrap(library.job(forDocument: book.documentID))
        XCTAssertNotEqual(newJob.id, job.id, "the lexicon is part of the job id")
        XCTAssertEqual(library.store.load(newJob.id)?.book.lexicon, kuno)
        let texts = await kokoro.texts
        XCTAssertTrue(texts.contains { $0.contains("[Kuno](/kˈuːnO/)") }, "the corrected name went to Kokoro marked up: \(texts.suffix(3))")
        XCTAssertFalse(texts.dropFirst(askedBefore).contains { $0.contains("Vashti sat in her room") }, "chapter 1's chunk came from the cache")
    }
}
