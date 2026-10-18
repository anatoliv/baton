import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Synthesis

/// One TTS request. Kokoro (and Chatterbox) behind the OpenAI-compatible `/v1/audio/speech`
/// in production, a fake in tests.
public protocol SpeechSynthesizing: Sendable {
    /// WAV bytes for `text` in `voice` (an `"engine:voice"` spec).
    func synthesize(text: String, voice: String, speed: Double?) async throws -> Data
    /// The same with an expressive style, for engines that take one (Chatterbox). The default
    /// ignores the style, so a synthesizer that has no use for it need not change.
    func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?) async throws -> Data
    /// The same with a delivery instruction, for engines that take one (an OpenAI-compatible
    /// server such as Qwen3-TTS, TBX-11142). The default drops the instruction, so a
    /// synthesizer that has no use for it need not change; one that forwards to another must
    /// implement this, or the instruction is lost on the way.
    func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?, instruction: String?) async throws -> Data
}

extension SpeechSynthesizing {
    public func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?) async throws -> Data {
        try await synthesize(text: text, voice: voice, speed: speed)
    }

    public func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?,
                           instruction: String?) async throws -> Data {
        try await synthesize(text: text, voice: voice, speed: speed, style: style)
    }
}

/// How expressively Chatterbox reads (`specs/document-clippings.md`, *Expansions* 4). Its
/// defaults are 0.5 and 0.5; its authors suggest exaggeration 0.7 with cfg_weight 0.3 for
/// dramatic speech, and a lower exaggeration for calm reading. Kokoro has no such controls.
public struct SpeechStyle: Codable, Sendable, Equatable, Hashable {
    public var exaggeration: Double
    public var cfgWeight: Double

    public init(exaggeration: Double, cfgWeight: Double) {
        self.exaggeration = exaggeration
        self.cfgWeight = cfgWeight
    }

    /// The voice suggestion's `tone` ("dry, ominous", "warm and playful") as a style. Nil for
    /// a tone with no clear lean either way: the engine's defaults are the honest choice.
    public static func forTone(_ tone: String?) -> SpeechStyle? {
        guard let tone = tone?.lowercased(), !tone.isEmpty else { return nil }
        func has(_ words: [String]) -> Bool { words.contains { tone.contains($0) } }
        if has(["dramatic", "intense", "ominous", "menacing", "tense", "passionate", "urgent", "dark", "gothic", "suspense", "thrill"]) {
            return SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3)
        }
        if has(["playful", "lively", "whimsical", "humor", "humour", "comic", "energetic", "witty", "light"]) {
            return SpeechStyle(exaggeration: 0.6, cfgWeight: 0.4)
        }
        if has(["calm", "measured", "dry", "neutral", "reflective", "restrained", "formal", "academic", "detached", "quiet", "meditative"]) {
            return SpeechStyle(exaggeration: 0.35, cfgWeight: 0.5)
        }
        return nil
    }

    var key: String { String(format: "e%.2f-c%.2f", exaggeration, cfgWeight) }
}

public enum SynthesisError: Error, Equatable, CustomStringConvertible {
    /// Worth retrying: the host is down, slow, or restarting.
    case transient(String)
    /// Not worth retrying: the engine refuses this request (unknown voice, bad input).
    case permanent(String)

    public var description: String {
        switch self {
        case let .transient(why), let .permanent(why): return why
        }
    }

    /// How a refusal by the Mac's "Voice engine for books" setting starts.
    public static let voiceEngineSettingPrefix = "Voice engine for books is set to"

    /// The same failure in words a listener reads ("Paused: the voice server isn't answering").
    /// `description` keeps the engine's own wording for the log, where it belongs: "kokoro did
    /// not answer: cannot parse response" is a diagnosis for a person debugging, not a status
    /// line (found in the M3 walk).
    public var listenerReason: String {
        // The Mac's voice engine setting refuses in a listener's words already.
        if description.hasPrefix(Self.voiceEngineSettingPrefix) { return description }
        let raw = description.lowercased()
        if raw.contains("did not answer") { return "the voice server isn't answering" }
        if raw.contains("not wav") { return "the voice server sent back audio Baton can't read" }
        if raw.contains("no ") && raw.contains("host is configured") { return "no voice server is set up for this voice" }
        if let code = Int(raw.components(separatedBy: "answered ").last?.prefix(3) ?? "") {
            if code == 429 { return "the voice server is busy" }
            if code >= 500 { return "the voice server is having trouble (error \(code))" }
        }
        if case .permanent = self { return "the voice server refused this book" }
        return "the voice server isn't working right now"
    }
}

