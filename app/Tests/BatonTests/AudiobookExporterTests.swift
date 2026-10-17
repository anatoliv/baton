import AVFoundation
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// M4B export on the Mac (M8.8): a tiny book's chapters become one `.m4b` whose chapter list
/// a player reads back, titled and at the chapters' starts, with the book's tags. Read back
/// through AVFoundation, and by ffprobe when it is installed, which is what any other player
/// sees.
@MainActor
final class AudiobookExporterTests: XCTestCase {

    private var root: URL!
    private var clippings: ClippingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-m4b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                  defaults: ThrowawayDefaults.make("m4b"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A chapter as the Mac's muxer makes it: a tone of `seconds` as 16-bit WAV (written whole,
    /// header and all, so nothing is left open), encoded as AAC.
    private func chapter(_ index: Int, seconds: Double) async throws -> URL {
        let wav = root.appendingPathComponent("chapter-\(index).wav")
        let frames = Int(24_000 * seconds)
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let sample = Int16(0.2 * sin(Double(i) * 2 * .pi * 440 / 24_000) * Double(Int16.max))
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        try (WAV.header(format: .init(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16), dataBytes: pcm.count) + pcm)
            .write(to: wav)
        let m4a = root.appendingPathComponent("chapter-\(index).m4a")
        try await AVAssetWriterMuxer().encode(wav: wav, to: m4a, bitrate: 48_000, channels: 1,
                                              tags: ["title": "Part \(index + 1)", "album": "A Small Room", "track": "\(index + 1)/3"])
        return m4a
    }

    private func threeChapters() async throws -> (files: [URL], marks: [AudiobookExport.Mark]) {
        let lengths = [2.0, 3.0, 1.5]
        var files: [URL] = []
        for (index, seconds) in lengths.enumerated() { files.append(try await chapter(index, seconds: seconds)) }
        var at = 0.0
        let marks = lengths.enumerated().map { index, seconds -> AudiobookExport.Mark in
            defer { at += seconds }
            return AudiobookExport.Mark(title: "Part \(index + 1)", start: at, end: at + seconds)
        }
        return (files, marks)
    }

    /// With ffmpeg: the M4B every player reads, titled marks at the chapter starts, read back
    /// by AVFoundation (what Books.app uses) and by ffprobe.
    func testAnM4BCarriesTitledChapterMarksAtTheChapterStarts() async throws {
        guard let ffmpeg = AudiobookExporter.locateFFmpeg() else { throw XCTSkip("ffmpeg is not installed") }
        let (files, marks) = try await threeChapters()
        let out = root.appendingPathComponent("A Small Room - Someone.m4b")
        let outcome = try await AudiobookExporter.export(chapters: files, marks: marks, title: "A Small Room", author: "Someone", to: out)
        XCTAssertEqual(outcome.tool, "ffmpeg")
        XCTAssertTrue(outcome.hasMarks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".A Small Room - Someone.m4b.partial.m4b").path))

        // Marks are where each chapter's words begin: the rendered lengths plus the earlier
        // chapters' encoder priming and padding, which stream copy keeps.
        let placed = outcome.chapters
        XCTAssertEqual(placed.map(\.title), ["Part 1", "Part 2", "Part 3"])
        var expectedStart = 0.0
        for (index, file) in files.enumerated() {
            XCTAssertEqual(placed[index].start, expectedStart, accuracy: 0.001, placed[index].title)
            expectedStart += try await AudiobookExporter.packetDuration(file)
        }
        XCTAssertGreaterThan(placed[2].start, marks[2].start + 0.1, "the lengths alone would put chapter 3 early")

