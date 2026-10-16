import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments

/// The pronunciation lexicon (M8.6) and Chatterbox's expressive style (M8.7): what each sends,
/// to which engine, and that a book with neither renders and caches exactly as before.
final class PronunciationLexiconTests: XCTestCase {
    func testIPABecomesKokorosSpelling() {
        XCTAssertEqual(PronunciationLexicon.kokoroPhonemes(fromIPA: "/ˈkuːnoʊ/"), "ˈkuːnO")
        XCTAssertEqual(PronunciationLexicon.kokoroPhonemes(fromIPA: "[ˈvæʃ.ti]"), "ˈvæʃti")
        XCTAssertEqual(PronunciationLexicon.kokoroPhonemes(fromIPA: "dʒeɪn"), "ʤAn")
        XCTAssertEqual(PronunciationLexicon.kokoroPhonemes(fromIPA: "ˈhɝmaɪəni"), "ˈhɜɹmIəni")
        XCTAssertEqual(PronunciationLexicon.kokoroPhonemes(fromIPA: "ˈgreɪ"), "ˈɡɹA")
        XCTAssertTrue(PronunciationLexicon.isValid("ˈkuːnO"))
        XCTAssertFalse(PronunciationLexicon.isValid("KOO-noh"), "respelling is not phonemes")
        XCTAssertFalse(PronunciationLexicon.isValid(""))
    }

    func testApplyMarksWholeWordsOnly() {
        var lexicon = PronunciationLexicon()
        lexicon.set("Kuno", ipa: "ˈkuːnoʊ")
        lexicon.set("Vashti", ipa: "ˈvæʃti")
        lexicon.set("Vashtiland", ipa: "ˈvæʃtilænd")
        lexicon.set("Bad", ipa: "KOO-noh")   // refused: not phonemes
        XCTAssertEqual(lexicon.entries.map(\.word), ["Kuno", "Vashti", "Vashtiland"])
        XCTAssertEqual(lexicon.apply(to: "Kuno saw Vashti's room, not Kunolike Vashtiland."),
                       "[Kuno](/ˈkuːnO/) saw [Vashti](/ˈvæʃti/)'s room, not Kunolike [Vashtiland](/ˈvæʃtilænd/).")
        let once = lexicon.apply(to: "Kuno.")
        XCTAssertEqual(lexicon.apply(to: once), once, "applying twice changes nothing")
        XCTAssertEqual(PronunciationLexicon().apply(to: "Kuno."), "Kuno.")
    }

    func testCandidatesAreRepeatedNamesNotSentenceStarts() {
        let doc = ImportedDocument(sourceSHA256: "x", sourceKind: .text, title: "T", chapters: [
            DocumentChapter(index: 0, title: "One", paragraphs: [
                "Then Kuno spoke. Vashti listened to Kuno in silence.",
                "Then the plate went dark, and Vashti said nothing on Monday, and Mr Smith agreed.",
                "Smith left. The xenomorph and the xenomorph's cousin came.",
            ]),
        ])
        let found = PronunciationLexicon.candidates(in: doc)
        XCTAssertEqual(found.map(\.word), ["Kuno", "Smith", "Vashti"], "Then is only ever first; Monday and Mr are common")
        XCTAssertEqual(found.first?.count, 2)
        XCTAssertEqual(found.first?.example, "Then Kuno spoke.")
        let withChecker = PronunciationLexicon.candidates(in: doc, isWord: { $0 != "xenomorph" })
        XCTAssertTrue(withChecker.map(\.word).contains("xenomorph"), "a word the spell checker does not know")
    }

