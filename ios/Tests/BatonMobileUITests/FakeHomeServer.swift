import AVFoundation
import BatonDocuments
import Foundation
import Network

/// A home server for phone UI tests, in the test runner, on 127.0.0.1 (M5.3). It speaks the
/// gateway's book routes over a real socket, as `HomeServerBooksPhoneTests.FakeGateway` does in
/// process: list, submit, status, chapter download (with `X-Baton-SHA256`), finished, delete. The
/// app reaches it through `uitestGatewayURL` (DEBUG only), so a test can say when a chapter is
/// ready and count what the app asked for, and when.
///
/// The simulator shares the Mac's loopback, and loopback is outside local network privacy, so no
/// prompt stands between the app and this server. Chapters are real AAC audio, so a chapter can
/// be played.
final class FakeHomeServer: @unchecked Sendable {
    struct Request: Equatable {
        var method: String
        var path: String
        var at: Date
    }

    private(set) var port: UInt16 = 0
    var baseURL: String { "http://127.0.0.1:\(port)" }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-home-server")
    private let lock = NSLock()
    private var jobs: [String: BookJob] = [:]
    private var readyCount: [String: Int] = [:]
    private var readyOnSubmit = 0
    private var log: [Request] = []
    private let audio: Data
    /// Whether `GET /v1/books` answers that books are on, and why not when they are off.
    private var booksOn = true
    private var booksOffReason = "no voice server is set up"
    /// The gateway's file store (`/v1/files`), for "Send to my Mac".
    private var files: [String: (contentType: String, body: Data)] = [:]

    init() throws {
        audio = try Self.makeAudio(seconds: 30)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.port = port
    }

    func stop() { listener.cancel() }

    // MARK: - What the test controls and reads

    /// How many chapters are ready the moment a book is submitted.
    func setReadyOnSubmit(_ count: Int) { lock.withLock { readyOnSubmit = count } }
    /// Make the first `count` chapters of every submitted book ready.
    func setReady(_ count: Int) { lock.withLock { for id in jobs.keys { readyCount[id] = count } } }
    /// Answer that books are off, as a home server with no voice server does.
    func setBooksOff(reason: String) { lock.withLock { booksOn = false; booksOffReason = reason } }
    /// A file the app put in the file store, with its content type.
    func storedFile(_ id: String) -> (contentType: String, body: Data)? { lock.withLock { files[id] } }
    var requests: [Request] { lock.withLock { log } }
    var bookIDs: [String] { lock.withLock { Array(jobs.keys) } }
    /// Status reads of one book: what the five-second watch and every collection ask.
    func statusReads(since: Date = .distantPast) -> [Request] {
        requests.filter { $0.method == "GET" && $0.at >= since && $0.path.split(separator: "/").count == 3 }
    }
    func requests(_ method: String, since: Date = .distantPast) -> [Request] {
        requests.filter { $0.method == method && $0.at >= since }
    }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let (status, headers, body) = self.answer(method: request.method, path: request.path, body: request.body,
                                                          contentType: request.contentType)
                var head = "HTTP/1.1 \(status) \(status < 300 ? "OK" : "Error")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                for (name, value) in headers { head += "\(name): \(value)\r\n" }
                head += "\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if done || error != nil { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }

