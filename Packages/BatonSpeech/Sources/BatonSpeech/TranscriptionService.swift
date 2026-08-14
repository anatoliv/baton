import Foundation
import BatonSubsonicModels

/// Turns a spoken track into a timed `Transcript` by calling an OpenAI-compatible
/// `/v1/audio/transcriptions` endpoint — a self-hosted Whisper on the LAN.
///
/// The mirror image of `SpeechService`, and deliberately built the same way: resolve a
/// configured base URL, build a `URLRequest`, validate the `HTTPURLResponse`, surface typed
/// errors. The differences are the two that long audio forces — a multipart body streamed
/// from a file rather than a JSON blob held in memory, and a retry policy that knows a
/// re-send costs an entire upload.
///
/// Why the recognizer is on a server at all: the apps deploy to macOS 15 / iOS 18, which
/// predates `SpeechAnalyzer`, and `SFSpeechRecognizer` is shaped for push-to-talk rather
/// than for an hour of audio. See `specs/track-transcription.md`.
public enum TranscriptionService {
    public struct TranscribeError: Error, LocalizedError, Sendable {
        public let message: String
        /// True when the host simply could not be reached. The UI says "unavailable" for
        /// this and "failed" for everything else — an off-network phone is the normal case,
        /// not a fault, and it must not read like one.
        public let isUnreachable: Bool
        /// True when the recognizer ran fine and simply found nothing worth transcribing —
        /// an instrumental track, silence, crowd noise. Not a fault, and the UI must not
        /// dress it as one.
        public let isEmptyOfSpeech: Bool
        public var errorDescription: String? { message }

        public init(message: String, isUnreachable: Bool = false, isEmptyOfSpeech: Bool = false) {
            self.message = message
            self.isUnreachable = isUnreachable
            self.isEmptyOfSpeech = isEmptyOfSpeech
        }
    }

    /// Generous, because this is the whole point of the wall clock: a 90-minute episode is a
    /// large upload followed by a GPU pass. Short enough that a dead connection still fails
    /// today rather than hanging until someone notices.
    public static let requestTimeout: TimeInterval = 900

    // MARK: - Transcribe

