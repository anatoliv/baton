import BatonDocuments
import BatonMCPProtocol
import Foundation

/// The book routes (`specs/document-clippings.md`, *Rendering*), in the core target so a test
/// can drive them through the real `Router`.
///
///     PUT    /v1/books/{id}                    submit a PreparedBook (streamed, like a file upload)
///     PUT    /v1/books/{id}/upload             a book made on another device: its
///                                              PreparedBook, kept as a job nothing here renders
///     PUT    /v1/books/{id}/cover              the book's cover, a JPEG or PNG a device re-encoded
///, checked against its X-Baton-SHA256
///     PUT    /v1/books/{id}/chapters/{n}/timing  that book's chapter n read-along timing
///     PUT    /v1/books/{id}/chapters/{n}       that book's chapter n M4A, checked against its
///                                              X-Baton-SHA256 before it is kept
///     GET    /v1/books                         list, newest first, without the text
///     GET    /v1/books/{id}                    one job's status, per chapter
///     GET    /v1/books/{id}/book               the shaped book it was made from, for another device
///     GET    /v1/books/{id}/cover              the book's cover, with its digest (404: none)
///     DELETE /v1/books/{id}/cover              remove it, for every device
///     GET    /v1/books/{id}/chapters/{n}       chapter n's M4A (1-based), with its digest
///     GET    /v1/books/{id}/chapters/{n}/timing  where each chunk sits in it, for read-along (404: none kept)
///     GET    /v1/books/{id}/export.m4b         the whole book as one audiobook with chapter marks
///     POST   /v1/books/{id}/finished           the listener reached the end: retention starts
///     POST   /v1/books/complete                one book task (a recap) by the gateway's model, only
///                                              when it is on the home network (`BookCompletionRoute`)
///     DELETE /v1/books/{id}                    cancel and remove
///     POST   /v1/speech/preview                a few seconds of a voice, for the import sheet
///     GET    /v1/voices                        the voices the voice server offers (`VoiceListing`)
///
/// Submission is a `PUT` that streams to disk because a prepared novel is larger than the 1 MB
/// the ordinary request path accepts; the same streaming path files already use takes it.
public struct BookRoutes: Sendable {
    public let renderer: BookRenderer?
    public let store: BookStore
    public let synthesizer: (any SpeechSynthesizing)?
    /// Why book rendering is off, when it is (no ffmpeg, no TTS host): every book route says it.
    public let unavailableReason: String?
    /// Joins chapters into an `.m4b` (`FFmpegMuxer.exportM4B`); nil turns the export off.
    public let exporter: FFmpegMuxer?
    /// What `GET /v1/voices` answers with; nil answers 503.
    public let voices: VoiceListing?
    /// `POST /v1/books/complete`; nil answers 503.
    public let completion: BookCompletionRoute?

    public static let maximumPreviewCharacters = 600
    /// The export is answered from memory like every response here (`httpResponse`'s known
    /// limit), so it has a ceiling: about 70 hours at the default 48 kbps.
    public static let maximumExportBytes = 1_500_000_000

    public init(renderer: BookRenderer?, store: BookStore, synthesizer: (any SpeechSynthesizing)?,
                unavailableReason: String?, exporter: FFmpegMuxer? = nil, voices: VoiceListing? = nil,
                completion: BookCompletionRoute? = nil) {
        self.renderer = renderer
        self.completion = completion
        self.voices = voices
        self.store = store
        self.synthesizer = synthesizer
        self.unavailableReason = unavailableReason
        self.exporter = exporter
    }

    /// Read-along timing is a few hundred entries for a long chapter; anything near this is not
    /// timing.
    public static let maximumTimingBytes = 2 * 1024 * 1024
    /// The longest chapter an upload may say it is, in seconds: a day.
    static let maximumChapterSeconds = 86_400.0
    /// One upload changes a job at a time, so two chapters arriving together cannot each write
    /// back a job that lacks the other.
    private static let uploadLock = NSLock()

    public static func isBookUpload(_ request: StreamingUpload.Request) -> Bool {
        request.method == "PUT" && request.path.hasPrefix("/v1/books/")
    }