/// The OpenAI-compatible speech endpoint, the same request `BatonSpeech.SpeechService` makes on
/// the Mac: `{model, voice, input, response_format: "wav"}`. One base URL per engine; an
/// expressive server (`openai`, TBX-11142) also has its model, an optional key, and is sent
/// each line's delivery instruction.
public struct HTTPSpeechSynthesizer: SpeechSynthesizing {
    public let engines: [String: URL]
    public let endpoints: [String: SpeechEngineEndpoint]
    public let timeout: TimeInterval
    /// The most audio one answer may carry (`CappedDownload.speechLimit`); more is refused as it
    /// streams, for every engine.
    public let responseLimit: Int

    public init(engines: [String: URL], timeout: TimeInterval = 60) {
        self.init(endpoints: engines.map { SpeechEngineEndpoint(engine: $0.key, baseURL: $0.value) }, timeout: timeout)
    }

    public init(endpoints: [SpeechEngineEndpoint], timeout: TimeInterval = 60,
                responseLimit: Int = CappedDownload.speechLimit) {
        let byEngine = Dictionary(endpoints.map { ($0.engine, $0) }, uniquingKeysWith: { first, _ in first })
        self.endpoints = byEngine
        self.engines = byEngine.mapValues(\.baseURL)
        self.timeout = timeout
        self.responseLimit = responseLimit
    }

