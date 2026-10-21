import Foundation
import XCTest
@testable import BatonDocuments

// The render loop the gateway and the Mac share: chapter order, the chunk cache, pause and
// resume on a TTS outage, restart. Encoding is faked here (`CopyMuxer`); the gateway's tests
// run the real ffmpeg, and the Mac's run AVAssetWriter.

// MARK: - Fakes

/// A TTS engine that answers with a short tone per request and records what it was asked, in
/// order. Failures are scripted: `transientFailures` requests fail before the first success,
/// and `permanentVoice` is refused outright.
final class FakeSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(text: String, voice: String)] = []
    private var failuresLeft: Int
    let permanentVoice: String?
    let secondsPerClip: Double

    init(transientFailures: Int = 0, permanentVoice: String? = nil, secondsPerClip: Double = 0.2) {
        self.failuresLeft = transientFailures
        self.permanentVoice = permanentVoice
        self.secondsPerClip = secondsPerClip
    }

    var calls: [(text: String, voice: String)] { lock.withLock { _calls } }

    func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
        if voice == permanentVoice { throw SynthesisError.permanent("unknown voice \(voice)") }
        let fail: Bool = lock.withLock {
            if failuresLeft > 0 { failuresLeft -= 1; return true }
            _calls.append((text, voice))
            return false
        }
        if fail { throw SynthesisError.transient("kokoro did not answer: connection refused") }
        return FakeSynthesizer.tone(seconds: secondsPerClip)
    }

    static func tone(seconds: Double, rate: UInt32 = 24_000) -> Data {
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let sample = Int16(3000 * sin(Double(i) / 8))
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let format = WAV.Format(audioFormat: 1, channels: 1, sampleRate: rate, bitsPerSample: 16)
        return WAV.header(format: format, dataBytes: pcm.count) + pcm
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// An encoder that copies the WAV, for tests about the loop rather than the encoding.
struct CopyMuxer: AudioMuxing {
    func encode(wav: URL, to destination: URL, bitrate: Int, channels: Int, tags: [String: String]) async throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: wav, to: destination)
    }
}

// MARK: - Fixtures

