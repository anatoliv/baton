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
}

extension SpeechSynthesizing {
    public func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?) async throws -> Data {
        try await synthesize(text: text, voice: voice, speed: speed)
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
/// the Mac: `{model, voice, input, response_format: "wav"}`. One base URL per engine.
public struct HTTPSpeechSynthesizer: SpeechSynthesizing {
    public let engines: [String: URL]
    public let timeout: TimeInterval

    public init(engines: [String: URL], timeout: TimeInterval = 60) {
        self.engines = engines
        self.timeout = timeout
    }

    public func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
        try await synthesize(text: text, voice: voice, speed: speed, style: nil)
    }

    /// With a style and a Chatterbox voice, the request goes to Chatterbox-TTS-Server's own
    /// `/tts` route: its OpenAI-compatible route ignores `exaggeration` and `cfg_weight`.
    public func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?) async throws -> Data {
        let (engine, name) = Self.split(voice)
        guard let base = engines[engine] else {
            throw SynthesisError.permanent("no \(engine) host is configured on the Baton server")
        }
        let request = try Self.request(base: base, engine: engine, voice: name, text: text, speed: speed,
                                       style: style, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
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
                        style: SpeechStyle?, timeout: TimeInterval) throws -> URLRequest {
        let expressive = engine == "chatterbox" ? style : nil
        var request = URLRequest(url: base.appendingPathComponent(expressive == nil ? "v1/audio/speech" : "tts"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any]
        if let expressive {
            body = ["text": text, "voice_mode": "predefined", "predefined_voice_id": voice, "output_format": "wav",
                    "split_text": false, "exaggeration": expressive.exaggeration, "cfg_weight": expressive.cfgWeight]
            if let speed { body["speed_factor"] = speed }
        } else {
            body = ["model": engine, "voice": voice, "input": text, "response_format": "wav"]
            if let speed { body["speed"] = speed }
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
    private var cancelled: Set<String> = []
    private var wake: [CheckedContinuation<Void, Never>] = []

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

    public func cancel(_ id: String) {
        cancelled.insert(id)
        store.remove(id)
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
        while store.list().contains(where: { $0.status == .rendering || $0.status == .paused }) {
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
            .filter { ($0.status == .rendering || $0.status == .paused) && !cancelled.contains($0.id) }
            .min { $0.createdAt < $1.createdAt }
    }

    private func loop() async {
        while !Task.isCancelled {
            if let job = nextJob() {
                await render(job)
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
        job.chapters[index] = .rendering(done: 0, of: segments.count)
        try? store.save(job)

        // Synthesize into the content-addressed cache, a few at a time. What came from the cache
        // is counted, because "a restart synthesizes nothing twice" is checked from the log.
        var done = 0
        var synthesized = 0
        var lastSave = Date()
        var next = 0
        let jobID = job.id
        try await withThrowingTaskGroup(of: Bool.self) { group in
            let book = job.book
            func launch(_ i: Int) {
                let request = book.request(for: segments[i])
                let url = cacheDirectory.appendingPathComponent(request.cacheKey + ".wav")
                let synthesizer = self.synthesizer
                group.addTask {
                    if FileManager.default.fileExists(atPath: url.path) { return false }
                    let data = try await self.synthesizeWithRetry(synthesizer, request, jobID: jobID)
                    try data.write(to: url, options: .atomic)
                    return true
                }
            }
            while next < min(concurrency, segments.count) { launch(next); next += 1 }
            while let wasSynthesized = try await group.next() {
                done += 1
                if wasSynthesized { synthesized += 1 }
                if next < segments.count { launch(next); next += 1 }
                if cancelled.contains(job.id) { group.cancelAll(); throw CancellationError() }
                if Date().timeIntervalSince(lastSave) > 1 || done == segments.count {
                    if var latest = store.load(job.id) {
                        latest.chapters[index] = .rendering(done: done, of: segments.count)
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
        let (seconds, timing) = try joinWAV(segments: segments, book: job.book, to: joined)
        let tags = ["title": chapter.title, "album": job.book.title, "artist": job.book.author ?? "",
                    "track": "\(index + 1)/\(job.book.chapters.count)", "genre": "Audiobook"]
        try await muxer.encode(wav: joined, to: dir.appendingPathComponent(file), bitrate: job.book.audio.bitrate,
                               channels: job.book.audio.channels, tags: tags)
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
            + "(\(synthesized) synthesized, \(segments.count - synthesized) from cache)")
        return job
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
                                                            speed: request.speed, style: request.style)
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

    /// Concatenate the cached clips, with each segment's pause as silence, into one WAV.
    /// Returns the duration in seconds and where each segment's speech starts and ends in it,
    /// for read-along. Every clip must share one format; Kokoro always answers 24 kHz mono
    /// 16-bit, and a mixed cast across engines is refused here rather than garbled.
    nonisolated func joinWAV(segments: [SpeechSegment], book: PreparedBook,
                             to destination: URL) throws -> (seconds: Double, timing: ReadAlongTiming) {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw SynthesisError.permanent("could not create \(destination.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var format: WAV.Format?
        var total = 0
        var timed: [ReadAlongTiming.Segment] = []
        try handle.write(contentsOf: Data(count: 44))   // header placeholder, rewritten below
        for segment in segments {
            let url = cacheDirectory.appendingPathComponent(book.request(for: segment).cacheKey + ".wav")
            guard let clip = WAV.parse(try Data(contentsOf: url)) else {
                throw SynthesisError.permanent("a cached clip is not WAV: \(url.lastPathComponent)")
            }
            if let format, format != clip.format {
                throw SynthesisError.permanent("voices in this book return different audio formats; render it with one engine")
            }
            format = clip.format
            let silence = Int(Double(clip.format.sampleRate) * Double(segment.pauseBeforeMs) / 1000) * clip.format.blockAlign
            if silence > 0 { try handle.write(contentsOf: Data(count: silence)); total += silence }
            let bytesPerSecond = Double(clip.format.blockAlign) * Double(clip.format.sampleRate)
            let start = Double(total) / bytesPerSecond
            try handle.write(contentsOf: clip.pcm)
            total += clip.pcm.count
            timed.append(ReadAlongTiming.Segment(text: segment.text, paragraph: segment.paragraph,
                                                 start: start, end: Double(total) / bytesPerSecond))
        }
        guard let format else { throw SynthesisError.permanent("the chapter has no audio") }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAV.header(format: format, dataBytes: total))
        return (Double(total) / Double(format.blockAlign) / Double(format.sampleRate), ReadAlongTiming(segments: timed))
    }
}
