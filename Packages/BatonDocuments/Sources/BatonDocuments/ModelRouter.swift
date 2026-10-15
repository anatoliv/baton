import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Every model the person has set up, in the order they prefer, and the rules for which one a
/// task may use (`specs/document-clippings.md`, *Models*; `specs/local-models-on-mac.md`).
///
/// Decided 2026-10-03: all configured sources are used. Each task declares what it needs (how
/// much context, how much of the book it sends); the router skips sources that cannot meet it
/// or have no consent for it, tries the rest in order, and reports which one answered. A source
/// is *local* when it never leaves the person's own machines (Apple's on-device model, a server
/// on this Mac, one on the LAN) and *cloud* otherwise. Cloud sources need consent per provider
/// and per kind of content, because "short excerpts" and "whole chapters" are different things
/// to agree to.
public struct ModelSource: Codable, Sendable, Equatable, Hashable {
    public enum Provider: String, Codable, Sendable {
        /// Apple's Foundation Models. Run by the app (`#available(macOS 26, iOS 26, *)`), not over HTTP.
        case appleOnDevice
        /// Ollama's native API, which is the only one that takes `num_ctx`.
        case ollama
        /// Anything speaking `/chat/completions`: LiteLLM on the home server, LM Studio, OpenAI.
        case openAICompatible
        case anthropic
    }

    /// Stable identity, used for consent: `"ollama|http://127.0.0.1:11434|qwen3.5:4b"`.
    public var id: String { "\(provider.rawValue)|\(baseURL ?? "-")|\(model)" }
    /// What the person reads: "qwen3.5:4b on this Mac", "the home server".
    public var name: String
    public var provider: Provider
    public var baseURL: String?
    public var model: String
    /// The context window to plan against, in tokens. For Ollama it is also what the router
    /// asks for, because Ollama's own default on a 16 GB Mac is 4k and it truncates silently.
    public var contextTokens: Int

    public init(name: String, provider: Provider, baseURL: String?, model: String, contextTokens: Int) {
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.contextTokens = contextTokens
    }

    /// What consent is recorded against: the provider and the host, not the model, so picking
    /// another model from the same provider keeps what the person allowed it
    /// (`"anthropic|api.anthropic.com"`).
    public var consentID: String {
        let host = baseURL.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces))?.host?.lowercased() }
        return "\(provider.rawValue)|\(host ?? baseURL ?? "-")"
    }

    /// Never leaves the person's machines: on-device, or a host on this Mac or the LAN.
    public var isLocal: Bool {
        if provider == .appleOnDevice { return true }
        guard let base = baseURL, let host = URL(string: base)?.host else { return false }
        return Self.isPrivateHost(host)
    }

    /// The same rule as `RemoteNaturalLanguage.isPrivate`, which this package cannot import:
    /// loopback, `.local`, and the private IPv4 ranges, matched as addresses, never as prefixes.
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let v = Int(part), (0...255).contains(v) else { return nil }
            return v
        }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true
        case (100, 64...127): return true   // CGNAT, which is what Tailscale addresses are
        default: return false
        }
    }
}

/// How much of a book a task sends, which is what consent is given for (M4.6). Two kinds,
/// because "short excerpts" and "whole chapters" are different things to agree to:
/// - `excerpt`: the book's opening to suggest a narrator, the names to propose pronunciations
///   for, the dialogue lines a cast sheet is drawn from;
/// - `chapter`: the chapters already heard, for a recap, and whole chapters to cast dialogue.
///
/// Every excerpt and chapter goes through `SecretRedactor` before any prompt is built.
public enum ModelContent: String, Codable, Sendable, CaseIterable {
    case excerpt
    case chapter
}

public struct ModelTask: Sendable, Equatable {
    public var name: String
    public var minimumContextTokens: Int
    public var content: ModelContent
    /// The most a reply may run to, in tokens: `max_tokens`, and `num_predict` for Ollama, so a
    /// model that starts repeating itself stops there instead of running past the timeout.
    public var replyTokens: Int

