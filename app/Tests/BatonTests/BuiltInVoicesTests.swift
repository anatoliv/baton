import BatonDocuments
import BatonKokoroMLX
import Darwin
import Foundation
import Testing
@testable import Baton

/// The built-in "This Mac" voices: Kokoro on MLX, registered ahead of the servers
/// once its model is downloaded. The package's own tests (`Packages/BatonKokoroMLX`) cover the
/// engine's chunking and the download's resume; these pin the Mac's side and, when the model is
/// on this machine, one real render.

/// A built-in engine that answers with a fixed WAV and records what it was asked.
final class StubBuiltInEngine: BuiltInSpeechEngine, @unchecked Sendable {
    let wav = KokoroWAV.encode([Float](repeating: 0.25, count: 2_400), sampleRate: 24_000)
    private let lock = NSLock()
    private var asked: [String] = []
    var voices: [String] { lock.withLock { asked } }

    func speaks(_ voice: String) -> Bool {
        KokoroVoices.modelName(for: voice).map(BuiltInVoices.englishVoices.contains) ?? false
    }

    func synthesizeWAV(text: String, voice: String, speed: Double?) async throws -> Data {
        lock.withLock { asked.append(voice) }
        return wav
    }
}

/// A model that answers one sample per character, standing in for the 342 MB weights.
final class StubKokoroModel: KokoroBackend {
    func voiceNames() throws -> [String] { ["af_heart", "bf_emma", "jf_alpha", "zf_xiaobei"] }
    func render(text: String, voice: String, british: Bool, speed: Float) throws -> [Float] {
        [Float](repeating: 0.1, count: text.count * 10)
    }
}

