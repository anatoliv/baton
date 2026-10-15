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
    public func exportM4B(chapters: [URL], metadata: String, to destination: URL) async throws {
        let work = destination.deletingLastPathComponent()
        let list = work.appendingPathComponent(destination.lastPathComponent + ".list")
        let meta = work.appendingPathComponent(destination.lastPathComponent + ".meta")
        defer {
            try? FileManager.default.removeItem(at: list)
            try? FileManager.default.removeItem(at: meta)
        }
        // The concat demuxer's list: one quoted path per line, a quote written as '\''.
        let lines = chapters.map { "file '" + $0.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        try lines.joined(separator: "\n").appending("\n").write(to: list, atomically: true, encoding: .utf8)
        try metadata.write(to: meta, atomically: true, encoding: .utf8)
        try run(["-nostdin", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list.path,
                 "-i", meta.path, "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1", "-c", "copy",
                 "-movflags", "+faststart", "-f", "ipod", destination.path])
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SynthesisError.permanent("ffmpeg failed (\(process.terminationStatus)): "
                + (String(data: errorOutput.prefix(400), encoding: .utf8) ?? ""))
        }
    }

    public func encode(wav: URL, to destination: URL, bitrate: Int, channels: Int, tags: [String: String]) async throws {
        var arguments = ["-nostdin", "-y", "-loglevel", "error", "-i", wav.path,
                         "-c:a", "aac", "-b:a", "\(bitrate / 1000)k", "-ac", "\(channels)"]
        for (key, value) in tags.sorted(by: { $0.key < $1.key }) { arguments += ["-metadata", "\(key)=\(value)"] }
        arguments += ["-movflags", "+faststart", "-f", "ipod", destination.path]
        try run(arguments)
    }
}
