import BatonDocuments
import Foundation
import XCTest
@testable import BatonGatewayCore

/// A book whose cast mixes engines, made and exported with the real ffmpeg. Its first
/// chapter is untitled and opens with a character read by an engine that answers 48 kHz stereo
/// float, the rest is Kokoro's 24 kHz mono 16-bit. Before the fix that chapter came out in the
/// other format, the M4B export's stream copy joined the two, ffmpeg exited 0, and the file
/// reported 12.04 s but decoded to 3.95 s. Now every chapter is encoded alike and the M4B
/// decodes to its full length.
final class MixedEngineExportTests: XCTestCase {
    /// Kokoro answers 24 kHz mono 16-bit; any other engine 48 kHz stereo float. Each clip is a
    /// one-second tone.
    final class TwoFormats: SpeechSynthesizing, @unchecked Sendable {
        func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
            let format = voice.hasPrefix("kokoro:")
                ? WAV.Format(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16)
                : WAV.Format(audioFormat: 3, channels: 2, sampleRate: 48_000, bitsPerSample: 32)
            let frames = Int(format.sampleRate)
            var pcm = Data(capacity: frames * format.blockAlign)
            for i in 0..<frames {
                let v = 0.2 * sin(2 * Double.pi * 330 * Double(i) / Double(format.sampleRate))
                for _ in 0..<Int(format.channels) {
                    if format.audioFormat == 3 {
                        withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { pcm.append(contentsOf: $0) }
                    } else {
                        withUnsafeBytes(of: Int16(v * 32767).littleEndian) { pcm.append(contentsOf: $0) }
                    }
                }
            }
            return WAV.header(format: format, dataBytes: pcm.count) + pcm
        }
    }

    func testAMixedEngineBookExportsToAnM4BThatDecodesToItsFullLength() async throws {
        guard let ffmpeg = FFmpegMuxer.locate() else { throw XCTSkip("ffmpeg is not installed") }
        let muxer = FFmpegMuxer(executable: ffmpeg)
        guard let ffprobe = FFmpegMuxer.locate(muxer.probeExecutable) else { throw XCTSkip("ffprobe is not installed beside ffmpeg") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        XCTAssertEqual(book.chapters[0].segments.first?.speaker, "Vashti")
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: TwoFormats(),
                                    muxer: muxer, concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let id = BookJob.id(for: book)
        _ = try await renderer.submit(book, id: id)
        await renderer.waitUntilIdle()
        let job = try XCTUnwrap(store.load(id))
        XCTAssertEqual(job.status, BookJob.Status.ready, "\(job.chapters)")

        var files: [URL] = []
        var marks: [AudiobookExport.Mark] = []
        var rendered = 0.0
        for (index, chapter) in job.chapters.enumerated() {
            guard case let .ready(file, _, seconds, _) = chapter else { return XCTFail("\(chapter)") }
            let url = try XCTUnwrap(store.chapterURL(id, file: file))
            let stream = try Self.tool(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=sample_rate,channels",
                                                 "-of", "csv=p=0", url.path]).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(stream, "24000,1", "chapter \(index + 1) is encoded at 24 kHz mono, like every other")
            files.append(url)
            marks.append(AudiobookExport.Mark(title: "Part \(index + 1)", start: rendered, end: rendered + seconds))
            rendered += seconds
        }
        let out = dir.appendingPathComponent("book.m4b")
        try await muxer.exportM4B(chapters: files, book: book, marks: marks, to: out)

        // Decoded in full, not as reported: the broken file reported its length and decoded to a third of it.
        let pcm = dir.appendingPathComponent("decoded.raw")
        _ = try Self.tool(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", out.path, "-f", "s16le", "-ac", "1", "-ar", "24000", pcm.path])
        let decodedSeconds = Double((try FileManager.default.attributesOfItem(atPath: pcm.path)[.size] as? Int) ?? 0) / 48_000
        XCTAssertEqual(decodedSeconds, rendered, accuracy: 0.1 * Double(files.count) + 0.1,
                       "the M4B decodes to the chapters' full length (\(rendered) s)")
    }

    private static func tool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let capture = FileManager.default.temporaryDirectory.appendingPathComponent("tool-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: capture.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: capture) }
        let handle = try FileHandle(forWritingTo: capture)
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try handle.close()
        guard process.terminationStatus == 0 else { throw SynthesisError.permanent("\(path) exited \(process.terminationStatus)") }
        return try String(contentsOf: capture, encoding: .utf8)
    }
}