    public func routes() -> [Router.Route] {
        [
            Router.Route(methods: ["GET"], pattern: .exact("/v1/books"), handler: { _, _ in self.list() }),
            // Before the `/v1/books/` prefix, which would take "complete" for a book id.
            Router.Route(methods: ["POST"], pattern: .exact(BookCompletion.path), handler: { request, _ in
                guard let completion = self.completion else {
                    return httpErrorResponse(status: "503 Service Unavailable", message: "no model is set up on the home server")
                }
                return await completion.handle(request)
            }),
            Router.Route(methods: ["GET", "POST", "DELETE"], pattern: .prefix("/v1/books/"),
                         handler: { request, rest in await self.book(request, rest) }),
            Router.Route(methods: ["POST"], pattern: .exact("/v1/speech/preview"),
                         handler: { request, _ in await self.preview(request) }),
            Router.Route(methods: ["GET"], pattern: .exact("/v1/voices"), handler: { _, _ in await self.voiceList() }),
        ]
    }

    // MARK: - Handlers

    public func list() -> Data {
        let body: [String: Any] = [
            "books": store.list().map { try? JSONSerialization.jsonObject(with: BookJSON.encoder.encode(store.summary(of: $0))) }
                .compactMap { $0 },
            "used_bytes": store.usedBytes,
            "maximum_bytes": store.maximumBytes,
            "keep_finished_days": Int(store.keepFinished / 86_400),
            "available": unavailableReason == nil,
            "unavailable_reason": unavailableReason ?? NSNull(),
        ]
        return httpResponse(status: "200 OK", body: jsonObject(body))
    }

