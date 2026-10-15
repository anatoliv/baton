import CryptoKit
import Foundation

/// One file of the model: where it comes from, its size and its sha256.
public struct KokoroModelFile: Sendable, Equatable {
    public let name: String
    public let source: URL
    public let bytes: Int64
    public let sha256: String

    public init(name: String, source: URL, bytes: Int64, sha256: String) {
        self.name = name
        self.source = source
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// The two files Kokoro needs, pinned by revision and checksum (recorded in TBX-10849,
/// `spikes/kokoro-mlx/RESULTS.md`; the weights' sha256 is also Hugging Face's own LFS id).
public enum KokoroModelFiles {
    /// Kokoro-82M v1.0 converted for MLX, Apache-2.0, from Hugging Face prince-canuma/Kokoro-82M
    /// at revision e02c9ead (the same file as mlx-community/Kokoro-82M-bf16).
    public static let weights = KokoroModelFile(
        name: "kokoro-v1_0.safetensors",
        source: URL(string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/e02c9eada7ce7416798af36b190a8a2dd2ecd566/kokoro-v1_0.safetensors")!,
        bytes: 327_115_152,
        sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8")

    /// The 28 English voices as one NumPy archive, Apache-2.0 (from Kokoro-82M), from
    /// mlalma/KokoroTestApp `Resources/voices.npz` at commit 9dcd3b06 (git blob 8e8efa95).
    public static let voices = KokoroModelFile(
        name: "voices.npz",
        source: URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/9dcd3b06468a3c1ecee6d09a33ca687c8e708566/Resources/voices.npz")!,
        bytes: 14_629_684,
        sha256: "56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f")

    public static let all = [weights, voices]

    /// 341,744,836 bytes: "342 MB" in Settings.
    public static var totalBytes: Int64 { all.reduce(0) { $0 + $1.bytes } }
}

public enum KokoroModelError: Error, Equatable, CustomStringConvertible {
    /// The file arrived but is not the pinned one. It is deleted, never installed.
    case checksumMismatch(file: String)
    /// The server answered something other than the file.
    case badResponse(file: String, status: Int)

    public var description: String {
        switch self {
        case .checksumMismatch(let file): return "\(file) did not match its checksum, so Baton deleted it"
        case .badResponse(let file, let status): return "the download of \(file) failed (HTTP \(status))"
        }
    }
}

/// How a file's bytes arrive. The real one is `URLSessionModelTransport`; tests give one that
/// writes known bytes.
public protocol KokoroModelTransport: Sendable {
    /// Writes `source` into `partial`, asking for the bytes from `offset` on. Returns true when the
    /// server sent only those bytes (appended), false when it sent the whole file (the partial is
    /// rewritten from the start). Reports the partial file's size as it grows.
    func fetch(_ source: URL, from offset: Int64, into partial: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws -> Bool
}

/// The model directory: `Application Support/Baton/Models/kokoro-mlx` in the app. Installs the
/// files with progress, resumes a part-downloaded file, refuses one whose checksum is wrong, and
/// removes everything on request.
public struct KokoroModelStore: Sendable {
    public let directory: URL
    public let files: [KokoroModelFile]

    /// Written once every file has passed its checksum, so "installed" is a cheap check.
    static let markerName = "installed.json"

    public init(directory: URL, files: [KokoroModelFile] = KokoroModelFiles.all) {
        self.directory = directory
        self.files = files
    }

    /// True when every file passed its checksum and is still there at its size.
    public var isInstalled: Bool {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: directory.appendingPathComponent(Self.markerName).path),
              let recorded = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return files.allSatisfy { file in
            let path = directory.appendingPathComponent(file.name).path
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return recorded[file.name] == file.sha256 && size == file.bytes
        }
    }

    /// Bytes on disk, part-downloaded files included.
    public var bytesOnDisk: Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(0) { total, name in
            let path = directory.appendingPathComponent(name).path
            return total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Downloads whatever is missing. A part-downloaded file resumes where it stopped when the
    /// server honours the range, and starts again when it does not. Every file is checked against
    /// its sha256 before it is kept; a mismatch deletes it and throws. `progress` is the bytes
    /// done across all files and the total.
    public func install(transport: any KokoroModelTransport = URLSessionModelTransport(),
                        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
        let total = files.reduce(0) { $0 + $1.bytes }
        var done: Int64 = 0
        for file in files {
            let final = directory.appendingPathComponent(file.name)
            if Self.size(of: final) == file.bytes, try Self.sha256(of: final) == file.sha256 {
                done += file.bytes
                progress(done, total)
                continue
            }
            try? fm.removeItem(at: final)
            let partial = directory.appendingPathComponent(file.name + ".partial")
            var offset = Self.size(of: partial) ?? 0
            if offset >= file.bytes { try? fm.removeItem(at: partial); offset = 0 }
            let base = done
            progress(base + offset, total)
            _ = try await transport.fetch(file.source, from: offset, into: partial) { written in
                progress(base + written, total)
            }
            guard Self.size(of: partial) == file.bytes, try Self.sha256(of: partial) == file.sha256 else {
                try? fm.removeItem(at: partial)
                throw KokoroModelError.checksumMismatch(file: file.name)
            }
            try fm.moveItem(at: partial, to: final)
            done += file.bytes
            progress(done, total)
        }
        let marker = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.sha256) })
        try JSONEncoder().encode(marker).write(to: directory.appendingPathComponent(Self.markerName), options: .atomic)
    }

    /// Deletes the model directory and everything in it, part-downloads included.
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// The file's sha256 as lowercase hex, read 4 MB at a time.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The model is 342 MB that Baton can fetch again, so it stays out of Time Machine.
    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}

/// Streams a file to disk over URLSession, asking for a byte range when resuming. Cancelling
/// the task stops the transfer and keeps the part already written for the next attempt.
public struct URLSessionModelTransport: KokoroModelTransport {
    public init() {}

    public func fetch(_ source: URL, from offset: Int64, into partial: URL,
                      progress: @escaping @Sendable (Int64) -> Void) async throws -> Bool {
        var request = URLRequest(url: source, timeoutInterval: 60)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let writer = StreamingWriter(partial: partial, offset: offset, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: writer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                writer.begin(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class StreamingWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let offset: Int64
    private let progress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var appended = false
    private var written: Int64 = 0
    private var continuation: CheckedContinuation<Bool, Error>?
    private var failure: Error?

    init(partial: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.partial = partial
        self.offset = offset
        self.progress = progress
    }

    func begin(_ continuation: CheckedContinuation<Bool, Error>) { self.continuation = continuation }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206 where offset > 0:
                appended = true
                let h = try FileHandle(forWritingTo: partial)
                written = Int64(try h.seekToEnd())
                handle = h
            case 200:
                appended = false
                written = 0
                FileManager.default.createFile(atPath: partial.path, contents: nil)
                handle = try FileHandle(forWritingTo: partial)
            default:
                throw KokoroModelError.badResponse(file: partial.deletingPathExtension().lastPathComponent, status: status)
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            progress(written)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let failure = failure ?? error {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume(returning: appended)
        }
        continuation = nil
    }
}
