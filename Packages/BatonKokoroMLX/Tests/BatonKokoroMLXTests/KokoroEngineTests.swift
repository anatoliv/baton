import Foundation
import Testing
@testable import BatonKokoroMLX

/// A model that answers with one sample per character, so tests can see what was rendered.
final class StubBackend: KokoroBackend {
    var names = ["af_heart", "bm_george", "ef_dora", "jf_alpha"]
    var rendered: [(text: String, voice: String, british: Bool, speed: Float)] = []
    var tokenLimit = Int.max

    func voiceNames() throws -> [String] { names }

    func render(text: String, voice: String, british: Bool, speed: Float) throws -> [Float] {
        if text.count > tokenLimit { throw KokoroChunkTooLong() }
        rendered.append((text, voice, british, speed))
        return Array(repeating: 0.5, count: text.count)
    }
}

@Suite("Kokoro engine contract")
struct KokoroEngineTests {
    @Test("Lists the English voices only, sorted")
    func englishVoicesOnly() throws {
        let engine = KokoroEngine(backend: { StubBackend() })
        #expect(try engine.voices() == ["af_heart", "bm_george"])
    }

    @Test("App voice ids map to the model's names; other engines, languages and blends do not")
    func voiceMapping() {
        #expect(KokoroVoices.modelName(for: "kokoro:af_heart") == "af_heart")
        #expect(KokoroVoices.modelName(for: " Kokoro:BM_George ") == "bm_george")
        #expect(KokoroVoices.modelName(for: "af_heart") == "af_heart")
        #expect(KokoroVoices.modelName(for: "chatterbox:Abigail.wav") == nil)
        #expect(KokoroVoices.modelName(for: "kokoro:jf_alpha") == nil)
        #expect(KokoroVoices.modelName(for: "kokoro:af_heart+af_bella") == nil)
        #expect(KokoroVoices.modelName(for: "kokoro:af_bella(2)") == nil)
        #expect(KokoroVoices.isBritish("bf_emma"))
        #expect(!KokoroVoices.isBritish("am_adam"))
    }

    @Test("Renders WAV at 24 kHz mono 16-bit with the voice's accent and the speed held in range")
    func wavContract() throws {
        let stub = StubBackend()
        let engine = KokoroEngine(backend: { stub })
        let wav = try engine.synthesizeWAV(text: "Hello there.", voice: "kokoro:bm_george", speed: 9)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let channels = wav[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let bits = wav[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        #expect(rate == 24_000 && channels == 1 && bits == 16)
        #expect(wav.count == 44 + 2 * "Hello there.".count)
        #expect(stub.rendered.first?.british == true)
        #expect(stub.rendered.first?.speed == 2)
        #expect(stub.rendered.first?.voice == "bm_george")
    }

    @Test("A voice the model lacks, or another engine's, is refused before anything renders")
    func unknownVoice() throws {
        let stub = StubBackend()
        let engine = KokoroEngine(backend: { stub })
        #expect(throws: KokoroEngineError.unknownVoice("kokoro:af_nobody")) {
            try engine.synthesize(text: "Hi.", voice: "kokoro:af_nobody")
        }
        #expect(throws: KokoroEngineError.unknownVoice("chatterbox:Abigail.wav")) {
            try engine.synthesize(text: "Hi.", voice: "chatterbox:Abigail.wav")
        }
        #expect(stub.rendered.isEmpty)
    }

    @Test("Long text is read in chunks under the limit, and nothing to say is silence")
    func chunking() throws {
        let sentence = "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife. "
        let text = String(repeating: sentence, count: 6)
        let chunks = KokoroEngine.chunks(text)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= KokoroEngine.chunkCharacters })
        #expect(chunks.joined(separator: " ").filter(\.isLetter) == text.filter(\.isLetter))
        #expect(KokoroEngine.chunks("  …  — !! ").isEmpty)
        let engine = KokoroEngine(backend: { StubBackend() })
        #expect(try engine.synthesize(text: " -- ", voice: "af_heart").isEmpty)
    }

    @Test("A chunk over the token limit is split and read, not dropped")
    func tooManyTokensSplits() throws {
        let stub = StubBackend()
        stub.tokenLimit = 40
        let engine = KokoroEngine(backend: { stub })
        let text = "One two three four five six seven eight nine ten eleven twelve thirteen fourteen."
        let samples = try engine.synthesize(text: text, voice: "af_heart")
        #expect(stub.rendered.count > 1)
        #expect(stub.rendered.map(\.text).joined(separator: " ") == text)
        #expect(samples.count == stub.rendered.reduce(0) { $0 + $1.text.count })
    }
}