    public init(name: String, minimumContextTokens: Int, content: ModelContent, replyTokens: Int = 1_024) {
        self.name = name
        self.minimumContextTokens = minimumContextTokens
        self.content = content
        self.replyTokens = replyTokens
    }

    /// The voice suggestion's prompt is about 3,500 characters plus the reply.
    public static let voiceSuggestion = ModelTask(name: "voice suggestion", minimumContextTokens: 2_000, content: .excerpt)
    /// Placing the quotes the rules leave (`DialogueCast.fill`): passages of a chapter around
    /// those quotes, at most about 3,500 tokens with the cast, and a JSON reply of up to 60
    /// answers (8,000 leaves room for a long cast list). Chapter content for consent, like the
    /// recap.
    public static let dialogueCast = ModelTask(name: "dialogue cast", minimumContextTokens: 8_000, content: .chapter, replyTokens: 1_536)
    /// The cast sheet: tag phrases, names and about 6,000 characters of dialogue passages. The
    /// reply is at most 24 people with 4 phrases each; 2,048 tokens leaves room for that.
    public static let castSheet = ModelTask(name: "cast sheet", minimumContextTokens: 6_000, content: .excerpt, replyTokens: 2_048)
    public static let recap = ModelTask(name: "recap", minimumContextTokens: 4_000, content: .chapter)
    /// The pronunciation proposal: the candidate names with one sentence each, about 3,000
    /// characters on the sample, plus a JSON reply.
    public static let pronunciations = ModelTask(name: "pronunciations", minimumContextTokens: 2_000, content: .excerpt)
}

/// Consent the person gave a cloud source, per kind of content.
public struct ModelConsent: Codable, Sendable, Equatable {
    public var granted: Set<String> = []

    public init(granted: Set<String> = []) { self.granted = granted }

    static func key(_ source: ModelSource, _ content: ModelContent) -> String { "\(source.consentID)#\(content.rawValue)" }

    public func allows(_ source: ModelSource, _ content: ModelContent) -> Bool {
        source.isLocal || granted.contains(Self.key(source, content))
    }

    /// This consent plus one more grant, for "Allow once": used for one call, never stored.
    public func granting(_ source: ModelSource, _ content: ModelContent) -> ModelConsent {
        var copy = self
        copy.grant(source, content)
        return copy
    }

    public mutating func grant(_ source: ModelSource, _ content: ModelContent) { granted.insert(Self.key(source, content)) }
    public mutating func revoke(_ source: ModelSource, _ content: ModelContent) { granted.remove(Self.key(source, content)) }
}

public struct ModelRouter: Sendable {
    /// In the person's preference order. The default order is on-device, this Mac, home, cloud.
    public var sources: [ModelSource]
    public var consent: ModelConsent

    public init(sources: [ModelSource], consent: ModelConsent = ModelConsent()) {
        self.sources = sources
        self.consent = consent
    }

    public enum Skip: Equatable, Sendable {
        case contextTooSmall(have: Int, need: Int)
        case needsConsent(ModelContent)
    }

    /// Which sources may run `task`, in order, and why the others may not.
    public func plan(for task: ModelTask) -> (usable: [ModelSource], skipped: [(ModelSource, Skip)]) {
        var usable: [ModelSource] = []
        var skipped: [(ModelSource, Skip)] = []
        for source in sources {
            if source.contextTokens < task.minimumContextTokens {
                skipped.append((source, .contextTooSmall(have: source.contextTokens, need: task.minimumContextTokens)))
            } else if !consent.allows(source, task.content) {
                skipped.append((source, .needsConsent(task.content)))
            } else {
                usable.append(source)
            }
        }
        return (usable, skipped)
    }

    public typealias Executor = @Sendable (_ source: ModelSource, _ system: String, _ user: String) async throws -> String

