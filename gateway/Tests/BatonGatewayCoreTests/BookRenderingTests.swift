import BatonDocuments
import BatonMCPProtocol
import Foundation
import XCTest
@testable import BatonGatewayCore
#if canImport(AVFoundation)
import AVFoundation
#endif

// The gateway's half of books: the real ffmpeg encoder and the HTTP routes. The render loop
// itself is shared and tested in BatonDocuments (`BookRenderingTests` there).

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

private func sampleBook(narrator: String = "kokoro:bf_emma", chapters: Int = 2) -> PreparedBook {
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

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("books-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Encoding

final class FFmpegMuxerTests: XCTestCase {
    private func renderer(_ dir: URL, _ synth: FakeSynthesizer, muxer: any AudioMuxing = CopyMuxer(),
                          concurrency: Int = 2) -> (BookRenderer, BookStore) {
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let r = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"), synthesizer: synth,
                             muxer: muxer, concurrency: concurrency,
                             retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        return (r, store)
    }

    func testRealFFmpegEncodesAPlayableTaggedChapter() async throws {
        guard let ffmpeg = FFmpegMuxer.locate() else { throw XCTSkip("ffmpeg is not installed") }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (r, store) = renderer(dir, FakeSynthesizer(secondsPerClip: 0.5), muxer: FFmpegMuxer(executable: ffmpeg))
        let book = sampleBook(chapters: 1)
        let id = BookJob.id(for: book)
        _ = try await r.submit(book, id: id)
        await r.waitUntilIdle()
        let job = try XCTUnwrap(store.load(id))
        guard case let .ready(file, bytes, seconds, _) = job.chapters[0] else { return XCTFail("\(job.chapters)") }
        let url = try XCTUnwrap(store.chapterURL(id, file: file))
        XCTAssertGreaterThan(bytes, 1000)

        // ffprobe (beside ffmpeg) reads the duration and tags back out of the file.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe"))
        probe.arguments = ["-v", "error", "-show_entries", "format=duration:format_tags=album,title,track",
                           "-of", "default=noprint_wrappers=1", url.path]
        let out = Pipe()
        probe.standardOutput = out
        try probe.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        probe.waitUntilExit()
        let duration = Double(text.components(separatedBy: "\n").first { $0.hasPrefix("duration=") }?
            .dropFirst("duration=".count) ?? "") ?? 0
        XCTAssertEqual(duration, seconds, accuracy: 0.15, text)
        XCTAssertTrue(text.contains("TAG:album=A Small Room"), text)
        XCTAssertTrue(text.contains("TAG:title=Part 1"), text)
        XCTAssertTrue(text.contains("TAG:track=1/1"), text)
    }

    /// TBX-10845: every chapter mark lands where its chapter starts in the joined file. Twelve
    /// chapters of real AAC from the gateway's own `encode`, each 0.25 s of silence then a tone
    /// of its own, joined by `exportM4B` with marks from the rendered lengths. Checked three
    /// ways: each chapter's first packet in the joined file sits on its mark; the joined file
    /// holds every chapter's packets in full, none overlapped away; and, where AVFoundation is
    /// there, each tone is heard on its mark when Apple's decoder plays the file, as Books does.
    /// Before the fix the joined file lost about 0.04 s per chapter and AVFoundation heard the
    /// tones up to 0.46 s after their marks by chapter 12. Main-actor so that the assertions
    /// after AVFoundation's `await` are recorded: on another thread XCTest dropped them.
    @MainActor
    func testExportedMarksLandWhereEachChapterStarts() async throws {
        guard let ffmpeg = FFmpegMuxer.locate() else { throw XCTSkip("ffmpeg is not installed") }
        let muxer = FFmpegMuxer(executable: ffmpeg)
        guard let ffprobe = FFmpegMuxer.locate(muxer.probeExecutable) else { throw XCTSkip("ffprobe is not installed beside ffmpeg") }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lengths = [3.349, 2.801, 2.357, 3.006, 3.526, 2.444, 3.461, 2.974, 1.775, 1.020, 1.168, 2.400]
        var files: [URL] = []
        var marks: [AudiobookExport.Mark] = []
        var rendered = 0.0
        for (index, seconds) in lengths.enumerated() {
            let wav = dir.appendingPathComponent("chapter-\(index + 1).wav")
            let m4a = dir.appendingPathComponent("chapter-\(index + 1).m4a")
            _ = try Self.tool(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi",
                                       "-i", "sine=frequency=\(400 + 150 * index):sample_rate=24000:duration=\(seconds - 0.25)",
                                       "-af", "adelay=250:all=1", "-ac", "1", wav.path])
            try await muxer.encode(wav: wav, to: m4a, bitrate: 48_000, channels: 1, tags: [:])
            files.append(m4a)
            marks.append(AudiobookExport.Mark(title: "Part \(index + 1)", start: rendered, end: rendered + seconds))
            rendered += seconds
        }
        let out = dir.appendingPathComponent("book.m4b")
        try await muxer.exportM4B(chapters: files, book: sampleBook(chapters: lengths.count), marks: marks, to: out)

        let chapterJSON = try Self.tool(ffprobe, ["-v", "error", "-show_chapters", "-of", "json", out.path])
        let chapters = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chapterJSON.utf8)) as? [String: Any])["chapters"] as? [[String: Any]]
        let starts = try XCTUnwrap(chapters).map { Double($0["start_time"] as? String ?? "") ?? -1 }
        XCTAssertEqual(try XCTUnwrap(chapters).compactMap { ($0["tags"] as? [String: Any])?["title"] as? String },
                       (1...lengths.count).map { "Part \($0)" })
        XCTAssertEqual(starts.count, lengths.count)

        // Each chapter's packets, in order, and the joined file's: chapter k begins at the packet
        // after all of the earlier chapters' packets.
        func packets(_ url: URL) throws -> [(pts: Double, duration: Double)] {
            try Self.tool(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "packet=pts_time,duration_time",
                                    "-of", "csv=p=0", url.path])
                .split(whereSeparator: \.isNewline).map { line in
                    let fields = line.split(separator: ",").compactMap { Double($0) }
                    return (fields.first ?? .nan, fields.count > 1 ? fields[1] : .nan)
                }
        }
        let joined = try packets(out)
        var first = 0
        var chapterPackets = 0.0
        for (index, file) in files.enumerated() {
            let own = try packets(file)
            XCTAssertEqual(starts[index], joined[first].pts - joined[0].pts, accuracy: 0.05, "chapter \(index + 1)'s first packet")
            first += own.count
            chapterPackets += own.reduce(0) { $0 + $1.duration }
        }
        XCTAssertEqual(joined.count, first, "every chapter's packets are in the joined file")
        XCTAssertEqual(joined.reduce(0) { $0 + $1.duration }, chapterPackets, accuracy: 0.05,
                       "no chapter's packets were overlapped away")

        #if canImport(AVFoundation)
        // Where each tone is heard as Apple's decoder plays the file: the first sound after at
        // least 0.15 s of quiet. Chapter 1's tone is the reference, since every chapter opens the same way.
        let asset = AVURLAsset(url: out)
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
        var quiet = 3600
        while let buffer = output.copyNextSampleBuffer() {
            let at = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let count = CMSampleBufferGetNumSamples(buffer)
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var samples = [Int16](repeating: 0, count: count)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: &samples)
            for (i, sample) in samples.enumerated() {
                if abs(Int(sample)) < 100 { quiet += 1; continue }
                if quiet >= 3600 { onsets.append(at + Double(i) / 24_000) }
                quiet = 0
            }
        }
        XCTAssertEqual(onsets.count, lengths.count, "one tone per chapter")
        for (index, (start, onset)) in zip(starts, onsets).enumerated() {
            XCTAssertEqual(start, onset - onsets[0], accuracy: 0.05, "chapter \(index + 1) as AVFoundation plays it")
        }
        #endif
    }

    /// Runs ffmpeg or ffprobe and returns what it printed, failing on a non-zero exit.
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

