import AVFoundation
import BatonDocuments
import Foundation
import Network

/// A home server for phone UI tests, in the test runner, on 127.0.0.1 (M5.3). It speaks the
/// gateway's book routes over a real socket, as `HomeServerBooksPhoneTests.FakeGateway` does in
/// process: list, submit, status, chapter download (with `X-Baton-SHA256`), chapter timing,
/// finished, delete, and the voice list (`/v1/voices`, 404 until `setVoices`). The
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
    private var submitted: [PreparedBook] = []
    private var readyCount: [String: Int] = [:]
    private var readyOnSubmit = 0
    private var log: [Request] = []
    /// One tone per chapter, so no two chapters share a digest: the shared ledger names audio
    /// by digest, and one file for every chapter gave chapter 2 chapter 1's title.
    private let chapterAudio: [Data]
    private func audio(chapter n: Int) -> Data { chapterAudio[(n - 1) % chapterAudio.count] }
    /// Real narrated chapters, when a test asks for them and the runner is given a folder of
    /// them: `chapter-N.m4a` and `chapter-N.timing.json`, as a renderer leaves them,
    /// through `TEST_RUNNER_BATON_UITEST_SPEECH_DIR`. Speech, not a tone, so the now-playing bars and
    /// Read Along are seen against what a book really sounds like. Nil: the tones.
    private let speech: (seconds: [Double], timing: [ReadAlongTiming?])?
    /// How long each tone chapter is, when there are no narrated chapters.
    private let toneSeconds: Double
    private func seconds(chapter n: Int) -> Double { speech.map { $0.seconds[(n - 1) % $0.seconds.count] } ?? toneSeconds }
    /// Other tones for a book read by one narrator, so a book made again in
    /// another voice is other audio, of another length, and the player can be seen to take it.
    private var voiced: [String: (seconds: Double, audio: [Data])] = [:]
    private func audio(chapter n: Int, of job: BookJob) -> Data {
        voiced[job.book.voices.narrator].map { $0.audio[(n - 1) % $0.audio.count] } ?? audio(chapter: n)
    }
    private func seconds(chapter n: Int, of job: BookJob) -> Double {
        voiced[job.book.voices.narrator]?.seconds ?? seconds(chapter: n)
    }
    /// Whether `GET /v1/books` answers that books are on, and why not when they are off.
    private var booksOn = true
    private var booksOffReason = "no voice server is set up"
    /// What `GET /v1/voices` lists, as specs; nil answers 404, as a gateway from
    /// before the route does, which is the default so other tests see today's import screen.
    private var voices: [String]?
    /// The gateway's file store (`/v1/files`), for "Send to my Mac".
    private var files: [String: (contentType: String, body: Data)] = [:]
    /// "Previously…": what was asked of the model and of the voice, and what they
    /// answer. The model is an OpenAI-shaped `/v1/chat/completions` on loopback, which the phone
    /// treats as a model on the person's network; the voice is the gateway's speech preview.
    private var bodies: [String: [Data]] = [:]
    private var modelReply = "Previously, Ada wound the great clock all winter, and a letter came that was not from Tobias."
    private let previewSpeech: Data
    /// `POST /v1/books/complete`: 404, like a gateway from before the route, until a
    /// test turns it on; then the home server's model answers with `homeReply`.
    private var answersBookTasks = false
    private let homeReply = "Previously, Ada wound the great clock in the hall all winter, and a letter came that was not from Tobias."
    /// Voice the dialogue: the cast list the model writes (JSON as a model answers),
    /// who it says speaks each line it is asked to place (by quote id, "c1q3"), and how long
    /// placing takes. Nil answers those prompts like any other, with the recap.
    private var castSheet: String?
    private var castFill: [String: String]?
    private var castFillDelay: TimeInterval = 0
    /// How long the reply to every PUT is held (a book's submit, `PUT /v1/books/{id}`, and a file
    /// upload alike), as a slow home server or a slow upload holds it. The
    /// request is taken at once; only the answer waits. Zero unless a test sets it.
    private var submitDelay: TimeInterval = 0

    /// `speech`: serve the narrated chapters from `BATON_UITEST_SPEECH_DIR` when the runner has
    /// them; otherwise, and by default, the tones, each `chapterSeconds` long.
    init(speech useSpeech: Bool = false, chapterSeconds: Double = 30) throws {
        toneSeconds = chapterSeconds
        if useSpeech, let folder = ProcessInfo.processInfo.environment["BATON_UITEST_SPEECH_DIR"], !folder.isEmpty {
            let dir = URL(fileURLWithPath: folder)
            let files = (1...9).map { dir.appendingPathComponent("chapter-\($0).m4a") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !files.isEmpty else { throw URLError(.fileDoesNotExist) }
            chapterAudio = try files.map { try Data(contentsOf: $0) }
            speech = (try files.map { url in
                let file = try AVAudioFile(forReading: url)
                return Double(file.length) / file.fileFormat.sampleRate
            }, files.map { url in
                (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("timing.json")))
                    .flatMap(ReadAlongTiming.decode)
            })
        } else {
            chapterAudio = try (0..<4).map { try Self.makeAudio(seconds: chapterSeconds, frequency: 440 + 110 * Double($0)) }
            speech = nil
        }
        previewSpeech = try Self.makeWAV(seconds: 4)
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
    /// List these voices on `GET /v1/voices`, or answer 404 with nil.
    func setVoices(_ specs: [String]?) { lock.withLock { voices = specs } }
    /// Chapters `seconds` long, in tones of their own, for a book read by `narrator`.
    func setChapterSeconds(_ seconds: Double, forNarrator narrator: String) throws {
        let audio = try (0..<4).map { try Self.makeAudio(seconds: seconds, frequency: 330 + 110 * Double($0)) }
        lock.withLock { voiced[narrator] = (seconds, audio) }
    }
    /// The narrator of a submitted book, as its voice plan names it.
    func narrator(ofBook id: String) -> String? { lock.withLock { jobs[id]?.book.voices.narrator } }
    /// A file the app put in the file store, with its content type.
    func storedFile(_ id: String) -> (contentType: String, body: Data)? { lock.withLock { files[id] } }
    var requests: [Request] { lock.withLock { log } }
    func setAnswersBookTasks(_ on: Bool) { lock.withLock { answersBookTasks = on } }
    /// The model's answers for Voice the dialogue: the cast list, and who speaks the lines it
    /// is asked about (those it knows; the others it leaves out), after `fillDelay` seconds.
    func setCastReplies(sheet: String?, fill: [String: String]?, fillDelay: TimeInterval = 0) {
        lock.withLock { castSheet = sheet; castFill = fill; castFillDelay = fillDelay }
    }
    /// Hold every PUT's reply (book submits included) for `seconds`.
    func setSubmitDelay(_ seconds: TimeInterval) { lock.withLock { submitDelay = seconds } }
    /// A submitted book as it was sent.
    func book(_ id: String) -> PreparedBook? { lock.withLock { jobs[id]?.book } }
    /// Every submitted book, in the order sent.
    var submittedBooks: [PreparedBook] { lock.withLock { submitted } }
    /// Every body sent to `path`, oldest first.
    func bodies(_ path: String) -> [Data] { lock.withLock { bodies[path] ?? [] } }
    /// The narrator of every submitted book.
    var narrators: [String] { lock.withLock { jobs.values.map(\.book.voices.narrator) } }
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
                let reply = Data(head.utf8) + body
                let wait = self.delay(request.method, request.body)
                self.queue.asyncAfter(deadline: .now() + wait) {
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                }
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
            if method == "POST" { bodies[path, default: []].append(body) }
            let parts = path.split(separator: "/").map(String.init)
            if method == "POST", path == "/v1/chat/completions" {
                let reply: [String: Any] = ["choices": [["message": ["role": "assistant", "content": modelText(body, otherwise: modelReply)],
                                                         "finish_reason": "stop"]]]
                return (200, ["Content-Type": "application/json"], (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            }
            if method == "POST", path == "/v1/books/complete" {
                guard answersBookTasks else {
                    return (404, ["Content-Type": "application/json"], Data(#"{"error":"no such book"}"#.utf8))
                }
                let reply: [String: Any] = ["text": modelText(body, otherwise: homeReply), "model": "fake-home-model"]
                return (200, ["Content-Type": "application/json"], (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            }
            if method == "POST", path == "/v1/speech/preview" { return (200, ["Content-Type": "audio/wav"], previewSpeech) }
            if parts.count >= 2, parts[0] == "v1", parts[1] == "files" { return answerFile(method, parts, body, contentType) }
            if method == "GET", parts == ["v1", "voices"] {
                guard let voices else { return (404, ["Content-Type": "application/json"], Data(#"{"error":"not found"}"#.utf8)) }
                let list = GatewayVoiceList(voices: voices.map { spec in
                    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                    return GatewayVoiceList.Voice(engine: parts[0], id: parts[1], language: VoiceCatalogue.declaredLanguage(spec))
                }, sources: ["kokoro": "server"])
                return (200, ["Content-Type": "application/json"], (try? JSONEncoder().encode(list)) ?? Data())
            }
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
                submitted.append(book)
                readyCount[id] = readyOnSubmit
                return (201, ["Content-Type": "application/json"], (try? BookJSON.encoder.encode(summary(jobs[id]!))) ?? Data())
            }
            guard let job = jobs[id] else { return (404, [:], Data()) }
            if method == "DELETE" { jobs[id] = nil; return (204, [:], Data()) }
            if method == "POST" { return (204, [:], Data()) }
            // The shaped book, which a device that did not send it fetches to adopt it.
            if parts.count == 4, parts[3] == "book" {
                return (200, ["Content-Type": "application/json"], (try? job.book.encoded()) ?? Data())
            }
            // Read-along timing for chapter 1, its chunks spread over its length.
            // Every other chapter answers 404, as one made before timing was kept does.
            if parts.count == 6, parts[3] == "chapters", parts[5] == "timing", let n = Int(parts[4]) {
                if let speech {
                    guard n <= (readyCount[id] ?? 0), let timing = speech.timing[(n - 1) % speech.timing.count] else { return (404, [:], Data()) }
                    return (200, ["Content-Type": "application/json"], (try? timing.encoded()) ?? Data())
                }
                guard n == 1, n <= (readyCount[id] ?? 0), let segments = job.book.chapters.first?.segments,
                      !segments.isEmpty else { return (404, [:], Data()) }
                let span = toneSeconds / Double(segments.count)
                let timing = ReadAlongTiming(segments: segments.enumerated().map { i, segment in
                    .init(text: segment.text, paragraph: segment.paragraph,
                          start: Double(i) * span, end: Double(i + 1) * span - 0.2)
                })
                return (200, ["Content-Type": "application/json"], (try? timing.encoded()) ?? Data())
            }
            if parts.count == 5, parts[3] == "chapters", let n = Int(parts[4]) {
                guard n >= 1, n <= (readyCount[id] ?? 0) else { return (404, [:], Data()) }
                let chapter = audio(chapter: n, of: job)
                return (200, ["Content-Type": "audio/mp4", "X-Baton-SHA256": SHA256Digest.hex(of: chapter),
                              "X-Baton-Duration": String(format: "%.3f", seconds(chapter: n, of: job)), "X-Baton-Name": "chapter-\(n).m4a"], chapter)
            }
            return (200, ["Content-Type": "application/json"], (try? BookJSON.encoder.encode(summary(job))) ?? Data())
        }
    }

    /// The prompts of a model request, as one text: `{"system", "user"}` for the home server's
    /// book route, `{"messages": [...]}` for an OpenAI-shaped one.
    private static func prompts(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        if let messages = object["messages"] as? [[String: Any]] {
            return messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        }
        return [object["system"], object["user"]].compactMap { $0 as? String }.joined(separator: "\n")
    }

    private static func isFill(_ prompts: String) -> Bool { prompts.contains("You attribute quoted dialogue") }

    /// What the model says: the cast list, who speaks each asked line, or `otherwise`. Called
    /// holding the lock.
    private func modelText(_ body: Data, otherwise: String) -> String {
        let text = Self.prompts(body)
        if let castSheet, text.contains("You prepare the cast list") { return castSheet }
        if let castFill, Self.isFill(text), let ask = text.components(separatedBy: "ASK: ").last {
            let ids = ask.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            let answer = castFill.filter { ids.contains($0.key) }
            return (try? JSONSerialization.data(withJSONObject: answer)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
        return otherwise
    }

    /// How long to hold a reply: placing lines takes `castFillDelay`, any PUT `submitDelay`.
    private func delay(_ method: String, _ body: Data) -> TimeInterval {
        if method == "PUT" { return lock.withLock { submitDelay } }
        guard method == "POST" else { return 0 }
        return lock.withLock { castFill != nil && Self.isFill(Self.prompts(body)) ? castFillDelay : 0 }
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
                ? .ready(file: "chapter-\(i + 1).m4a", bytes: audio(chapter: i + 1, of: original).count,
                         seconds: seconds(chapter: i + 1, of: original),
                         sha256: SHA256Digest.hex(of: audio(chapter: i + 1, of: original)))
                : (i == ready ? .rendering(done: 1, of: 4) : .queued)
        }
        job.status = ready >= job.chapters.count ? .ready : .rendering
        return job.summary
    }

    /// A quiet tone as WAV, which is what the speech preview answers.
    private static func makeWAV(seconds: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-speech-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(24_000 * seconds))!
            buffer.frameLength = buffer.frameCapacity
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) { samples[i] = Float(0.05 * sin(2 * Double.pi * 330 * Double(i) / 24_000)) }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    /// A few seconds of a quiet tone as AAC in MPEG-4, which is what a chapter is.
    private static func makeAudio(seconds: Double, frequency: Double) throws -> Data {
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
            for i in 0..<Int(frames) { samples[i] = Float(0.1 * sin(2 * Double.pi * frequency * Double(i) / rate)) }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}