    /// The task being run while an executor is called, so an executor that can do better than
    /// text for a known task (Apple's on-device model, which generates typed replies with
    /// `@Generable`) can tell which one it is. Nil outside `complete`.
    @TaskLocal public static var currentTask: ModelTask?

    /// The cloud sources `task` skipped only for want of consent: the ones a person could
    /// allow. A source too small for the task is not among them, since allowing it changes
    /// nothing.
    public func awaitingConsent(for task: ModelTask) -> [ModelSource] {
        plan(for: task).skipped.compactMap { source, skip in
            if case .needsConsent = skip { return source }
            return nil
        }
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        /// Each source tried or skipped, with what happened, in order.
        public var attempts: [String]
        public var description: String {
            attempts.isEmpty ? "no model is set up" : attempts.joined(separator: "; ")
        }
    }

    /// Run `task` on the first source that answers. Throws `Failure` listing every source and
    /// what happened to it, which is the "says why" the import sheet shows.
    public func complete(_ task: ModelTask, system: String, user: String,
                         executor: Executor) async throws -> (text: String, source: String) {
        let (usable, skipped) = plan(for: task)
        var attempts = skipped.map { source, skip -> String in
            switch skip {
            case let .contextTooSmall(have, need): return "\(source.name): \(have) tokens of context, needs \(need)"
            case let .needsConsent(content):
                return "\(source.name): not asked, since sending it \(content == .chapter ? "chapters" : "excerpts") is not allowed"
            }
        }
        for source in usable {
            do {
                let text = try await Self.$currentTask.withValue(task) { try await executor(source, system, user) }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, source.name) }
                attempts.append("\(source.name): empty answer")
            } catch {
                attempts.append("\(source.name): \(error)")
            }
        }
        throw Failure(attempts: attempts)
    }
}

/// The app's one model client: build the request, send it, read the answer. Apple's on-device
/// model is not HTTP and is run by the app.
///
/// The router's executor and `TranscriptSummarizer` (BatonAgentKit) both go through here, so
/// the Anthropic and OpenAI-shaped calls exist once (card M4.2b). What differs between them is
/// a choice each caller makes, not a second client: the summarizer keeps the server's own
/// temperature and a two-minute timeout, the router's tasks ask for temperature 0 and wait
/// three minutes.
public enum HTTPModelClient {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notHTTP
        case badURL(String)
        /// The status and the server's own message (`error.message` when it sent one, else the
        /// start of the body).
        case status(Int, String)
        /// Something answered, but not over HTTP.
        case noHTTPResponse
        case unreadable
        /// The reply is empty because a reasoning model spent the whole `max_tokens` budget
        /// thinking (`finish_reason: "length"` with `reasoning_content` and no `content`), which
        /// LM Studio does with Qwen3 on a small budget.
        case reasoningUsedTheBudget

