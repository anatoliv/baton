import BatonDocuments
import BatonMCPProtocol
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `POST /v1/books/complete` (TBX-10966, the contract is `BookCompletion` in BatonDocuments):
/// one book task answered by this gateway's own model, for a phone that reaches a model only
/// through the home server.
///
/// It answers only when that model is on the home network, by the apps' own rule
/// (`ModelSource.isLocal`: loopback, `.local`, private and CGNAT/Tailscale addresses), or when the
/// operator says so with `BATON_LLM_LOCAL=1` for a name the rule cannot read, like a Docker
/// service or a bare host name. A cloud model is refused with the reason, since the phone asked
/// nobody about sending it chapters. Bounded: `BookCompletion.maximumCharacters` in,
/// `maximumReplyTokens` out, `modelTimeout` to answer.
public struct BookCompletionRoute: Sendable {
    /// Calls the model: the source, the system and user prompts, and the reply budget.
    public typealias Complete = @Sendable (ModelSource, String, String, Int) async throws -> String

    /// The gateway's model (`BATON_LLM_*`); nil when none is set up.
    public let source: ModelSource?
    /// `BATON_LLM_LOCAL=1`: the operator's word that the model is on the home network.
    public let declaredLocal: Bool
    public let timeout: TimeInterval
    let complete: Complete

    public init(source: ModelSource?, apiKey: String?, declaredLocal: Bool = false,
                timeout: TimeInterval = BookCompletion.modelTimeout, complete: Complete? = nil) {
        self.source = source
        self.declaredLocal = declaredLocal
        self.timeout = timeout
        self.complete = complete ?? { source, system, user, maxTokens in
            let request = try HTTPModelClient.request(for: source, system: system, user: user, apiKey: apiKey,
                                                      maxTokens: maxTokens, timeout: timeout)
            return try await HTTPModelClient.send(request, provider: source.provider)
        }
    }

    /// The gateway's agent settings as a source: Anthropic or an OpenAI-compatible server, at the
    /// configured address. Nil without a model or an address.
    public static func source(provider: String?, baseURL: String, model: String) -> ModelSource? {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        let name = model.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !name.isEmpty else { return nil }
        return ModelSource(name: "the home server's model", provider: provider == "openai-compatible" ? .openAICompatible : .anthropic,
                           baseURL: base, model: name, contextTokens: BookCompletion.contextTokens)
    }

    /// Why this gateway will not take book text, or nil when it will.
    public var refusal: (status: String, reason: String)? {
        guard let source else {
            return ("503 Service Unavailable", "no model is set up on the home server")
        }
        guard source.isLocal || declaredLocal else {
            let host = source.baseURL.flatMap { URL(string: $0)?.host } ?? ModelConsentWording.providerName(source)
            return ("403 Forbidden", "the home server's model is a cloud one (\(host)), so it is not sent book text; set BATON_LLM_LOCAL=1 if it is on your network")
        }
        return nil
    }

    func handle(_ request: HTTPRequestMessage) async -> Data {
        if let refusal { return httpErrorResponse(status: refusal.status, message: refusal.reason) }
        guard let source else { return httpErrorResponse(status: "503 Service Unavailable", message: "no model") }
        guard let body = try? JSONDecoder().decode(BookCompletion.Request.self, from: request.body),
              !body.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return httpErrorResponse(status: "400 Bad Request", message: "system and user are required")
        }
        guard body.system.count + body.user.count <= BookCompletion.maximumCharacters else {
            return httpErrorResponse(status: "413 Payload Too Large",
                                     message: "a book task is at most \(BookCompletion.maximumCharacters) characters")
        }
        let maxTokens = min(max(body.maxTokens ?? 1_024, 1), BookCompletion.maximumReplyTokens)
        let user = SecretRedactor.redact(body.user)
        let complete = self.complete
        let text: String
        do {
            text = try await Self.within(timeout) { try await complete(source, body.system, user, maxTokens) }
        } catch is TimedOut {
            return httpErrorResponse(status: "504 Gateway Timeout",
                                     message: "the home server's model did not answer within \(Int(timeout)) seconds")
        } catch {
            return httpErrorResponse(status: "502 Bad Gateway", message: "the home server's model did not answer: \(error)")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return httpErrorResponse(status: "502 Bad Gateway", message: "the home server's model gave an empty answer")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(BookCompletion.Response(text: text, model: source.model))) ?? Data("{}".utf8)
        return httpResponse(status: "200 OK", contentType: "application/json", payload: payload)
    }

    struct TimedOut: Error {}

    /// `work`, or `TimedOut` once `seconds` pass, whichever is first. A URL session's timeout is
    /// between bytes, so a model that streams slowly would otherwise hold the request for ever.
    static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}
