import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BatonDocuments

/// A real model for the opt-in measurements, asked the way the app asks: through `ModelRouter`
/// and `HTTPModelClient.executor`, so the request, the task's reply budget and the three-minute
/// timeout are the app's.
///
/// - `BATON_LIVE_AGENT_FILE`: a JSON file with `base`, `model`, `provider` and `key`, such as
///   `~/.baton-live-agent.json` for the home server. The key is handed to the request and never
///   printed.
/// - otherwise `BATON_LIVE_OLLAMA_MODEL` (and `BATON_LIVE_OLLAMA_URL`): Ollama at 8,192 tokens of
///   context, as the app detects it.
enum LiveModel {
    static func source() -> (source: ModelSource, key: String?)? {
        let env = ProcessInfo.processInfo.environment
        if let file = env["BATON_LIVE_AGENT_FILE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
           let agent = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            let provider: ModelSource.Provider = agent["provider"] == "anthropic" ? .anthropic : .openAICompatible
            return (ModelSource(name: "\(agent["model"] ?? "?") on the home server", provider: provider,
                                baseURL: agent["base"], model: agent["model"] ?? "", contextTokens: 8_192), agent["key"])
        }
        guard let model = env["BATON_LIVE_OLLAMA_MODEL"] else { return nil }
        return (ModelSource(name: "\(model) on this Mac", provider: .ollama,
                            baseURL: env["BATON_LIVE_OLLAMA_URL"] ?? "http://127.0.0.1:11434", model: model,
                            contextTokens: 8_192), nil)
    }

    /// `task` on the live model, or nil when none is configured.
    static func complete(_ task: ModelTask) -> (complete: VoiceCaster.Complete, name: String)? {
        guard let (source, key) = source() else { return nil }
        let router = ModelRouter(sources: [source])
        let executor = HTTPModelClient.executor(apiKey: { _ in key })
        return ({ system, user in try await router.complete(task, system: system, user: user, executor: executor) }, source.name)
    }
}