/// Copies model files from disk instead of downloading them.
struct LocalFileTransport: KokoroModelTransport {
    let files: [URL: URL]
    func fetch(_ source: URL, from offset: Int64, into partial: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws -> Bool {
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.copyItem(at: files[source] ?? source, to: partial)
        progress((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0)
        return false
    }
}

private func temporaryDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("baton-\(label)-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
@Suite("Built-in voices on this Mac", .serialized)
struct BuiltInVoicesTests {
    private func withSettings(builtIn: (any BuiltInSpeechEngine)?, _ body: () async throws -> Void) async rethrows {
        let suite = ThrowawayDefaults.name("builtin-voices")
        let defaults = UserDefaults(suiteName: suite)!
        let savedDefaults = SpeechConfig.defaults
        let savedBuiltIn = ConfiguredSpeechSynthesizer.builtIn
        let savedChoice = ConfiguredSpeechSynthesizer.choice
        SpeechConfig.defaults = defaults
        ConfiguredSpeechSynthesizer.builtIn = { builtIn }
        ConfiguredSpeechSynthesizer.choice = { .automatic }   // TBX-10909: these pin Automatic
        defer {
            SpeechConfig.defaults = savedDefaults
            ConfiguredSpeechSynthesizer.builtIn = savedBuiltIn
            ConfiguredSpeechSynthesizer.choice = savedChoice
            defaults.removePersistentDomain(forName: suite)
        }
        try await body()
    }

    // MARK: Registration

    @Test("With the model present, the built-in engine is registered ahead of the Kokoro server")
    func builtInBeforeServer() async throws {
        try await withSettings(builtIn: StubBuiltInEngine()) {
            SpeechConfig.kokoroBaseURL = "http://127.0.0.1:8880"
            SpeechConfig.chatterboxBaseURL = "http://chatterbox.test:8183"
            #expect(ConfiguredSpeechSynthesizer.registeredEngines() == [.thisMac, .server("kokoro"), .server("chatterbox")])
            #expect(ConfiguredSpeechSynthesizer.engine(for: "kokoro:af_heart") == .thisMac)
            #expect(ConfiguredSpeechSynthesizer.engine(for: "kokoro:bm_george") == .thisMac)
            // Not English, a blend, or another engine's voice: the server keeps it.
            #expect(ConfiguredSpeechSynthesizer.engine(for: "kokoro:jf_alpha") == .server("kokoro"))
            #expect(ConfiguredSpeechSynthesizer.engine(for: "kokoro:af_heart+af_bella") == .server("kokoro"))
            #expect(ConfiguredSpeechSynthesizer.engine(for: "chatterbox:Abigail.wav") == .server("chatterbox"))

            // TBX-10909: Voice server leaves the built-in engine out; Built-in leaves the servers out.
            ConfiguredSpeechSynthesizer.choice = { .server }
            #expect(ConfiguredSpeechSynthesizer.registeredEngines() == [.server("kokoro"), .server("chatterbox")])
            #expect(ConfiguredSpeechSynthesizer.engine(for: "kokoro:af_heart") == .server("kokoro"))
            ConfiguredSpeechSynthesizer.choice = { .builtIn }
            #expect(ConfiguredSpeechSynthesizer.registeredEngines() == [.thisMac])
            #expect(ConfiguredSpeechSynthesizer.engine(for: "chatterbox:Abigail.wav") == nil)
        }
    }

    @Test("Without the model, there is no built-in engine and Kokoro voices go to the server")
    func absentWithoutModel() async throws {
        let empty = BuiltInVoices(store: KokoroModelStore(directory: temporaryDirectory("no-model")))
        #expect(!empty.isAvailable)
        try await withSettings(builtIn: empty.ifAvailable) {
            SpeechConfig.kokoroBaseURL = "http://127.0.0.1:8880"
            SpeechConfig.chatterboxBaseURL = ""
            #expect(ConfiguredSpeechSynthesizer.registeredEngines() == [.server("kokoro")])
            #expect(ConfiguredSpeechSynthesizer.engine(for: "kokoro:af_heart") == .server("kokoro"))
        }
    }

    @Test("A built-in voice is rendered in process and never reaches a server")
    func rendersWithoutServer() async throws {
        let stub = StubBuiltInEngine()
        try await withSettings(builtIn: stub) {
            // No Kokoro host at all: a server request would fail as "no kokoro host".
            SpeechConfig.kokoroBaseURL = ""
            let data = try await ConfiguredSpeechSynthesizer().synthesize(text: "Hello.", voice: "kokoro:af_heart", speed: nil)
            #expect(data == stub.wav)
            #expect(stub.voices == ["kokoro:af_heart"])
            // Its audio joins with the server's: the same 24 kHz mono 16-bit format.
            let format = try #require(WAV.parse(data)).format
            #expect(format.sampleRate == 24_000 && format.channels == 1 && format.bitsPerSample == 16)

            do {
                _ = try await ConfiguredSpeechSynthesizer().synthesize(text: "Hello.", voice: "kokoro:jf_alpha", speed: nil)
                Issue.record("a voice the built-in engine does not speak should go to the (missing) server")
            } catch let error as SynthesisError {
                #expect(error.description.contains("kokoro"))
            }
        }
    }

    // MARK: Import's voice list

    @Test("Import offers the built-in voices when no Kokoro server answers, and the server's when one does")
    func importVoiceList() async {
        let down: DocumentImporter.Fetch = { _ in throw URLError(.cannotConnectToHost) }
        let builtIn = ["kokoro:af_heart", "kokoro:bm_george"]
        #expect(await VoiceSuggestions.availableVoices(kokoroBase: "http://127.0.0.1:8880", builtIn: builtIn, engine: .automatic, fetch: down) == builtIn)
        #expect(await VoiceSuggestions.availableVoices(kokoroBase: "http://127.0.0.1:8880", builtIn: [], engine: .automatic, fetch: down).isEmpty)
        let up: DocumentImporter.Fetch = { request in
            (Data(#"{"voices":["af_heart","jf_alpha"]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await VoiceSuggestions.availableVoices(kokoroBase: "http://127.0.0.1:8880", builtIn: builtIn, engine: .automatic, fetch: up)
                == ["kokoro:af_heart", "kokoro:jf_alpha"])
        let none = BuiltInVoices(store: KokoroModelStore(directory: temporaryDirectory("no-model-ids")))
        #expect(none.availableVoiceIDs.isEmpty)
    }

    // MARK: Engine contract with a stub model

    @Test("The engine offers English voices only and returns WAV for an app voice id")
    func engineContract() throws {
        let engine = KokoroEngine(backend: { StubKokoroModel() })
        #expect(try engine.voices() == ["af_heart", "bf_emma"])
        let wav = try engine.synthesizeWAV(text: "A short line.", voice: "kokoro:bf_emma", speed: 1.1)
        let parsed = try #require(WAV.parse(wav))
        #expect(parsed.format.sampleRate == 24_000)
        #expect(parsed.pcm.count == "A short line.".count * 10 * 2)
        #expect(throws: KokoroEngineError.unknownVoice("kokoro:jf_alpha")) {
            try engine.synthesizeWAV(text: "Hi.", voice: "kokoro:jf_alpha")
        }
    }

    @Test("The voices Baton routes without loading the model are the 28 English voices of the pinned file")
    func knownVoices() {
        #expect(BuiltInVoices.englishVoices.count == 28)
        #expect(BuiltInVoices.englishVoices.allSatisfy(KokoroVoices.isEnglish))
    }

    // MARK: Download

    @Test("A download whose checksum is wrong is refused and the engine stays off")
    func checksumRefusal() async throws {
        let dir = temporaryDirectory("bad-model")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.deletingLastPathComponent().appendingPathComponent("fake-\(UUID().uuidString).bin")
        try Data("not the weights".utf8).write(to: fake)
        defer { try? FileManager.default.removeItem(at: fake) }
        let pinned = KokoroModelFile(name: "kokoro-v1_0.safetensors", source: URL(string: "https://example.test/w")!,
                                     bytes: 15, sha256: String(repeating: "0", count: 64))
        let voices = BuiltInVoices(store: KokoroModelStore(directory: dir, files: [pinned]))
        await #expect(throws: KokoroModelError.checksumMismatch(file: "kokoro-v1_0.safetensors")) {
            try await voices.store.install(transport: LocalFileTransport(files: [pinned.source: fake]))
        }
        #expect(!voices.isAvailable)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("kokoro-v1_0.safetensors").path))
    }

    @Test("The model goes to Application Support/Baton/Models/kokoro-mlx, and the size Settings shows is 342 MB")
    func whereAndHowBig() {
        let path = BuiltInVoices.defaultDirectory().path
        #expect(path.hasSuffix("/Models/kokoro-mlx"))
        #expect(BuiltInVoicesModel.sizeText == "342 MB")
    }

    // MARK: MLX

    @Test("MLX's buffer cache is capped at 512 MB before the engine allocates anything",
          .enabled(if: BuiltInVoices.shadersPresent, "this build has no MLX shaders"))
    func cacheCapApplied() throws {
        KokoroMLXRuntime.applyCacheLimit()
        #expect(KokoroMLXRuntime.cacheLimit == 512 * 1_048_576)
    }
}

/// One real render, when the model and MLX's shaders are on this Mac. The model is looked for
/// in `Packages/BatonKokoroMLX/Models/` (gitignored); copy or download the two files there.
@Suite("Built-in voices real render", .serialized)
struct BuiltInVoicesRenderTests {
    static let modelSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/BatonKokoroMLX/Models", isDirectory: true)

    static var modelPresent: Bool {
        KokoroModelFiles.all.allSatisfy {
            FileManager.default.fileExists(atPath: modelSource.appendingPathComponent($0.name).path)
        }
    }

    /// Austen, *Pride and Prejudice* (1813), chapter I: public domain.
    static let sentence = "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife."

    @Test("Installs the real model through its checksums and renders a sentence that is speech-length and not silent",
          .enabled(if: BuiltInVoices.shadersPresent && modelPresent, "the model or MLX's shaders are not on this Mac"),
          .timeLimit(.minutes(5)))
    func realRender() async throws {
        let dir = temporaryDirectory("real-model")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KokoroModelStore(directory: dir)
        let copies = Dictionary(uniqueKeysWithValues: KokoroModelFiles.all.map {
            ($0.source, Self.modelSource.appendingPathComponent($0.name))
        })
        try await store.install(transport: LocalFileTransport(files: copies))
        #expect(store.isInstalled)
        let voices = BuiltInVoices(store: store)
        #expect(voices.isAvailable)

        let engine = try KokoroEngine(modelDirectory: dir)
        #expect(KokoroMLXRuntime.cacheLimit == KokoroMLXRuntime.gpuCacheLimitBytes)
        #expect(try engine.voices() == BuiltInVoices.englishVoices.sorted())

        // Cold (weights load on the first render), then warm.
        let coldStart = Date()
        let cold = try await voices.synthesizeWAV(text: Self.sentence, voice: "kokoro:af_heart", speed: nil)
        let coldWall = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        let wav = try await voices.synthesizeWAV(text: Self.sentence, voice: "kokoro:af_heart", speed: nil)
        let warmWall = Date().timeIntervalSince(warmStart)

        let parsed = try #require(WAV.parse(wav))
        #expect(WAV.parse(cold) != nil)
        let samples = parsed.pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let seconds = Double(samples.count) / 24_000
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        let rms = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1))).squareRoot()
        // 23 words: about 6 to 8 s at Kokoro's pace.
        #expect(seconds > 4 && seconds < 12, "rendered \(seconds) s")
        #expect(peak > 3_000, "peak \(peak)")
        #expect(rms > 300, "rms \(rms)")

        // The spike's passage (Austen, 233 words, 74 s of speech), when it is in the tree, for a
        // real-time factor comparable with TBX-10849's.
        let passageURL = Self.modelSource.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spikes/kokoro-mlx/passage.txt")
        var passageLine = ""
        if let passage = try? String(contentsOf: passageURL, encoding: .utf8) {
            let start = Date()
            let long = try await voices.synthesizeWAV(text: passage, voice: "kokoro:af_heart", speed: nil)
            let wall = Date().timeIntervalSince(start)
            let audio = Double(try #require(WAV.parse(long)).pcm.count / 2) / 24_000
            #expect(audio > 50, "the passage rendered \(audio) s")
            passageLine = String(format: " passage=%.1fs in %.2fs (%.1fx)", audio, wall, audio / wall)
            try? long.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kokoro-passage.wav"))
        }

        let memory = KokoroMLXRuntime.memory
        let line = String(format: "KOKORO-MEASURE audio=%.2fs cold=%.3fs (%.1fx) warm=%.3fs (%.1fx) mlxPeak=%.0fMB mlxCache=%.0fMB footprint=%.0fMB footprintPeak=%.0fMB cacheLimit=%dMB",
                          seconds, coldWall, seconds / coldWall, warmWall, seconds / warmWall,
                          Double(memory.peak) / 1e6, Double(memory.cache) / 1e6, Double(Self.footprint().now) / 1e6,
                          Double(Self.footprint().peak) / 1e6, (KokoroMLXRuntime.cacheLimit ?? 0) / 1_048_576) + passageLine
        print(line)
        try? line.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kokoro-measure.txt"),
                        atomically: true, encoding: .utf8)
        try? wav.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kokoro-measure.wav"))
    }

    /// The process's physical footprint (the figure Activity Monitor shows as Memory) and its peak.
    static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak)) : (0, 0)
    }
}
