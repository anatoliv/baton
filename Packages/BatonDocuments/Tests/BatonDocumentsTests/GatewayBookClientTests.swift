import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments

/// The gateway client against a scripted transport (shape of every request, digest check,
/// errors), and, when `BATON_LIVE_GATEWAY_URL` and `BATON_LIVE_GATEWAY_TOKEN` are set, against a
/// real gateway end to end.
final class GatewayBookClientTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { _requests } }
        func add(_ r: URLRequest) { lock.withLock { _requests.append(r) } }
    }

    private func client(_ recorder: Recorder,
                        answer: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data)) -> GatewayBookClient {
        GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "tok") { request in
            recorder.add(request)
            let (status, headers, body) = answer(request)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }

    private func book() -> PreparedBook {
        DocumentSpeech.prepare(ImportedDocument(sourceSHA256: "ab", sourceKind: .text, title: "T", author: "A",
                                                chapters: [DocumentChapter(index: 0, title: "One",
                                                                           paragraphs: ["A sentence long enough to speak aloud."])]),
                               voices: VoicePlan(narrator: "kokoro:bf_emma"))
    }

    private func summaryJSON(_ id: String) -> Data {
        let summary = BookJob(id: id, book: book(), now: Date(timeIntervalSince1970: 1_800_000_000)).summary
        return try! BookJSON.encoder.encode(summary)
    }

    func testSubmitPutsThePreparedBookUnderItsOwnID() async throws {
        let recorder = Recorder()
        let b = book()
        let id = BookJob.id(for: b)
        let json = summaryJSON(id)
        let c = client(recorder) { _ in (201, [:], json) }
        let summary = try await c.submit(b)
        XCTAssertEqual(summary.id, id)
        let r = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(r.httpMethod, "PUT")
        XCTAssertEqual(r.url?.path, "/v1/books/\(id)")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(try PreparedBook.decode(XCTUnwrap(r.httpBody)), b)
    }

    /// TBX-10962: `GET /v1/voices` with the token, read into specs and languages; an older
    /// gateway's 404 comes back as that 404, which the phone takes as "keep today's default".
    func testVoicesAreReadAndAnOlderGatewaysNotFoundIsReported() async throws {
        let recorder = Recorder()
        let json = Data(#"{"voices":[{"spec":"kokoro:af_heart","engine":"kokoro","id":"af_heart","language":"en"},{"spec":"chatterbox:Emily.wav","engine":"chatterbox","id":"Emily.wav"}],"sources":{"kokoro":"server","chatterbox":"server"}}"#.utf8)
        let list = try await client(recorder) { _ in (200, ["Content-Type": "application/json"], json) }.voices()
        XCTAssertEqual(list.specs, ["kokoro:af_heart", "chatterbox:Emily.wav"])
        XCTAssertEqual(list.voices.map(\.language), ["en", nil])
        XCTAssertEqual(list.sources["kokoro"], "server")
        let r = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.url?.path, "/v1/voices")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        do {
            _ = try await client(Recorder()) { _ in (404, [:], Data(#"{"error":"not found"}"#.utf8)) }.voices()
            XCTFail("a 404 must throw")
        } catch let error as GatewayBookError {
            guard case .http(404, _) = error else { return XCTFail("\(error)") }
        }
        do {
            _ = try await client(Recorder()) { _ in (200, [:], Data("<html>".utf8)) }.voices()
            XCTFail("an unreadable answer must throw")
        } catch let error as GatewayBookError {
            XCTAssertEqual(error, .unreadable)
        }
    }

    /// The list the gateway falls back to and the language it reads from an id.
    func testKokorosEnglishVoicesAndDeclaredLanguages() {
        let voices = VoiceCatalogue.kokoroEnglishVoices
        XCTAssertEqual(voices.count, 28)
        XCTAssertTrue(voices.contains("kokoro:af_heart") && voices.contains("kokoro:bf_emma"))
        XCTAssertTrue(voices.contains("kokoro:af_aoede") && voices.contains("kokoro:bm_lewis"))
        XCTAssertEqual(VoiceCatalogue.declaredLanguage("kokoro:bf_emma"), "en")
        XCTAssertEqual(VoiceCatalogue.declaredLanguage("kokoro:zf_xiaobei"), "zh")
        XCTAssertNil(VoiceCatalogue.declaredLanguage("chatterbox:Emily.wav"))
        XCTAssertNil(VoiceCatalogue.declaredLanguage("kokoro:custom"))
    }

    func testAChapterIsWrittenOnlyWhenItsDigestMatches() async throws {
        let audio = Data("pretend this is an m4a".utf8)
        let good = SHA256Digest.hex(of: audio)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = client(Recorder()) { _ in (200, ["X-Baton-SHA256": good, "X-Baton-Duration": "12.500", "X-Baton-Name": "T - 1. One"], audio) }
        let chapter = try await ok.downloadChapter("abc", number: 1, to: dir.appendingPathComponent("1.m4a"))
        XCTAssertEqual(chapter.seconds, 12.5)
        XCTAssertEqual(chapter.name, "T - 1. One")
        XCTAssertEqual(try Data(contentsOf: chapter.url), audio)

        let bad = client(Recorder()) { _ in (200, ["X-Baton-SHA256": String(repeating: "0", count: 64)], audio) }
        let target = dir.appendingPathComponent("2.m4a")
        do {
            _ = try await bad.downloadChapter("abc", number: 2, to: target)
            XCTFail("a damaged chapter must not be accepted")
        } catch let error as GatewayBookError {
            guard case .digestMismatch = error else { return XCTFail("\(error)") }
            XCTAssertEqual(error.listenerReason, "a chapter arrived damaged and will be fetched again")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testErrorsCarryTheGatewaysMessageAndAListenerReason() async {
        let full = client(Recorder()) { _ in
            (507, [:], Data(#"{"error":"the home server's space for books is full of unfinished books"}"#.utf8))
        }
        do {
            _ = try await full.submit(book())
            XCTFail("expected 507")
        } catch let error as GatewayBookError {
            XCTAssertEqual(error, .http(status: 507, message: "the home server's space for books is full of unfinished books"))
            XCTAssertEqual(error.listenerReason, "the Baton server is out of space for books")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testListingAndTheSmallCalls() async throws {
        let recorder = Recorder()
        let id = String(repeating: "a", count: 64)
        let json = summaryJSON(id)
        let c = client(recorder) { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("GET", "/v1/books"):
                let summary = try! JSONSerialization.jsonObject(with: json)
                let body: [String: Any] = ["books": [summary], "used_bytes": 10, "maximum_bytes": 100,
                                           "keep_finished_days": 30, "available": true, "unavailable_reason": NSNull()]
                return (200, [:], try! JSONSerialization.data(withJSONObject: body))
            case ("POST", "/v1/speech/preview"):
                return (200, ["Content-Type": "audio/wav"], Data("RIFF".utf8))
            default:
                return (200, [:], Data(#"{"ok":true}"#.utf8))
            }
        }
        let listing = try await c.list()
        XCTAssertEqual(listing.books.map(\.id), [id])
        XCTAssertEqual(listing.maximumBytes, 100)
        XCTAssertTrue(listing.available)
        XCTAssertNil(listing.unavailableReason)
        try await c.markFinished(id)
        try await c.delete(id)
        let wav = try await c.preview(text: "Hello there.", voice: "kokoro:bf_emma", speed: 0.95)
        XCTAssertEqual(wav, Data("RIFF".utf8))
        XCTAssertEqual(recorder.requests.map { "\($0.httpMethod!) \($0.url!.path)" }, [
            "GET /v1/books", "POST /v1/books/\(id)/finished", "DELETE /v1/books/\(id)", "POST /v1/speech/preview",
        ])
        let previewBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.requests.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(previewBody["speed"] as? Double, 0.95)
    }

    /// End to end against a real gateway (the cloud session runs one with a stand-in Kokoro and
    /// real ffmpeg; the Mac can point this at the deployed one).
    func testAgainstARealGateway() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["BATON_LIVE_GATEWAY_URL"].flatMap(URL.init(string:)), let token = env["BATON_LIVE_GATEWAY_TOKEN"] else {
            throw XCTSkip("set BATON_LIVE_GATEWAY_URL and BATON_LIVE_GATEWAY_TOKEN to run against a real gateway")
        }
        let c = GatewayBookClient(baseURL: base, token: token)
        let listing = try await c.list()
        try XCTSkipUnless(listing.available, listing.unavailableReason ?? "books are off on that gateway")

        let b = DocumentSpeech.prepare(ImportedDocument(
            sourceSHA256: SHA256Digest.hex(of: Data(UUID().uuidString.utf8)), sourceKind: .text, title: "Client test",
            author: nil, chapters: [DocumentChapter(index: 0, title: "Only", paragraphs: [
                "This short book exists to prove the client and the gateway agree.",
                "It is rendered, downloaded, checked and deleted again.",
            ])]), voices: VoicePlan(narrator: "kokoro:bf_emma"))
        let submitted = try await c.submit(b)
        XCTAssertEqual(submitted.id, BookJob.id(for: b))
        var summary = submitted
        for _ in 0..<600 where summary.status != .ready && summary.status != .failed {
            try await Task.sleep(nanoseconds: 200_000_000)
            summary = try await c.status(submitted.id)
        }
        XCTAssertEqual(summary.status, .ready, summary.pauseReason ?? "")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let chapter = try await c.downloadChapter(submitted.id, number: 1, to: dir.appendingPathComponent("1.m4a"))
        XCTAssertEqual(chapter.sha256, summary.chapters[0].sha256)
        XCTAssertGreaterThan(chapter.seconds ?? 0, 1)
        try await c.markFinished(submitted.id)
        let finished = try await c.status(submitted.id)
        XCTAssertNotNil(finished.finishedAt)
        try await c.delete(submitted.id)
        do {
            _ = try await c.status(submitted.id)
            XCTFail("deleted")
        } catch let error as GatewayBookError {
            XCTAssertEqual(error, .http(status: 404, message: "no such book"))
        }
    }
}

/// The audiobook export's shared half: marks only when every chapter is ready, metadata that
/// survives awkward titles, a file name safe anywhere, and the client's download.
final class AudiobookExportTests: XCTestCase {
    private func job() -> BookJob {
        let book = DocumentSpeech.prepare(ImportedDocument(sourceSHA256: "e", sourceKind: .text, title: "Odd: A=B; #1", author: "A. Writer",
                                                           chapters: [DocumentChapter(index: 0, title: "One; two", paragraphs: ["Words enough to speak aloud."]),
                                                                      DocumentChapter(index: 1, title: "Three", paragraphs: ["More words to speak aloud."])]),
                                          voices: VoicePlan(narrator: "kokoro:bf_emma"))
        return BookJob(id: BookJob.id(for: book), book: book)
    }

    func testMarksWaitForEveryChapter() {
        var j = job()
        XCTAssertNil(AudiobookExport.marks(j))
        j.chapters[0] = .ready(file: "chapter-1.m4a", bytes: 10, seconds: 12.5, sha256: "a")
        XCTAssertNil(AudiobookExport.marks(j))
        XCTAssertNil(AudiobookExport.chapterFiles(j))
        j.chapters[1] = .ready(file: "chapter-2.m4a", bytes: 10, seconds: 7.25, sha256: "b")
        XCTAssertEqual(AudiobookExport.marks(j), [AudiobookExport.Mark(title: "One; two", start: 0, end: 12.5), AudiobookExport.Mark(title: "Three", start: 12.5, end: 19.75)])
        XCTAssertEqual(AudiobookExport.chapterFiles(j), ["chapter-1.m4a", "chapter-2.m4a"])
    }

    /// TBX-10845: marks move onto the joined lengths, titles kept; a count mismatch changes nothing.
    func testMarksArePlacedOnTheMuxedLengths() {
        let rendered = [AudiobookExport.Mark(title: "One", start: 0, end: 2), AudiobookExport.Mark(title: "Two", start: 2, end: 5),
                        AudiobookExport.Mark(title: "Three", start: 5, end: 6.5)]
        let placed = AudiobookExport.placed(rendered, muxedLengths: [2.0427, 3.0427, 1.5427])
        XCTAssertEqual(placed.map(\.title), ["One", "Two", "Three"])
        for (mark, (start, end)) in zip(placed, [(0, 2.0427), (2.0427, 5.0854), (5.0854, 6.6281)]) {
            XCTAssertEqual(mark.start, start, accuracy: 1e-9)
            XCTAssertEqual(mark.end, end, accuracy: 1e-9)
        }
        XCTAssertEqual(AudiobookExport.placed(rendered, muxedLengths: [1, 2]), rendered)
    }

    func testMetadataAndFileName() {
        let j = job()
        let meta = AudiobookExport.ffmetadata(book: j.book, marks: [AudiobookExport.Mark(title: "One; two", start: 0, end: 12.5)])
        XCTAssertTrue(meta.hasPrefix(";FFMETADATA1"), meta)
        XCTAssertTrue(meta.contains(##"title=Odd: A\=B\; \#1"##), meta)
        XCTAssertTrue(meta.contains("[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=12500\n"), meta)
        XCTAssertTrue(meta.contains(#"title=One\; two"#), meta)
        XCTAssertEqual(AudiobookExport.fileName(j.book), "Odd_ A=B; #1 - A. Writer.m4b")
    }

    /// A title cannot end its line and start a section of its own: "\r\n" is one Character in
    /// Swift, a NUL ends ffmpeg's line read, and either let "[CHAPTER]" through.
    func testTitlesCannotInjectSections() {
        let marks = [AudiobookExport.Mark(title: "Part 1\r\n[CHAPTER]\r\ntitle=x", start: 0, end: 1),
                     AudiobookExport.Mark(title: "Part 2\r[CHAPTER]", start: 1, end: 2),
                     AudiobookExport.Mark(title: "Part 3\u{0}[CHAPTER]", start: 2, end: 3)]
        let meta = AudiobookExport.ffmetadata(book: job().book, marks: marks)
        // Lines as ffmpeg's reader splits them: at CR, LF or NUL not escaped by a backslash.
        var lines: [String] = [], line = "", escaped = false
        for scalar in meta.unicodeScalars {
            if !escaped, scalar == "\r" || scalar == "\n" || scalar == "\u{0}" { lines.append(line); line = ""; continue }
            escaped = !escaped && scalar == "\\"
            line.unicodeScalars.append(scalar)
        }
        XCTAssertEqual(lines.filter { $0.hasPrefix("[CHAPTER]") }.count, marks.count, meta.debugDescription)
        XCTAssertEqual(lines.filter { $0.hasPrefix("title=x") }.count, 0, meta.debugDescription)
    }

    func testTheClientDownloadsTheExportChecked() async throws {
        let audio = Data("pretend m4b".utf8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = GatewayBookClient(baseURL: URL(string: "http://gateway.test")!, token: "t") { request in
            XCTAssertEqual(request.url?.path, "/v1/books/abc/export.m4b")
            return (audio, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["X-Baton-SHA256": SHA256Digest.hex(of: audio), "X-Baton-Name": "../T - A.m4b"])!)
        }
        // A file that happens to carry the server's suggested name is someone else's: untouched.
        let unrelated = dir.appendingPathComponent("T - A.m4b")
        let theirs = Data("an older export the person kept".utf8)
        try theirs.write(to: unrelated)
        let chosen = dir.appendingPathComponent("My Book.m4b")
        let file = try await client.exportAudiobook("abc", to: chosen)
        XCTAssertEqual(file.url, chosen)
        XCTAssertEqual(file.name, "T - A.m4b", "a name from the server never leaves the directory")
        XCTAssertEqual(try Data(contentsOf: chosen), audio)
        XCTAssertEqual(try Data(contentsOf: unrelated), theirs, "an unrelated file in the folder is untouched")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["T - A.m4b", "My Book.m4b"],
                       "nothing else is left behind")

        // Choosing an existing file (confirmed in the save panel) replaces that file only.
        let replaced = try await client.exportAudiobook("abc", to: unrelated)
        XCTAssertEqual(replaced.url, unrelated)
        XCTAssertEqual(try Data(contentsOf: unrelated), audio)
    }

    func testADamagedExportWritesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = GatewayBookClient(baseURL: URL(string: "http://gateway.test")!, token: "t") { request in
            (Data("bytes".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["X-Baton-SHA256": String(repeating: "0", count: 64)])!)
        }
        do {
            _ = try await client.exportAudiobook("abc", to: dir.appendingPathComponent("Book.m4b"))
            XCTFail("a digest mismatch must throw")
        } catch GatewayBookError.digestMismatch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
