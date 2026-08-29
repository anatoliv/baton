import BatonSpeech
import XCTest
@testable import Baton

/// Read aloud, Phase 3: the coordinator that chunks, synthesizes and enqueues.
///
/// Every test here runs with the TTS host stubbed **and the native fallback off**, so the
/// coordinator's loop returns as soon as synthesis fails. That keeps the audio engine entirely
/// out of the way: what is under test is the preparation, the voice resolution and the
/// history-untouched property, none of which need a speaker.
@MainActor
final class ReadAloudCoordinatorTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        suite = UserDefaults(suiteName: "read-aloud-coord-\(UUID().uuidString)")!
        SpeechConfig.defaults = suite
        ReadAloudSettings.defaults = suite
        SpeechConfig.fallbackEnabled = false   // no native voice in tests
    }

    override func tearDown() {
        SpeechConfig.defaults = .standard
        ReadAloudSettings.defaults = .standard
    }

    /// A stub that records what it was asked to synthesize and then fails, so nothing reaches
    /// the audio engine.
    private struct StubFailure: Error {}

    private func makeCoordinator(_ music: MusicModel,
                                 record: @escaping (String, SpeechConfig.Voice) -> Void) -> ReadAloudCoordinator {
        let c = ReadAloudCoordinator(music: music)
        c.synthesize = { text, voice in
            record(text, voice)
            throw StubFailure()
        }
        return c
    }

    /// Drain the main-actor queue until the coordinator's task has run. The loop is one `await`
    /// deep before it fails, so a couple of yields is enough; the assertion, not the sleep, is
    /// what proves the work happened.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(120))
    }

    // MARK: - Preparation

    /// A selection that normalizes away to nothing must not start a reading — no synthesis, no
    /// duck, no HUD. Escape codes and whitespace are exactly what "nothing" looks like here.
    func testNothingSpeakableStartsNoReading() async {
        let music = MusicModel()
        var calls = 0
        let c = makeCoordinator(music) { _, _ in calls += 1 }

        c.read(.init(text: "\u{1B}[0m   \n\n  ", profile: .terminal, sourceName: "Ghostty"))
        await settle()

        XCTAssertEqual(calls, 0, "an empty selection should not reach the TTS host")
        XCTAssertFalse(c.isReading)
    }

    /// The first request must be a *sentence*, not the whole document. This is what makes first
    /// audio land in about a second instead of after the entire article renders.
    ///
    /// It also proves the 2000-character `maxSummaryChars` ceiling was not copied into this
    /// path: that limit exists to keep an agent's summary short, and a reading is legitimately
    /// long. A 6000-character selection must simply read.
    func testFirstRequestIsOneSentenceNotTheWholeDocument() async {
        let music = MusicModel()
        var requested: [String] = []
        let c = makeCoordinator(music) { text, _ in requested.append(text) }

        let article = (1...120).map { "This is sentence number \($0), of quite ordinary length." }
            .joined(separator: " ")
        XCTAssertGreaterThan(article.count, SpeechConfig.maxSummaryChars,
                             "the fixture must exceed the summary ceiling for this test to mean anything")

        c.read(.init(text: article, profile: .generic, sourceName: nil))
        await settle()

        XCTAssertEqual(requested.count, 1, "synthesis should stop at the first failure with fallback off")
        let first = try? XCTUnwrap(requested.first)
        XCTAssertLessThanOrEqual(first?.count ?? .max, SpeakableText.maxChunkCharacters)
        XCTAssertNotEqual(first, article, "the whole document must not be sent as one request")
    }

    // MARK: - Voices

    func testPerSourceVoicesOffUsesTheConfiguredDefault() async {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_bella", "terminal": "kokoro:am_fenrir"])
        ReadAloudSettings.perSourceVoices = false

        let music = MusicModel()
        var used: SpeechConfig.Voice?
        let c = makeCoordinator(music) { _, voice in used = voice }

        c.read(.init(text: "Build finished successfully after nine minutes.", profile: .terminal, sourceName: "Ghostty"))
        await settle()

        XCTAssertEqual(used?.voice, "af_bella", "with the toggle off, source must not change the voice")
    }

    func testPerSourceVoicesOnResolvesThroughTheCategoryMap() async {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_bella", "terminal": "kokoro:am_fenrir"])
        ReadAloudSettings.perSourceVoices = true

        let music = MusicModel()
        var used: SpeechConfig.Voice?
        let c = makeCoordinator(music) { _, voice in used = voice }

        c.read(.init(text: "Build finished successfully after nine minutes.", profile: .terminal, sourceName: "Ghostty"))
        await settle()

        XCTAssertEqual(used?.voice, "am_fenrir", "terminal should resolve through the ordinary category map")
    }

    /// An unmapped source falls back to the default voice rather than failing. `generic` has no
    /// category at all, so this is the common case for any app that is not a terminal or browser.
    func testGenericSourceFallsBackToTheDefaultVoice() async {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_bella"])
        ReadAloudSettings.perSourceVoices = true

        let music = MusicModel()
        var used: SpeechConfig.Voice?
        let c = makeCoordinator(music) { _, voice in used = voice }

        c.read(.init(text: "An ordinary paragraph from an ordinary application.", profile: .generic, sourceName: "Notes"))
        await settle()

        XCTAssertEqual(used?.voice, "af_bella")
    }

    // MARK: - Language (Phase 15)

    private let spanish = "La implementación terminó en cuarenta y dos segundos y todas las "
        + "comprobaciones salieron correctas. La migración de la base de datos se aplicó "
        + "limpiamente en los tres fragmentos del servidor."

    func testSpanishTextResolvesToTheSpanishVoiceCategory() {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_bella", "es": "kokoro:ef_dora"])
        XCTAssertEqual(ReadAloudCoordinator.languageCategory(for: spanish), "es")
    }

    /// English is the assumed default everywhere in this app. Naming it as a category would
    /// override a perfectly good source voice for no gain.
    func testEnglishNeverOverridesTheVoice() {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_bella", "es": "kokoro:ef_dora", "en": "kokoro:am_fenrir"])
        let english = "The deployment finished in forty two seconds and every single check came back green."
        XCTAssertNil(ReadAloudCoordinator.languageCategory(for: english))
    }

    /// A Spanish quotation inside an English article must not flip the voice. Detection runs
    /// once, over the whole reading, on the dominant language.
    func testAQuotationDoesNotFlipTheVoice() {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_bella", "es": "kokoro:ef_dora"])
        let mixed = "The release notes were unusually blunt this time. One engineer summarised "
            + "it as \"la migración salió bien\" and left it at that. Everything else in the "
            + "document is the usual list of fixes and known issues, in the same tone as always."
        XCTAssertNil(ReadAloudCoordinator.languageCategory(for: mixed))
    }

    /// Recognition on a fragment is guesswork, and guessing wrong here is audible.
    func testTooShortToJudgeLeavesTheVoiceAlone() {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_bella", "es": "kokoro:ef_dora"])
        XCTAssertNil(ReadAloudCoordinator.languageCategory(for: "Hola."))
    }

    /// An unmapped language reads in the configured voice rather than discarding a source voice
    /// for a category that would resolve to the default anyway.
    func testUnmappedLanguageLeavesTheVoiceAlone() {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_bella"])   // no "es" row
        XCTAssertNil(ReadAloudCoordinator.languageCategory(for: spanish))
    }

    // MARK: - History

    /// Decision 1: readings are never persisted. A long reading must leave Spoken Summaries
    /// exactly as it was — the store caps at 50 entries, so recording per utterance would evict
    /// a user's whole summary history on one article.
    ///
    /// This is structural rather than a flag — the only `speechHistory.record(...)` in the app
    /// is in `BatonMCPSpeakTools` — which is precisely why it is asserted: a later refactor that
    /// moved the write into the engine would break it silently.
    func testAReadingWritesNothingToSpeechHistory() async {
        let music = MusicModel()
        let before = music.speechHistory.entries.count
        let c = makeCoordinator(music) { _, _ in }

        let article = (1...40).map { "Sentence number \($0) of the article being read." }.joined(separator: " ")
        c.read(.init(text: article, profile: .browser, sourceName: "Google Chrome"))
        await settle()

        XCTAssertEqual(music.speechHistory.entries.count, before,
                       "a reading must not appear in Spoken Summaries")
    }

    // MARK: - HUD reading context (Phase 4)

    /// Every range must select exactly its own chunk out of the joined document. Computing the
    /// join and the offsets separately is how a highlight ends up one separator out per
    /// sentence — invisible at chunk one, badly wrong by chunk forty.
    func testLayoutRangesSelectTheirOwnChunk() {
        let chunks = ["First sentence.", "Second one here.", "And a third."]
        let (document, ranges) = ReadAloudCoordinator.layout(chunks)
        XCTAssertEqual(ranges.count, chunks.count)
        for (chunk, range) in zip(chunks, ranges) {
            XCTAssertEqual((document as NSString).substring(with: range), chunk)
        }
    }

    /// `NSRange` counts UTF-16 units while `String.count` counts characters, so anything outside
    /// the basic plane desynchronises the two. An emoji in a selection is ordinary, and getting
    /// this wrong would drift the highlight for the rest of the document.
    func testLayoutRangesSurviveMultibyteText() {
        let chunks = ["Shipped 🚀 at last.", "Then it broke 😤 again.", "Fixed."]
        let (document, ranges) = ReadAloudCoordinator.layout(chunks)
        for (chunk, range) in zip(chunks, ranges) {
            XCTAssertEqual((document as NSString).substring(with: range), chunk)
        }
    }

    /// The HUD shows the reading *entire*, highlighting where it is — not one sentence at a
    /// time with no sense of place.
    func testReadingContextCarriesTheWholeDocument() async {
        let music = MusicModel()
        let c = makeCoordinator(music) { _, _ in }

        c.read(.init(text: "First sentence here. Second sentence here. Third sentence here.",
                     profile: .generic, sourceName: nil))

        let reading = music.speech.reading
        XCTAssertNotNil(reading, "a reading must publish its context for the HUD")
        XCTAssertEqual(reading?.text, c.fullText)
        XCTAssertTrue(reading?.text.contains("First sentence") ?? false)
        XCTAssertTrue(reading?.text.contains("Third sentence") ?? false)
        XCTAssertEqual(reading?.spokenRange.location, 0, "the highlight starts at the first sentence")
        await settle()
    }

    func testStopClearsTheReadingContext() async {
        let music = MusicModel()
        let c = makeCoordinator(music) { _, _ in }

        c.read(.init(text: "Something long enough to be a chunk of its own.", profile: .generic, sourceName: nil))
        XCTAssertNotNil(music.speech.reading)
        c.stop()
        XCTAssertNil(music.speech.reading, "a stopped reading must not linger in the HUD")
        await settle()
    }

    /// An ordinary spoken summary is a single utterance and must not acquire reading state —
    /// otherwise the HUD would hide the scrubber for summaries too.
    func testAnOrdinarySummaryHasNoReadingContext() {
        let music = MusicModel()
        XCTAssertNil(music.speech.reading)
        music.speech.play(.native("A short spoken summary."), text: "A short spoken summary.")
        XCTAssertNil(music.speech.reading)
        music.speech.stop()
    }

    // MARK: - Cancellation

    func testStopEndsTheReading() async {
        let music = MusicModel()
        let c = makeCoordinator(music) { _, _ in }

        c.read(.init(text: "One sentence. Two sentences. Three sentences here.", profile: .generic, sourceName: nil))
        c.stop()

        XCTAssertFalse(c.isReading)
        XCTAssertNil(c.fullText, "stopping clears the reading rather than leaving it on screen")
        await settle()
    }

    /// Starting a second reading replaces the first rather than interleaving with it.
    func testASecondReadingReplacesTheFirst() async {
        let music = MusicModel()
        var requested: [String] = []
        let c = makeCoordinator(music) { text, _ in requested.append(text) }

        c.read(.init(text: "The first selection, which is long enough to be a chunk.", profile: .generic, sourceName: nil))
        c.read(.init(text: "The second selection, which is also long enough to be one.", profile: .generic, sourceName: nil))
        await settle()

        XCTAssertTrue(requested.allSatisfy { !$0.contains("first selection") },
                      "the replaced reading should not still be synthesizing: \(requested)")
    }

    // MARK: - What a save has to work from

    /// Stopping a reading part-way must not also throw away the ability to save it.
    ///
    /// This is the whole reason the export re-synthesizes from text rather than joining the
    /// played audio: you can stop after one sentence and still keep the whole article. If
    /// `stop()` ever starts clearing `exportable`, "save that thing I was listening to" quietly
    /// stops working for the case it is most wanted in.
    func testAStoppedReadingIsStillSaveable() async {
        let music = MusicModel()
        let c = makeCoordinator(music) { _, _ in }

        // Sentences long enough to survive chunking: below `minChunkCharacters` they merge, and
        // the point here is that the *later* ones are kept, not how many chunks they make.
        c.read(.init(text: "The first sentence is long enough to stand on its own here. "
                         + "The second sentence is also comfortably long enough to stand alone. "
                         + "And the third one closes the reading with room to spare.",
                     profile: .generic, sourceName: "Google Chrome"))
        c.stop()
        await settle()

        let exportable = c.exportable
        XCTAssertNotNil(exportable)
        XCTAssertTrue(c.canExport)
        XCTAssertEqual(exportable?.sourceName, "Google Chrome")

        let joined = (exportable?.chunks ?? []).joined(separator: " ")
        XCTAssertTrue(joined.contains("third one closes the reading"),
                      "a save must hold the whole reading, not only the part that was spoken")
    }

    /// What a save would render is the **prepared** text, so a credential cannot reach an
    /// exported file even though the file outlives the reading.
    ///
    /// The redactor already protects the speaker. What this pins is that the export works from
    /// the same side of it — the reason the ticket could ship the Mac half without the audio
    /// needing a redactor of its own. Assembled at runtime so the literal never appears in
    /// source; `publish-repo.sh`'s secret scan cannot tell a fixture from the real thing.
    func testWhatWouldBeSavedIsAlreadyRedacted() async {
        let music = MusicModel()
        let c = makeCoordinator(music) { _, _ in }
        let token = "ghp" + "_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"

        c.read(.init(text: "Here is the token \(token) and here is a following sentence.",
                     profile: .terminal, sourceName: "Ghostty"))
        await settle()

        let joined = (c.exportable?.chunks ?? []).joined(separator: " ")
        XCTAssertFalse(joined.isEmpty, "the reading produced nothing to save")
        XCTAssertFalse(joined.contains(token), "an export would have carried the token into a file")
    }

    /// Nothing to save is the state at launch, and it is what the menu item reads.
    func testNothingIsSaveableBeforeAnyReading() {
        let c = makeCoordinator(MusicModel()) { _, _ in }
        XCTAssertFalse(c.canExport)
        XCTAssertNil(c.exportable)
    }

    // MARK: - Resuming where you left off

    /// A temp-directory store, so a test never touches the user's real saved readings.
    private func scratchStore() throws -> (UnfinishedReadings, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-coord-unfinished-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (UnfinishedReadings(directory: dir), dir)
    }

    /// Stopping part-way through records where the *engine* got to, not where the coordinator
    /// had synthesized to.
    ///
    /// Those differ by the lookahead: the loop renders two chunks ahead of what is being spoken,
    /// so saving the enqueued position would silently skip a sentence or two on every resume.
    /// The test advances the engine's reported range by hand and asserts the saved index follows
    /// that rather than the synthesis.
    func testStoppingSavesWhereTheEngineGotToNotWhereSynthesisGotTo() async throws {
        let (store, dir) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let music = MusicModel()
        let c = ReadAloudCoordinator(music: music, unfinished: store)
        // Slow but successful, so the reading is still in progress when stop() lands — which is
        // the situation this is about. (A 1-byte "clip" fails to load in the engine and makes no
        // sound; what matters here is that the loop keeps running.)
        c.synthesize = { _, _ in
            try await Task.sleep(for: .milliseconds(80))
            return Data([0x00])
        }

        let sentences = (1...6).map { "This is sentence number \($0), long enough to be its own chunk." }
        c.read(.init(text: sentences.joined(separator: " "), profile: .generic, sourceName: "Google Chrome"))
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(c.isReading, "the reading ended before the test could stop it")

        // The document the HUD is showing, and where each chunk sits in it.
        let chunks = try XCTUnwrap(c.exportable?.chunks)
        let (document, ranges) = ReadAloudCoordinator.layout(chunks)
        XCTAssertGreaterThan(ranges.count, 3, "need several chunks for this to mean anything")

        // Pretend the engine has started speaking the third chunk.
        music.speech.reading = .init(text: document, spokenRange: ranges[2])
        c.stop()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.resumeIndex, 2)
        XCTAssertEqual(store.entries.first?.sourceName, "Google Chrome")
        XCTAssertEqual(store.entries.first?.chunks, chunks, "the whole reading has to be kept, not the tail")
    }

    /// Resuming speaks the remainder, and does not start the article over.
    func testResumeStartsFromTheSavedPositionRatherThanTheBeginning() async throws {
        let (store, dir) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let music = MusicModel()
        var requested: [String] = []
        let c = ReadAloudCoordinator(music: music, unfinished: store)
        c.synthesize = { text, _ in
            requested.append(text)
            throw StubFailure()
        }

        let chunks = (1...5).map { "This is sentence number \($0), long enough to be its own chunk." }
        store.record(id: UUID(), chunks: chunks, resumeIndex: 3,
                     sourceName: "Ghostty", startedAt: Date())
        let entry = try XCTUnwrap(store.entries.first)

        c.resume(entry)
        await settle()

        let spoken = requested.joined(separator: " ")
        XCTAssertFalse(spoken.contains("sentence number 1"), "resume started the article over: \(requested)")
        XCTAssertTrue(spoken.contains("sentence number 4"), "resume did not reach the saved position")
    }

    /// Resuming keeps the entry's identity, so finishing an article you resumed removes it
    /// instead of leaving the original behind at its old position forever.
    func testResumingKeepsTheSameEntryRatherThanForkingANewOne() async throws {
        let (store, dir) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let music = MusicModel()
        let c = ReadAloudCoordinator(music: music, unfinished: store)
        c.synthesize = { _, _ in
            try await Task.sleep(for: .milliseconds(80))
            return Data([0x00])
        }

        let chunks = (1...6).map { "This is sentence number \($0), long enough to be its own chunk." }
        let id = UUID()
        store.record(id: id, chunks: chunks, resumeIndex: 2, sourceName: "Ghostty", startedAt: Date())

        c.resume(try XCTUnwrap(store.entries.first))
        try? await Task.sleep(for: .milliseconds(120))
        let resumedChunks = try XCTUnwrap(c.exportable?.chunks)
        let (document, ranges) = ReadAloudCoordinator.layout(resumedChunks)
        music.speech.reading = .init(text: document, spokenRange: ranges[min(1, ranges.count - 1)])
        c.stop()

        XCTAssertEqual(store.entries.count, 1, "resuming forked a second entry for the same article")
        XCTAssertEqual(store.entries.first?.id, id)
    }

    // MARK: - Stopping means stopping

    /// Stopping mid-reading must end the *production* of sentences, not just empty the queue.
    ///
    /// This is the bug behind "I closed the reading window and the next one opened to continue".
    /// The HUD's × cancelled the engine, which is the whole story for a spoken summary but only
    /// half of it for a reading: the coordinator's loop rendered the next sentence straight back
    /// into the queue that had just been emptied, `isSpeaking` went true again, and the window
    /// re-opened. Closing it dismissed one sentence and the article carried on.
    ///
    /// The assertion is that no further synthesis is requested after `stop()`. A test that only
    /// checked the queue was empty would have passed throughout the bug.
    func testStopEndsSynthesisRatherThanJustEmptyingTheQueue() async {
        let music = MusicModel()
        var requested: [String] = []
        let c = ReadAloudCoordinator(music: music)
        c.synthesize = { text, _ in
            requested.append(text)
            try await Task.sleep(for: .milliseconds(60))
            return Data([0x00])
        }

        c.read(.init(
            text: "The first sentence is long enough to be its own chunk here. "
                + "The second sentence is also long enough to stand by itself. "
                + "A third sentence, and a fourth that should never be requested at all. "
                + "This fifth one should certainly never reach the host either, not once.",
            profile: .generic, sourceName: nil
        ))
        // Let it get going, then stop the way the window's × now does.
        try? await Task.sleep(for: .milliseconds(80))
        let atStop = requested.count
        c.stop()
        await settle()

        XCTAssertFalse(c.isReading)
        XCTAssertNil(music.speech.reading, "the HUD would still have a document to show")
        XCTAssertLessThanOrEqual(
            requested.count, atStop + 1,
            "synthesis continued after stop — the loop kept feeding sentences into a queue the "
                + "user had just emptied, which is what re-opened the window: \(requested)"
        )
    }

    // MARK: - One bad chunk must not cost the rest of the reading

    /// A single synthesis failure mid-reading must not stop Baton asking the host.
    ///
    /// This is the bug a user heard as "the voice changes on longer selections". The TTS host
    /// closes idle keep-alive connections, and a reading is mostly idle — it renders only two
    /// chunks ahead of playback — so the first request after a gap dies on a dead socket while
    /// the host is answering in 15 ms. One failure latched `hostIsDown`, and every remaining
    /// sentence was spoken by the built-in macOS voice. Measured: a retry succeeds in 0.24 s.
    ///
    /// The assertion is that the host is asked for chunk three *after* chunk two failed. Under
    /// the old latching behaviour that request was never made, so this fails on the exact
    /// regression rather than on a proxy for it.
    func testOneFailedChunkDoesNotStopBatonAskingTheHost() async {
        SpeechConfig.fallbackEnabled = true    // the native voice stands in for the failed chunk
        defer { SpeechConfig.fallbackEnabled = false }

        let music = MusicModel()
        var requested: [String] = []
        let c = ReadAloudCoordinator(music: music)
        c.synthesize = { text, _ in
            requested.append(text)
            // Fail only the second chunk, the way a stale socket does.
            if requested.count == 2 { throw SpeechService.SynthError(message: "stale socket") }
            return Data([0x00])
        }

        c.read(.init(
            text: "The first sentence is long enough to be its own chunk here. "
                + "The second sentence is also long enough to stand by itself. "
                + "And the third sentence needs to be asked for after the failure.",
            profile: .generic, sourceName: nil
        ))
        await settle()

        XCTAssertGreaterThanOrEqual(
            requested.count, 3,
            "after one chunk failed Baton stopped asking the host — that is the latch that made "
                + "a long reading change voice part-way and stay changed: \(requested)"
        )
    }

    /// A host that is genuinely gone still gives up promptly rather than making every sentence
    /// wait out its own timeout, which is what the original latch was right to avoid.
    func testAHostThatKeepsFailingIsGivenUpOn() async {
        SpeechConfig.fallbackEnabled = true
        defer { SpeechConfig.fallbackEnabled = false }

        let music = MusicModel()
        var requested: [String] = []
        let c = ReadAloudCoordinator(music: music)
        c.synthesize = { text, _ in
            requested.append(text)
            throw SpeechService.SynthError(message: "host is gone")
        }

        c.read(.init(
            text: "The first sentence is long enough to be its own chunk here. "
                + "The second sentence is also long enough to stand by itself. "
                + "And a third sentence, plus a fourth that should never be requested at all. "
                + "This fifth one should certainly never reach the host either, not once.",
            profile: .generic, sourceName: nil
        ))
        await settle()

        XCTAssertEqual(
            requested.count, 2,
            "a dead host should be given up on after two consecutive failures, not asked for "
                + "every sentence: \(requested)"
        )
    }
}

/// The synthetic-copy regression from 0.17.1, pinned.
///
/// This is a one-assertion test about a constant, which normally earns nothing. It earns its
/// place here because the bug it guards is invisible to every other kind of check: with
/// `.combinedSessionState` the code compiles, runs, raises no error, and reports the same
/// `.noSelection` as an empty selection — while the hotkey silently stops working in every
/// browser, which is the one source with no alternative route to its selection.
///
/// The behaviour itself cannot be tested here. It needs a real hotkey held down by a real hand
/// in front of a real browser, which is how it was found and is stated as such rather than
/// dressed up in a test that would pass either way.
@MainActor
final class SelectionCopyEventSourceTests: XCTestCase {
    func testTheSyntheticCopyUsesAPrivateEventSource() {
        XCTAssertEqual(
            SelectionReader.copyEventSourceState, .privateState,
            "a shared event-source state merges the modifiers the user is still holding for the "
                + "hotkey, so the target app receives ⌃⌘C rather than ⌘C and copies nothing"
        )
    }
}
