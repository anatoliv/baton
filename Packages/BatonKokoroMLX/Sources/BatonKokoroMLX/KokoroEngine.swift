import Foundation

/// What renders one chunk of text. The real one is `MLXKokoroBackend`; tests give a stub so the
/// engine's contract (voices, chunking, speed, WAV) is checked without the 342 MB model.
public protocol KokoroBackend: AnyObject {
    /// Every voice in the model, by the model's own name (`af_heart`).
    func voiceNames() throws -> [String]
    /// 24 kHz mono samples for `text`, which is short enough for one call.
    func render(text: String, voice: String, british: Bool, speed: Float) throws -> [Float]
}

/// The backend's way of saying a chunk is over Kokoro's 510 phoneme limit, so the engine splits
/// it and tries again.
public struct KokoroChunkTooLong: Error {
    public init() {}
}

public enum KokoroEngineError: Error, Equatable, CustomStringConvertible {
    /// A model file is missing from the directory.
    case modelMissing(String)
    /// MLX's compiled shaders are not in this build of the app.
    case metalLibraryMissing
    /// `voices.npz` could not be read.
    case voicesUnreadable
    /// A voice this engine does not speak.
    case unknownVoice(String)
    /// Kokoro could not fit the text into one call even split to single words.
    case textTooLong

    public var description: String {
        switch self {
        case .modelMissing(let name): return "the built-in voices are not downloaded (\(name) is missing)"
        case .metalLibraryMissing: return "this build of Baton has no MLX shaders, so the built-in voices cannot run"
        case .voicesUnreadable: return "the built-in voices file could not be read"
        case .unknownVoice(let voice): return "the built-in voices have no voice \(voice)"
        case .textTooLong: return "a sentence is too long for the built-in voices"
        }
    }
}

/// Kokoro, on this Mac. Loads a model directory, lists its English voices and turns text into
/// 24 kHz mono 16-bit WAV, the same format the Kokoro server returns, so a book can mix clips
/// from either without the joiner refusing them.
///
/// One render at a time: the model keeps state between calls (the chosen language), so calls
/// are serialised by a lock. Rendering is synchronous and long; call it off the main actor.
public final class KokoroEngine: @unchecked Sendable {
    public static let sampleRate = 24_000

    /// Kokoro reads at most 510 phoneme tokens per call. About 300 characters stays well under
    /// that for English prose (the spike read the Austen passage in chunks this size).
    public static let chunkCharacters = 300

    private let lock = NSLock()
    private let makeBackend: () throws -> any KokoroBackend
    private var backend: (any KokoroBackend)?

    /// The real engine over a model directory holding `kokoro-v1_0.safetensors` and
    /// `voices.npz`. Checks the files and MLX's shaders, then caps MLX's buffer cache before
    /// anything is allocated. The weights load on the first render.
    public convenience init(modelDirectory: URL) throws {
        for file in KokoroModelFiles.all {
            let url = modelDirectory.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw KokoroEngineError.modelMissing(file.name) }
        }
        guard KokoroMLXRuntime.metalLibraryURL() != nil else { throw KokoroEngineError.metalLibraryMissing }
        KokoroMLXRuntime.applyCacheLimit()
        let weights = modelDirectory.appendingPathComponent(KokoroModelFiles.weights.name)
        let voices = modelDirectory.appendingPathComponent(KokoroModelFiles.voices.name)
        self.init(backend: { try MLXKokoroBackend(weights: weights, voices: voices) })
    }

    /// An engine over any backend, made on first use.
    public init(backend: @escaping () throws -> any KokoroBackend) {
        self.makeBackend = backend
    }

    /// The English voices, by the model's names, sorted.
    public func voices() throws -> [String] {
        try locked { backend in try backend.voiceNames().filter(KokoroVoices.isEnglish).sorted() }
    }

    /// Samples for `text` in `voice` (an app id like `kokoro:af_heart`, or the bare name).
    /// `speed` is Kokoro's multiplier, 1 when nil, held between 0.5 and 2.
    public func synthesize(text: String, voice: String, speed: Double? = nil) throws -> [Float] {
        guard let name = KokoroVoices.modelName(for: voice) else { throw KokoroEngineError.unknownVoice(voice) }
        let rate = Float(min(2, max(0.5, speed ?? 1)))
        return try locked { backend in
            guard try backend.voiceNames().contains(name) else { throw KokoroEngineError.unknownVoice(voice) }
            var samples: [Float] = []
            for chunk in Self.chunks(text) {
                samples += try render(chunk, backend: backend, voice: name, speed: rate)
            }
            return samples
        }
    }

    /// The same as WAV bytes: RIFF, PCM 16-bit, mono, 24 kHz.
    public func synthesizeWAV(text: String, voice: String, speed: Double? = nil) throws -> Data {
        KokoroWAV.encode(try synthesize(text: text, voice: voice, speed: speed), sampleRate: Self.sampleRate)
    }

    // MARK: - Chunking

    /// Splits text into pieces Kokoro can read in one call: sentences, packed up to
    /// `chunkCharacters`, and a sentence longer than that at its commas, semicolons or spaces.
    /// Text with nothing to say (blank, or punctuation alone) is no chunks.
    static func chunks(_ text: String, limit: Int = chunkCharacters) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sentences.append(s) }
        }
        if sentences.isEmpty { sentences = [trimmed] }
        var out: [String] = []
        var current = ""
        for sentence in sentences.flatMap({ split($0, limit: limit) }) {
            if current.isEmpty { current = sentence }
            else if current.count + 1 + sentence.count <= limit { current += " " + sentence }
            else { out.append(current); current = sentence }
        }
        if !current.isEmpty { out.append(current) }
        return out.filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// One sentence in pieces of at most `limit` characters, cut after a clause mark where there
    /// is one and at a space otherwise.
    static func split(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        let head = String(sentence.prefix(limit))
        let cut = head.lastIndex(where: { ";:,".contains($0) }).map { head.index(after: $0) }
            ?? head.lastIndex(of: " ")
            ?? head.endIndex
        let first = String(head[..<cut]).trimmingCharacters(in: .whitespaces)
        let rest = String(sentence.dropFirst(head.distance(from: head.startIndex, to: cut)))
            .trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty else { return [head] + split(String(sentence.dropFirst(limit)), limit: limit) }
        return [first] + (rest.isEmpty ? [] : split(rest, limit: limit))
    }

    /// Renders a chunk, halving it at a space when the backend says it is over the token limit.
    private func render(_ chunk: String, backend: any KokoroBackend, voice: String, speed: Float, depth: Int = 0) throws -> [Float] {
        do {
            return try backend.render(text: chunk, voice: voice, british: KokoroVoices.isBritish(voice), speed: speed)
        } catch is KokoroChunkTooLong {
            let halves = Self.split(chunk, limit: max(1, chunk.count / 2))
            guard depth < 6, halves.count > 1 else { throw KokoroEngineError.textTooLong }
            return try halves.flatMap { try render($0, backend: backend, voice: voice, speed: speed, depth: depth + 1) }
        }
    }

    private func locked<T>(_ body: (any KokoroBackend) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if backend == nil { backend = try makeBackend() }
        return try body(backend!)
    }
}

/// 16-bit PCM mono WAV, the format the Kokoro server returns.
public enum KokoroWAV {
    public static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples {
            let clamped = s.isFinite ? max(-1, min(1, s)) : 0
            u16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}