func sampleBook(narrator: String = "kokoro:bf_emma", chapters: Int = 2) -> PreparedBook {
    let doc = ImportedDocument(
        sourceSHA256: String(repeating: "ab", count: 32), sourceKind: .pdf, title: "A Small Room", author: "A. N. Author",
        chapters: (0..<chapters).map { c in
            DocumentChapter(index: c, title: "Part \(c + 1)", paragraphs: [
                "Chapter \(c + 1) opens on a small room, shaped like the cell of a bee, lit by nothing at all.",
                "\u{201C}Who is it?\u{201D} she called, in chapter \(c + 1). Nobody answered her for a long while.",
            ], label: "\(c + 1)")
        })
    return DocumentSpeech.prepare(doc, voices: VoicePlan(narrator: narrator))
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("books-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - WAV

final class WAVTests: XCTestCase {
    func testRoundTripAndStreamedLength() throws {
        let tone = FakeSynthesizer.tone(seconds: 0.1)
        let parsed = try XCTUnwrap(WAV.parse(tone))
        XCTAssertEqual(parsed.format, WAV.Format(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16))
        XCTAssertEqual(parsed.pcm.count, 2400 * 2)

        // A streamed WAV says 0xFFFFFFFF for the data size and means "to the end".
        var streamed = tone
        streamed.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(WAV.parse(streamed)?.pcm.count, 2400 * 2)
        XCTAssertNil(WAV.parse(Data("not audio at all".utf8)))
    }

    /// A speech server's `fmt ` chunk is not trusted: a format no audio has is refused at parse,
    /// rather than trapping on overflow when the joined chapter's header is written.
    func testAnAbsurdFormatIsRefused() {
        var absurd = FakeSynthesizer.tone(seconds: 0.1)
        absurd.replaceSubrange(22..<24, with: [0xFF, 0xFF])             // channels
        absurd.replaceSubrange(24..<28, with: [0xFF, 0xFF, 0xFF, 0xFF]) // sample rate
        absurd.replaceSubrange(34..<36, with: [0xFF, 0xFF])             // bits per sample
        XCTAssertNil(WAV.parse(absurd))
        var silent = FakeSynthesizer.tone(seconds: 0.1)
        silent.replaceSubrange(22..<24, with: [0, 0])
        XCTAssertNil(WAV.parse(silent), "no channels")
    }

    /// Past 4 GB the sizes do not fit the header's 32 bits: it says "to the end", as a streamed
    /// WAV does, instead of trapping.
    func testAHeaderPastFourGigabytesSaysToTheEnd() throws {
        let format = WAV.Format(audioFormat: 1, channels: 2, sampleRate: 48_000, bitsPerSample: 16)
        let header = WAV.header(format: format, dataBytes: Int(UInt32.max) + 10)
        XCTAssertEqual(Array(header[40..<44]), [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(Array(header[4..<8]), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testVoiceSpecSplit() {
        XCTAssertEqual(HTTPSpeechSynthesizer.split("kokoro:bf_emma").engine, "kokoro")
        XCTAssertEqual(HTTPSpeechSynthesizer.split("chatterbox:Emily.wav").voice, "Emily.wav")
        XCTAssertEqual(HTTPSpeechSynthesizer.split("af_heart").engine, "kokoro")
    }
}

// MARK: - Store

final class BookStoreTests: XCTestCase {
    func testRetentionAndQuotaNeverTouchAnUnfinishedBook() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir, maximumBytes: 250, keepFinished: 10 * 86_400)
        let now = Date()

        func job(_ n: Int, bytes: Int, finishedDaysAgo: Double?) throws -> BookJob {
            var j = BookJob(id: String(repeating: "\(n)", count: 64), book: sampleBook(chapters: 1),
                            now: now.addingTimeInterval(Double(-n)))
            j.chapters = [.ready(file: "chapter-1.m4a", bytes: bytes, seconds: 1, sha256: "x")]
            j.status = .ready
            j.finishedAt = finishedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
            try store.save(j)
            return j
        }
        let unfinished = try job(1, bytes: 200, finishedDaysAgo: nil)
        let old = try job(2, bytes: 10, finishedDaysAgo: 20)         // past retention
        let recent = try job(3, bytes: 50, finishedDaysAgo: 2)
        let older = try job(4, bytes: 50, finishedDaysAgo: 5)

        // Retention takes `old`; then 300 > 250, so the earliest-finished (`older`) goes; then
        // 250 fits. The unfinished 200-byte book is never a candidate.
        let removed = store.prune(now: now)
        XCTAssertEqual(Set(removed), [old.id, older.id])
        XCTAssertNotNil(store.load(unfinished.id))
        XCTAssertNotNil(store.load(recent.id))
        XCTAssertFalse(store.hasRoom(for: 100, now: now))   // only unfinished + recent left: 250
        XCTAssertEqual(store.usedBytes, 250)
    }

    func testJobIDDependsOnDocumentAndVoicesOnly() {
        XCTAssertEqual(BookJob.id(for: sampleBook()), BookJob.id(for: sampleBook()))
        XCTAssertNotEqual(BookJob.id(for: sampleBook()), BookJob.id(for: sampleBook(narrator: "kokoro:bm_george")))
        XCTAssertEqual(BookJob.id(for: sampleBook()).count, 64)
    }

    /// The listing says which books a Mac made and uploaded, so the iPhone can say
    /// "Made on your Mac" rather than "Made on the Baton server"; a book made here says nothing.
    func testTheSummaryTellsAnUploadedBookFromOneMadeHere() throws {
        var uploaded = BookJob(id: BookJob.id(for: sampleBook()), book: sampleBook())
        uploaded.uploaded = true
        let made = BookJob(id: BookJob.id(for: sampleBook()), book: sampleBook())
        XCTAssertEqual(uploaded.summary.uploaded, true)
        XCTAssertNil(made.summary.uploaded)
        let decoded = try BookJSON.decoder.decode(BookJob.Summary.self, from: BookJSON.encoder.encode(uploaded.summary))
        XCTAssertEqual(decoded.uploaded, true, "it reaches the other device")
        XCTAssertFalse(String(decoding: try BookJSON.encoder.encode(made.summary), as: UTF8.self).contains("uploaded"),
                       "nothing extra for a book the home server made")
    }
}

// MARK: - Renderer

final class BookRendererTests: XCTestCase {
    private func renderer(_ dir: URL, _ synth: FakeSynthesizer, muxer: any AudioMuxing = CopyMuxer(),
                          concurrency: Int = 2) -> (BookRenderer, BookStore) {
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let r = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: synth,
                             muxer: muxer, concurrency: concurrency,
                             retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        return (r, store)
    }

    func testRendersEveryChapterInOrderWithItsPauses() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = FakeSynthesizer()
        let (r, store) = renderer(dir, synth, concurrency: 1)
        let book = sampleBook()
        let id = BookJob.id(for: book)
        _ = try await r.submit(book, id: id)
        await r.waitUntilIdle()

        let job = try XCTUnwrap(store.load(id))
        XCTAssertEqual(job.status, .ready)
        XCTAssertEqual(job.readyChapters, 2)
        // Chapter 1's chunks are all asked for before any of chapter 2's.
        let chapterOfCall = synth.calls.map { $0.text.contains("chapter 2") || $0.text.contains("Chapter 2") ? 2 : 1 }
        XCTAssertEqual(chapterOfCall, chapterOfCall.sorted())
        XCTAssertTrue(synth.calls.allSatisfy { $0.voice == "kokoro:bf_emma" })

        // Duration = clips + the pauses the prepared book asked for.
        guard case let .ready(file, _, seconds, sha) = job.chapters[0] else { return XCTFail("chapter 1 not ready") }
        let segments = book.chapters[0].segments
        let expected = Double(segments.count) * 0.2 + Double(segments.map(\.pauseBeforeMs).reduce(0, +)) / 1000
        XCTAssertEqual(seconds, expected, accuracy: 0.01)
        let url = try XCTUnwrap(store.chapterURL(id, file: file))
        XCTAssertEqual(sha, try SHA256Digest.hex(ofFileAt: url))
        // The joined WAV is a temporary; only the encoded chapter stays.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("chapter-1.wav").path))
    }

    func testTheChunkCacheMeansAReRenderAsksForNothingNew() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = FakeSynthesizer()
        let (r, store) = renderer(dir, synth)
        let book = sampleBook()
        _ = try await r.submit(book, id: BookJob.id(for: book))
        await r.waitUntilIdle()
        let first = synth.calls.count
        XCTAssertEqual(first, book.segmentCount)

        // The same book again under a new job id (it was deleted and re-submitted).
        await r.cancel(BookJob.id(for: book))
        _ = try await r.submit(book, id: String(repeating: "c", count: 64))
        await r.waitUntilIdle()
        XCTAssertEqual(synth.calls.count, first)
        XCTAssertEqual(store.load(String(repeating: "c", count: 64))?.status, .ready)
    }

    func testAnUnreachableHostPausesTheBookAndItResumesInTheSameVoice() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = FakeSynthesizer(transientFailures: 5)
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let lines = LogLines()
        let r = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: synth,
                             muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02),
                             log: { lines.append($0) })
        let book = sampleBook()
        _ = try await r.submit(book, id: BookJob.id(for: book))
        await r.waitUntilIdle()

        let job = try XCTUnwrap(store.load(BookJob.id(for: book)))
        XCTAssertEqual(job.status, .ready)
        XCTAssertNil(job.pauseReason)
        XCTAssertTrue(synth.calls.allSatisfy { $0.voice == "kokoro:bf_emma" }, "never another voice")
        let log = lines.all
        XCTAssertTrue(log.contains { $0.contains("paused: kokoro did not answer") }, "\(log)")
        // While it was paused, the listener read plain words and the log kept the engine's own.
        let pausedLine = log.first { $0.contains("paused:") } ?? ""
        XCTAssertTrue(pausedLine.contains("connection refused"), pausedLine)
        XCTAssertTrue(log.contains { $0.contains("resumed") })
    }

    func testARefusedVoiceFailsTheBookWithTheReason() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (r, store) = renderer(dir, FakeSynthesizer(permanentVoice: "kokoro:xx_nobody"))
        let book = sampleBook(narrator: "kokoro:xx_nobody")
        _ = try await r.submit(book, id: BookJob.id(for: book))
        await r.waitUntilIdle()
        let job = try XCTUnwrap(store.load(BookJob.id(for: book)))
        XCTAssertEqual(job.status, .failed)
        guard case let .failed(reason) = job.chapters[0] else { return XCTFail("\(job.chapters[0])") }
        XCTAssertTrue(reason.contains("unknown voice"))
    }

    func testARestartedGatewayResumesWhereItStopped() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = sampleBook()
        let id = BookJob.id(for: book)

        // First life: render everything, then pretend chapter 2 never finished.
        do {
            let (r, store) = renderer(dir, FakeSynthesizer())
            _ = try await r.submit(book, id: id)
            await r.waitUntilIdle()
            var job = try XCTUnwrap(store.load(id))
            job.chapters[1] = .rendering(done: 1, of: book.chapters[1].segments.count)
            job.status = .rendering
            try store.save(job)
        }
        // Second life: a new renderer over the same directories picks it up by itself, and
        // the cache means chapter 2 needs no TTS at all.
        let synth = FakeSynthesizer()
        let lines = LogLines()
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let r = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: synth,
                             muxer: CopyMuxer(), retry: .init(initialDelay: 0.01, maximumDelay: 0.02),
                             log: { lines.append($0) })
        await r.startIfNeeded()
        await r.waitUntilIdle()
        XCTAssertEqual(store.load(id)?.status, .ready)
        XCTAssertEqual(synth.calls.count, 0)
        // And the log says so, which is how a person checks it on a real run.
        let segments = book.chapters[1].segments.count
        XCTAssertTrue(lines.all.contains { $0.contains("chapter 2/2 ready") && $0.contains("(0 synthesized, \(segments) from cache)") },
                      "\(lines.all)")
    }
}