    func testTheModelsProposalsAreCheckedBeforeTheyAreKept() {
        let candidates = [PronunciationLexicon.Candidate(word: "Kuno", count: 3, example: "Kuno spoke."),
                          PronunciationLexicon.Candidate(word: "Vashti", count: 3, example: "Vashti listened.")]
        let reply = """
        <think>names</think>Here you go: {"words": [{"word": "Kuno", "ipa": "/ˈkuːnoʊ/"},
        {"word": "Vashti", "ipa": "VASH-tee"}, {"word": "Machine", "ipa": "məˈʃiːn"}]}
        """
        let lexicon = PronunciationLexicon.parse(reply, candidates: candidates)
        XCTAssertEqual(lexicon.entries, [.init(word: "Kuno", phonemes: "ˈkuːnO", source: "model")],
                       "a respelling and a word nobody asked about are dropped")
        XCTAssertTrue(PronunciationLexicon.parse("no JSON at all", candidates: candidates).isEmpty)
    }

    /// TBX-10947: on the TBX-10886 walk (Pride and Prejudice, chapter 1) the US spell checker
    /// did not know the British "neighbourhood", so it was asked about beside "Netherfield",
    /// and Apple's on-device model gave both the same phonemes. The chapter then said
    /// "Netherfield" for "neighbourhood". The reply is the typed reply's JSON as the job's
    /// lexicon recorded it (`docs/evidence/tbx-10886/walk/job.json`).
    private let walkReply = """
        {"words": [{"word": "Netherfield", "ipa": "ˈnɛθəˌfiːld"}, {"word": "neighbourhood", "ipa": "ˈnɛθəˌfiːld"}]}
        """

    private var walkChapter: ImportedDocument {
        ImportedDocument(sourceSHA256: "pp", sourceKind: .text, title: "Pride and Prejudice", chapters: [
            DocumentChapter(index: 0, title: "Chapter 1", paragraphs: [
                "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed.",
                "“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?”",
                "“Why, my dear, you must know, Mrs. Long says that Netherfield is taken by a young man of large fortune.”",
                "“But, my dear, you must indeed go and see Mr. Bingley when he comes into the neighbourhood.”",
            ]),
        ])
    }

    func testTwoProposedWordsWithOneSoundAreBothDropped() {
        // What NSSpellChecker's default "en" dictionary answered for these on the walk's Mac.
        let usDictionary: (String) -> Bool? = { !["neighbourhood", "Netherfield"].contains($0) }
        let candidates = PronunciationLexicon.candidates(in: walkChapter, isWord: usDictionary)
        XCTAssertTrue(Set(candidates.map(\.word)).isSuperset(of: ["Netherfield", "neighbourhood"]),
                      "the walk's two words were both asked about: \(candidates.map(\.word))")

        let lexicon = PronunciationLexicon.parse(walkReply, candidates: candidates)
        XCTAssertFalse(lexicon.entries.contains { $0.word == "neighbourhood" }, "neighbourhood is not Netherfield")
        XCTAssertTrue(lexicon.isEmpty, "which of the two is the copy cannot be told, so both are read as written")

        let honest = PronunciationLexicon.parse("""
            {"words": [{"word": "Netherfield", "ipa": "ˈnɛðəfiːld"}, {"word": "neighbourhood", "ipa": "ˈneɪbəhʊd"}]}
            """, candidates: candidates)
        XCTAssertEqual(honest.entries.map(\.word), ["Netherfield", "neighbourhood"], "different sounds are both kept")
    }

