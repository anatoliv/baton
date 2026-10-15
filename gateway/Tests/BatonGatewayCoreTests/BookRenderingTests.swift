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

    func testBookSubmissionTakesTheStreamingPath() {
        XCTAssertTrue(isStreamingUpload(.init(method: "PUT", path: "/v1/books/abc", headers: [:], contentLength: 1)))
        XCTAssertTrue(isStreamingUpload(.init(method: "PUT", path: "/v1/files/abc", headers: [:], contentLength: 1)))
        XCTAssertFalse(isStreamingUpload(.init(method: "GET", path: "/v1/books/abc", headers: [:], contentLength: 0)))
    }
}
