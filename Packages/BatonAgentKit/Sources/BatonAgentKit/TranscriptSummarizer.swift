import Foundation
import OSLog
import BatonSubsonicModels

private let summarizerLog = Logger(subsystem: "io.tonebox.baton", category: "TranscriptSummary")

/// Turns a `Transcript` into a `Summary` — one overview plus timestamped sections — by
/// map-reducing it through whatever chat endpoint the natural-language settings point at.
///
/// **Why map-reduce rather than one call.** An hour of speech is around ten thousand words.
/// The local models this is aimed at commonly carry an 8k context, so a single-shot prompt
/// does not merely degrade, it fails. Chunking is not an optimization here; it is the only
/// way the feature works at all on the hardware it targets.
///
/// **Why the chunks are the product.** Summarizing each window yields a titled, timestamped
/// section, and those sections are chapter marks that seek. An overview tells you whether to
/// listen; the sections tell you where. The reduce step is the cheap part.
///
/// **Why there is a consent gate.** `NaturalLanguageConfig.isAgentEnabled` already carries the
/// reasoning: an endpoint receives whatever is sent to it, and pointing it at a model on your
/// own network is what makes that stop mattering. A transcript is the full content of what
/// someone listened to, which is a long way past a song title, so a non-local endpoint has to
/// be agreed to rather than inherited from a setting made for something else.
///
/// See `specs/track-transcription.md`.
public enum TranscriptSummarizer {
    public struct SummaryError: Error, LocalizedError, Sendable {
        public let message: String
        /// True when the only thing standing in the way is consent to use a remote endpoint —
        /// the UI turns this into an explanation and a choice, not a failure.
        public let needsConsent: Bool
        public var errorDescription: String? { message }

        public init(message: String, needsConsent: Bool = false) {
            self.message = message
            self.needsConsent = needsConsent
        }
    }

    /// One window of transcript handed to the model as a unit.
    public struct Chunk: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    /// Target window length. Ten minutes is short enough to fit a small context alongside the
    /// instructions, and long enough that an hour yields six sections rather than sixty.
    public static let defaultWindowSeconds: Double = 600
    /// Hard character ceiling per chunk, independent of the clock. A dense interview can pack
    /// far more words into ten minutes than a lecture, and the context limit is counted in
    /// tokens, not minutes.
    public static let defaultMaxCharacters = 6000

    // MARK: - Chunking (pure)

    /// Split a transcript into windows on **segment boundaries**.
    ///
    /// Never mid-segment: a sentence cut in half summarizes badly and its timestamps stop
    /// meaning anything. A single segment longer than the character ceiling is emitted alone
    /// rather than dropped — losing content silently would be worse than one oversized call.
    ///
    /// `windowSeconds` is a **ceiling, not a target**: a segment that would push the window
    /// past it starts the next one instead of overflowing this one. With segments long
    /// relative to the window that yields short windows, which is the safe direction to err —
    /// an overrun is what breaks a small context.
    public static func chunks(
        from transcript: Transcript,
        windowSeconds: Double = defaultWindowSeconds,
        maxCharacters: Int = defaultMaxCharacters
    ) -> [Chunk] {
        guard !transcript.segments.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var current: [Transcript.Segment] = []
        var currentCharacters = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            chunks.append(Chunk(
                start: first.start,
                end: last.end,
                text: current.map(\.text).joined(separator: " ")
            ))
            current = []
            currentCharacters = 0
        }