/// Writes a fixed body, honouring a range like a server that supports resume.
struct FixedTransport: KokoroModelTransport {
    let bodies: [URL: Data]
    var honoursRange = true

    func fetch(_ source: URL, from offset: Int64, into partial: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws -> Bool {
        let body = bodies[source] ?? Data()
        if offset > 0, honoursRange {
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            try handle.write(contentsOf: body.dropFirst(Int(offset)))
            try handle.close()
            progress(Int64(body.count))
            return true
        }
        try body.write(to: partial)
        progress(Int64(body.count))
        return false
    }
}

@Suite("Kokoro model download")
struct KokoroModelStoreTests {
    private func file(_ name: String, _ body: Data) -> KokoroModelFile {
        KokoroModelFile(name: name, source: URL(string: "https://example.test/\(name)")!,
                        bytes: Int64(body.count), sha256: Self.hex(body))
    }

    static func hex(_ data: Data) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! data.write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try! KokoroModelStore.sha256(of: dir)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-store-\(UUID().uuidString)")
    }

    @Test("The pinned files are the ones the spike measured")
    func pinnedFiles() {
        #expect(KokoroModelFiles.weights.sha256 == "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8")
        #expect(KokoroModelFiles.weights.source.absoluteString.contains("e02c9eada7ce7416798af36b190a8a2dd2ecd566"))
        #expect(KokoroModelFiles.voices.sha256 == "56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f")
        #expect(KokoroModelFiles.totalBytes == 341_744_836)
    }

    @Test("Installs, reports progress to the total, and removes")
    func installAndRemove() async throws {
        let a = Data("weights".utf8), b = Data("voices!!".utf8)
        let files = [file("a.bin", a), file("b.bin", b)]
        let store = KokoroModelStore(directory: tempDir(), files: files)
        let seen = Seen()
        try await store.install(transport: FixedTransport(bodies: [files[0].source: a, files[1].source: b])) { done, total in
            seen.add(done, total)
        }
        #expect(store.isInstalled)
        #expect(seen.last?.0 == Int64(a.count + b.count) && seen.last?.1 == Int64(a.count + b.count))
        try store.remove()
        #expect(!store.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test("A file whose checksum is wrong is deleted and never installed")
    func checksumRefusal() async throws {
        let good = Data("the real weights".utf8)
        let pinned = file("w.bin", good)
        let store = KokoroModelStore(directory: tempDir(), files: [pinned])
        let tampered = Data("the fake weights".utf8)
        await #expect(throws: KokoroModelError.checksumMismatch(file: "w.bin")) {
            try await store.install(transport: FixedTransport(bodies: [pinned.source: tampered]))
        }
        #expect(!store.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("w.bin").path))
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("w.bin.partial").path))
        try store.remove()
    }

    @Test("A part-downloaded file resumes from where it stopped, or restarts when the server ignores the range")
    func resumeOrRestart() async throws {
        let body = Data((0..<1000).map { UInt8($0 % 251) })
        let pinned = file("w.bin", body)
        for honours in [true, false] {
            let store = KokoroModelStore(directory: tempDir(), files: [pinned])
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try body.prefix(400).write(to: store.directory.appendingPathComponent("w.bin.partial"))
            let seen = Seen()
            try await store.install(transport: FixedTransport(bodies: [pinned.source: body], honoursRange: honours)) { done, total in
                seen.add(done, total)
            }
            #expect(store.isInstalled)
            #expect(seen.first?.0 == 400 && seen.first?.1 == 1000)
            try store.remove()
        }
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64)] = []
    func add(_ done: Int64, _ total: Int64) { lock.lock(); values.append((done, total)); lock.unlock() }
    var first: (Int64, Int64)? { lock.lock(); defer { lock.unlock() }; return values.first }
    var last: (Int64, Int64)? { lock.lock(); defer { lock.unlock() }; return values.last }
}