    func testAStoredLexiconWithOneSoundForTwoWordsIsNotSentOnEitherRenderer() {
        // The walk's job carried the bad pair already; the Mac and the home server both mark
        // text through `PreparedBook.request(for:)`, so neither may send it.
        let stored = PronunciationLexicon(entries: [
            .init(word: "Netherfield", phonemes: "ˈnɛθəˌfiːld", source: "model"),
            .init(word: "neighbourhood", phonemes: "ˈnɛθəˌfiːld", source: "model"),
        ])
        var book = DocumentSpeech.prepare(walkChapter, voices: VoicePlan(narrator: "kokoro:bf_emma"))
        book.lexicon = stored
        let sent = book.chapters[0].segments.map { book.request(for: $0).text }.joined(separator: " ")
        XCTAssertTrue(sent.contains("into the neighbourhood"), sent)
        XCTAssertFalse(sent.contains("](/"), "no markup from the bad pair: \(sent)")

        // A person's word stands; a model's entry that repeats its sound for another word goes.
        var corrected = stored
        corrected.entries[0].source = "person"
        XCTAssertEqual(corrected.validated().entries.map(\.word), ["Netherfield"])
        XCTAssertEqual(corrected.apply(to: "Netherfield and the neighbourhood"),
                       "[Netherfield](/ˈnɛθəˌfiːld/) and the neighbourhood")

        // A word the model was not asked about is refused, and so are phonemes Kokoro cannot read.
        let asked = PronunciationLexicon(entries: [
            .init(word: "Bingley", phonemes: "ˈbɪŋli", source: "model"),
            .init(word: "Lizzy", phonemes: "LIZ-ee", source: "model"),
        ])
        XCTAssertEqual(asked.validated(asked: ["Netherfield"]).entries, [])
        XCTAssertEqual(asked.validated().entries.map(\.word), ["Bingley"])
    }
}

final class SpeechStyleTests: XCTestCase {
    private func book(narrator: String, lexicon: PronunciationLexicon? = nil, style: SpeechStyle? = nil) -> PreparedBook {
        var b = DocumentSpeech.prepare(ImportedDocument(sourceSHA256: "s", sourceKind: .text, title: "T", chapters: [
            DocumentChapter(index: 0, title: "One", paragraphs: ["Kuno called his mother from far away, as he often did."]),
        ]), voices: VoicePlan(narrator: narrator, style: style))
        b.lexicon = lexicon
        return b
    }

    private var lexicon: PronunciationLexicon {
        var l = PronunciationLexicon()
        l.set("Kuno", ipa: "ˈkuːnoʊ")
        return l
    }