    /// Transcribe an audio file. `trackID` is stamped into the result so the store never has
    /// to guess what it belongs to.
    public static func transcribe(
        fileURL: URL,
        trackID: String,
        language: String? = nil,
        session: URLSession = .shared
    ) async throws -> Transcript {
        let base = SpeechConfig.whisperBaseURL.trimmingCharacters(in: .whitespaces)
        let url = try endpoint(base: base, path: "/v1/audio/transcriptions")
        let model = SpeechConfig.whisperModel

        let boundary = "baton-\(UUID().uuidString)"
        var fields: [(name: String, value: String)] = [
            ("model", model),
            // `verbose_json` is what carries the segment timings. Plain `json` returns text
            // only, and text without timings cannot highlight, cannot seek, and cannot be
            // chunked on real boundaries — three of the four things this feature is for.
            ("response_format", "verbose_json"),
            // Voice-activity detection, and the reason it is not optional: over music or
            // silence Whisper does not fall silent, it *invents*. A track with no speech in
            // it came back as the word "Yeah" repeated down the whole pane. Measured against
            // 45 s of non-speech audio: without this, two hallucinated segments; with it,
            // zero. Servers that don't know the field ignore it (WhisperX 200s either way).
            ("vad_filter", "true"),
        ]
        if let language, !language.isEmpty { fields.append(("language", language)) }

        // Assembled on disk, not in memory. An hour of audio is tens of megabytes and the
        // phone is the constrained device here; `upload(for:fromFile:)` streams it.
        let bodyFile = try writeMultipartBody(fields: fields, fileURL: fileURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Baton (transcription)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = requestTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await uploadWithRetry(request, fromFile: bodyFile, session: session)
        } catch {
            throw TranscribeError(
                message: "Couldn't reach the transcription service at \(base): \(error.localizedDescription)",
                isUnreachable: true
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw TranscribeError(message: "Unexpected response from the transcription service.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw TranscribeError(message: "Transcription service returned HTTP \(http.statusCode). \(detail)")
        }

        let transcript = try parse(data, trackID: trackID, fallbackModel: model)
        speechLog.info("transcribed \(transcript.segments.count) segments for track (synced: \(transcript.synced, privacy: .public))")
        return transcript
    }

    /// Retry only when the connection was never established.
    ///
    /// `SpeechService` retries on timeout and connection-lost too, and that is right for a
    /// sentence of TTS. Here the body may be a hundred megabytes, so re-sending after a
    /// mid-upload failure spends the whole transfer again on a link that just proved itself
    /// unreliable. `cannotConnectToHost` is the one case where nothing was sent and the box
    /// is probably just waking up.
    private static func uploadWithRetry(
        _ request: URLRequest,
        fromFile bodyFile: URL,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.upload(for: request, fromFile: bodyFile)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return try await session.upload(for: request, fromFile: bodyFile)
        }
    }

    // MARK: - Reachability

    /// Ask the host which models it has. Used by Settings to prove the address is right —
    /// a saved host that was never contacted is a setting, not a working feature.
    ///
    /// Tries the OpenAI `/v1/models` path first, then `/models/list`. Not every server that
    /// serves `/v1/audio/transcriptions` also serves the OpenAI model list: WhisperX answers
    /// 404 on `/v1/models` while transcribing perfectly well. Reporting a working host as
    /// unreachable because of a route it never claimed to have would send someone off to debug
    /// their network over nothing.
    public static func availableModels(session: URLSession = .shared) async throws -> [String] {
        let base = SpeechConfig.whisperBaseURL.trimmingCharacters(in: .whitespaces)
        var lastFailure: TranscribeError?

        for path in ["/v1/models", "/models/list"] {
            let url = try endpoint(base: base, path: path)
            var request = URLRequest(url: url)
            request.timeoutInterval = 15

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                // A transport failure is about the host, not the route, so it ends the search.
                throw TranscribeError(
                    message: "Couldn't reach the transcription service at \(base): \(error.localizedDescription)",
                    isUnreachable: true
                )
            }
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                lastFailure = TranscribeError(message: "The transcription host answered, but not with a model list.")
                continue
            }
            if let ids = modelIDs(in: data) { return ids.sorted() }
            lastFailure = TranscribeError(message: "Unexpected model list from the transcription service.")
        }
        throw lastFailure ?? TranscribeError(message: "The transcription host listed no models.")
    }

    /// Pull model ids out of either list shape: OpenAI's `{"data":[{"id":…}]}` or the plainer
    /// `{"models":["large-v3"]}` that WhisperX returns.
    public static func modelIDs(in data: Data) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let raw: [Any]
        if let openAI = obj["data"] as? [Any] {
            raw = openAI
        } else if let plain = obj["models"] as? [Any] {
            raw = plain
        } else {
            return nil
        }
        let ids: [String] = raw.compactMap { element in
            if let s = element as? String { return s }
            if let d = element as? [String: Any] { return (d["id"] as? String) ?? (d["name"] as? String) }
            return nil
        }
        return ids.isEmpty ? nil : ids
    }

    // MARK: - Request shaping (pure, so it is testable without a transport)

    /// Build the multipart body bytes. Split out from the upload so the wire format can be
    /// asserted directly — once the body is streamed from a file, `URLProtocol` stubs can no
    /// longer see it.
    public static func multipartBody(
        fields: [(name: String, value: String)],
        fileName: String,
        fileData: Data,
        boundary: String
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for field in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            append("\(field.value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func writeMultipartBody(
        fields: [(name: String, value: String)],
        fileURL: URL,
        boundary: String
    ) throws -> URL {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw TranscribeError(message: "Couldn't read the audio to transcribe: \(error.localizedDescription)")
        }
        guard !fileData.isEmpty else {
            throw TranscribeError(message: "The audio file is empty, so there is nothing to transcribe.")
        }
        let body = multipartBody(
            fields: fields,
            fileName: fileURL.lastPathComponent,
            fileData: fileData,
            boundary: boundary
        )
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-transcribe-\(UUID().uuidString).multipart")
        do {
            try body.write(to: temp, options: .atomic)
        } catch {
            throw TranscribeError(message: "Couldn't stage the upload: \(error.localizedDescription)")
        }
        return temp
    }

    /// Resolve `base` + `path` the way `SpeechService` does: a host is required, any base path
    /// prefix is preserved, and a trailing slash never produces a double one.
    private static func endpoint(base: String, path: String) throws -> URL {
        guard var comps = URLComponents(string: base), comps.host != nil else {
            throw TranscribeError(
                message: "Invalid transcription host \"\(base)\". Set it in Settings → Speech."
            )
        }
        var basePath = comps.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        comps.path = basePath + path
        guard let url = comps.url else {
            throw TranscribeError(message: "Couldn't build a transcription URL from \"\(base)\".")
        }
        return url
    }

    // MARK: - Response parsing (pure)

    /// Whether what came back is too little of the track to be a transcript of it.
    ///
    /// Voice-activity detection throws away everything that isn't speech, which is right, and
    /// over a song it throws away nearly all of it. What survives is a fragment: measured on
    /// "Riders on the Storm", one segment of 1.7 seconds out of 7 minutes 15 — four tenths of
    /// one per cent of the track — reading "Do this as we're born", which is a mangled line of
    /// the lyric. Showing that as *the transcript* claims the track said one wrong sentence
    /// and nothing else.
    ///
    /// A tenth of the running time is far below anything spoken-word: talk covers most of its
    /// duration, and even an interview full of pauses stays well above this. Only applied to
    /// tracks over a minute, so a short clip is never judged on a ratio.
    public static func isTooSparse(_ segments: [Transcript.Segment], duration: Double?) -> Bool {
        guard let duration, duration > 60 else { return false }
        let covered = segments.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        return covered / duration < 0.10
    }

    /// Whether a transcript is the recognizer looping rather than reporting speech.
    ///
    /// Belt to VAD's braces: a server without voice-activity detection, or one whose VAD
    /// lets a little through, returns the same line over and over. Ten segments that are
    /// almost all the same short string is not a transcript of anything, and showing it as
    /// one is worse than saying nothing was found — it looks like the feature works and
    /// like the track said "Yeah" four hundred times.
    ///
    /// Deliberately conservative: real speech repeats too ("Yeah." "Yeah." "Right.") so this
    /// only fires when nearly every segment is identical AND the repeated line is short.
    public static func isDegenerate(_ segments: [Transcript.Segment]) -> Bool {
        guard segments.count >= 10 else { return false }
        let normalized = segments.map {
            $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…"))
        }
        let unique = Set(normalized)
        guard let commonest = unique.max(by: { a, b in
            normalized.filter { $0 == a }.count < normalized.filter { $0 == b }.count
        }) else { return false }
        let share = Double(normalized.filter { $0 == commonest }.count) / Double(normalized.count)
        // A long repeated line is more likely a real refrain than a decoding loop.
        return share >= 0.8 && commonest.count <= 40
    }

    /// Find the segment array, whichever shape the server used.
    ///
    /// OpenAI's `verbose_json` puts it at the top level. WhisperX nests it a level deeper as
    /// `segments.segments`, alongside a `word_segments` sibling. Both were seen on the same
    /// machine, so this reads the shape rather than the vendor: without it a WhisperX server
    /// falls through to the plain-text branch and every timing is silently lost, which costs
    /// the highlight, tap-to-seek, and summarizing on real boundaries.
    public static func segmentArray(in root: [String: Any]) -> [[String: Any]]? {
        if let flat = root["segments"] as? [[String: Any]] { return flat }
        if let nested = root["segments"] as? [String: Any] {
            return nested["segments"] as? [[String: Any]]
        }
        return nil
    }

    /// Parse a `verbose_json` transcription response.
    ///
    /// Tolerates a server that returns plain `json` (text, no segments) by keeping the text as
    /// a single unsynced segment. That is worth reading, but it is marked `synced: false` so
    /// nothing downstream pretends to a timing it does not have — an invented timestamp would
    /// seek to the wrong place and look like a bug in the player.
    public static func parse(_ data: Data, trackID: String, fallbackModel: String) throws -> Transcript {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscribeError(message: "The transcription service returned something that isn't JSON.")
        }
        let language = root["language"] as? String
        let duration = root["duration"] as? Double
        let model = (root["model"] as? String) ?? fallbackModel

        if let rawSegments = segmentArray(in: root), !rawSegments.isEmpty {
            let segments: [Transcript.Segment] = rawSegments.compactMap { raw in
                guard let text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      let start = raw["start"] as? Double else { return nil }
                let end = (raw["end"] as? Double) ?? start
                return Transcript.Segment(start: start, end: max(end, start), text: text)
            }
            if isTooSparse(segments, duration: duration) {
                throw TranscribeError(
                    message: "No speech was found in this track.", isEmptyOfSpeech: true
                )
            }
            if isDegenerate(segments) {
                throw TranscribeError(
                    message: "No speech was found in this track.", isEmptyOfSpeech: true
                )
            }
            if !segments.isEmpty {
                return Transcript(
                    trackID: trackID,
                    segments: segments.sorted { $0.start < $1.start },
                    synced: true,
                    language: language,
                    model: model,
                    duration: duration
                )
            }
        }

        let text = (root["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw TranscribeError(
                message: "No speech was found in this track.", isEmptyOfSpeech: true
            )
        }
        return Transcript(
            trackID: trackID,
            segments: [Transcript.Segment(start: 0, end: duration ?? 0, text: text)],
            synced: false,
            language: language,
            model: model,
            duration: duration
        )
    }
}