        public var description: String {
            switch self {
            case .notHTTP: return "runs on the device, not over HTTP"
            case let .badURL(url): return "bad address \(url)"
            case let .status(code, body): return "answered \(code): \(body)"
            case .noHTTPResponse: return "did not answer over HTTP"
            case .unreadable: return "answered with something that is not a model reply"
            case .reasoningUsedTheBudget: return "spent its whole reply budget reasoning and never answered"
            }
        }
    }

    /// Where to POST for `source`. Tolerant of the two ways people paste a base URL, the bare
    /// root or the full endpoint copied out of a provider's docs, because appending a second
    /// path to the full one is a 404 that explains nothing. The same rule the agent's settings
    /// have always used (`RemoteNaturalLanguage.endpoint`).
    public static func endpoint(for source: ModelSource) throws -> URL {
        guard source.provider != .appleOnDevice else { throw Failure.notHTTP }
        var base = (source.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let path: String
        switch source.provider {
        case .ollama:
            path = "/api/chat"
        case .openAICompatible:
            if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
            if base.hasSuffix("/v1") { base.removeLast("/v1".count) }
            path = "/v1/chat/completions"
        case .anthropic:
            for suffix in ["/v1/messages", "/v1"] where base.hasSuffix(suffix) {
                base.removeLast(suffix.count)
                break
            }
            path = "/v1/messages"
        case .appleOnDevice:
            throw Failure.notHTTP
        }
        guard let url = URL(string: base + path), url.scheme != nil else { throw Failure.badURL(base + path) }
        return url
    }

    /// The request for one prompt. `apiKey` is sent exactly as given: `nil` means the source has
    /// no key and nothing is sent, while a string (even an empty one) goes in the provider's
    /// header. `temperature: nil` leaves it to the server (Anthropic is always left to it).
    public static func request(for source: ModelSource, system: String, user: String, apiKey: String?,
                               maxTokens: Int = 1_024, timeout: TimeInterval = 180,
                               temperature: Double? = 0) throws -> URLRequest {
        let url = try endpoint(for: source)
        var body: [String: Any]
        switch source.provider {
        case .ollama:
            var options: [String: Any] = ["num_ctx": source.contextTokens, "num_predict": maxTokens]
            if let temperature { options["temperature"] = temperature }
            body = ["model": source.model, "stream": false, "think": false, "options": options,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        case .openAICompatible:
            body = ["model": source.model, "max_tokens": maxTokens,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
            if let temperature { body["temperature"] = temperature }
        case .anthropic:
            body = ["model": source.model, "max_tokens": maxTokens, "system": system,
                    "messages": [["role": "user", "content": user]]]
            // No temperature: neither caller has ever sent Anthropic one, and adding it would
            // change answers that nothing here has measured.
        case .appleOnDevice:
            throw Failure.notHTTP
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if source.provider == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let apiKey {
            if source.provider == .anthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Send `request` and return the reply text, which may be empty: whether an empty answer is
    /// a failure is the caller's call. A transport failure is rethrown as the `URLError` it is,
    /// so a caller can tell a host that is down from a local network macOS is blocking.
    public static func send(_ request: URLRequest, provider: ModelSource.Provider,
                            session: URLSession = .shared) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.noHTTPResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.status(http.statusCode, errorMessage(from: data))
        }
        return try text(from: data, provider: provider)
    }

    /// The server's own words for a failure: `error.message` when the body is the JSON error
    /// shape OpenAI, Anthropic and LiteLLM share, otherwise the first 200 bytes as text.
    public static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return String(data: data.prefix(200), encoding: .utf8) ?? "" }
        return message
    }

    /// The reply text from a response body, whichever dialect it is in.
    public static func text(from data: Data, provider: ModelSource.Provider) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        switch provider {
        case .ollama:
            if let message = json["message"] as? [String: Any], let content = message["content"] as? String { return content }
        case .openAICompatible:
            if let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] {
                let content = message["content"] as? String ?? ""
                if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   choices.first?["finish_reason"] as? String == "length",
                   let reasoning = (message["reasoning_content"] ?? message["reasoning"]) as? String,
                   !reasoning.isEmpty {
                    throw Failure.reasoningUsedTheBudget
                }
                if let content = message["content"] as? String { return content }
            }
        case .anthropic:
            if let blocks = json["content"] as? [[String: Any]] {
                let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                if !text.isEmpty { return text }
            }
        case .appleOnDevice:
            break
        }
        throw Failure.unreadable
    }

    /// An `Executor` for the router over URLSession. `apiKey` looks a source's key up (the app
    /// reads its Keychain), so no key is ever stored in a `ModelSource`.
    public static func executor(session: URLSession = .shared,
                                apiKey: @escaping @Sendable (ModelSource) -> String?) -> ModelRouter.Executor {
        { source, system, user in
            let request = try request(for: source, system: system, user: user, apiKey: apiKey(source),
                                      maxTokens: ModelRouter.currentTask?.replyTokens ?? 1_024)
            return try await send(request, provider: source.provider, session: session)
        }
    }
}