    private static func parse(_ buffer: Data) -> (method: String, path: String, body: Data, contentType: String)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        let path = String(first[1]).components(separatedBy: "?")[0]
        let contentType = lines.dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-type" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.first ?? "application/octet-stream"
        return (String(first[0]), path, Data(body.prefix(length)), contentType)
    }

    private func answer(method: String, path: String, body: Data, contentType: String) -> (Int, [String: String], Data) {
        lock.withLock {
            log.append(Request(method: method, path: path, at: Date()))
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "v1", parts[1] == "files" { return answerFile(method, parts, body, contentType) }
            if method == "GET", parts == ["v1", "books"], !booksOn {
                let listing: [String: Any] = ["available": false, "unavailable_reason": booksOffReason, "books": []]
                return (200, ["Content-Type": "application/json"], (try? JSONSerialization.data(withJSONObject: listing)) ?? Data())
            }
            if method == "GET", parts == ["v1", "books"] {
                let books = jobs.values.map { try? JSONSerialization.jsonObject(with: BookJSON.encoder.encode(summary($0))) }
                let listing: [String: Any] = ["available": true, "books": books.compactMap { $0 },
                                              "used_bytes": 0, "maximum_bytes": 4_294_967_296, "keep_finished_days": 30]
                return (200, ["Content-Type": "application/json"], (try? JSONSerialization.data(withJSONObject: listing)) ?? Data())
            }
            guard parts.count >= 3, parts[0] == "v1", parts[1] == "books" else { return (404, [:], Data()) }
            let id = parts[2]
            if method == "PUT" {
                guard let book = try? PreparedBook.decode(body) else { return (400, [:], Data()) }
                jobs[id] = BookJob(id: id, book: book)
                readyCount[id] = readyOnSubmit
                return (201, ["Content-Type": "application/json"], (try? BookJSON.encoder.encode(summary(jobs[id]!))) ?? Data())
            }
            guard let job = jobs[id] else { return (404, [:], Data()) }
            if method == "DELETE" { jobs[id] = nil; return (204, [:], Data()) }
            if method == "POST" { return (204, [:], Data()) }
            if parts.count == 5, parts[3] == "chapters", let n = Int(parts[4]) {
                guard n >= 1, n <= (readyCount[id] ?? 0) else { return (404, [:], Data()) }
                return (200, ["Content-Type": "audio/mp4", "X-Baton-SHA256": SHA256Digest.hex(of: audio),
                              "X-Baton-Duration": "30.0", "X-Baton-Name": "chapter-\(n).m4a"], audio)
            }
            return (200, ["Content-Type": "application/json"], (try? BookJSON.encoder.encode(summary(job))) ?? Data())
        }
    }

    /// The gateway's file routes, as `GatewayRoutes.file` answers them. Called holding the lock.
    private func answerFile(_ method: String, _ parts: [String], _ body: Data, _ contentType: String) -> (Int, [String: String], Data) {
        func meta(_ id: String) -> [String: Any] {
            ["id": id, "name": "file", "contentType": files[id]?.contentType ?? contentType,
             "size": files[id]?.body.count ?? 0, "createdAt": ISO8601DateFormatter().string(from: Date())]
        }
        func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
        if parts.count == 2 {
            return method == "GET" ? (200, ["Content-Type": "application/json"], json(files.keys.sorted().map(meta))) : (404, [:], Data())
        }
        let id = parts[2]
        switch method {
        case "PUT":
            files[id] = (contentType, body)
            return (201, ["Content-Type": "application/json"], json(meta(id)))
        case "DELETE":
            files[id] = nil
            return (200, ["Content-Type": "application/json"], Data(#"{"ok":true}"#.utf8))
        default:
            guard let file = files[id] else { return (404, [:], Data()) }
            return (200, ["Content-Type": file.contentType], file.body)
        }
    }

    /// The job as the server would report it now: the first `readyCount` chapters ready, the
    /// next one being made.
    private func summary(_ original: BookJob) -> BookJob.Summary {
        var job = original
        let ready = readyCount[job.id] ?? 0
        for i in job.chapters.indices {
            job.chapters[i] = i < ready
                ? .ready(file: "chapter-\(i + 1).m4a", bytes: audio.count, seconds: 30, sha256: SHA256Digest.hex(of: audio))
                : (i == ready ? .rendering(done: 1, of: 4) : .queued)
        }
        job.status = ready >= job.chapters.count ? .ready : .rendering
        return job.summary
    }

    /// A few seconds of a quiet tone as AAC in MPEG-4, which is what a chapter is.
    private static func makeAudio(seconds: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-chapter-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 24_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                     AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
            let frames = AVAudioFrameCount(rate * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(frames) { samples[i] = Float(0.1 * sin(2 * Double.pi * 440 * Double(i) / rate)) }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}