    func testToneToStyle() {
        XCTAssertEqual(SpeechStyle.forTone("dark, ominous"), SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3))
        XCTAssertEqual(SpeechStyle.forTone("Playful and warm"), SpeechStyle(exaggeration: 0.6, cfgWeight: 0.4))
        XCTAssertEqual(SpeechStyle.forTone("measured, dry"), SpeechStyle(exaggeration: 0.35, cfgWeight: 0.5))
        XCTAssertNil(SpeechStyle.forTone("warm"), "no clear lean: the engine's defaults")
        XCTAssertNil(SpeechStyle.forTone(nil))
    }

    func testEachEngineGetsOnlyWhatItReads() {
        let style = SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3)
        let kokoro = book(narrator: "kokoro:bf_emma", lexicon: lexicon, style: style)
        let k = kokoro.request(for: kokoro.chapters[0].segments.last!)
        XCTAssertTrue(k.text.hasPrefix("[Kuno](/ˈkuːnO/) called"), k.text)
        XCTAssertNil(k.style, "Kokoro has no style")

        let chatterbox = book(narrator: "chatterbox:Emily.wav", lexicon: lexicon, style: style)
        let c = chatterbox.request(for: chatterbox.chapters[0].segments.last!)
        XCTAssertTrue(c.text.hasPrefix("Kuno called"), "Chatterbox would read the brackets aloud")
        XCTAssertEqual(c.style, style)
        XCTAssertNotEqual(c.cacheKey, chatterbox.chapters[0].segments.last!.cacheKey(voice: "chatterbox:Emily.wav", speed: nil),
                          "a styled chunk is a different chunk")
    }

    func testABookWithNeitherKeepsItsCacheKeysAndItsID() throws {
        let plain = book(narrator: "kokoro:bf_emma")
        for segment in plain.chapters[0].segments {
            XCTAssertEqual(plain.request(for: segment).cacheKey, segment.cacheKey(voice: "kokoro:bf_emma", speed: nil))
        }
        // A book encoded before lexicons and styles existed decodes, and keeps its job id.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BookJSON.encoder.encode(plain)) as? [String: Any])
        json.removeValue(forKey: "lexicon")
        let old = try PreparedBook.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.lexicon)
        XCTAssertNil(old.voices.style)
        XCTAssertEqual(BookJob.id(for: old), BookJob.id(for: plain))
        XCTAssertNotEqual(BookJob.id(for: book(narrator: "kokoro:bf_emma", lexicon: lexicon)), BookJob.id(for: plain),
                          "a corrected pronunciation is a new reading")
        XCTAssertEqual(BookJob.id(for: book(narrator: "kokoro:bf_emma", lexicon: PronunciationLexicon())), BookJob.id(for: plain))
    }

    func testTheRequestEachEngineGets() throws {
        let base = URL(string: "http://tts.test:8004")!
        let styled = try HTTPSpeechSynthesizer.request(base: base, engine: "chatterbox", voice: "Emily.wav", text: "Hello.",
                                                       speed: 0.9, style: SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3), timeout: 5)
        XCTAssertEqual(styled.url?.path, "/tts")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(styled.httpBody)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "Hello.")
        XCTAssertEqual(body["voice_mode"] as? String, "predefined")
        XCTAssertEqual(body["predefined_voice_id"] as? String, "Emily.wav")
        XCTAssertEqual(body["exaggeration"] as? Double, 0.7)
        XCTAssertEqual(body["cfg_weight"] as? Double, 0.3)
        XCTAssertEqual(body["speed_factor"] as? Double, 0.9)
        XCTAssertEqual(body["output_format"] as? String, "wav")
        XCTAssertEqual(body["split_text"] as? Bool, false, "Baton chunks; the server must not split again")

        let plain = try HTTPSpeechSynthesizer.request(base: base, engine: "chatterbox", voice: "Emily.wav", text: "Hello.",
                                                      speed: nil, style: nil, timeout: 5)
        XCTAssertEqual(plain.url?.path, "/v1/audio/speech")
        let kokoro = try HTTPSpeechSynthesizer.request(base: base, engine: "kokoro", voice: "bf_emma", text: "Hello.",
                                                       speed: nil, style: SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3), timeout: 5)
        XCTAssertEqual(kokoro.url?.path, "/v1/audio/speech", "a style never sends Kokoro elsewhere")
    }

    /// End to end through the shared renderer: the engine is asked for the marked-up text.
    func testTheRendererSendsTheLexiconToKokoro() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = FakeSynthesizer()
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let r = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: synth,
                             muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let b = book(narrator: "kokoro:bf_emma", lexicon: lexicon)
        _ = try await r.submit(b, id: BookJob.id(for: b))
        await r.waitUntilIdle()
        XCTAssertEqual(store.load(BookJob.id(for: b))?.status, .ready)
        XCTAssertTrue(synth.calls.contains { $0.text.hasPrefix("[Kuno](/ˈkuːnO/) called") }, "\(synth.calls.map(\.text))")
    }

    /// A stand-in for Chatterbox-TTS-Server's two routes, over a real socket: `/tts` must get the
    /// style, and answer WAV the renderer accepts.
    func testHTTPSynthesizerTalksToBothRoutes() async throws {
        let style = SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3)
        let seen = Recorded()
        let server = try TinyHTTPServer { path, body in
            seen.add(path, body)
            return FakeSynthesizer.tone(seconds: 0.05)
        }
        defer { server.stop() }
        let synth = HTTPSpeechSynthesizer(engines: ["chatterbox": server.baseURL])
        let a = try await synth.synthesize(text: "Hello.", voice: "chatterbox:Emily.wav", speed: nil, style: style)
        let b = try await synth.synthesize(text: "Hello.", voice: "chatterbox:Emily.wav", speed: nil)
        XCTAssertNotNil(WAV.parse(a))
        XCTAssertNotNil(WAV.parse(b))
        XCTAssertEqual(seen.paths, ["/tts", "/v1/audio/speech"])
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: seen.bodies[0]) as? [String: Any])?["exaggeration"] as? Double, 0.7)
    }

    /// The product path (M8.7): the plan the import sheet builds from a voice suggestion. Its
    /// tone styles a Chatterbox narrator whichever voice is chosen; the speed stays with the
    /// suggested voice; a Kokoro narrator's plan is exactly what it was before styles existed.
    func testThePlanTakesTheBooksToneForAChatterboxNarrator() {
        let dramatic = VoiceSuggestion(primary: "chatterbox:Emily.wav", alternates: ["kokoro:bf_emma"], rationale: "",
                                       tone: "dark, ominous", speed: 0.95, source: "a test model", fallbackReason: nil)
        let plan = VoicePlan.forBook(narrator: "chatterbox:Emily.wav", suggestion: dramatic)
        XCTAssertEqual(plan.style, SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3))
        XCTAssertEqual(plan.speed, 0.95)

        let other = VoicePlan.forBook(narrator: "chatterbox:Gabriel.wav", suggestion: dramatic)
        XCTAssertEqual(other.style, SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3), "the tone is the book's, not the voice's")
        XCTAssertNil(other.speed, "the suggested speed belongs to the suggested voice")

        XCTAssertEqual(VoicePlan.forBook(narrator: "kokoro:bf_emma", suggestion: dramatic),
                       VoicePlan(narrator: "kokoro:bf_emma"), "Kokoro has no style, and its book keeps its id")
        XCTAssertNil(VoicePlan.forBook(narrator: "chatterbox:Emily.wav", suggestion: nil).style)
        XCTAssertEqual(VoicePlan.forBook(narrator: "chatterbox:Emily.wav", tone: "calm, measured").style,
                       SpeechStyle(exaggeration: 0.35, cfgWeight: 0.5), "an agent's tone when there is no suggestion")
        var fallback = dramatic
        fallback.fallbackReason = "no model is set up"
        XCTAssertNil(VoicePlan.forBook(narrator: "chatterbox:Emily.wav", suggestion: fallback).speed)
    }

    /// End to end: a dramatic suggestion's book, rendered by the shared renderer, sends every
    /// chunk to Chatterbox's `/tts` with exaggeration 0.7 (the audit's confirming test).
    func testADramaticSuggestionsBookSendsTheStyleToTTS() async throws {
        let seen = Recorded()
        let server = try TinyHTTPServer { path, body in
            seen.add(path, body)
            return FakeSynthesizer.tone(seconds: 0.05)
        }
        defer { server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let r = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"),
                             synthesizer: HTTPSpeechSynthesizer(engines: ["chatterbox": server.baseURL]),
                             muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let dramatic = VoiceSuggestion(primary: "chatterbox:Emily.wav", alternates: [], rationale: "",
                                       tone: "tense, dramatic", source: "a test model", fallbackReason: nil)
        let b = DocumentSpeech.prepare(ImportedDocument(sourceSHA256: "s", sourceKind: .text, title: "T", chapters: [
            DocumentChapter(index: 0, title: "One", paragraphs: ["The machine stopped, and nobody knew why."]),
        ]), voices: .forBook(narrator: "chatterbox:Emily.wav", suggestion: dramatic))
        _ = try await r.submit(b, id: BookJob.id(for: b))
        await r.waitUntilIdle()
        XCTAssertEqual(store.load(BookJob.id(for: b))?.status, .ready)
        XCTAssertFalse(seen.paths.isEmpty)
        XCTAssertEqual(Set(seen.paths), ["/tts"])
        for body in seen.bodies {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["exaggeration"] as? Double, 0.7)
            XCTAssertEqual(json["cfg_weight"] as? Double, 0.3)
        }
    }
}