        // As AVFoundation (Books.app, the player) reads it back.
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, placed[2].end, accuracy: 0.15)
        let chapters = try await AudiobookExporter.chapters(of: out)
        XCTAssertEqual(chapters.map(\.title), ["Part 1", "Part 2", "Part 3"])
        for (chapter, mark) in zip(chapters, placed) {
            XCTAssertEqual(chapter.start, mark.start, accuracy: 0.02, chapter.title)
        }
        let tags = try await asset.load(.metadata)
        let title = try await AVMetadataItem.metadataItems(from: tags, filteredByIdentifier: .iTunesMetadataSongName).first?.load(.stringValue)
        let artist = try await AVMetadataItem.metadataItems(from: tags, filteredByIdentifier: .iTunesMetadataArtist).first?.load(.stringValue)
        XCTAssertEqual(title, "A Small Room")
        XCTAssertEqual(artist, "Someone")

        // And as ffprobe sees it: the chapter list every other player uses.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: ffmpeg.path.replacingOccurrences(of: "ffmpeg", with: "ffprobe"))
        probe.arguments = ["-v", "error", "-show_chapters", "-show_entries", "format=duration:format_tags=title,artist", "-of", "json", out.path]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try probe.run()
        let json = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let probed = try XCTUnwrap(parsed["chapters"] as? [[String: Any]])
        print("ffprobe chapters: " + probed.map { "\(($0["tags"] as? [String: Any])?["title"] ?? "?") \($0["start_time"] ?? "?")-\($0["end_time"] ?? "?")" }.joined(separator: ", "))
        XCTAssertEqual(probed.compactMap { ($0["tags"] as? [String: Any])?["title"] as? String }, ["Part 1", "Part 2", "Part 3"])
        for (chapter, mark) in zip(probed, placed) {
            XCTAssertEqual(Double(chapter["start_time"] as? String ?? "") ?? -1, mark.start, accuracy: 0.02)
        }
        let format = try XCTUnwrap(parsed["format"] as? [String: Any])
        XCTAssertEqual(((format["tags"] as? [String: Any])?["title"] as? String), "A Small Room")
    }

    /// TBX-10856: every mark lands where AVFoundation (Books.app) hears its chapter begin, for
    /// both kinds of chapter file a Mac book is made of: AAC from this Mac's own encoder
    /// (`AVAssetWriterMuxer`) and AAC from ffmpeg's encoder, which is how a book rendered on the
    /// home server arrives. Fourteen chapters, each 0.25 s of silence then a tone of its own.
    /// Chapter 1's tone is the reference, since every chapter opens the same way. Before the
    /// concat list stated each chapter's span, ffmpeg-encoded chapters were heard progressively
    /// earlier than their marks (each one's priming packet overlapped the previous chapter's last).
    func testEveryMarkLandsWhereItsChapterIsHeardForBothEncoders() async throws {
        guard let ffmpeg = AudiobookExporter.locateFFmpeg() else { throw XCTSkip("ffmpeg is not installed, so the export has no marks to check") }
        let lengths = [3.349, 2.801, 2.357, 3.006, 3.526, 2.444, 3.461, 2.974, 1.775, 1.020, 1.168, 2.400, 2.913, 1.637]
        for kind in ["AVAssetWriterMuxer", "ffmpeg"] {
            var files: [URL] = []
            for (index, seconds) in lengths.enumerated() {
                let wav = try toneWAV("\(kind)-\(index)", seconds: seconds, frequency: 400 + 90 * Double(index))
                let m4a = root.appendingPathComponent("\(kind)-\(index).m4a")
                if kind == "ffmpeg" {
                    try Self.run(ffmpeg, ["-nostdin", "-y", "-loglevel", "error", "-i", wav.path, "-c:a", "aac", "-b:a", "48k", "-ac", "1",
                                          "-movflags", "+faststart", "-f", "ipod", m4a.path])
                } else {
                    try await AVAssetWriterMuxer().encode(wav: wav, to: m4a, bitrate: 48_000, channels: 1, tags: [:])
                }
                files.append(m4a)
            }
            var at = 0.0
            let marks = lengths.enumerated().map { index, seconds -> AudiobookExport.Mark in
                defer { at += seconds }
                return AudiobookExport.Mark(title: "Part \(index + 1)", start: at, end: at + seconds)
            }
            let out = root.appendingPathComponent("\(kind).m4b")
            let outcome = try await AudiobookExporter.export(chapters: files, marks: marks, title: "Tones", author: nil, to: out,
                                                             tool: .ffmpeg(ffmpeg))
            let read = try await AudiobookExporter.chapters(of: out)
            XCTAssertEqual(read.count, lengths.count, kind)
            for (chapter, mark) in zip(read, outcome.chapters) {
                XCTAssertEqual(chapter.start, mark.start, accuracy: 0.02, "\(kind) \(chapter.title) as AVFoundation reads the mark")
            }
            let heard = try await onsets(out)
            XCTAssertEqual(heard.count, lengths.count, "\(kind): one tone per chapter")
            guard heard.count == lengths.count, read.count == lengths.count else { continue }
            let errors = zip(read, heard).map { $1 - heard[0] - $0.start }
            print("TBX-10856 \(kind): heard minus mark per chapter: " + errors.map { String(format: "%+.4f", $0) }.joined(separator: " "))
            for (index, error) in errors.enumerated() {
                XCTAssertEqual(error, 0, accuracy: 0.05, "\(kind) chapter \(index + 1) as AVFoundation plays it")
            }
        }
    }

    /// TBX-11141: a book whose voices answered in two formats, 48 kHz stereo float and Kokoro's
    /// 24 kHz mono 16-bit. Each chapter is encoded at the one rate and channel count every chapter
    /// gets, so the export's stream copy joins alike files, and Apple's decoder plays the M4B to
    /// its full length. Joined as they came, the file reported its length and decoded to a third.
    func testChaptersFromTwoFormatsExportToAnM4BThatPlaysToTheEnd() async throws {
        guard let ffmpeg = AudiobookExporter.locateFFmpeg() else { throw XCTSkip("ffmpeg is not installed") }
        func wav(_ name: String, format: WAV.Format, seconds: Double) throws -> URL {
            let url = root.appendingPathComponent("\(name).wav")
            let frames = Int(Double(format.sampleRate) * seconds)
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
            try (WAV.header(format: format, dataBytes: pcm.count) + pcm).write(to: url)
            return url
        }
        let sources = [
            try wav("float-stereo", format: .init(audioFormat: 3, channels: 2, sampleRate: 48_000, bitsPerSample: 32), seconds: 2),
            try wav("kokoro", format: .init(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16), seconds: 3),
        ]
        var files: [URL] = []
        for (index, source) in sources.enumerated() {
            let m4a = root.appendingPathComponent("mixed-\(index).m4a")
            try await AVAssetWriterMuxer().encode(wav: source, to: m4a, bitrate: 48_000, channels: 1,
                                                  sampleRate: AudioSettings.encodedSampleRate, tags: [:])
            let chapterTracks = try await AVURLAsset(url: m4a).loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(chapterTracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            let description = try XCTUnwrap(descriptions.first)
            let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
            XCTAssertEqual(asbd.mSampleRate, 24_000, "chapter \(index + 1) encoded at the one rate")
            XCTAssertEqual(asbd.mChannelsPerFrame, 1, "chapter \(index + 1) encoded mono")
            files.append(m4a)
        }
        let marks = [AudiobookExport.Mark(title: "Part 1", start: 0, end: 2), AudiobookExport.Mark(title: "Part 2", start: 2, end: 5)]
        let out = root.appendingPathComponent("mixed.m4b")
        _ = try await AudiobookExporter.export(chapters: files, marks: marks, title: "Two formats", author: nil, to: out,
                                               tool: .ffmpeg(ffmpeg))
        // Every sample Apple's decoder gives, counted: the length as heard, not as reported.
        let asset = AVURLAsset(url: out)
        let bookTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(bookTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 24_000,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(buffer) }
        XCTAssertEqual(Double(frames) / 24_000, 5, accuracy: 0.2, "the M4B plays both chapters to the end")
    }

    /// 0.25 s of silence then a tone, as 16-bit mono WAV at 24 kHz.
    private func toneWAV(_ name: String, seconds: Double, frequency: Double) throws -> URL {
        let wav = root.appendingPathComponent("\(name).wav")
        let frames = Int(24_000 * seconds)
        let silence = 6_000
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let value = i < silence ? 0 : 0.2 * sin(Double(i - silence) * 2 * .pi * frequency / 24_000)
            let sample = Int16(value * Double(Int16.max))
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        try (WAV.header(format: .init(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16), dataBytes: pcm.count) + pcm)
            .write(to: wav)
        return wav
    }

    /// Where each tone starts as Apple's decoder plays the file: the first sound after at least
    /// 0.15 s of quiet.
    private func onsets(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 24_000,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var onsets: [Double] = []
        var quiet = 3_600
        while let buffer = output.copyNextSampleBuffer() {
            let at = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let count = CMSampleBufferGetNumSamples(buffer)
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var samples = [Int16](repeating: 0, count: count)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: &samples)
            for (i, sample) in samples.enumerated() {
                if abs(Int(sample)) < 100 { quiet += 1; continue }
                if quiet >= 3_600 { onsets.append(at + Double(i) / 24_000) }
                quiet = 0
            }
        }
        return onsets
    }

    /// Runs ffmpeg, failing on a non-zero exit.
    private static func run(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool.lastPathComponent) \(arguments.joined(separator: " "))")
    }

    /// Without ffmpeg: one tagged M4B of the same audio, honestly without marks.
    func testWithoutFFmpegTheBookIsStillOneTaggedFileAndSaysItHasNoMarks() async throws {
        let (files, marks) = try await threeChapters()
        let out = root.appendingPathComponent("plain.m4b")
        let outcome = try await AudiobookExporter.export(chapters: files, marks: marks, title: "A Small Room", author: "Someone", to: out, tool: .avFoundation)
        XCTAssertEqual(outcome.tool, "AVFoundation")
        XCTAssertFalse(outcome.hasMarks)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 6.5, accuracy: 0.15)
        let chapters = try await AudiobookExporter.chapters(of: out)
        XCTAssertEqual(chapters, [])
        let tags = try await asset.load(.metadata)
        let title = try await AVMetadataItem.metadataItems(from: tags, filteredByIdentifier: .iTunesMetadataSongName).first?.load(.stringValue)
        XCTAssertEqual(title, "A Small Room")
    }

    func testAMissingChapterRefusesRatherThanLeavingAHole() throws {
        var book = BookShelf.Book(documentID: "doc", title: "T", author: nil, chapters: [], createdAt: Date(),
                                  pauseReason: nil, failure: nil, isRendering: false, position: nil, finished: false)
        XCTAssertThrowsError(try AudiobookExporter.chapterFiles(book))
        book.chapters = [.init(index: 0, title: "Chapter 1", item: nil, state: .queued)]
        XCTAssertThrowsError(try AudiobookExporter.chapterFiles(book)) { error in
            XCTAssertEqual("\(error)", "chapter 1 is not on this Mac")
        }
        XCTAssertNil(AudiobookExporter.marks(book, job: nil), "no lengths, no marks")
    }
}