// MARK: - Routes

/// Not `@MainActor` as a class: Swift 6.0's Linux test discovery cannot call a synchronous
/// test method of a main-actor class (as `RouterTests` finds under 6.0). The async tests that
/// dispatch through the router are main-actor one by one instead.
final class BookRoutesTests: XCTestCase {
    private let token = "correct-horse"

    private func request(_ method: String, _ path: String, body: Data = Data(), token: String? = "correct-horse")
        -> HTTPRequestMessage {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequestMessage(method: method, path: path, query: [:], headers: headers, body: body)
    }

    private func status(_ data: Data) -> String {
        String(data: data.prefix(64), encoding: .utf8)?.components(separatedBy: "\r\n").first?
            .replacingOccurrences(of: "HTTP/1.1 ", with: "") ?? ""
    }

    private func body(_ data: Data) -> Data {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return data[range.upperBound...]
    }

    private func header(_ name: String, _ data: Data) -> String? {
        let end = data.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? data.endIndex
        let head = String(data: data[..<end], encoding: .utf8) ?? ""
        return head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    @MainActor
    private func upload(_ routes: BookRoutes, _ dir: URL, id: String, body: Data, token: String = "correct-horse") async -> Data {
        let staged = dir.appendingPathComponent("staged-\(UUID().uuidString)")
        try? body.write(to: staged)
        let req = StreamingUpload.Request(method: "PUT", path: "/v1/books/\(id)",
                                          headers: ["authorization": "Bearer \(token)"], contentLength: body.count)
        let response = await routes.handleUpload(req, staged, token: self.token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staged body must always be removed")
        return response
    }

    @MainActor
    func testTheWholeLifeOfABookThroughTheRoutes() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let synth = FakeSynthesizer()
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"),
                                    synthesizer: synth, muxer: CopyMuxer(), retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let routes = BookRoutes(renderer: renderer, store: store, synthesizer: synth, unavailableReason: nil)
        let router = Router(token: token, routes: routes.routes())
        let book = sampleBook()
        let id = BookJob.id(for: book)
        let payload = try book.encoded()

        let r1 = await upload(routes, dir, id: id, body: payload, token: "wrong")
        XCTAssertEqual(status(r1), "401 Unauthorized")
        let r2 = await upload(routes, dir, id: "../etc", body: payload)
        XCTAssertEqual(status(r2), "400 Bad Request")
        let r3 = await upload(routes, dir, id: String(repeating: "d", count: 64), body: payload)
        XCTAssertEqual(status(r3),
                       "400 Bad Request", "an id that is not the book's own is refused")
        let r4 = await upload(routes, dir, id: id, body: Data("{}".utf8))
        XCTAssertEqual(status(r4), "400 Bad Request")
        let r5 = await upload(routes, dir, id: id, body: payload)
        XCTAssertEqual(status(r5), "201 Created")
        let r6 = await upload(routes, dir, id: id, body: payload)
        XCTAssertEqual(status(r6), "200 OK", "a resubmission finds the job")

        await renderer.waitUntilIdle()

        let list = await router.dispatch(request("GET", "/v1/books"))
        let listing = try XCTUnwrap(JSONSerialization.jsonObject(with: body(list)) as? [String: Any])
        XCTAssertEqual((listing["books"] as? [Any])?.count, 1)
        XCTAssertEqual(listing["available"] as? Bool, true)

        let detail = await router.dispatch(request("GET", "/v1/books/\(id)"))
        let summary = try BookJSON.decoder.decode(BookJob.Summary.self, from: body(detail))
        XCTAssertEqual(summary.status, .ready)
        XCTAssertEqual(summary.chapters.map(\.state), ["ready", "ready"])
        // A device that did not send the book adopts it: the summary names its
        // document, and the shaped book comes back as it was submitted, behind the token.
        XCTAssertEqual(summary.documentID, book.documentID)
        let listed = try XCTUnwrap((listing["books"] as? [[String: Any]])?.first)
        XCTAssertEqual(listed["documentID"] as? String, book.documentID)
        let shaped = await router.dispatch(request("GET", "/v1/books/\(id)/book"))
        XCTAssertEqual(status(shaped), "200 OK")
        XCTAssertEqual(try PreparedBook.decode(body(shaped)), book)
        let refused = await router.dispatch(request("GET", "/v1/books/\(id)/book", token: "wrong"))
        XCTAssertEqual(status(refused), "401 Unauthorized")
        let unknown = await router.dispatch(request("GET", "/v1/books/\(String(repeating: "e", count: 64))/book"))
        XCTAssertEqual(status(unknown), "404 Not Found")

        let chapter = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/1"))
        XCTAssertEqual(status(chapter), "200 OK")
        XCTAssertEqual(header("X-Baton-SHA256", chapter), summary.chapters[0].sha256)
        XCTAssertEqual(header("Content-Type", chapter), "audio/mp4")
        XCTAssertEqual(SHA256Digest.hex(of: body(chapter)), summary.chapters[0].sha256)
        let r7 = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/9"))
        XCTAssertEqual(status(r7), "404 Not Found")

        let r8 = await router.dispatch(request("POST", "/v1/books/\(id)/finished"))
        XCTAssertEqual(status(r8), "200 OK")
        XCTAssertNotNil(store.load(id)?.finishedAt)

        let r9 = await router.dispatch(request("DELETE", "/v1/books/\(id)"))
        XCTAssertEqual(status(r9), "200 OK")
        XCTAssertNil(store.load(id))
        let r10 = await router.dispatch(request("GET", "/v1/books/\(id)"))
        XCTAssertEqual(status(r10), "404 Not Found")
        let r11 = await router.dispatch(request("GET", "/v1/books", token: nil))
        XCTAssertEqual(status(r11), "401 Unauthorized")
    }

    /// M8.8: a rendered book exported as one `.m4b` through the route, with the real ffmpeg,
    /// read back by ffprobe: one chapter mark per chapter, where the chapters are, titled.
    /// And M6.6: a finished book says when it will be removed.
    @MainActor
    func testExportAnAudiobookWithChapterMarks() async throws {
        guard let ffmpeg = FFmpegMuxer.locate() else { throw XCTSkip("ffmpeg is not installed") }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"), keepFinished: 7 * 86_400)
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"),
                                    synthesizer: FakeSynthesizer(secondsPerClip: 0.4), muxer: FFmpegMuxer(executable: ffmpeg),
                                    retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let routes = BookRoutes(renderer: renderer, store: store, synthesizer: nil, unavailableReason: nil,
                                exporter: FFmpegMuxer(executable: ffmpeg))
        let router = Router(token: token, routes: routes.routes())
        let book = sampleBook(chapters: 3)
        let id = BookJob.id(for: book)

        // Before it is rendered there is nothing to export, and the answer says how far along.
        var pending = BookJob(id: id, book: book)
        pending.chapters[0] = .ready(file: "chapter-1.m4a", bytes: 1, seconds: 1, sha256: "x")
        try store.save(pending)
        let early = await router.dispatch(request("GET", "/v1/books/\(id)/export.m4b"))
        XCTAssertEqual(status(early), "409 Conflict")
        XCTAssertTrue(String(decoding: body(early), as: UTF8.self).contains("1 of 3 chapters are ready"))
        store.remove(id)

        _ = try await renderer.submit(book, id: id)
        await renderer.waitUntilIdle()
        let job = try XCTUnwrap(store.load(id))
        let marks = try XCTUnwrap(AudiobookExport.marks(job))

        let response = await router.dispatch(request("GET", "/v1/books/\(id)/export.m4b"))
        XCTAssertEqual(status(response), "200 OK")
        XCTAssertEqual(header("X-Baton-Name", response), "A Small Room - A. N. Author.m4b")
        XCTAssertEqual(header("X-Baton-SHA256", response), SHA256Digest.hex(of: body(response)))
        let file = dir.appendingPathComponent("book.m4b")
        try body(response).write(to: file)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("baton-export-") }, [], "the export is not kept")

        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe"))
        probe.arguments = ["-v", "error", "-show_chapters", "-show_entries", "format=duration:format_tags=title,artist",
                           "-of", "json", file.path]
        let out = Pipe()
        probe.standardOutput = out
        try probe.run()
        let json = out.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let chapters = try XCTUnwrap(parsed["chapters"] as? [[String: Any]])
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters.compactMap { ($0["tags"] as? [String: Any])?["title"] as? String }, ["Part 1", "Part 2", "Part 3"])
        for (chapter, mark) in zip(chapters, marks) {
            XCTAssertEqual(Double(chapter["start_time"] as? String ?? "") ?? -1, mark.start, accuracy: 0.15)
        }
        let format = try XCTUnwrap(parsed["format"] as? [String: Any])
        XCTAssertEqual(Double(format["duration"] as? String ?? "") ?? 0, marks.last!.end, accuracy: 0.3)
        XCTAssertEqual((format["tags"] as? [String: Any])?["title"] as? String, "A Small Room")
        XCTAssertEqual((format["tags"] as? [String: Any])?["artist"] as? String, "A. N. Author")

        // M6.6: finishing starts the clock, and the listing says when the book goes.
        _ = await router.dispatch(request("POST", "/v1/books/\(id)/finished"))
        let detail = await router.dispatch(request("GET", "/v1/books/\(id)"))
        let summary = try BookJSON.decoder.decode(BookJob.Summary.self, from: body(detail))
        let finished = try XCTUnwrap(summary.finishedAt)
        XCTAssertEqual(try XCTUnwrap(summary.removesAt).timeIntervalSince(finished), 7 * 86_400, accuracy: 1)
        let list = await router.dispatch(request("GET", "/v1/books"))
        XCTAssertTrue(String(decoding: body(list), as: UTF8.self).contains("removesAt"))
    }

    @MainActor
    func testPreviewIsBoundedAndRedacted() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = FakeSynthesizer()
        let routes = BookRoutes(renderer: nil, store: BookStore(directory: dir), synthesizer: synth,
                                unavailableReason: nil)
        let router = Router(token: token, routes: routes.routes())
        let key = "sk-" + "abcdefghijklmnopqrstuvwxyz012345"
        func preview(_ text: String) async -> Data {
            let json = try! JSONSerialization.data(withJSONObject: ["text": text, "voice": "kokoro:bf_emma"])
            return await router.dispatch(request("POST", "/v1/speech/preview", body: json))
        }
        let ok = await preview("Imagine a small room. Paste \(key) here.")
        XCTAssertEqual(status(ok), "200 OK")
        XCTAssertEqual(header("Content-Type", ok), "audio/wav")
        XCTAssertNotNil(WAV.parse(body(ok)))
        XCTAssertFalse(synth.calls.contains { $0.text.contains(key) })
        let r12 = await preview(String(repeating: "a", count: 601))
        XCTAssertEqual(status(r12), "413 Payload Too Large")
    }

    /// TBX-10902: a cast book's id carries who speaks each line. The gateway recomputes it, so
    /// it takes a cast book under the id with the attribution, refuses the id the same book had
    /// before (what a gateway without this change computes, and so the answer such a gateway
    /// gives a client with it: 400, "book id does not match its content"), and treats the same
    /// voices with a line given to someone else as a book of its own.
    @MainActor
    func testACastBookIsTakenUnderTheIdThatCarriesItsAttribution() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let synth = FakeSynthesizer()
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"),
                                    synthesizer: synth, muxer: CopyMuxer(), retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let routes = BookRoutes(renderer: renderer, store: store, synthesizer: synth, unavailableReason: nil)

        func castBook(_ secondLine: String?) -> PreparedBook {
            PreparedBook(documentID: String(repeating: "5a", count: 32), title: "The Room", author: nil, language: "en",
                         voices: VoicePlan(narrator: "kokoro:bf_isabella",
                                           characters: ["Mary": "kokoro:bf_emma", "Tom": "kokoro:bm_george"]),
                         chapters: [PreparedChapter(index: 0, title: "Chapter 1", segments: [
                             SpeechSegment(text: "Who is it at this hour?", kind: .quote, speaker: "Mary", pauseBeforeMs: 0, paragraph: 0),
                             SpeechSegment(text: "Only me.", kind: .quote, speaker: secondLine, pauseBeforeMs: 300, paragraph: 1),
                             SpeechSegment(text: "I came to see the surface.", kind: .quote, speaker: "Tom", pauseBeforeMs: 300, paragraph: 2),
                         ])])
        }
        let rules = castBook(nil), filled = castBook("Tom")
        let rulesID = BookJob.id(for: rules), filledID = BookJob.id(for: filled)
        XCTAssertNotEqual(rulesID, filledID, "the same voices, a line given to someone else")
        // The id before TBX-10902: the document, the voices, no lexicon. Both books had it.
        let previousID = SHA256Digest.hex(of: Data("book-v1|\(rules.documentID)|".utf8) + (try BookJSON.encoder.encode(rules.voices)))
        XCTAssertNotEqual(previousID, rulesID)

        let refused = await upload(routes, dir, id: previousID, body: try filled.encoded())
        XCTAssertEqual(status(refused), "400 Bad Request")
        XCTAssertEqual(String(data: body(refused), encoding: .utf8), #"{"error":"book id does not match its content"}"#)
        let crossed = await upload(routes, dir, id: rulesID, body: try filled.encoded())
        XCTAssertEqual(status(crossed), "400 Bad Request", "another attribution's id")

        let first = await upload(routes, dir, id: rulesID, body: try rules.encoded())
        XCTAssertEqual(status(first), "201 Created")
        let second = await upload(routes, dir, id: filledID, body: try filled.encoded())
        XCTAssertEqual(status(second), "201 Created", "a book of its own, not the first one found again")
        await renderer.waitUntilIdle()
        XCTAssertEqual(store.load(rulesID)?.status, .ready)
        XCTAssertEqual(store.load(filledID)?.status, .ready)
        XCTAssertTrue(synth.calls.contains { $0.text == "Only me." && $0.voice == "kokoro:bm_george" })
        XCTAssertTrue(synth.calls.contains { $0.text == "Only me." && $0.voice == "kokoro:bf_isabella" })
    }

    /// TBX-10960: a chapter's read-along timing through the route, and a 404, the same answer an
    /// older gateway gives, for a chapter made before timing was kept.
    @MainActor
    func testAReadyChapterServesItsReadAlongTiming() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let synth = FakeSynthesizer()
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"),
                                    synthesizer: synth, muxer: CopyMuxer(), retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let routes = BookRoutes(renderer: renderer, store: store, synthesizer: synth, unavailableReason: nil)
        let router = Router(token: token, routes: routes.routes())
        let book = sampleBook()
        let id = BookJob.id(for: book)
        _ = try await renderer.submit(book, id: id)
        await renderer.waitUntilIdle()

        let response = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/1/timing"))
        XCTAssertEqual(status(response), "200 OK")
        XCTAssertEqual(header("Content-Type", response), "application/json")
        let timing = try XCTUnwrap(ReadAlongTiming.decode(body(response)))
        XCTAssertEqual(timing.segments.map(\.text), book.chapters[0].segments.map(\.text))
        XCTAssertGreaterThan(try XCTUnwrap(timing.segments.last).end, 0)

        // A chapter made before timing was kept: its file is there, its timing is not.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("books/\(id)/chapter-2.timing.json"))
        let old = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/2/timing"))
        XCTAssertEqual(status(old), "404 Not Found")
        let missing = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/3/timing"))
        XCTAssertEqual(status(missing), "404 Not Found")
        let unauthorized = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/1/timing", token: nil))
        XCTAssertEqual(status(unauthorized), "401 Unauthorized")
    }

    @MainActor
    func testWithoutFFmpegEveryBookRouteSaysWhy() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let routes = BookRoutes(renderer: nil, store: BookStore(directory: dir), synthesizer: nil,
                                unavailableReason: "ffmpeg is not installed on the gateway")
        let book = sampleBook()
        let response = await upload(routes, dir, id: BookJob.id(for: book), body: try book.encoded())
        XCTAssertEqual(status(response), "503 Service Unavailable")
        XCTAssertTrue(String(data: body(response), encoding: .utf8)!.contains("ffmpeg"))
        let list = Router(token: token, routes: routes.routes())
        let listed = await list.dispatch(request("GET", "/v1/books"))
        let listing = try XCTUnwrap(JSONSerialization.jsonObject(with: body(listed)) as? [String: Any])
        XCTAssertEqual(listing["available"] as? Bool, false)
        XCTAssertEqual(listing["unavailable_reason"] as? String, "ffmpeg is not installed on the gateway")
    }

    // MARK: Books made on another device

    @MainActor
    private func put(_ routes: BookRoutes, _ dir: URL, _ path: String, body: Data, headers: [String: String] = [:],
                     token: String = "correct-horse") async -> Data {
        let staged = dir.appendingPathComponent("staged-\(UUID().uuidString)")
        try? body.write(to: staged)
        var all = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        all["authorization"] = "Bearer \(token)"
        let req = StreamingUpload.Request(method: "PUT", path: path, headers: all, contentLength: body.count)
        let response = await routes.handleUpload(req, staged, token: self.token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staged body must always be removed")
        return response
    }

    private func chapterHeaders(_ audio: Data, seconds: Double = 12.5) -> [String: String] {
        ["X-Baton-SHA256": SHA256Digest.hex(of: audio), "X-Baton-Duration": String(seconds)]
    }

    /// A book the Mac made with its own voices reaches the home server whole: its shaped book,
    /// then each chapter's timing and audio, checked by digest. It is listed with its document
    /// like a book made here, so the iPhone adopts it the same way, and the render loop never
    /// tries to make it.
    @MainActor
    func testABookMadeOnTheMacIsUploadedChapterByChapterAndListedForTheOtherDevices() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let synth = FakeSynthesizer()
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"),
                                    synthesizer: synth, muxer: CopyMuxer(), retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        await renderer.startIfNeeded()
        let routes = BookRoutes(renderer: renderer, store: store, synthesizer: synth, unavailableReason: nil)
        let router = Router(token: token, routes: routes.routes())
        let book = sampleBook(narrator: "kokoro:af_heart")
        let id = BookJob.id(for: book)
        let payload = try book.encoded()

        // The shaped book: behind the token, under its own id, once.
        let refused = await put(routes, dir, "/v1/books/\(id)/upload", body: payload, token: "wrong")
        XCTAssertEqual(status(refused), "401 Unauthorized")
        XCTAssertNil(store.load(id), "nothing is kept from a request without the token")
        let wrongID = await put(routes, dir, "/v1/books/\(String(repeating: "d", count: 64))/upload", body: payload)
        XCTAssertEqual(status(wrongID), "400 Bad Request", "an id that is not the book's own is refused")
        let notABook = await put(routes, dir, "/v1/books/\(id)/upload", body: Data("{}".utf8))
        XCTAssertEqual(status(notABook), "400 Bad Request")
        let created = await put(routes, dir, "/v1/books/\(id)/upload", body: payload)
        XCTAssertEqual(status(created), "201 Created")
        let again = await put(routes, dir, "/v1/books/\(id)/upload", body: payload)
        XCTAssertEqual(status(again), "200 OK", "the same book again finds the job")
        XCTAssertEqual(store.load(id)?.uploaded, true)

        // Listed with its document, every chapter waiting for its audio; nothing synthesized.
        await renderer.waitUntilIdle()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(synth.calls.isEmpty, "the render loop never makes a book another device made")
        let listed = await router.dispatch(request("GET", "/v1/books"))
        let listing = try XCTUnwrap(JSONSerialization.jsonObject(with: body(listed)) as? [String: Any])
        let first = try XCTUnwrap((listing["books"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["documentID"] as? String, book.documentID)
        XCTAssertEqual(first["status"] as? String, "rendering")
        XCTAssertEqual((first["chapters"] as? [[String: Any]])?.compactMap { $0["state"] as? String }, ["queued", "queued"])

        // Chapter 1: timing first, then the audio, which is kept only when its digest matches.
        let timing = ReadAlongTiming(segments: book.chapters[0].segments.enumerated().map { i, segment in
            .init(text: segment.text, paragraph: segment.paragraph, start: Double(i), end: Double(i) + 0.8)
        })
        let tooBig = await put(routes, dir, "/v1/books/\(id)/chapters/1/timing",
                               body: Data(count: BookRoutes.maximumTimingBytes + 1))
        XCTAssertEqual(status(tooBig), "413 Payload Too Large")
        let garbage = await put(routes, dir, "/v1/books/\(id)/chapters/1/timing", body: Data("nonsense".utf8))
        XCTAssertEqual(status(garbage), "400 Bad Request")
        let noChapter = await put(routes, dir, "/v1/books/\(id)/chapters/9/timing", body: try timing.encoded())
        XCTAssertEqual(status(noChapter), "404 Not Found")
        let timed = await put(routes, dir, "/v1/books/\(id)/chapters/1/timing", body: try timing.encoded())
        XCTAssertEqual(status(timed), "200 OK")

        let audio1 = Data((0..<6_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let unsigned = await put(routes, dir, "/v1/books/\(id)/chapters/1", body: audio1)
        XCTAssertEqual(status(unsigned), "400 Bad Request", "a chapter without its digest is refused")
        let noLength = await put(routes, dir, "/v1/books/\(id)/chapters/1", body: audio1,
                                 headers: ["X-Baton-SHA256": SHA256Digest.hex(of: audio1)])
        XCTAssertEqual(status(noLength), "400 Bad Request", "a chapter without its duration is refused")
        let damaged = await put(routes, dir, "/v1/books/\(id)/chapters/1", body: audio1 + Data([1]),
                                headers: chapterHeaders(audio1))
        XCTAssertEqual(status(damaged), "422 Unprocessable Entity", "a chapter damaged on the way is refused")
        let notYet = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/1"))
        XCTAssertEqual(status(notYet), "409 Conflict", "and not kept")
        let one = await put(routes, dir, "/v1/books/\(id)/chapters/1", body: audio1, headers: chapterHeaders(audio1))
        XCTAssertEqual(status(one), "200 OK")
        let afterOne = try BookJSON.decoder.decode(BookJob.Summary.self, from: body(one))
        XCTAssertEqual(afterOne.chapters.map(\.state), ["ready", "queued"])
        XCTAssertEqual(afterOne.status, .rendering)
        XCTAssertEqual(afterOne.documentID, book.documentID)

        // What the iPhone fetches, as it does for a book made here.
        let served = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/1"))
        XCTAssertEqual(status(served), "200 OK")
        XCTAssertEqual(body(served), audio1)
        XCTAssertEqual(header("X-Baton-SHA256", served), SHA256Digest.hex(of: audio1))
        XCTAssertEqual(header("X-Baton-Duration", served), "12.500")
        let servedTiming = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/1/timing"))
        XCTAssertEqual(ReadAlongTiming.decode(body(servedTiming)), timing)
        let shaped = await router.dispatch(request("GET", "/v1/books/\(id)/book"))
        XCTAssertEqual(try PreparedBook.decode(body(shaped)), book)

        // The same chapter again changes nothing; the last one makes the book ready.
        let modified = try XCTUnwrap(store.load(id)?.updatedAt)
        let same = await put(routes, dir, "/v1/books/\(id)/chapters/1", body: audio1, headers: chapterHeaders(audio1))
        XCTAssertEqual(status(same), "200 OK")
        XCTAssertEqual(store.load(id)?.updatedAt, modified)
        let audio2 = Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 * 3) })
        let two = await put(routes, dir, "/v1/books/\(id)/chapters/2", body: audio2, headers: chapterHeaders(audio2, seconds: 8))
        XCTAssertEqual(status(two), "200 OK")
        let done = await router.dispatch(request("GET", "/v1/books/\(id)"))
        let summary = try BookJSON.decoder.decode(BookJob.Summary.self, from: body(done))
        XCTAssertEqual(summary.status, .ready)
        XCTAssertEqual(summary.chapters.map(\.sha256), [SHA256Digest.hex(of: audio1), SHA256Digest.hex(of: audio2)])
        XCTAssertEqual(summary.bytes, audio1.count + audio2.count)
        let noTiming = await router.dispatch(request("GET", "/v1/books/\(id)/chapters/2/timing"))
        XCTAssertEqual(status(noTiming), "404 Not Found", "a chapter sent without timing shows its text without a highlight")
        XCTAssertTrue(synth.calls.isEmpty)

        // Finished and deleted like any other book.
        let finished = await router.dispatch(request("POST", "/v1/books/\(id)/finished"))
        XCTAssertEqual(status(finished), "200 OK")
        let deleted = await router.dispatch(request("DELETE", "/v1/books/\(id)"))
        XCTAssertEqual(status(deleted), "200 OK")
        let gone = await put(routes, dir, "/v1/books/\(id)/chapters/1", body: audio1, headers: chapterHeaders(audio1))
        XCTAssertEqual(status(gone), "404 Not Found", "a chapter for a book deleted meanwhile is not kept")
        XCTAssertNil(store.load(id))
    }

    /// A book this gateway makes takes no chapters from elsewhere, and an upload is bounded by
    /// the books' space like a submission. Uploading needs no ffmpeg: the book is only kept.
    @MainActor
    func testAnUploadIsRefusedForABookMadeHereAndWhenTheSpaceIsFull() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let synth = FakeSynthesizer()
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"),
                                    synthesizer: synth, muxer: CopyMuxer(), retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let routes = BookRoutes(renderer: renderer, store: store, synthesizer: synth, unavailableReason: nil)
        let rendered = sampleBook()
        let renderedID = BookJob.id(for: rendered)
        _ = try await renderer.submit(rendered, id: renderedID)
        await renderer.waitUntilIdle()
        let audio = Data(repeating: 7, count: 2_000)
        let madeHere = await put(routes, dir, "/v1/books/\(renderedID)/chapters/1", body: audio, headers: chapterHeaders(audio))
        XCTAssertEqual(status(madeHere), "409 Conflict")
        XCTAssertEqual(store.load(renderedID)?.uploaded, nil)
        let existing = await put(routes, dir, "/v1/books/\(renderedID)/upload", body: try rendered.encoded())
        XCTAssertEqual(status(existing), "200 OK", "the same book uploaded finds the job made here")
        XCTAssertNil(store.load(renderedID)?.uploaded)

        // No ffmpeg, and a space of 1 MB.
        let small = BookStore(directory: dir.appendingPathComponent("small"), maximumBytes: 1_000_000)
        let keeper = BookRoutes(renderer: nil, store: small, synthesizer: nil, unavailableReason: "ffmpeg is not installed on the gateway")
        let book = sampleBook(narrator: "kokoro:af_heart", chapters: 1)
        let id = BookJob.id(for: book)
        let created = await put(keeper, dir, "/v1/books/\(id)/upload", body: try book.encoded())
        XCTAssertEqual(status(created), "201 Created", "a gateway that cannot make books still keeps one made elsewhere")
        let large = Data(repeating: 9, count: 1_100_000)
        let full = await put(keeper, dir, "/v1/books/\(id)/chapters/1", body: large, headers: chapterHeaders(large))
        XCTAssertEqual(status(full), "507 Insufficient Storage")
        XCTAssertEqual(small.load(id)?.readyChapters, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: small.jobDirectory(id)!.path), ["job.json"],
                       "nothing of a refused chapter is left behind")
        let unknown = await put(keeper, dir, "/v1/books/\(id)/chapters/1/extra", body: audio, headers: chapterHeaders(audio))
        XCTAssertEqual(status(unknown), "404 Not Found")
    }

    /// The two clients end to end through the real routes: the Mac's `GatewayBookClient` sends
    /// a book it made, and the iPhone's, which did not send it, finds it in the listing under its
    /// document, fetches the shaped book, and downloads each chapter checked against its digest
    /// with its read-along timing: the TBX-10985 adoption path, unchanged.
    @MainActor
    func testWhatTheMacUploadsTheIPhoneDownloadsThroughTheRealRoutes() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let routes = BookRoutes(renderer: nil, store: store, synthesizer: nil, unavailableReason: "ffmpeg is not installed on the gateway")
        let router = Router(token: token, routes: routes.routes())
        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let expectedToken = token
        // The transport as the gateway's: a PUT under /v1/books/ is streamed to disk, the rest buffered.
        let wire: GatewayBookClient.Transport = { request in
            var headers: [String: String] = [:]
            for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
            let body = request.httpBody ?? Data()
            let path = request.url!.path
            let raw: Data
            if request.httpMethod == "PUT" {
                let staged = staging.appendingPathComponent("upload-\(UUID().uuidString)")
                try body.write(to: staged)
                raw = await routes.handleUpload(.init(method: "PUT", path: path, headers: headers, contentLength: body.count),
                                                staged, token: expectedToken)
            } else {
                raw = await router.dispatch(HTTPRequestMessage(method: request.httpMethod ?? "GET", path: path, query: [:],
                                                               headers: headers, body: body))
            }
            let split = try XCTUnwrap(raw.range(of: Data("\r\n\r\n".utf8)))
            let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let code = Int(head[0].split(separator: " ")[1]) ?? 0
            var fields: [String: String] = [:]
            for line in head.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return (Data(raw[split.upperBound...]), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                                                     headerFields: fields)!)
        }
        let base = URL(string: "http://gateway.test:8788")!
        let mac = GatewayBookClient(baseURL: base, token: token, transport: wire)
        let phone = GatewayBookClient(baseURL: base, token: token, transport: wire)
        let book = sampleBook(narrator: "kokoro:af_heart")
        let id = BookJob.id(for: book)

        let accepted = try await mac.upload(book)
        XCTAssertEqual(accepted.id, id)
        XCTAssertEqual(accepted.chapters.map(\.state), ["queued", "queued"])
        let audio = [Data(repeating: 0x31, count: 3_000), Data(repeating: 0x32, count: 5_000)]
        for (index, chapter) in audio.enumerated() {
            let timing = ReadAlongTiming(segments: book.chapters[index].segments.map {
                .init(text: $0.text, paragraph: $0.paragraph, start: 0, end: 1)
            })
            try await mac.uploadTiming(id, number: index + 1, timing: timing)
            _ = try await mac.uploadChapter(id, number: index + 1, audio: chapter, seconds: 20)
        }

        let listing = try await phone.list()
        let listed = try XCTUnwrap(listing.books.first { $0.id == id })
        XCTAssertEqual(listed.documentID, book.documentID)
        XCTAssertEqual(listed.status, .ready)
        let shaped = try await phone.preparedBook(id)
        XCTAssertEqual(shaped, book)
        for index in audio.indices {
            let file = dir.appendingPathComponent("phone-\(index).m4a")
            let chapter = try await phone.downloadChapter(id, number: index + 1, to: file)
            XCTAssertEqual(try Data(contentsOf: file), audio[index])
            XCTAssertEqual(chapter.sha256, SHA256Digest.hex(of: audio[index]))
            XCTAssertEqual(chapter.seconds, 20)
            let timing = try await phone.chapterTiming(id, number: index + 1)
            XCTAssertEqual(timing?.segments.map(\.text), book.chapters[index].segments.map(\.text))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [], "no upload left behind")
    }

    func testBookSubmissionTakesTheStreamingPath() {
        XCTAssertTrue(isStreamingUpload(.init(method: "PUT", path: "/v1/books/abc", headers: [:], contentLength: 1)))
        XCTAssertTrue(isStreamingUpload(.init(method: "PUT", path: "/v1/files/abc", headers: [:], contentLength: 1)))
        XCTAssertFalse(isStreamingUpload(.init(method: "GET", path: "/v1/books/abc", headers: [:], contentLength: 0)))
        // A book made on another device and its chapters stream too.
        XCTAssertTrue(isStreamingUpload(.init(method: "PUT", path: "/v1/books/abc/upload", headers: [:], contentLength: 1)))
        XCTAssertTrue(isStreamingUpload(.init(method: "PUT", path: "/v1/books/abc/chapters/1", headers: [:], contentLength: 1)))
    }
}