final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    private var _bodies: [Data] = []
    var paths: [String] { lock.withLock { _paths } }
    var bodies: [Data] { lock.withLock { _bodies } }
    func add(_ path: String, _ body: Data) { lock.withLock { _paths.append(path); _bodies.append(body) } }
}

/// One-connection-at-a-time HTTP/1.1 server on 127.0.0.1 for tests: reads a request with a
/// Content-Length body and answers 200 with what `handler` returns.
final class TinyHTTPServer: @unchecked Sendable {
    let baseURL: URL
    private let fd: Int32
    private let thread: Thread

    init(handler: @escaping @Sendable (String, Data) -> Data) throws {
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, length) } }
        listen(s, 8)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) } }
        fd = s
        baseURL = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: addr.sin_port))")!
        thread = Thread {
            while true {
                let c = accept(s, nil, nil)
                if c < 0 { return }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let n = read(c, &buffer, buffer.count)
                    if n <= 0 { break }
                    data.append(contentsOf: buffer[0..<n])
                    if let split = data.range(of: Data("\r\n\r\n".utf8)) {
                        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
                        let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                        if data.count - split.upperBound >= length {
                            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                            let reply = handler(path, Data(data[split.upperBound...]))
                            let header = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: \(reply.count)\r\nConnection: close\r\n\r\n"
                            let out = Data(header.utf8) + reply
                            _ = out.withUnsafeBytes { write(c, $0.baseAddress, out.count) }
                            break
                        }
                    }
                }
                close(c)
            }
        }
        thread.start()
    }

    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }
}

