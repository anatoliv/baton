import AVFoundation
import BatonDocuments
import Foundation

/// A book made on this Mac as one `.m4b` with chapter marks (M8.8), for Books.app or any
/// audiobook player.
///
/// The chapter marks come from `AudiobookExport.marks` and are written the way the gateway
/// writes them: ffmpeg's concat demuxer, stream copy, chapters and tags from the package's
/// `ffmetadata`. That gives the QuickTime text chapter track every player reads. AVFoundation
/// cannot write that track: measured on 2026-10-15, `AVAssetWriter` refuses text samples for a
/// chapter list (-17545) even with a format description taken from a real file, and the timed
/// metadata track it does write is read by neither its own chapter API nor ffprobe. So without
/// ffmpeg (`brew install ffmpeg`) the export is AVFoundation's: the chapters decoded and encoded
/// once more as AAC into one tagged M4B (`joinWithAVFoundation`), with no marks, and the row
/// says so.
enum AudiobookExporter {
    enum ExportError: Error, CustomStringConvertible {
        case noChapters
        case chapterMissing(Int)
        case noAudioTrack(URL)
        case cannotRead(String)
        case cannotWrite(String)

        var description: String {
            switch self {
            case .noChapters: return "the book has no chapters to export"
            case let .chapterMissing(index): return "chapter \(index + 1) is not on this Mac"
            case let .noAudioTrack(url): return "\(url.lastPathComponent) has no audio"
            case let .cannotRead(why): return "could not read a chapter: \(why)"
            case let .cannotWrite(why): return "could not write the audiobook: \(why)"
            }
        }
    }

    /// What the player reads back: one titled mark per chapter.
    struct Chapter: Equatable {
        var title: String
        var start: Double
        var end: Double
    }

    /// "The Machine Stops - E. M. Forster.m4b": the package's one naming rule, for a book known
    /// by its title and author alone.
    static func fileName(title: String, author: String?) -> String {
        AudiobookExport.fileName(PreparedBook(documentID: "", title: title, author: author, language: nil,
                                              voices: VoicePlan(narrator: ""), chapters: []))
    }

    /// The chapter files of a book in Clippings, in order, or which one is missing.
    static func chapterFiles(_ book: BookShelf.Book) throws -> [URL] {
        guard !book.chapters.isEmpty else { throw ExportError.noChapters }
        return try book.chapters.sorted { $0.index < $1.index }.map { chapter in
            guard let item = chapter.item, item.isPresent else { throw ExportError.chapterMissing(chapter.index) }
            return item.url
        }
    }

    /// Marks from the job's measured lengths when this Mac still holds the job, else from the
    /// chapters' lengths in Clippings.
    static func marks(_ book: BookShelf.Book, job: BookJob?) -> [AudiobookExport.Mark]? {
        if let job, let marks = AudiobookExport.marks(job) { return marks }
        var at = 0.0
        var marks: [AudiobookExport.Mark] = []
        for chapter in book.chapters.sorted(by: { $0.index < $1.index }) {
            guard let seconds = chapter.item?.clipping.durationSeconds else { return nil }
            marks.append(AudiobookExport.Mark(title: chapter.title, start: at, end: at + seconds))
            at += seconds
        }
        return marks.isEmpty ? nil : marks
    }

    /// What an export made: the marks a player reads back, and how it was made.
    struct Outcome: Equatable {
        var chapters: [Chapter]
        /// False when ffmpeg was not there and the file carries no chapter marks.
        var hasMarks: Bool
        var tool: String
    }

    enum Tool: Equatable {
        case ffmpeg(URL)
        case avFoundation
    }