    public func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
        try await synthesize(text: text, voice: voice, speed: speed, style: nil, instruction: nil)
    }

    public func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?) async throws -> Data {
        try await synthesize(text: text, voice: voice, speed: speed, style: style, instruction: nil)
    }

    /// With a style and a Chatterbox voice, the request goes to Chatterbox-TTS-Server's own
    /// `/tts` route: its OpenAI-compatible route ignores `exaggeration` and `cfg_weight`. The
    /// instruction goes only to an expressive server.
    public func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?,
                           instruction: String?) async throws -> Data {
        let (engine, name) = Self.split(voice)
        guard let endpoint = endpoints[engine] else {
            throw SynthesisError.permanent("no \(engine) host is configured on the Baton server")
        }
        let request = try Self.request(base: endpoint.baseURL, engine: engine, voice: name, text: text, speed: speed,
                                       style: style, timeout: timeout, model: endpoint.requestModel,
                                       apiKey: endpoint.apiKey, instruction: instruction)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await CappedDownload.data(for: request, limit: responseLimit)
        } catch let tooLarge as CappedDownload.TooLarge {
            throw SynthesisError.permanent("\(engine) sent too much audio for one request: \(tooLarge)")
        } catch {
            throw SynthesisError.transient("\(engine) did not answer: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            guard WAV.parse(data) != nil else { throw SynthesisError.transient("\(engine) returned audio that is not WAV") }
            return data
        case 400..<500 where status != 408 && status != 429:
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw SynthesisError.permanent("\(engine) refused the request (\(status)): \(detail)")
        default:
            throw SynthesisError.transient("\(engine) answered \(status)")
        }
    }

    static func request(base: URL, engine: String, voice: String, text: String, speed: Double?,
                        style: SpeechStyle?, timeout: TimeInterval, model: String? = nil, apiKey: String? = nil,
                        instruction: String? = nil) throws -> URLRequest {
        let expressive = engine == "chatterbox" ? style : nil
        var request = URLRequest(url: base.appendingPathComponent(expressive == nil ? "v1/audio/speech" : "tts"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any]
        if let expressive {
            body = ["text": text, "voice_mode": "predefined", "predefined_voice_id": voice, "output_format": "wav",
                    "split_text": false, "exaggeration": expressive.exaggeration, "cfg_weight": expressive.cfgWeight]
            if let speed { body["speed_factor"] = speed }
        } else {
            body = ["model": model ?? engine, "voice": voice, "input": text, "response_format": "wav"]
            if let speed { body["speed"] = speed }
            if SpeechEngines.takesInstructions(engine), let instruction, !instruction.isEmpty {
                body["instructions"] = instruction
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `"kokoro:bf_emma"` → (`kokoro`, `bf_emma`); a bare voice is Kokoro's.
    static func split(_ spec: String) -> (engine: String, voice: String) {
        guard let colon = spec.firstIndex(of: ":") else { return ("kokoro", spec) }
        return (String(spec[..<colon]).lowercased(), String(spec[spec.index(after: colon)...]))
    }
}

// MARK: - WAV

/// The little of RIFF/WAVE needed to join TTS clips: find `fmt ` and `data`, keep the PCM.
public enum WAV {
    public struct Format: Equatable, Sendable {
        public var audioFormat: UInt16   // 1 = PCM integer, 3 = float
        public var channels: UInt16
        public var sampleRate: UInt32
        public var bitsPerSample: UInt16
        public var blockAlign: Int { Int(channels) * Int(bitsPerSample) / 8 }

        public init(audioFormat: UInt16, channels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16) {
            self.audioFormat = audioFormat
            self.channels = channels
            self.sampleRate = sampleRate
            self.bitsPerSample = bitsPerSample
        }
    }

    public static func parse(_ data: Data) -> (format: Format, pcm: Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45]
        else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
        var format: Format?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            var size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt ", body + 16 <= bytes.count {
                format = Format(audioFormat: u16(body), channels: u16(body + 2), sampleRate: u32(body + 4),
                                bitsPerSample: u16(body + 14))
            } else if id == "data", let format {
                // A streamed WAV writes 0 or 0xFFFFFFFF here and means "to the end".
                if size == 0 || size == 0xFFFF_FFFF || body + size > bytes.count { size = bytes.count - body }
                return (format, Data(bytes[body..<body + size]))
            }
            offset = body + size + (size & 1)
        }
        return nil
    }

    /// The PCM without the silence a clip starts and ends with, keeping 30 ms either
    /// side so no word is clipped: what is quieter than 45 dB below the clip's loudest 10 ms
    /// counts as silence, the rule the TBX-11102 bake-off measured its pauses with. An expressive
    /// engine pads each sentence differently, so without this the pause heard between sentences
    /// would be the inserted 0.45 s plus whatever the engine added. PCM 16-bit and 32-bit float
    /// only; any other format, or a clip with no sound, comes back as it was.
    public static func trimmingSilence(_ pcm: Data, format: Format) -> Data {
        let frameBytes = format.blockAlign
        guard frameBytes > 0, pcm.count >= frameBytes,
              (format.audioFormat == 1 && format.bitsPerSample == 16) || (format.audioFormat == 3 && format.bitsPerSample == 32)
        else { return pcm }
        let bytes = [UInt8](pcm)
        let frames = bytes.count / frameBytes
        let window = max(1, Int(format.sampleRate) / 100)
        let windows = frames / window
        guard windows > 0 else { return pcm }
        func sample(_ frame: Int) -> Double {
            let i = frame * frameBytes
            if format.audioFormat == 1 {
                return Double(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768
            }
            let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            return Double(Float(bitPattern: bits))
        }
        var energy = [Double](repeating: 0, count: windows)
        for w in 0..<windows {
            var sum = 0.0
            for f in (w * window)..<((w + 1) * window) { let v = sample(f); sum += v * v }
            energy[w] = (sum / Double(window)).squareRoot()
        }
        guard let peak = energy.max(), peak > 0 else { return pcm }
        let threshold = peak * pow(10, -45.0 / 20)
        guard let first = energy.firstIndex(where: { $0 > threshold }),
              let last = energy.lastIndex(where: { $0 > threshold }) else { return pcm }
        let pad = Int(format.sampleRate) * 3 / 100
        let from = max(0, first * window - pad)
        let to = min(frames, (last + 1) * window + pad)
        return Data(bytes[(from * frameBytes)..<(to * frameBytes)])
    }

    /// Whether `converting` reads and writes this format: 16-bit integer or 32-bit float PCM.
    public static func isConvertible(_ format: Format) -> Bool {
        format.channels > 0 && format.sampleRate > 0
            && ((format.audioFormat == 1 && format.bitsPerSample == 16) || (format.audioFormat == 3 && format.bitsPerSample == 32))
    }

    /// `pcm` in `source`'s format as `target`'s: a book whose lines are read by
    /// different engines is made in one format, and the engines need not answer alike (Kokoro
    /// 24 kHz mono 16-bit; another server another rate, float samples or two channels). Channels
    /// are averaged to mono and copied out to the target's count, the rate is changed by
    /// `resample` (windowed sinc, low-passed below the lower rate's Nyquist, so 48 kHz to 24 kHz
    /// does not fold what is above 12 kHz back down), and samples are scaled between integer and
    /// float. Deterministic: the same input gives the same bytes. Nil for a format it does not read.
    public static func converting(_ pcm: Data, from source: Format, to target: Format) -> Data? {
        guard isConvertible(source), isConvertible(target) else { return nil }
        if source == target { return pcm }
        let bytes = [UInt8](pcm)
        let frameBytes = source.blockAlign
        let frames = bytes.count / frameBytes
        func value(_ at: Int) -> Double {
            if source.audioFormat == 1 {
                return Double(Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8)) / 32768
            }
            let bits = UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
            return Double(Float(bitPattern: bits))
        }
        let sampleBytes = Int(source.bitsPerSample) / 8
        var mono = [Double](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum = 0.0
            for c in 0..<Int(source.channels) { sum += value(f * frameBytes + c * sampleBytes) }
            mono[f] = sum / Double(source.channels)
        }
        let samples = source.sampleRate == target.sampleRate
            ? mono : resample(mono, from: Int(source.sampleRate), to: Int(target.sampleRate))
        var out = Data(capacity: samples.count * target.blockAlign)
        for v in samples {
            for _ in 0..<Int(target.channels) {
                if target.audioFormat == 1 {
                    let n = Int16(max(-32768, min(32767, (v * 32768).rounded())))
                    withUnsafeBytes(of: n.littleEndian) { out.append(contentsOf: $0) }
                } else {
                    withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { out.append(contentsOf: $0) }
                }
            }
        }
        return out
    }

    /// Taps either side of each output sample, in units of the lower rate's samples: 16 gives a
    /// transition band of about a tenth of the band and a stopband below -70 dB with the
    /// Blackman window, plenty for speech.
    static let resampleZeroCrossings = 16

    /// `samples` at `from` Hz as `to` Hz by windowed-sinc interpolation. The kernel's cutoff is
    /// the lower of the two Nyquist frequencies, so downsampling low-passes first (no aliasing)
    /// and upsampling interpolates band-limited. Blackman window; plain Double arithmetic in a
    /// fixed order, so the result is the same on every run and every machine.
    static func resample(_ samples: [Double], from: Int, to: Int) -> [Double] {
        guard !samples.isEmpty, from > 0, to > 0 else { return [] }
        let ratio = Double(to) / Double(from)
        let cutoff = min(1, ratio)                      // as a fraction of the source's Nyquist
        let half = Double(resampleZeroCrossings) / cutoff // half-width in source samples
        let count = Int((Double(samples.count) * ratio).rounded())
        var out = [Double](repeating: 0, count: count)
        for f in 0..<count {
            let center = Double(f) / ratio
            let first = max(0, Int((center - half).rounded(.up)))
            let last = min(samples.count - 1, Int((center + half).rounded(.down)))
            guard first <= last else { continue }
            var sum = 0.0
            for k in first...last {
                let d = Double(k) - center
                let x = d * cutoff
                let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                let w = 0.42 + 0.5 * cos(Double.pi * d / half) + 0.08 * cos(2 * Double.pi * d / half)
                sum += samples[k] * cutoff * sinc * w
            }
            out[f] = sum
        }
        return out
    }

    /// "24 kHz mono 16-bit", for a message about a clip that cannot be joined.
    public static func describe(_ format: Format) -> String {
        let rate = format.sampleRate % 1000 == 0 ? "\(format.sampleRate / 1000) kHz" : "\(format.sampleRate) Hz"
        let channels = format.channels == 1 ? "mono" : (format.channels == 2 ? "stereo" : "\(format.channels) channels")
        let kind = format.audioFormat == 3 ? "\(format.bitsPerSample)-bit float" : "\(format.bitsPerSample)-bit"
        return "\(rate) \(channels) \(kind)"
    }

    public static func header(format: Format, dataBytes: Int) -> Data {
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16)
        put16(format.audioFormat); put16(format.channels); put32(format.sampleRate)
        put32(format.sampleRate * UInt32(format.blockAlign)); put16(UInt16(format.blockAlign)); put16(format.bitsPerSample)
        d.append(contentsOf: Array("data".utf8)); put32(UInt32(dataBytes))
        return d
    }
}