        for segment in transcript.segments {
            let wouldExceedClock = current.first.map { segment.end - $0.start > windowSeconds } ?? false
            let wouldExceedSize = currentCharacters + segment.text.count > maxCharacters
            if !current.isEmpty, wouldExceedClock || wouldExceedSize { flush() }
            current.append(segment)
            currentCharacters += segment.text.count
        }
        flush()
        return chunks
    }

    // MARK: - Consent

    /// Whether this endpoint may be sent transcript text without asking first.
    ///
    /// A model on the LAN may; anything else needs explicit agreement, which the caller
    /// passes as `consented`.
    public static func isLocalEndpoint(_ config: RemoteControlSettings.NaturalLanguageConfig) -> Bool {
        guard let host = URLComponents(string: config.baseURL)?.host else { return false }
        return RemoteNaturalLanguage.isPrivate(host)
    }

    // MARK: - Summarize

    /// Summarize a transcript. `consented` records that the person agreed to send this text to
    /// a non-local endpoint; it is ignored when the endpoint is already local.
    public static func summarize(
        _ transcript: Transcript,
        config: RemoteControlSettings.NaturalLanguageConfig,
        consented: Bool = false,
        windowSeconds: Double = defaultWindowSeconds,
        maxCharacters: Int = defaultMaxCharacters,
        session: URLSession = .shared
    ) async throws -> Summary {
        guard !transcript.isEmpty else {
            throw SummaryError(message: "There's no transcript to summarize yet.")
        }
        guard config.isEnabled, !config.baseURL.isEmpty else {
            throw SummaryError(message: "No summarizing model is configured. Set one up in Settings → Remote.")
        }
        guard isLocalEndpoint(config) || consented else {
            throw SummaryError(
                message: "Summarizing sends the whole transcript to \(config.baseURL), which isn't on your network. "
                    + "Point the model at a host on your LAN, or agree to send it.",
                needsConsent: true
            )
        }

        let windows = chunks(from: transcript, windowSeconds: windowSeconds, maxCharacters: maxCharacters)
        guard !windows.isEmpty else {
            throw SummaryError(message: "There's no transcript to summarize yet.")
        }
        summarizerLog.info("summarizing \(windows.count) windows")

        // Sequential, not concurrent: this is usually one small model on one GPU, and firing
        // six requests at it at once makes each slower without finishing any sooner.
        var sections: [Summary.Section] = []
        for window in windows {
            let reply = try await complete(
                system: Self.sectionSystemPrompt,
                user: "Transcript excerpt (\(timestamp(window.start)) to \(timestamp(window.end))):\n\n\(window.text)",
                config: config,
                session: session
            )
            let (title, body) = parseSection(reply)
            sections.append(Summary.Section(start: window.start, end: window.end, title: title, text: body))
        }

        let overview: String
        if sections.count == 1 {
            // One window means the whole thing already fit; a reduce pass over a single
            // section would just paraphrase it back at half the fidelity.
            overview = sections[0].text
        } else {
            let outline = sections
                .map { "[\(timestamp($0.start))] \($0.title): \($0.text)" }
                .joined(separator: "\n\n")
            overview = try await complete(
                system: Self.overviewSystemPrompt,
                user: "Section summaries, in order:\n\n\(outline)",
                config: config,
                session: session
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return Summary(overview: overview, sections: sections, model: config.model)
    }

    // MARK: - Prompts

    static let sectionSystemPrompt = """
    You summarize an excerpt from a spoken-word recording — a podcast, talk, or interview.

    Reply in exactly this shape, and nothing else:
    TITLE: <a short, specific title for this excerpt — under 8 words>
    <two or three sentences saying what was actually discussed>

    Name the concrete things: who spoke, what was claimed, what was decided. Do not editorialize,
    do not say "the speakers discuss", and do not mention that this is an excerpt.
    """

    static let overviewSystemPrompt = """
    You are given ordered section summaries of one spoken-word recording.

    Write a single paragraph of three to five sentences saying what the whole recording covers
    and what someone would take away from it. Do not list the sections back, do not use bullet
    points, and do not refer to "sections" or "the transcript".
    """

    // MARK: - Parsing (pure)

    /// Split a `TITLE: …` reply into its title and body.
    ///
    /// A small model will not always honour the shape, so an untitled reply keeps its text and
    /// gets a placeholder title rather than being discarded — a section with a dull name is
    /// worth more than a hole in the chapter list.
    static func parseSection(_ reply: String) -> (title: String, text: String) {
        let lines = reply.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("title:") })
        else {
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return (title: "Untitled section", text: text)
        }
        let rawTitle = lines[index]
            .trimmingCharacters(in: .whitespaces)
            .dropFirst("title:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines[(index + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? "Untitled section" : rawTitle
        return (title: title, text: body.isEmpty ? title : body)
    }

    /// `h:mm:ss`, or `m:ss` under an hour — how a person reads a position in an episode.
    public static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Transport

    /// One prompt in, one reply out. Deliberately not `RemoteAgent`'s loop: summarizing needs
    /// no tools, no memory, and no multi-turn browsing, and reusing the loop would drag all
    /// three into a job that is a single completion.
    private static func complete(
        system: String,
        user: String,
        config: RemoteControlSettings.NaturalLanguageConfig,
        session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: try RemoteNaturalLanguage.endpoint(for: config))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any]
        switch config.provider {
        case .anthropic:
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            body = [
                "model": config.model,
                "max_tokens": 1024,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        case .openAICompatible:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": config.model,
                "max_tokens": 1024,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            let host = URLComponents(string: config.baseURL)?.host ?? config.baseURL
            throw SummaryError(message: RemoteNaturalLanguage.transportFailure(error, host: host).localizedDescription)
        } catch {
            throw SummaryError(message: "The summarizing model couldn't be reached: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SummaryError(message: "Unexpected response from the summarizing model.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let detail = RemoteNaturalLanguage.errorBody(from: data)
            throw SummaryError(
                message: "The summarizing model returned HTTP \(http.statusCode). \(detail)"
                    + RemoteNaturalLanguage.hint(status: http.statusCode, body: detail)
            )
        }
        guard let text = extractText(data, provider: config.provider), !text.isEmpty else {
            throw SummaryError(message: "The summarizing model replied with nothing usable.")
        }
        return text
    }

    /// Pull the assistant's text out of either dialect's response shape.
    static func extractText(_ data: Data, provider: RemoteControlSettings.LLMProvider) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch provider {
        case .anthropic:
            guard let content = root["content"] as? [[String: Any]] else { return nil }
            let text = content
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return text.isEmpty ? nil : text
        case .openAICompatible:
            guard let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else { return nil }
            return text.isEmpty ? nil : text
        }
    }
}