final class PauseReasonTests: XCTestCase {
    func testListenerReasonsAreWordsNotDiagnostics() {
        XCTAssertEqual(SynthesisError.transient("kokoro did not answer: cannot parse response").listenerReason,
                       "the voice server isn't answering")
        XCTAssertEqual(SynthesisError.transient("kokoro returned audio that is not WAV").listenerReason,
                       "the voice server sent back audio Baton can't read")
        XCTAssertEqual(SynthesisError.transient("kokoro answered 503").listenerReason,
                       "the voice server is having trouble (error 503)")
        XCTAssertEqual(SynthesisError.transient("kokoro answered 429").listenerReason, "the voice server is busy")
        XCTAssertEqual(SynthesisError.permanent("no chatterbox host is configured on the gateway").listenerReason,
                       "no voice server is set up for this voice")
        XCTAssertEqual(SynthesisError.transient("something new").listenerReason, "the voice server isn't working right now")
        // User copy: no em or en dashes.
        for e in [SynthesisError.transient("x answered 500"), .permanent("refused")] {
            XCTAssertFalse(e.listenerReason.contains("\u{2014}") || e.listenerReason.contains("\u{2013}"))
        }
    }

    func testAPausedJobCarriesBothAndResumingClearsBoth() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let gate = PauseGate()
        let r = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: gate,
                             muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.02, maximumDelay: 0.02))
        let book = sampleBook(chapters: 1)
        let id = BookJob.id(for: book)
        _ = try await r.submit(book, id: id)
        var paused: BookJob?
        for _ in 0..<200 {
            if let j = store.load(id), j.status == .paused { paused = j; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(paused?.pauseReason, "the voice server isn't answering")
        XCTAssertEqual(paused?.pauseDetail, "kokoro did not answer: cannot parse response")
        XCTAssertEqual(paused?.summary.pauseDetail, "kokoro did not answer: cannot parse response")
        gate.up = true
        await r.waitUntilIdle()
        XCTAssertNil(store.load(id)?.pauseReason)
        XCTAssertNil(store.load(id)?.pauseDetail)
    }
}

/// Down until `up` is set: the outage the M3 walk produced by stopping Kokoro.
final class PauseGate: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _up = false
    var up: Bool {
        get { lock.withLock { _up } }
        set { lock.withLock { _up = newValue } }
    }
    func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
        guard up else { throw SynthesisError.transient("kokoro did not answer: cannot parse response") }
        return FakeSynthesizer.tone(seconds: 0.05)
    }
}