// MARK: - Encoding

public protocol AudioMuxing: Sendable {
    /// Encode `wav` to an M4A at `destination`, tagged with the chapter's metadata.
    func encode(wav: URL, to destination: URL, bitrate: Int, channels: Int, tags: [String: String]) async throws
    /// The same at exactly `sampleRate` and `channels`, whatever the WAV is: every
    /// chapter file comes out alike, so an M4B export, which joins chapters by stream copy, can
    /// never join two formats. The default keeps the WAV's rate, for an encoder (a test's copy)
    /// that does not convert.
    func encode(wav: URL, to destination: URL, bitrate: Int, channels: Int, sampleRate: Int, tags: [String: String]) async throws
}

extension AudioMuxing {
    public func encode(wav: URL, to destination: URL, bitrate: Int, channels: Int, sampleRate: Int,
                       tags: [String: String]) async throws {
        try await encode(wav: wav, to: destination, bitrate: bitrate, channels: channels, tags: tags)
    }
}

/// A book's one audio format and the voice it was taken from (`BookRenderer.bookFormat`).
public struct BookFormat: Sendable, Equatable {
    public var format: WAV.Format
    public var voice: String
}

// MARK: - The render loop

/// Renders submitted books, one at a time, chapter 1 first, a few chunks in flight.
///
/// The failure policy is the point of this type. A host that stops answering **pauses** the job,
/// with the reason visible to every client, and the chunk is retried with backoff until it
/// succeeds or the job is cancelled. It never finishes the book in a different voice: an
/// 80-minute file whose voice changes at minute 12 is worse than a book that says "paused"
/// (`specs/document-clippings.md`, *What breaks at book length*, 2).
public actor BookRenderer {
    public struct Retry: Sendable {
        public var initialDelay: Double
        public var maximumDelay: Double
        public init(initialDelay: Double = 1, maximumDelay: Double = 60) {
            self.initialDelay = initialDelay
            self.maximumDelay = maximumDelay
        }
    }

    let store: BookStore
    let cacheDirectory: URL
    let synthesizer: any SpeechSynthesizing
    let muxer: any AudioMuxing
    let concurrency: Int
    let retry: Retry
    let log: @Sendable (String) -> Void

    private var worker: Task<Void, Never>?
    /// The job being made now, and the task making it, so cancelling that job stops its work
    /// where it is.
    private var current: (id: String, task: Task<Void, Never>)?
    private var cancelled: Set<String> = []
    private var wake: [CheckedContinuation<Void, Never>] = []
    /// Each job's one format, once known (`bookFormat`).
    private var bookFormats: [String: BookFormat] = [:]

    public init(store: BookStore, cacheDirectory: URL, synthesizer: any SpeechSynthesizing,
                muxer: any AudioMuxing, concurrency: Int = 2, retry: Retry = Retry(),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.cacheDirectory = cacheDirectory
        self.synthesizer = synthesizer
        self.muxer = muxer
        self.concurrency = max(1, concurrency)
        self.retry = retry
        self.log = log
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: Requests

    public enum SubmitResult: Equatable, Sendable {
        case created(BookJob.Summary)
        case existing(BookJob.Summary)
    }

    /// Accept a book. The same id again returns the job already there, whatever state it is in.
    public func submit(_ book: PreparedBook, id: String, now: Date = Date()) throws -> SubmitResult {
        if let existing = store.load(id) { return .existing(existing.summary) }
        let job = BookJob(id: id, book: book, now: now)
        try store.save(job)
        cancelled.remove(id)
        log("book \(id.prefix(12)): accepted \"\(book.title)\", \(book.chapters.count) chapters, \(book.segmentCount) chunks")
        startIfNeeded()
        poke()
        return .created(job.summary)
    }

    /// Stop making a book and remove it. The job being made stops where it is: a chunk whose
    /// voice keeps failing is retried until it answers, and a cancel that only marked the job
    /// left that retry going, so the book submitted after it (the same book in another voice,
    /// from Change Voice) waited behind it until a relaunch.
    public func cancel(_ id: String) {
        cancelled.insert(id)
        store.remove(id)
        if let current, current.id == id { current.task.cancel() }
        poke()
    }

    public func markFinished(_ id: String, at date: Date = Date()) -> Bool {
        guard var job = store.load(id) else { return false }
        job.finishedAt = date
        job.updatedAt = date
        try? store.save(job)
        return true
    }

    /// Put chapters back in the queue to be made again: chapters whose audio has left this
    /// device (offloaded, M6.3) or, with `nil`, the whole book. Synthesis comes from the chunk
    /// cache where it can, so a chapter made before is joined and encoded rather than voiced
    /// again. Returns false when there is no such job.
    @discardableResult
    public func requeue(_ id: String, chapters: [Int]? = nil, now: Date = Date()) -> Bool {
        guard var job = store.load(id) else { return false }
        let indices = chapters ?? Array(job.chapters.indices)
        for index in indices where job.chapters.indices.contains(index) {
            job.chapters[index] = .queued
        }
        job.status = .rendering
        job.pauseReason = nil
        job.pauseDetail = nil
        job.updatedAt = now
        do { try store.save(job) } catch { return false }
        cancelled.remove(id)
        log("book \(id.prefix(12)): \(indices.count) chapters queued to be made again")
        startIfNeeded()
        poke()
        return true
    }

    /// Start the loop: on launch it resumes whatever was left unfinished.
    public func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { await self.loop() }
    }

    /// Stop the loop and leave every job as it is, mid-chapter included: the next
    /// `startIfNeeded` picks them up again from the chunk cache. For a device that turns
    /// documents off in Settings; nothing is marked failed or paused by stopping.
    public func stop() {
        worker?.cancel()
        worker = nil
        poke()
    }

    /// Wait until no job is left to render. For tests and for a graceful stop.
    public func waitUntilIdle() async {
        while store.list().contains(where: { ($0.status == .rendering || $0.status == .paused) && $0.uploaded != true }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Loop

    private func poke() {
        let waiting = wake
        wake.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func nextJob() -> BookJob? {
        store.list()
            // A book another device made and is uploading is not this loop's to make.
            .filter { ($0.status == .rendering || $0.status == .paused) && $0.uploaded != true && !cancelled.contains($0.id) }
            .min { $0.createdAt < $1.createdAt }
    }

    private func loop() async {
        while !Task.isCancelled {
            if let job = nextJob() {
                // Its own task, so `cancel` can stop this job alone; `stop` reaches it through
                // the handler.
                let task = Task { await self.render(job) }
                current = (job.id, task)
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                // Only its own: after a stop and a start, a newer loop may own the slot by now.
                if current?.task == task { current = nil }
            } else {
                await withCheckedContinuation { wake.append($0) }
            }
        }
    }

    private func render(_ initial: BookJob) async {
        var job = initial
        for chapterIndex in job.book.chapters.indices {
            if cancelled.contains(job.id) || Task.isCancelled { return }
            if case .ready = job.chapters[chapterIndex] { continue }
            do {
                job = try await renderChapter(job, chapterIndex)
            } catch {
                // Cancelled or stopped: the job stays as it was, to resume later.
                if cancelled.contains(job.id) || Task.isCancelled { return }
                job.chapters[chapterIndex] = .failed(reason: String(describing: error))
                job.status = .failed
                job.updatedAt = Date()
                try? store.save(job)
                log("book \(job.id.prefix(12)): chapter \(chapterIndex + 1) failed: \(error)")
                return
            }
        }
        job.status = .ready
        job.pauseReason = nil
        job.pauseDetail = nil
        job.updatedAt = Date()
        try? store.save(job)
        log("book \(job.id.prefix(12)): ready, \(job.bytesOnDisk) bytes")
    }

    private func renderChapter(_ initial: BookJob, _ index: Int) async throws -> BookJob {
        var job = initial
        let chapter = job.book.chapters[index]
        let segments = chapter.segments
        // A segment read by an expressive engine is a request per sentence.
        let parts = job.book.parts(of: chapter).map(\.part)
        job.chapters[index] = .rendering(done: 0, of: parts.count)
        try? store.save(job)

        // Synthesize into the content-addressed cache, a few at a time. What came from the cache
        // is counted, because "a restart synthesizes nothing twice" is checked from the log.
        var done = 0
        var synthesized = 0
        var lastSave = Date()
        var next = 0
        let jobID = job.id
        try await withThrowingTaskGroup(of: Bool.self) { group in
            func launch(_ i: Int) {
                let request = parts[i].request
                let url = cacheDirectory.appendingPathComponent(request.cacheKey + ".wav")
                let synthesizer = self.synthesizer
                group.addTask {
                    if FileManager.default.fileExists(atPath: url.path) { return false }
                    let data = try await self.synthesizeWithRetry(synthesizer, request, jobID: jobID)
                    try data.write(to: url, options: .atomic)
                    return true
                }
            }
            while next < min(concurrency, parts.count) { launch(next); next += 1 }
            while let wasSynthesized = try await group.next() {
                done += 1
                if wasSynthesized { synthesized += 1 }
                if next < parts.count { launch(next); next += 1 }
                if cancelled.contains(job.id) { group.cancelAll(); throw CancellationError() }
                if Date().timeIntervalSince(lastSave) > 1 || done == parts.count {
                    if var latest = store.load(job.id) {
                        latest.chapters[index] = .rendering(done: done, of: parts.count)
                        try? store.save(latest)
                        job = latest
                    }
                    lastSave = Date()
                }
            }
        }

        // Join the clips with their pauses into one WAV, then encode.
        guard let dir = store.jobDirectory(job.id) else { throw BookStoreError.badID }
        let joined = dir.appendingPathComponent("chapter-\(index + 1).wav")
        let file = "chapter-\(index + 1).m4a"
        let format = try await bookFormat(job)
        let (seconds, timing) = try joinWAV(segments: segments, book: job.book, format: format, to: joined)
        let tags = ["title": chapter.title, "album": job.book.title, "artist": job.book.author ?? "",
                    "track": "\(index + 1)/\(job.book.chapters.count)", "genre": "Audiobook"]
        try await muxer.encode(wav: joined, to: dir.appendingPathComponent(file), bitrate: job.book.audio.bitrate,
                               channels: job.book.audio.channels, sampleRate: AudioSettings.encodedSampleRate, tags: tags)
        try? FileManager.default.removeItem(at: joined)
        let encoded = dir.appendingPathComponent(file)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: encoded.path))?[.size] as? Int) ?? 0
        let sha = try SHA256Digest.hex(ofFileAt: encoded)
        // Read-along: where each chunk sits in the chapter, beside it. Written
        // before the chapter is marked ready, so a ready chapter made by this build has it.
        if let name = ReadAlongTiming.fileName(forChapterFile: file) {
            do {
                try timing.encoded().write(to: dir.appendingPathComponent(name), options: .atomic)
            } catch {
                log("book \(job.id.prefix(12)): chapter \(index + 1) timing not kept: \(error)")
            }
        }

        job = store.load(job.id) ?? job
        job.chapters[index] = .ready(file: file, bytes: bytes, seconds: seconds, sha256: sha)
        job.status = .rendering
        job.pauseReason = nil
        job.pauseDetail = nil
        job.updatedAt = Date()
        try store.save(job)
        log("book \(job.id.prefix(12)): chapter \(index + 1)/\(job.book.chapters.count) ready, \(Int(seconds)) s "
            + "(\(synthesized) synthesized, \(parts.count - synthesized) from cache)")
        return job
    }

    /// The one format a book's chapters are joined in: the narrator's, from the
    /// narrator's first clip in the book, synthesized now when it is not in the cache yet. Taken
    /// from a chapter's first clip instead, an untitled chapter that opens with a character
    /// read by another engine came out in that engine's format, and the chapters of one book
    /// could not be joined into one M4B. Nil only when the narrator reads nothing at all; a
    /// chapter then takes its first clip's format. Kept per job: it does not change.
    private func bookFormat(_ job: BookJob) async throws -> BookFormat? {
        if let known = bookFormats[job.id] { return known }
        let narrator = job.book.voices.narrator
        for chapter in job.book.chapters {
            for (_, part) in job.book.parts(of: chapter) where part.request.voice == narrator {
                let url = cacheDirectory.appendingPathComponent(part.request.cacheKey + ".wav")
                if !FileManager.default.fileExists(atPath: url.path) {
                    let data = try await synthesizeWithRetry(synthesizer, part.request, jobID: job.id)
                    try data.write(to: url, options: .atomic)
                }
                guard let clip = WAV.parse(try Data(contentsOf: url)) else {
                    throw SynthesisError.permanent("a cached clip is not WAV: \(url.lastPathComponent)")
                }
                let format = BookFormat(format: clip.format, voice: narrator)
                bookFormats[job.id] = format
                return format
            }
        }
        return nil
    }

    /// Retry a transient failure forever (with backoff), pausing the job while it fails and
    /// un-pausing it on the first success. A permanent failure is thrown.
    private func synthesizeWithRetry(_ synthesizer: any SpeechSynthesizing, _ request: SegmentRequest,
                                     jobID: String) async throws -> Data {
        var delay = retry.initialDelay
        var paused = false
        while true {
            try Task.checkCancellation()
            do {
                let data = try await synthesizer.synthesize(text: request.text, voice: request.voice,
                                                            speed: request.speed, style: request.style,
                                                            instruction: request.instruction)
                if paused { setPaused(jobID, error: nil) }
                return data
            } catch let error as SynthesisError {
                if case .permanent = error { throw error }
                // A request cut off by `stop()` is not the voice server failing.
                try Task.checkCancellation()
                if !paused {
                    paused = true
                    setPaused(jobID, error: error)
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(retry.maximumDelay, delay * 2)
            }
        }
    }

    private func setPaused(_ id: String, error: SynthesisError?) {
        guard var job = store.load(id) else { return }
        job.status = error == nil ? .rendering : .paused
        job.pauseReason = error?.listenerReason
        job.pauseDetail = error?.description
        job.updatedAt = Date()
        try? store.save(job)
        log(error.map { "book \(id.prefix(12)): paused: \($0.description)" } ?? "book \(id.prefix(12)): resumed")
    }

    /// Concatenate the cached clips, with each part's pause as silence, into one WAV.
    /// Returns the duration in seconds and where each segment's speech starts and ends in it,
    /// for read-along: a segment read sentence by sentence spans all its sentences. The chapter
    /// takes its first clip's format, and a clip in another (a cast whose voices come from
    /// different engines, TBX-11141) is converted to it; only a clip in a format `WAV.converting`
    /// does not read is refused, naming its voice, rather than garbled.
    nonisolated func joinWAV(segments: [SpeechSegment], book: PreparedBook, format bookFormat: BookFormat? = nil,
                             to destination: URL) throws -> (seconds: Double, timing: ReadAlongTiming) {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw SynthesisError.permanent("could not create \(destination.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var format = bookFormat?.format
        // Whose audio set the format, for a refusal that names the voice at fault.
        var formatVoice = bookFormat?.voice
        var total = 0
        var timed: [ReadAlongTiming.Segment] = []
        try handle.write(contentsOf: Data(count: 44))   // header placeholder, rewritten below
        for (i, segment) in segments.enumerated() {
            var start: Double?
            for part in book.parts(for: segment, after: i > 0 ? segments[i - 1] : nil) {
                let url = cacheDirectory.appendingPathComponent(part.request.cacheKey + ".wav")
                guard let clip = WAV.parse(try Data(contentsOf: url)) else {
                    throw SynthesisError.permanent("a cached clip is not WAV: \(url.lastPathComponent)")
                }
                var pcm = part.trimsSilence ? WAV.trimmingSilence(clip.pcm, format: clip.format) : clip.pcm
                let target = format ?? clip.format
                if format == nil { formatVoice = part.request.voice }
                if target != clip.format {
                    guard let converted = WAV.converting(pcm, from: clip.format, to: target) else {
                        // The voice whose format cannot be read: this clip's, or the one the
                        // book's format came from.
                        let (unreadable, other) = WAV.isConvertible(clip.format)
                            ? ((formatVoice ?? book.voices.narrator, target), (part.request.voice, clip.format))
                            : ((part.request.voice, clip.format), (formatVoice ?? book.voices.narrator, target))
                        throw SynthesisError.permanent("\(unreadable.0) answers \(WAV.describe(unreadable.1)) audio, which cannot be "
                            + "joined with the \(WAV.describe(other.1)) of \(other.0)")
                    }
                    pcm = converted
                }
                format = target
                let silence = Int(Double(target.sampleRate) * Double(part.pauseBeforeMs) / 1000) * target.blockAlign
                if silence > 0 { try handle.write(contentsOf: Data(count: silence)); total += silence }
                let bytesPerSecond = Double(target.blockAlign) * Double(target.sampleRate)
                if start == nil { start = Double(total) / bytesPerSecond }
                try handle.write(contentsOf: pcm)
                total += pcm.count
            }
            let bytesPerSecond = format.map { Double($0.blockAlign) * Double($0.sampleRate) } ?? 1
            timed.append(ReadAlongTiming.Segment(text: segment.text, paragraph: segment.paragraph,
                                                 start: start ?? Double(total) / bytesPerSecond,
                                                 end: Double(total) / bytesPerSecond))
        }
        guard let format else { throw SynthesisError.permanent("the chapter has no audio") }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAV.header(format: format, dataBytes: total))
        return (Double(total) / Double(format.blockAlign) / Double(format.sampleRate), ReadAlongTiming(segments: timed))
    }
}
