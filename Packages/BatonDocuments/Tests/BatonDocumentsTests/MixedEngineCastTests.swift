import Foundation
import XCTest
@testable import BatonDocuments

/// A cast whose voices come from different engines: Kokoro answers 24 kHz mono
/// 16-bit, another server may answer another rate, float samples or two channels. A chapter is
/// one file, so each clip is converted to the chapter's format as it is joined; only a format
/// the join cannot read is refused, and the refusal names the voice.
final class MixedEngineCastTests: XCTestCase {
    /// Answers each engine in its own format: Kokoro 24 kHz mono 16-bit, the other engine as
    /// `other` says, each clip `seconds` long.
    final class TwoFormats: SpeechSynthesizing, @unchecked Sendable {
        let other: WAV.Format
        let seconds: Double
        private let lock = NSLock()
        private var _voices: [String] = []
        var voices: [String] { lock.withLock { _voices } }

        init(other: WAV.Format, seconds: Double = 0.2) {
            self.other = other
            self.seconds = seconds
        }

        func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
            lock.withLock { _voices.append(voice) }
            if voice.hasPrefix("kokoro:") { return FakeSynthesizer.tone(seconds: seconds) }
            return Self.clip(other, seconds: seconds)
        }

        /// A 440 Hz tone in `format`; for a format the join does not read, the right number of
        /// zero bytes.
        static func clip(_ format: WAV.Format, seconds: Double) -> Data {
            let frames = Int(Double(format.sampleRate) * seconds)
            var pcm = Data(capacity: frames * format.blockAlign)
            for i in 0..<frames {
                let v = 0.1 * sin(2 * Double.pi * 440 * Double(i) / Double(format.sampleRate))
                for _ in 0..<Int(format.channels) {
                    if format.audioFormat == 3 {
                        withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { pcm.append(contentsOf: $0) }
                    } else if format.bitsPerSample == 16 {
                        withUnsafeBytes(of: Int16(v * 32767).littleEndian) { pcm.append(contentsOf: $0) }
                    } else {
                        pcm.append(Data(count: Int(format.bitsPerSample) / 8))
                    }
                }
            }
            return WAV.header(format: format, dataBytes: pcm.count) + pcm
        }
    }

    private let kokoro = WAV.Format(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16)

    /// A book read by a Kokoro narrator with one character in another engine's voice.
    private func castBook(character voice: String) -> PreparedBook {
        var book = sampleBook(narrator: "kokoro:bf_emma", chapters: 1)
        book.voices.characters = ["Vashti": voice]
        for s in book.chapters[0].segments.indices where book.chapters[0].segments[s].text.contains("\u{201C}") {
            book.chapters[0].segments[s].speaker = "Vashti"
        }
        return book
    }

    private func render(_ book: PreparedBook, _ synth: TwoFormats, in dir: URL) async throws -> BookJob {
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: synth,
                                    muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        _ = try await renderer.submit(book, id: BookJob.id(for: book))
        await renderer.waitUntilIdle()
        return try XCTUnwrap(store.load(BookJob.id(for: book)))
    }

    /// The review's repro: an untitled chapter (no spoken heading, as an EPUB's or a
    /// web page's opening before the first heading) that opens with a character read by another
    /// engine. Every chapter of the book is in one format, the narrator's.
    func testEveryChapterOfABookIsInTheNarratorsFormat() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = ImportedDocument(
            sourceSHA256: String(repeating: "cd", count: 32), sourceKind: .pdf, title: "Repro", author: nil,
            chapters: [
                DocumentChapter(index: 0, title: "", paragraphs: [
                    "\u{201C}Where is everyone?\u{201D} Vashti asked. The room did not answer her.",
                ]),
                DocumentChapter(index: 1, title: "The Machine", paragraphs: [
                    "The machine hummed on through the night, as it always had.",
                    "\u{201C}Who is it?\u{201D} Vashti called. Nobody answered.",
                ], label: "1"),
            ])
        let book = DocumentSpeech.prepare(doc, voices: VoicePlan(narrator: "kokoro:bf_emma", characters: ["Vashti": "chatterbox:Emily.wav"]),
                                          attribution: { _, _ in "Vashti" })
        XCTAssertEqual(book.chapters[0].segments.first?.speaker, "Vashti", "the repro's shape: chapter 1 opens with the character")
        let other = WAV.Format(audioFormat: 3, channels: 2, sampleRate: 48_000, bitsPerSample: 32)
        let job = try await render(book, TwoFormats(other: other), in: dir)
        XCTAssertEqual(job.status, .ready, "\(job.chapters)")
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        var formats: [WAV.Format] = []
        for chapter in job.chapters {
            guard case let .ready(file, _, _, _) = chapter else { return XCTFail("\(chapter)") }
            formats.append(try XCTUnwrap(WAV.parse(Data(contentsOf: try XCTUnwrap(store.chapterURL(job.id, file: file))))).format)
        }
        XCTAssertEqual(formats, [kokoro, kokoro], "one format for the book, the narrator's: \(formats.map(WAV.describe))")
    }

    /// When the narrator's own audio is the format the join cannot read, the refusal names the
    /// narrator, not the character whose clip came next.
    func testTheRefusalNamesTheVoiceWhoseAudioCannotBeRead() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pcm24 = WAV.Format(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 24)
        var book = castBook(character: "kokoro:af_bella")
        book.voices.narrator = "chatterbox:Emily.wav"
        let job = try await render(book, TwoFormats(other: pcm24), in: dir)
        guard case let .failed(reason) = job.chapters[0] else { return XCTFail("\(job.chapters[0])") }
        XCTAssertTrue(reason.contains("chatterbox:Emily.wav answers 24 kHz mono 24-bit audio, which cannot be joined with the 24 kHz mono 16-bit of kokoro:af_bella"),
                      reason)
    }

    /// Downsampling low-passes first: an 18 kHz tone at 48 kHz has nothing to say at 24 kHz
    /// (Nyquist 12 kHz), and linear interpolation folded it down to 6 kHz at nearly full level.
    /// The same input gives the same bytes every time.
    func testDownsamplingDoesNotAliasAndIsDeterministic() throws {
        let mono48 = WAV.Format(audioFormat: 3, channels: 1, sampleRate: 48_000, bitsPerSample: 32)
        func tone(_ hz: Double) -> Data {
            var pcm = Data()
            for i in 0..<24_000 {
                let v = Float(0.5 * sin(2 * Double.pi * hz * Double(i) / 48_000))
                withUnsafeBytes(of: v.bitPattern.littleEndian) { pcm.append(contentsOf: $0) }
            }
            return pcm
        }
        func rms(_ pcm16: Data) -> Double {
            let values = stride(from: 0, to: pcm16.count, by: 2).map {
                Double(Int16(bitPattern: UInt16(pcm16[$0]) | UInt16(pcm16[$0 + 1]) << 8)) / 32768
            }
            let middle = values[1_000..<(values.count - 1_000)]   // past the edges' ramp
            return (middle.reduce(0) { $0 + $1 * $1 } / Double(middle.count)).squareRoot()
        }
        let high = try XCTUnwrap(WAV.converting(tone(18_000), from: mono48, to: kokoro))
        let low = try XCTUnwrap(WAV.converting(tone(1_000), from: mono48, to: kokoro))
        XCTAssertEqual(rms(low), 0.5 / 2.squareRoot(), accuracy: 0.01, "a tone below the new Nyquist keeps its level")
        XCTAssertLessThan(rms(high), 0.5 / 2.squareRoot() / 100, "above it, at least 40 dB down, not folded back")
        XCTAssertEqual(WAV.converting(tone(18_000), from: mono48, to: kokoro), high, "deterministic")
    }

    /// A book in one format is joined exactly as before mixed engines were (review
    /// measured these on f840d9bb, with the copy encoder): Kokoro alone, a Kokoro cast, and an
    /// expressive narrator alone.
    func testABookInOneFormatIsMadeByteForByteAsBefore() async throws {
        func digests(_ book: PreparedBook) async throws -> [String] {
            let dir = tempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = BookStore(directory: dir.appendingPathComponent("books"))
            let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: FakeSynthesizer(),
                                        muxer: CopyMuxer(), concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
            _ = try await renderer.submit(book, id: BookJob.id(for: book))
            await renderer.waitUntilIdle()
            let job = try XCTUnwrap(store.load(BookJob.id(for: book)))
            var out = [String(job.id.prefix(12))]
            for chapter in job.chapters {
                guard case let .ready(file, _, seconds, _) = chapter else { XCTFail("\(chapter)"); return out }
                let data = try Data(contentsOf: try XCTUnwrap(store.chapterURL(job.id, file: file)))
                out.append(String(SHA256Digest.hex(of: data).prefix(16)) + "/\(seconds)")
            }
            return out
        }
        var cast = sampleBook(narrator: "kokoro:bf_emma", chapters: 2)
        cast.voices.characters = ["Vashti": "kokoro:af_bella"]
        for c in cast.chapters.indices {
            for s in cast.chapters[c].segments.indices where cast.chapters[c].segments[s].text.contains("\u{201C}") {
                cast.chapters[c].segments[s].speaker = "Vashti"
            }
        }
        let kokoroAlone = try await digests(sampleBook(narrator: "kokoro:bf_emma", chapters: 2))
        let kokoroCast = try await digests(cast)
        let expressiveAlone = try await digests(sampleBook(narrator: "openai:Ryan", chapters: 2))
        XCTAssertEqual(kokoroAlone, ["972375478d97", "ecb879d7ee920311/2.15", "ecb879d7ee920311/2.15"])
        XCTAssertEqual(kokoroCast, ["0db692961492", "ecb879d7ee920311/2.15", "ecb879d7ee920311/2.15"])
        XCTAssertEqual(expressiveAlone, ["f1a0ddf19c70", "d894978f882bb008/3.7", "d894978f882bb008/3.7"])
    }

    func testConvertingChangesRateChannelsAndSamplesAndKeepsTheSound() throws {
        let float48Stereo = WAV.Format(audioFormat: 3, channels: 2, sampleRate: 48_000, bitsPerSample: 32)
        let source = try XCTUnwrap(WAV.parse(TwoFormats.clip(float48Stereo, seconds: 0.5)))
        let converted = try XCTUnwrap(WAV.converting(source.pcm, from: float48Stereo, to: kokoro))
        XCTAssertEqual(converted.count / kokoro.blockAlign, 12_000, "half a second at 24 kHz")
        let samples = stride(from: 0, to: converted.count, by: 2).map {
            Double(Int16(bitPattern: UInt16(converted[$0]) | UInt16(converted[$0 + 1]) << 8)) / 32768
        }
        let peak = samples.map(abs).max() ?? 0
        XCTAssertEqual(peak, 0.1, accuracy: 0.01, "the same loudness")
        let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(Double(crossings) / 0.5, 440, accuracy: 6, "the same pitch")
        XCTAssertEqual(WAV.converting(source.pcm, from: kokoro, to: kokoro), source.pcm, "the same format is left alone")
        let pcm24 = WAV.Format(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 24)
        XCTAssertNil(WAV.converting(Data(count: 30), from: pcm24, to: kokoro))
        XCTAssertEqual(WAV.describe(float48Stereo), "48 kHz stereo 32-bit float")
    }

    /// A Kokoro narrator and a character from a server answering 48 kHz stereo float: the
    /// chapter is made, in Kokoro's format, as long as its clips and pauses.
    func testAChapterReadByTwoEnginesIsJoinedInOneFormat() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = WAV.Format(audioFormat: 3, channels: 2, sampleRate: 48_000, bitsPerSample: 32)
        let book = castBook(character: "chatterbox:Emily.wav")
        let synth = TwoFormats(other: other)
        let job = try await render(book, synth, in: dir)
        XCTAssertEqual(job.status, .ready, "\(job.chapters)")
        XCTAssertTrue(synth.voices.contains("chatterbox:Emily.wav") && synth.voices.contains("kokoro:bf_emma"),
                      "both engines were asked: \(Set(synth.voices))")
        guard case let .ready(file, _, seconds, _) = job.chapters[0] else { return XCTFail("\(job.chapters[0])") }
        let segments = book.chapters[0].segments
        let expected = Double(segments.count) * 0.2 + Double(segments.map(\.pauseBeforeMs).reduce(0, +)) / 1000
        XCTAssertEqual(seconds, expected, accuracy: 0.01)
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let joined = try XCTUnwrap(WAV.parse(Data(contentsOf: try XCTUnwrap(store.chapterURL(job.id, file: file)))))
        XCTAssertEqual(joined.format, kokoro)
    }

    /// A server answering a format the join does not read (24-bit integer): the chapter is
    /// refused, saying which voice and which formats.
    func testAFormatTheJoinCannotReadIsRefusedByName() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pcm24 = WAV.Format(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 24)
        let job = try await render(castBook(character: "chatterbox:Emily.wav"), TwoFormats(other: pcm24), in: dir)
        XCTAssertEqual(job.status, .failed)
        guard case let .failed(reason) = job.chapters[0] else { return XCTFail("\(job.chapters[0])") }
        XCTAssertTrue(reason.contains("chatterbox:Emily.wav answers 24 kHz mono 24-bit audio, which cannot be joined with the 24 kHz mono 16-bit"),
                      reason)
    }
}