    func book(_ request: HTTPRequestMessage, _ rest: String) async -> Data {
        let parts = rest.split(separator: "/").map(String.init)
        guard let id = parts.first, FileStore.sanitize(id) != nil else {
            return httpErrorResponse(status: "400 Bad Request", message: "bad book id")
        }
        switch (request.method.uppercased(), parts.count) {
        case ("GET", 1):
            guard let job = store.load(id) else { return notFound() }
            return json(store.summary(of: job))
        case ("GET", 2) where parts[1] == "book":
            // A device that did not send the book adopts it from this: the chapter
            // words for read-along, and the shaped book Render Again starts from.
            guard let job = store.load(id), let data = try? job.book.encoded() else { return notFound() }
            return httpResponse(status: "200 OK", contentType: "application/json", payload: data)
        case ("GET", 2) where parts[1] == "export.m4b":
            return await export(id)
        case ("GET", 2) where parts[1] == "cover":
            return cover(id)
        case ("DELETE", 2) where parts[1] == "cover":
            return removeCover(id)
        case ("GET", 3) where parts[1] == "chapters":
            return chapter(id, parts[2])
        case ("GET", 4) where parts[1] == "chapters" && parts[3] == "timing":
            return timing(id, parts[2])
        case ("POST", 2) where parts[1] == "finished":
            guard let renderer, await renderer.markFinished(id) else { return notFound() }
            return httpResponse(status: "200 OK", body: #"{"ok":true}"#)
        case ("DELETE", 1):
            if let renderer { await renderer.cancel(id) } else { store.remove(id) }
            return httpResponse(status: "200 OK", body: #"{"ok":true}"#)
        default:
            return notFound()
        }
    }

    func chapter(_ id: String, _ number: String) -> Data {
        guard let job = store.load(id), let n = Int(number), n >= 1, n <= job.chapters.count else { return notFound() }
        guard case let .ready(file, _, seconds, sha) = job.chapters[n - 1],
              let url = store.chapterURL(id, file: file), let payload = try? Data(contentsOf: url) else {
            return httpErrorResponse(status: "409 Conflict", message: "chapter \(n) is not ready")
        }
        let title = job.book.chapters[n - 1].title
        return httpResponse(status: "200 OK", contentType: "audio/mp4", payload: payload, extraHeaders: [
            "X-Baton-SHA256": sha,
            "X-Baton-Duration": String(format: "%.3f", seconds),
            "X-Baton-Name": "\(job.book.title) - \(n). \(title)",
        ])
    }

    /// A ready chapter's read-along timing. 404 for a chapter made before this
    /// gateway kept timing, which a client reads as "show the text without a highlight", the
    /// same answer an older gateway gives for the whole route.
    func timing(_ id: String, _ number: String) -> Data {
        guard let job = store.load(id), let n = Int(number), n >= 1, n <= job.chapters.count else { return notFound() }
        guard case let .ready(file, _, _, _) = job.chapters[n - 1] else {
            return httpErrorResponse(status: "409 Conflict", message: "chapter \(n) is not ready")
        }
        guard let timing = store.chapterTiming(id, file: file), let data = try? timing.encoded() else {
            return httpErrorResponse(status: "404 Not Found", message: "no timing for chapter \(n)")
        }
        return httpResponse(status: "200 OK", contentType: "application/json", payload: data)
    }

    /// The whole book as one `.m4b`, made on request into a temporary file and removed once
    /// read, so it never counts against the books' space.
    func export(_ id: String) async -> Data {
        guard let job = store.load(id), let dir = store.jobDirectory(id) else { return notFound() }
        guard let exporter else {
            return httpErrorResponse(status: "503 Service Unavailable", message: unavailableReason ?? "export is not available on this gateway")
        }
        guard let files = AudiobookExport.chapterFiles(job), let marks = AudiobookExport.marks(job) else {
            let ready = job.chapters.filter { if case .ready = $0 { return true } else { return false } }.count
            return httpErrorResponse(status: "409 Conflict", message: "\(ready) of \(job.chapters.count) chapters are ready; the audiobook is made when all are")
        }
        let urls = files.map { dir.appendingPathComponent($0) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return httpErrorResponse(status: "409 Conflict", message: "a chapter file is missing; render the book again")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("baton-export-\(UUID().uuidString).m4b")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            try await exporter.exportM4B(chapters: urls, book: job.book, marks: marks, to: out)
        } catch {
            return httpErrorResponse(status: "500 Internal Server Error", message: "the audiobook could not be made: \(error)")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
        guard size <= Self.maximumExportBytes else {
            return httpErrorResponse(status: "413 Payload Too Large", message: "this book is too long to export in one file; download its chapters")
        }
        guard let payload = try? Data(contentsOf: out) else {
            return httpErrorResponse(status: "500 Internal Server Error", message: "the audiobook could not be read back")
        }
        return httpResponse(status: "200 OK", contentType: "audio/mp4", payload: payload, extraHeaders: [
            "X-Baton-SHA256": SHA256Digest.hex(of: payload),
            "X-Baton-Name": AudiobookExport.fileName(job.book),
            "Content-Disposition": "attachment; filename=\"\(AudiobookExport.fileName(job.book).replacingOccurrences(of: "\"", with: ""))\"",
        ])
    }

    /// The streamed `PUT`. Authenticated here, after staging, exactly as file uploads are
    /// (`GatewayRoutes.handleUpload` explains why that order is safe); the staged file is
    /// removed on every path out.
    public func handleUpload(_ request: StreamingUpload.Request, _ staged: URL, token: String) async -> Data {
        defer { try? FileManager.default.removeItem(at: staged) }
        guard BatonMCPAuth.constantTimeEquals(request.bearerToken ?? "", token) else {
            return httpErrorResponse(status: "401 Unauthorized", message: "bad token")
        }
        let parts = request.path.dropFirst("/v1/books/".count).split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = parts.first, let clean = FileStore.sanitize(first), clean.count == 64 else {
            return httpErrorResponse(status: "400 Bad Request", message: "bad book id")
        }
        switch parts.count {
        case 1: break
        case 2 where parts[1] == "upload":
            return receiveBook(staged, id: clean)
        case 2 where parts[1] == "cover":
            return receiveCover(request, staged, id: clean)
        case 3 where parts[1] == "chapters":
            return receiveChapter(request, staged, id: clean, number: parts[2])
        case 4 where parts[1] == "chapters" && parts[3] == "timing":
            return receiveTiming(request, staged, id: clean, number: parts[2])
        default:
            return notFound()
        }
        guard let renderer else {
            return httpErrorResponse(status: "503 Service Unavailable",
                                     message: unavailableReason ?? "book rendering is not configured")
        }
        let book: PreparedBook
        do {
            book = try PreparedBook.decode(try Data(contentsOf: staged))
        } catch PreparedBookError.unsupportedSchema(let version) {
            return httpErrorResponse(status: "422 Unprocessable Entity",
                                     message: "this gateway does not know book format \(version); update it")
        } catch {
            return httpErrorResponse(status: "400 Bad Request", message: "body is not a prepared book")
        }
        guard BookJob.id(for: book) == clean else {
            return httpErrorResponse(status: "400 Bad Request", message: "book id does not match its content")
        }
        if store.load(clean) == nil {
            let estimate = ListeningEstimate(words: book.chapters.flatMap(\.segments)
                .reduce(0) { $0 + $1.text.split(separator: " ").count }, speed: book.voices.speed,
                bitrate: book.audio.bitrate).bytes
            guard store.hasRoom(for: estimate) else {
                return httpErrorResponse(status: "507 Insufficient Storage", message:
                    "the home server's space for books is full of unfinished books; finish or delete one first")
            }
        }
        do {
            switch try await renderer.submit(book, id: clean) {
            case let .created(summary): return json(summary, status: "201 Created")
            case let .existing(summary): return json(summary)
            }
        } catch {
            return httpErrorResponse(status: "500 Internal Server Error", message: "could not store the book")
        }
    }

    // MARK: - Books made on another device

    /// `PUT /v1/books/{id}/upload`: a book the Mac made with its own voices, so the other devices
    /// adopt it through the listing as they adopt one made here. Kept as a job the
    /// render loop never touches, every chapter queued until its audio arrives. The same book
    /// again finds the job already there, whichever way it came. Needs only the store, so a
    /// gateway that cannot make books (no ffmpeg) still keeps one made elsewhere.
    func receiveBook(_ staged: URL, id: String) -> Data {
        let book: PreparedBook
        do {
            book = try PreparedBook.decode(try Data(contentsOf: staged))
        } catch PreparedBookError.unsupportedSchema(let version) {
            return httpErrorResponse(status: "422 Unprocessable Entity",
                                     message: "this gateway does not know book format \(version); update it")
        } catch {
            return httpErrorResponse(status: "400 Bad Request", message: "body is not a prepared book")
        }
        guard BookJob.id(for: book) == id else {
            return httpErrorResponse(status: "400 Bad Request", message: "book id does not match its content")
        }
        Self.uploadLock.lock()
        defer { Self.uploadLock.unlock() }
        if let existing = store.load(id) { return json(store.summary(of: existing)) }
        let estimate = ListeningEstimate(words: book.chapters.flatMap(\.segments)
            .reduce(0) { $0 + $1.text.split(separator: " ").count }, speed: book.voices.speed,
            bitrate: book.audio.bitrate).bytes
        guard store.hasRoom(for: estimate) else {
            return httpErrorResponse(status: "507 Insufficient Storage", message:
                "the home server's space for books is full of unfinished books; finish or delete one first")
        }
        var job = BookJob(id: id, book: book)
        job.uploaded = true
        do { try store.save(job) } catch {
            return httpErrorResponse(status: "500 Internal Server Error", message: "could not store the book")
        }
        return json(store.summary(of: job), status: "201 Created")
    }

    /// `PUT /v1/books/{id}/chapters/{n}`: one chapter's M4A for an uploaded book, kept only when
    /// its digest matches `X-Baton-SHA256`, so a chapter damaged on the way is never handed to
    /// another device. The same audio again changes nothing. The last chapter makes the book ready.
    func receiveChapter(_ request: StreamingUpload.Request, _ staged: URL, id: String, number: String) -> Data {
        guard let expected = request.header("X-Baton-SHA256")?.lowercased(),
              expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            return httpErrorResponse(status: "400 Bad Request", message: "X-Baton-SHA256 is required")
        }
        guard let seconds = request.header("X-Baton-Duration").flatMap(Double.init), seconds.isFinite,
              seconds > 0, seconds <= Self.maximumChapterSeconds else {
            return httpErrorResponse(status: "400 Bad Request", message: "X-Baton-Duration is required")
        }
        guard let actual = try? SHA256Digest.hex(ofFileAt: staged), actual == expected else {
            return httpErrorResponse(status: "422 Unprocessable Entity", message: "the chapter arrived damaged; send it again")
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: staged.path))?[.size] as? Int) ?? 0
        Self.uploadLock.lock()
        defer { Self.uploadLock.unlock() }
        let found = uploadedJob(id, number)
        guard case .found(var job, let index) = found else { return found.refusal }
        if case let .ready(_, _, _, sha) = job.chapters[index], sha == actual { return json(store.summary(of: job)) }
        store.prune()
        guard store.usedBytes + bytes <= store.maximumBytes else {
            return httpErrorResponse(status: "507 Insufficient Storage", message:
                "the home server's space for books is full of unfinished books; finish or delete one first")
        }
        guard let dir = store.jobDirectory(id) else { return notFound() }
        let file = "chapter-\(index + 1).m4a"
        let destination = dir.appendingPathComponent(file)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch {
            return httpErrorResponse(status: "500 Internal Server Error", message: "could not keep the chapter")
        }
        job.chapters[index] = .ready(file: file, bytes: bytes, seconds: seconds, sha256: actual)
        job.status = job.readyChapters == job.chapters.count ? .ready : .rendering
        job.updatedAt = Date()
        do { try store.save(job) } catch {
            return httpErrorResponse(status: "500 Internal Server Error", message: "could not store the book")
        }
        return json(store.summary(of: job))
    }

    /// `PUT /v1/books/{id}/chapters/{n}/timing`: the read-along timing of an uploaded book's
    /// chapter, sent before its audio so the chapter is never ready without it.
    func receiveTiming(_ request: StreamingUpload.Request, _ staged: URL, id: String, number: String) -> Data {
        guard request.contentLength <= Self.maximumTimingBytes,
              let data = try? Data(contentsOf: staged), data.count <= Self.maximumTimingBytes else {
            return httpErrorResponse(status: "413 Payload Too Large", message: "that is too large to be read-along timing")
        }
        guard let timing = ReadAlongTiming.decode(data), let encoded = try? timing.encoded() else {
            return httpErrorResponse(status: "400 Bad Request", message: "body is not read-along timing")
        }
        Self.uploadLock.lock()
        defer { Self.uploadLock.unlock() }
        let found = uploadedJob(id, number)
        guard case .found(_, let index) = found else { return found.refusal }
        guard let dir = store.jobDirectory(id),
              let name = ReadAlongTiming.fileName(forChapterFile: "chapter-\(index + 1).m4a") else { return notFound() }
        do {
            try encoded.write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch {
            return httpErrorResponse(status: "500 Internal Server Error", message: "could not keep the timing")
        }
        return httpResponse(status: "200 OK", body: #"{"ok":true}"#)
    }

    // MARK: - Covers

    /// `PUT /v1/books/{id}/cover`: the book's cover, for any book this home server keeps, made
    /// here or uploaded. The device re-encoded it (`BookCoverImaging.sanitize`); here it is only
    /// checked: no larger than a cover, a JPEG or PNG by its own signature, and exactly the bytes
    /// `X-Baton-SHA256` names. It is never decoded on the gateway.
    func receiveCover(_ request: StreamingUpload.Request, _ staged: URL, id: String) -> Data {
        guard request.contentLength <= BookCoverImage.maximumBytes,
              let data = try? Data(contentsOf: staged), !data.isEmpty, data.count <= BookCoverImage.maximumBytes else {
            return httpErrorResponse(status: "413 Payload Too Large", message: "that is too large to be a cover")
        }
        guard let kind = BookCoverImage.kind(of: data) else {
            return httpErrorResponse(status: "415 Unsupported Media Type", message: "a cover is a JPEG or a PNG")
        }
        guard let expected = request.header("X-Baton-SHA256")?.lowercased(), expected == SHA256Digest.hex(of: data) else {
            return httpErrorResponse(status: "422 Unprocessable Entity", message: "the cover arrived damaged; send it again")
        }
        Self.uploadLock.lock()
        defer { Self.uploadLock.unlock() }
        guard store.load(id) != nil else { return notFound() }
        if let current = store.cover(of: id), current.sha256 == expected { return json(current) }
        do {
            return json(try store.setCover(data, kind: kind, of: id), status: "201 Created")
        } catch {
            return httpErrorResponse(status: "500 Internal Server Error", message: "could not keep the cover")
        }
    }

    /// `GET /v1/books/{id}/cover`: the cover's bytes with their digest, for a device to check.
    func cover(_ id: String) -> Data {
        guard let image = store.coverImage(of: id) else {
            return httpErrorResponse(status: "404 Not Found", message: "this book has no cover")
        }
        return httpResponse(status: "200 OK", contentType: image.kind.mimeType, payload: image.data,
                            extraHeaders: ["X-Baton-SHA256": SHA256Digest.hex(of: image.data)])
    }

    /// `DELETE /v1/books/{id}/cover`: the cover goes, and the record that it went stays, so the
    /// other devices remove theirs on their next look.
    func removeCover(_ id: String) -> Data {
        Self.uploadLock.lock()
        defer { Self.uploadLock.unlock() }
        guard store.load(id) != nil else { return notFound() }
        if let current = store.cover(of: id), current.isRemoved { return json(current) }
        do {
            return json(try store.removeCover(of: id))
        } catch {
            return httpErrorResponse(status: "500 Internal Server Error", message: "could not remove the cover")
        }
    }

    private enum UploadTarget {
        case found(BookJob, chapterIndex: Int)
        /// No such book, or no such chapter in it.
        case missing
        /// A book this gateway makes itself: its chapters are not taken from elsewhere.
        case madeHere

        var refusal: Data {
            switch self {
            case .found, .missing: return httpErrorResponse(status: "404 Not Found", message: "no such book")
            case .madeHere: return httpErrorResponse(status: "409 Conflict", message: "the Baton server makes this book itself")
            }
        }
    }

    /// The uploaded job and the 0-based index of chapter `number` (1-based) in it.
    private func uploadedJob(_ id: String, _ number: String) -> UploadTarget {
        guard let job = store.load(id) else { return .missing }
        guard job.uploaded == true else { return .madeHere }
        guard let n = Int(number), n >= 1, n <= job.chapters.count else { return .missing }
        return .found(job, chapterIndex: n - 1)
    }

    func preview(_ request: HTTPRequestMessage) async -> Data {
        guard let synthesizer else {
            return httpErrorResponse(status: "503 Service Unavailable", message: unavailableReason ?? "no TTS host")
        }
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let text = body["text"] as? String, !text.isEmpty, let voice = body["voice"] as? String else {
            return httpErrorResponse(status: "400 Bad Request", message: "text and voice are required")
        }
        guard text.count <= Self.maximumPreviewCharacters else {
            return httpErrorResponse(status: "413 Payload Too Large",
                                     message: "a preview is at most \(Self.maximumPreviewCharacters) characters")
        }
        do {
            let wav = try await synthesizer.synthesize(text: SecretRedactor.redact(text), voice: voice,
                                                       speed: body["speed"] as? Double)
            return httpResponse(status: "200 OK", contentType: "audio/wav", payload: wav)
        } catch let error as SynthesisError {
            if case .permanent = error { return httpErrorResponse(status: "400 Bad Request", message: error.description) }
            return httpErrorResponse(status: "502 Bad Gateway", message: error.description)
        } catch {
            return httpErrorResponse(status: "502 Bad Gateway", message: String(describing: error))
        }
    }

    /// `GET /v1/voices`: `GatewayVoiceList`, so the phone can offer the Mac's narrators. Not tied
    /// to book rendering being on: a gateway without ffmpeg still knows its voice server.
    func voiceList() async -> Data {
        guard let voices else {
            return httpErrorResponse(status: "503 Service Unavailable", message: "no voice server is configured")
        }
        let list = await voices.list()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return httpResponse(status: "200 OK", contentType: "application/json",
                            payload: (try? encoder.encode(list)) ?? Data("{}".utf8))
    }

    // MARK: - Helpers

    private func notFound() -> Data { httpErrorResponse(status: "404 Not Found", message: "no such book") }

    private func json<T: Encodable>(_ value: T, status: String = "200 OK") -> Data {
        let data = (try? BookJSON.encoder.encode(value)) ?? Data("{}".utf8)
        return httpResponse(status: status, contentType: "application/json", payload: data)
    }
}