    /// ffmpeg where Homebrew or a manual install leaves it, else nil.
    static func locateFFmpeg(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        if let path = environment["PATH"] { candidates += path.split(separator: ":").map { "\($0)/ffmpeg" } }
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Write `chapters` as one M4B at `destination`, tagged with the book's title and author,
    /// with ffmpeg when it is installed, else with AVFoundation and no marks. Written beside the
    /// destination and moved into place, so an interrupted export leaves no half file where a
    /// finished one is expected.
    @discardableResult
    static func export(chapters: [URL], marks: [AudiobookExport.Mark], title: String, author: String?,
                       to destination: URL, tool: Tool? = nil) async throws -> Outcome {
        guard !chapters.isEmpty, chapters.count == marks.count else { throw ExportError.noChapters }
        let tool = tool ?? locateFFmpeg().map(Tool.ffmpeg) ?? .avFoundation
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial.m4b")
        try? FileManager.default.removeItem(at: partial)
        let outcome: Outcome
        do {
            switch tool {
            case let .ffmpeg(ffmpeg):
                let spans = try await muxedSpans(chapters)
                let placed = AudiobookExport.placed(marks, muxedLengths: spans)
                try await muxWithFFmpeg(ffmpeg, chapters: chapters, spans: spans, marks: placed, title: title, author: author, to: partial)
                outcome = Outcome(chapters: placed.map { Chapter(title: $0.title, start: $0.start, end: $0.end) }, hasMarks: true, tool: "ffmpeg")
            case .avFoundation:
                try await joinWithAVFoundation(chapters: chapters, title: title, author: author, to: partial)
                outcome = Outcome(chapters: [], hasMarks: false, tool: "AVFoundation")
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: partial, to: destination) } catch {
            try? FileManager.default.removeItem(at: partial)
            throw ExportError.cannotWrite(error.localizedDescription)
        }
        return outcome
    }

    /// Each chapter's span in the joined file: its AAC packets' summed duration, encoder
    /// priming and end padding included, since stream copy keeps them all. That is about 0.09 s
    /// longer per chapter than the rendered length on the Mac's encoder and 0.04 s on ffmpeg's
    /// (measured 2026-10-15). The concat list states these spans and `AudiobookExport.placed`
    /// puts the marks on them, as the gateway does.
    static func muxedSpans(_ chapters: [URL]) async throws -> [Double] {
        var spans: [Double] = []
        for url in chapters { spans.append(try await packetDuration(url)) }
        return spans
    }

    /// Every compressed packet's duration, priming and padding included.
    static func packetDuration(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExportError.noAudioTrack(url) }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw ExportError.cannotRead(error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown") }
        var total = CMTime.zero
        while let buffer = output.copyNextSampleBuffer() { total = total + CMSampleBufferGetDuration(buffer) }
        if reader.status == .failed { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown") }
        return total.seconds
    }

    /// The gateway's recipe (`FFmpegMuxer.exportM4B`): a concat list, the package's ffmetadata,
    /// stream copy. The file is MPEG-4 whatever its name, so ffmpeg is told the format.
    ///
    /// Each `file` line is followed by `duration` and the chapter's measured span. Without it the
    /// concat demuxer starts each chapter where the previous one's container says it ends, which
    /// for ffmpeg-encoded chapters (a book made on the home server) is short of its last packet:
    /// each chapter's priming packet overlapped the one before, and AVFoundation heard chapter 14
    /// 0.09 s and chapter 30 0.7 s before its mark. The Mac's own chapters were
    /// already within 4 ms; the stated spans keep both kinds on their marks.
    static func muxWithFFmpeg(_ ffmpeg: URL, chapters: [URL], spans: [Double], marks: [AudiobookExport.Mark], title: String,
                              author: String?, to destination: URL) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("baton-m4b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let list = work.appendingPathComponent("chapters.txt")
        let lines = zip(chapters, spans).map { url, span in
            "file '\(url.path.replacingOccurrences(of: "'", with: "'\\''"))'\nduration " + String(format: "%.6f", span)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: list, atomically: true, encoding: .utf8)
        let metadata = work.appendingPathComponent("metadata.txt")
        let book = PreparedBook(documentID: "", title: title, author: author, language: nil, voices: VoicePlan(narrator: ""), chapters: [])
        try AudiobookExport.ffmetadata(book: book, marks: marks).write(to: metadata, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", list.path, "-i", metadata.path,
                             "-map", "0:a", "-map_metadata", "1", "-c", "copy", "-f", "mp4", "-movflags", "+faststart", destination.path]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { throw ExportError.cannotWrite("ffmpeg could not start: \(error.localizedDescription)") }
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.cannotWrite("ffmpeg exited \(process.terminationStatus): \(String(data: said, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
        }
    }

    /// One tagged file from the chapters, decoded and encoded once. Passing the AAC through
    /// does not work: the writer refuses a chapter's primed first packet once audio is already
    /// in the file (-17545), and with the priming marks removed it keeps only the first chapter
    /// (measured 2026-10-15). Decoding applies each chapter's trims, so the join is gapless.
    static func joinWithAVFoundation(chapters: [URL], title: String, author: String?, to destination: URL) async throws {
        let first = try await audioTrack(of: chapters[0])
        let source = try await first.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = source?.mSampleRate ?? 24_000
        let channels = Int(source?.mChannelsPerFrame ?? 1)
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ]

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: destination, fileType: .m4a) } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 48_000 * channels,
        ])
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(audio) else { throw ExportError.cannotWrite("the encoder refused these settings") }
        writer.add(audio)
        writer.metadata = AVAssetWriterMuxer.metadata(from: ["title": title, "album": title, "artist": author ?? "", "genre": "Audiobook"])
        guard writer.startWriting() else { throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)
        do {
            var offset = CMTime.zero
            for url in chapters {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExportError.noAudioTrack(url) }
                let reader: AVAssetReader
                do { reader = try AVAssetReader(asset: asset) } catch { throw ExportError.cannotRead(error.localizedDescription) }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
                reader.add(output)
                guard reader.startReading() else { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown") }
                var start: CMTime?
                var end = CMTime.zero
                while let buffer = output.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                    if start == nil { start = pts }
                    let shifted = try shift(buffer, by: offset - (start ?? .zero))
                    end = pts - (start ?? .zero) + CMSampleBufferGetDuration(buffer)
                    while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                    guard audio.append(shifted) else {
                        throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "the writer stopped taking audio")
                    }
                }
                if reader.status == .failed { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown") }
                offset = offset + end
            }
            audio.markAsFinished()
            try await finish(writer)
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    /// The chapters a file carries, as Books.app and every AVFoundation player read them: the
    /// chapter track's titled groups. What the test checks beside ffprobe.
    static func chapters(of url: URL) async throws -> [Chapter] {
        let asset = AVURLAsset(url: url)
        let locales = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: locales.map(\.identifier) + ["en"])
        var out: [Chapter] = []
        for group in groups {
            let title = try await AVMetadataItem.metadataItems(from: group.items, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common)
                .first?.load(.stringValue) ?? ""
            out.append(Chapter(title: title, start: group.timeRange.start.seconds, end: group.timeRange.end.seconds))
        }
        return out
    }

    // MARK: - Pieces

    private static func audioTrack(of url: URL) async throws -> AVAssetTrack {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first else {
            throw ExportError.noAudioTrack(url)
        }
        return track
    }

    private static func shift(_ buffer: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        guard offset != .zero else { return buffer }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + offset
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + offset }
        }
        var shifted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                                           sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                                           sampleBufferOut: &shifted)
        guard status == noErr, let shifted else { throw ExportError.cannotWrite("could not place a chapter in time (\(status))") }
        return shifted
    }

    private static func finish(_ writer: AVAssetWriter) async throws {
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }
}