/// The lexicon's candidates and a real model's proposals on the sample, opt-in like the other
/// live tests (`BATON_DOCS_SAMPLE`, `BATON_LIVE_OLLAMA_MODEL`).
final class PronunciationLiveTests: XCTestCase {
    func testProposalsForTheSample() async throws {
        guard let path = ProcessInfo.processInfo.environment["BATON_DOCS_SAMPLE"] else {
            throw XCTSkip("set BATON_DOCS_SAMPLE for the real book")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let r = LayoutTextImporter().extract(pages: text.components(separatedBy: "\u{0C}"))
        let doc = ImportedDocument(sourceSHA256: "sample", sourceKind: .pdf, title: r.title ?? "", author: r.author,
                                   language: "en", chapters: r.chapters, frontMatter: r.frontMatter)
        let candidates = PronunciationLexicon.candidates(in: doc)
        print("CANDIDATES: \(candidates.map { "\($0.word)×\($0.count)" }.joined(separator: ", "))")
        XCTAssertTrue(candidates.map(\.word).contains("Kuno"))
        XCTAssertTrue(candidates.map(\.word).contains("Vashti"))

        guard let model = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_MODEL"] else {
            throw XCTSkip("set BATON_LIVE_OLLAMA_MODEL for the model's proposals")
        }
        let base = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_URL"] ?? "http://127.0.0.1:11434"
        let source = ModelSource(name: "\(model) (live)", provider: .ollama, baseURL: base, model: model, contextTokens: 8_192)
        let executor = HTTPModelClient.executor(apiKey: { _ in nil })
        guard let ok = try? await executor(source, "Answer with one word.", "Say OK."), ok.lowercased().contains("ok") else {
            throw XCTSkip("\(model) did not answer a trivial prompt; not measurable")
        }
        let router = ModelRouter(sources: [source])
        let started = Date()
        let proposed = await PronunciationLexicon.propose(for: doc) { system, user in
            try await router.complete(.voiceSuggestion, system: system, user: user, executor: executor)
        }
        print("LIVE lexicon in \(String(format: "%.1f", Date().timeIntervalSince(started))) s by \(proposed.source ?? "nobody"): "
              + proposed.lexicon.entries.map { "\($0.word) /\($0.phonemes)/" }.joined(separator: ", "))
        XCTAssertNotNil(proposed.source)
        XCTAssertTrue(proposed.lexicon.entries.allSatisfy { PronunciationLexicon.isValid($0.phonemes) })
    }
}
