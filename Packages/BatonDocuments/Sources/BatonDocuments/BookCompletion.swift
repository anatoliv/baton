import Foundation

/// `POST /v1/books/complete`: one book task (a recap, a question about the book)
/// answered by the home server's own model, for a phone that reaches a model only through the
/// home server. The gateway answers only when its model is on the home network and refuses, with
/// the reason, when it is a cloud one, so book text never leaves the person's machines this way.
///
/// The phone reaches it as a `ModelSource` with `provider: .homeServer`, through
/// `HTTPModelClient` like any other model, so `ModelRouter` tries it in its place and moves on
/// when it refuses. A gateway without the route answers 404, which the router records as one
/// more source that did not answer.
///
///     POST /v1/books/complete    Authorization: Bearer <gateway token>
///     {"system": "...", "user": "...", "max_tokens": 1024}
///     200 {"text": "...", "model": "qwen3:8b"}
///     403 the gateway's model is a cloud one; 503 none is set up; 413 too long; 400 bad body;
///     502 the model failed or said nothing; 504 it took longer than `modelTimeout`.
public enum BookCompletion {
    public static let path = "/v1/books/complete"
    /// The system and user prompts together. A recap's prompt is at most about 6,000 characters
    /// of heard text (`Recap.window`) plus notes, and a question's passages about 4,000, so this
    /// leaves room without letting a request hand the home server's model a whole book.
    public static let maximumCharacters = 32_000
    /// The most a reply may ask for: a recap is 80 words, a cast sheet's reply 2,048 tokens.
    public static let maximumReplyTokens = 2_048
    /// How long the home server waits for its model. The phone waits longer
    /// (`HTTPModelClient.request`'s three minutes), so the gateway's answer arrives first.
    public static let modelTimeout: TimeInterval = 120
    /// The context the phone plans against: the gateway's model is unknown to it, and every
    /// book task fits in 8,000 tokens.
    public static let contextTokens = 8_192

    /// The home server as a model source, at the address and with the token the phone already
    /// uses for books.
    public static func source(gatewayURL: String) -> ModelSource {
        ModelSource(name: "your Baton server", provider: .homeServer, baseURL: gatewayURL,
                    model: "home-server", contextTokens: contextTokens)
    }

    /// The request body.
    public struct Request: Codable, Sendable, Equatable {
        public var system: String
        public var user: String
        public var maxTokens: Int?

        public init(system: String, user: String, maxTokens: Int? = nil) {
            self.system = system
            self.user = user
            self.maxTokens = maxTokens
        }

        enum CodingKeys: String, CodingKey {
            case system, user
            case maxTokens = "max_tokens"
        }
    }

    /// The answer: the reply text and which model wrote it.
    public struct Response: Codable, Sendable, Equatable {
        public var text: String
        public var model: String

        public init(text: String, model: String) {
            self.text = text
            self.model = model
        }
    }
}

/// The words for consent to cloud models (M4.6), shared so the phone asks in the Mac's terms.
/// `providerName` and `whatIsSent` are the Mac's `CloudModelConsent` sentences, word for word.
public enum ModelConsentWording {
    /// The provider as a person knows it: "Anthropic", or the host of an OpenAI-compatible one.
    public static func providerName(_ source: ModelSource) -> String {
        if source.provider == .anthropic { return "Anthropic" }
        if let host = source.baseURL.flatMap({ URL(string: $0)?.host }) {
            return host == "api.openai.com" ? "OpenAI" : host
        }
        return source.name
    }

    /// The switch's title for each kind of content.
    public static func title(_ content: ModelContent) -> String {
        switch content {
        case .excerpt: "Short excerpts"
        case .chapter: "Chapters"
        }
    }

    /// One plain sentence of what goes to that source when it is allowed.
    public static func whatIsSent(_ content: ModelContent, to source: ModelSource) -> String {
        let provider = providerName(source)
        switch content {
        case .excerpt:
            return "The book's opening to suggest a narrator, and the names a voice might stumble on, go to \(provider) as short excerpts with anything that looks like a password or key taken out first."
        case .chapter:
            return "The chapters you have already heard go to \(provider) to write a recap, with anything that looks like a password or key taken out first. Nothing past where you are is sent."
        }
    }

    /// The first time only a cloud source could write a recap: "Send the chapters you have heard
    /// to Anthropic to write a recap?"
    public static func recapQuestion(_ source: ModelSource) -> String {
        "Send the chapters you have heard to \(providerName(source)) to write a recap?"
    }

    /// `device` is "iPhone" or "Mac"; `settings` is where the answer can be changed.
    public static func recapQuestionDetail(_ source: ModelSource, device: String, settings: String) -> String {
        "Nothing on this \(device), your network or the Baton server could write one. "
            + whatIsSent(.chapter, to: source)
            + " Always lets chapters go there for later recaps too. You can change this any time in \(settings)."
    }
}
