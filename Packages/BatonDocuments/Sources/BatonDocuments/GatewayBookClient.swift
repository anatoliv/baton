import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The client half of the gateway's book routes (`gateway/README.md`, *Books*), shared by the
/// Mac ("Render on: Home server") and the iPhone, which always renders there (board M5.1).
///
/// One definition of the wire format: it submits the same `PreparedBook` the local renderer
/// takes, under the id the gateway checks (`BookJob.id(for:)`), and reads back the same
/// `BookJob.Summary` the gateway serves. A chapter download is verified against the gateway's
/// `X-Baton-SHA256` before it is handed over, end to end, as every file on that road is.
public struct GatewayBookClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public let baseURL: URL
    public let token: String
    let transport: Transport

    public init(baseURL: URL, token: String, transport: Transport? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GatewayBookError.notHTTP }
            return (data, http)
        }
    }

    // MARK: - Calls

    /// `GET /v1/books`: every book, the space used and allowed, and whether books are on.
    public func list() async throws -> Listing {
        let (data, _) = try await send("GET", "v1/books")
        return try Listing.decode(data)
    }

    /// `PUT /v1/books/{id}`. Returns the job, new or the one already there (a resubmission,
    /// or a second device importing the same file in the same voice).
    public func submit(_ book: PreparedBook) async throws -> BookJob.Summary {
        let id = BookJob.id(for: book)
        let (data, _) = try await send("PUT", "v1/books/\(id)", body: try book.encoded(),
                                       contentType: "application/json")
        return try BookJSON.decoder.decode(BookJob.Summary.self, from: data)
    }

    public func status(_ id: String) async throws -> BookJob.Summary {
        let (data, _) = try await send("GET", "v1/books/\(id)")
        return try BookJSON.decoder.decode(BookJob.Summary.self, from: data)
    }

    /// `GET /v1/books/{id}/book`: the shaped book the job was made from, for a
    /// device that did not send it: its chapter words for read-along, and what Render Again and
    /// pronunciations start from. 404 from a gateway older than the route.
    public func preparedBook(_ id: String) async throws -> PreparedBook {
        let (data, _) = try await send("GET", "v1/books/\(id)/book")
        return try PreparedBook.decode(data)
    }

    /// `GET /v1/books/{id}/chapters/{n}` (1-based), written to `destination` only after its
    /// digest matches the gateway's header. A mismatch throws and leaves nothing behind.
    public func downloadChapter(_ id: String, number: Int, to destination: URL) async throws -> Chapter {
        let (data, response) = try await send("GET", "v1/books/\(id)/chapters/\(number)")
        let digest = SHA256Digest.hex(of: data)
        let expected = response.value(forHTTPHeaderField: "X-Baton-SHA256")
        guard let expected, expected.lowercased() == digest else {
            throw GatewayBookError.digestMismatch(expected: expected, actual: digest)
        }
        try data.write(to: destination, options: .atomic)
        return Chapter(url: destination, sha256: digest, bytes: data.count,
                       seconds: response.value(forHTTPHeaderField: "X-Baton-Duration").flatMap(Double.init),
                       name: response.value(forHTTPHeaderField: "X-Baton-Name"))
    }

    /// `GET /v1/books/{id}/chapters/{n}/timing` (1-based): where each chunk sits in the chapter,
    /// for read-along. Nil when the home server has none: a chapter made before it
    /// kept timing, or a gateway older than the route (both answer 404). Other failures throw.
    public func chapterTiming(_ id: String, number: Int) async throws -> ReadAlongTiming? {
        do {
            let (data, _) = try await send("GET", "v1/books/\(id)/chapters/\(number)/timing")
            return ReadAlongTiming.decode(data)
        } catch GatewayBookError.http(404, _) {
            return nil
        }
    }

    /// `GET /v1/books/{id}/export.m4b`: the whole book as one audiobook with chapter marks,
    /// written to `destination` (the file the person chose) only when its digest matches. The
    /// bytes go to a private temporary file first and are then moved onto `destination`, so no
    /// other file in that folder is touched, whatever name the server suggests. 409 until every
    /// chapter is ready. The server's suggested name comes back in `name`.
    public func exportAudiobook(_ id: String, to destination: URL) async throws -> Chapter {
        let (data, response) = try await send("GET", "v1/books/\(id)/export.m4b")
        let digest = SHA256Digest.hex(of: data)
        let expected = response.value(forHTTPHeaderField: "X-Baton-SHA256")
        guard let expected, expected.lowercased() == digest else {
            throw GatewayBookError.digestMismatch(expected: expected, actual: digest)
        }
        let fm = FileManager.default
        // A private folder on the destination's volume, so the final step is a rename.
        let staging: URL
        if let replacement = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                         appropriateFor: destination, create: true) {
            staging = replacement
        } else {
            staging = fm.temporaryDirectory.appendingPathComponent("baton-export-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("export.m4b")
        try data.write(to: temporary)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        let name = response.value(forHTTPHeaderField: "X-Baton-Name").map { ($0 as NSString).lastPathComponent }
        return Chapter(url: destination, sha256: digest, bytes: data.count, seconds: nil, name: name)
    }

    // MARK: - A book made on this device, for the others

    /// `PUT /v1/books/{id}/upload`: a book this device made itself, so the home server keeps it
    /// for the other devices without making it. Returns the job, new or the one already there,
    /// with the chapters it already has. A gateway older than the route answers 400 or 404.
    public func upload(_ book: PreparedBook) async throws -> BookJob.Summary {
        let id = BookJob.id(for: book)
        let (data, _) = try await send("PUT", "v1/books/\(id)/upload", body: try book.encoded(),
                                       contentType: "application/json")
        return try BookJSON.decoder.decode(BookJob.Summary.self, from: data)
    }

    /// `PUT /v1/books/{id}/chapters/{n}/timing` (1-based): an uploaded chapter's read-along
    /// timing, sent before its audio.
    public func uploadTiming(_ id: String, number: Int, timing: ReadAlongTiming) async throws {
        _ = try await send("PUT", "v1/books/\(id)/chapters/\(number)/timing", body: try timing.encoded(),
                           contentType: "application/json")
    }

    /// `PUT /v1/books/{id}/chapters/{n}` (1-based): an uploaded chapter's audio, with the digest
    /// of exactly the bytes sent, which the home server checks before keeping it. Returns the
    /// job as it stands after.
    public func uploadChapter(_ id: String, number: Int, audio: Data, seconds: Double) async throws -> BookJob.Summary {
        let (data, _) = try await send("PUT", "v1/books/\(id)/chapters/\(number)", body: audio, contentType: "audio/mp4",
                                       headers: ["X-Baton-SHA256": SHA256Digest.hex(of: audio),
                                                 "X-Baton-Duration": String(format: "%.3f", seconds)])
        return try BookJSON.decoder.decode(BookJob.Summary.self, from: data)
    }

    /// `POST /v1/books/{id}/finished`: the listener reached the end; retention starts.
    public func markFinished(_ id: String) async throws {
        _ = try await send("POST", "v1/books/\(id)/finished")
    }

    public func delete(_ id: String) async throws {
        _ = try await send("DELETE", "v1/books/\(id)")
    }

    /// `POST /v1/speech/preview`: a few seconds of `voice` reading `text`, as WAV, for the
    /// import sheet's previews when the device has no TTS of its own (the phone, away from home).
    public func preview(text: String, voice: String, speed: Double? = nil) async throws -> Data {
        var body: [String: Any] = ["text": text, "voice": voice]
        if let speed { body["speed"] = speed }
        let (data, _) = try await send("POST", "v1/speech/preview",
                                       body: try JSONSerialization.data(withJSONObject: body),
                                       contentType: "application/json")
        return data
    }

    /// `GET /v1/voices`: the voices the home server's voice server offers, for the
    /// phone's narrator choice. A gateway from before the route answers 404, which throws
    /// `.http(404, …)` like any other refusal; the caller then keeps the configured default.
    public func voices() async throws -> GatewayVoiceList {
        let (data, _) = try await send("GET", "v1/voices")
        do { return try JSONDecoder().decode(GatewayVoiceList.self, from: data) } catch { throw GatewayBookError.unreadable }
    }

    // MARK: - Types

    public struct Chapter: Sendable, Equatable {
        public var url: URL
        public var sha256: String
        public var bytes: Int
        public var seconds: Double?
        public var name: String?
    }

    /// `GET /v1/books`'s answer.
    public struct Listing: Sendable, Equatable {
        public var books: [BookJob.Summary]
        public var usedBytes: Int
        public var maximumBytes: Int
        public var keepFinishedDays: Int
        public var available: Bool
        public var unavailableReason: String?

        static func decode(_ data: Data) throws -> Listing {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GatewayBookError.unreadable
            }
            let books = try ((json["books"] as? [Any]) ?? []).map { item -> BookJob.Summary in
                try BookJSON.decoder.decode(BookJob.Summary.self, from: JSONSerialization.data(withJSONObject: item))
            }
            return Listing(books: books, usedBytes: json["used_bytes"] as? Int ?? 0,
                           maximumBytes: json["maximum_bytes"] as? Int ?? 0,
                           keepFinishedDays: json["keep_finished_days"] as? Int ?? 0,
                           available: json["available"] as? Bool ?? false,
                           unavailableReason: json["unavailable_reason"] as? String)
        }
    }

    // MARK: - Transport

    func request(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil,
                 headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    func send(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil,
              headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport(request(method, path, body: body, contentType: contentType, headers: headers))
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw GatewayBookError.http(status: response.statusCode,
                                        message: message ?? String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return (data, response)
    }
}

/// `GET /v1/voices`'s answer, one definition for the gateway that writes it and
/// the client that reads it.
///
///     {"voices": [{"spec": "kokoro:af_heart", "engine": "kokoro", "id": "af_heart", "language": "en"}, …],
///      "sources": {"kokoro": "server"}}
///
/// `spec` is what a `VoicePlan` names. `language` is there when the id says it (Kokoro's
/// prefixes), absent otherwise (a Chatterbox reference file). `sources` says, per engine, where
/// the list came from: "server" (the voice server's own `/v1/audio/voices`), "built-in" (it did
/// not answer, so the Kokoro voices the gateway knows), or "unavailable" (no list at all).
public struct GatewayVoiceList: Codable, Sendable, Equatable {
    public struct Voice: Codable, Sendable, Equatable {
        public var spec: String
        public var engine: String
        public var id: String
        public var language: String?

        public init(engine: String, id: String, language: String?) {
            self.spec = "\(engine):\(id)"
            self.engine = engine
            self.id = id
            self.language = language
        }
    }

    public var voices: [Voice]
    public var sources: [String: String]

    public init(voices: [Voice], sources: [String: String]) {
        self.voices = voices
        self.sources = sources
    }

    /// The `"engine:voice"` specs, which is what `VoiceCatalogue` and `VoiceCaster` take.
    public var specs: [String] { voices.map(\.spec) }
}

public enum GatewayBookError: Error, Equatable, CustomStringConvertible {
    case notHTTP
    case unreadable
    case http(status: Int, message: String)
    case digestMismatch(expected: String?, actual: String)

    public var description: String {
        switch self {
        case .notHTTP: return "the Baton server's answer was not HTTP"
        case .unreadable: return "the Baton server answered with something Baton can't read"
        case let .http(status, message): return "the Baton server answered \(status): \(message)"
        case let .digestMismatch(expected, actual):
            return "a chapter arrived damaged (expected \(expected ?? "a digest"), got \(actual))"
        }
    }

    /// The same, in a listener's words, for a status line.
    public var listenerReason: String {
        switch self {
        case .http(401, _): return "the Baton server didn't accept Baton's token"
        case .http(507, _): return "the Baton server is out of space for books"
        case .http(503, _): return "books are off on the Baton server"
        case .digestMismatch: return "a chapter arrived damaged and will be fetched again"
        default: return "the Baton server isn't answering"
        }
    }
}
