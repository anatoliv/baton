import BatonDocuments
import Foundation

/// `ffmpeg` with its native AAC encoder (LGPL; not `libfdk_aac`). Swift on Linux has no
/// AVFoundation, and raw ADTS `.aac` would play but seek imprecisely, which is what chapters and
/// resume depend on (`specs/document-clippings.md`, *Rejected alternatives*).
public struct FFmpegMuxer: AudioMuxing {
    public let executable: String

    public init(executable: String = "ffmpeg") { self.executable = executable }

    /// The path to run, or nil when ffmpeg is not installed: the gateway then refuses book jobs
    /// up front instead of accepting one it can never finish.
    public static func locate(_ name: String = "ffmpeg") -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The chapters joined into one `.m4b` with chapter marks. Stream copy, not a re-encode:
    /// every chapter came out of `encode` with the same codec and settings, so joining them
    /// takes seconds and loses nothing.
    ///
    /// `marks` give the titles; where they go is measured here. Each chapter keeps
    /// its AAC priming and padding, so it spans its packets' summed duration, not its rendered
    /// length. The concat list states that span as each file's `duration`, so every chapter
    /// starts where the previous one's packets end (ffmpeg otherwise starts it at the rendered
    /// length, overlapping the previous chapter's last packet, and Apple's players drift from
    /// the marks), and the marks are placed on the same spans.
    public func exportM4B(chapters: [URL], book: PreparedBook, marks: [AudiobookExport.Mark], to destination: URL) async throws {
        guard let ffprobe = Self.locate(probeExecutable) else {
            throw SynthesisError.permanent("ffprobe is not installed beside ffmpeg; it measures the chapters for their marks")
        }
        let spans = try chapters.map { try packetSeconds($0, ffprobe: ffprobe) }
        let placed = AudiobookExport.placed(marks, muxedLengths: spans)
        let work = destination.deletingLastPathComponent()
        let list = work.appendingPathComponent(destination.lastPathComponent + ".list")
        let meta = work.appendingPathComponent(destination.lastPathComponent + ".meta")
        defer {
            try? FileManager.default.removeItem(at: list)
            try? FileManager.default.removeItem(at: meta)
        }
        // The concat demuxer's list: one quoted path per line, a quote written as '\'', then
        // the chapter's measured span.
        let lines = zip(chapters, spans).map { url, span in
            "file '" + url.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'\nduration " + String(format: "%.6f", span)
        }
        try lines.joined(separator: "\n").appending("\n").write(to: list, atomically: true, encoding: .utf8)
        try AudiobookExport.ffmetadata(book: book, marks: placed).write(to: meta, atomically: true, encoding: .utf8)
        try run(["-nostdin", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list.path,
                 "-i", meta.path, "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1", "-c", "copy",
                 "-movflags", "+faststart", "-f", "ipod", destination.path])
    }

    /// ffprobe beside this ffmpeg, or on the PATH when ffmpeg was found there.
    var probeExecutable: String {
        guard executable.contains("/") else { return "ffprobe" }
        return URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("ffprobe").path
    }

    /// A chapter's audio packets' summed duration in seconds, priming and padding included.
    func packetSeconds(_ url: URL, ffprobe: String) throws -> Double {
        let text = try run(["-v", "error", "-select_streams", "a:0", "-show_entries", "packet=duration_time",
                            "-of", "csv=p=0", url.path], executable: ffprobe)
        var total = 0.0
        for line in text.split(whereSeparator: \.isNewline) {
            guard let seconds = Double(line.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) else {
                throw SynthesisError.permanent("ffprobe gave no packet duration for \(url.lastPathComponent)")
            }
            total += seconds
        }
        guard total > 0 else { throw SynthesisError.permanent("ffprobe found no audio in \(url.lastPathComponent)") }
        return total
    }

    /// Runs ffmpeg (or `executable`), returning what it printed. Output goes to a temporary file
    /// rather than a pipe, so a long packet listing can never stall against unread errors.
    @discardableResult
    private func run(_ arguments: [String], executable: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable ?? self.executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        let capture = FileManager.default.temporaryDirectory.appendingPathComponent("baton-ffmpeg-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: capture.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: capture) }
        let stdout = try FileHandle(forWritingTo: capture)
        process.standardOutput = stdout
        try process.run()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? stdout.close()
        guard process.terminationStatus == 0 else {
            throw SynthesisError.permanent("\(process.executableURL?.lastPathComponent ?? "ffmpeg") failed (\(process.terminationStatus)): "
                + (String(data: errorOutput.prefix(400), encoding: .utf8) ?? ""))
        }
        return (try? String(contentsOf: capture, encoding: .utf8)) ?? ""
    }

    public func encode(wav: URL, to destination: URL, bitrate: Int, channels: Int, tags: [String: String]) async throws {
        var arguments = ["-nostdin", "-y", "-loglevel", "error", "-i", wav.path,
                         "-c:a", "aac", "-b:a", "\(bitrate / 1000)k", "-ac", "\(channels)"]
        for (key, value) in tags.sorted(by: { $0.key < $1.key }) { arguments += ["-metadata", "\(key)=\(value)"] }
        arguments += ["-movflags", "+faststart", "-f", "ipod", destination.path]
        try run(arguments)
    }
}
