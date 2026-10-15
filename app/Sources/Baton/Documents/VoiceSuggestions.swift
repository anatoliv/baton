import AVFoundation
import BatonAgentKit
import BatonDocuments
import BatonSpeech
import Foundation
import Observation

/// The narrator suggestion on the import sheet (M4.4, `specs/document-clippings.md`, *Voice
/// suggestion*): the model sources this Mac has, the voices the server offers, and three to hear.
///
/// The choosing is `VoiceCaster` in BatonDocuments; this is the Mac's wiring. Sources, in order:
/// Ollama on this Mac when it answers, then the model the music friend uses (the home server, or a
/// cloud provider). **No consent is recorded yet (M4.6)**, so `ModelRouter` skips every cloud
/// source by itself, and nothing from a book is sent to a cloud provider. The sheet says which
/// source answered, or why none did.
enum VoiceSuggestions {
    /// Where the suggestion's model calls go, built from what is configured and reachable: the
    /// models saved in Settings → Models on this Mac (M7.2 to M7.4), in the person's order, then a
    /// model Ollama has that is not among them, then the music friend's model.
    static func sources(agent: RemoteControlSettings.NaturalLanguageConfig, ollamaModel: String?,
                        saved: [ModelSource] = []) -> [ModelSource] {
        var sources = saved
        if let ollamaModel, !saved.contains(where: { $0.provider == .ollama && $0.model == ollamaModel }) {
            sources.append(ModelSource(name: "\(ollamaModel) on this Mac", provider: .ollama,
                                       baseURL: ollamaBase.absoluteString, model: ollamaModel, contextTokens: 8_192))
        }
        let base = agent.baseURL.trimmingCharacters(in: .whitespaces)
        if agent.isEnabled, !base.isEmpty, !agent.model.isEmpty {
            var source = ModelSource(name: "", provider: agent.provider == .anthropic ? .anthropic : .openAICompatible,
                                     baseURL: base, model: agent.model, contextTokens: 8_192)
            source.name = source.isLocal ? "the home server" : (agent.provider == .anthropic ? "Anthropic" : "\(URL(string: base)?.host ?? base)")
            sources.append(source)
        }
        return sources
    }

    static let ollamaBase = URL(string: "http://127.0.0.1:11434")!

    /// The first chat model Ollama on this Mac has, or nil when it is not running. Embedding models
    /// cannot answer, so they are passed over.
    static func detectOllamaModel(fetch: DocumentImporter.Fetch = { try await URLSession.shared.data(for: $0) }) async -> String? {
        var request = URLRequest(url: ollamaBase.appendingPathComponent("api/tags"), timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (data, _) = try? await fetch(request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
            .first { !$0.contains("embed") }
    }

    /// The voices the Kokoro host offers, as `kokoro:<id>` specs, or none when it does not answer.
    static func availableVoices(kokoroBase: String = SpeechConfig.kokoroBaseURL,
                                fetch: DocumentImporter.Fetch = { try await URLSession.shared.data(for: $0) }) async -> [String] {
        guard let url = URL(string: kokoroBase)?.appendingPathComponent("v1/audio/voices") else { return [] }
        guard let (data, _) = try? await fetch(URLRequest(url: url, timeoutInterval: 5)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = object["voices"] as? [Any] else { return [] }
        return voices.compactMap { entry -> String? in
            if let id = (entry as? [String: Any])?["id"] as? String { return "kokoro:\(id)" }
            if let id = entry as? String { return "kokoro:\(id)" }
            return nil
        }
    }

    /// A suggestion for `document`. Never throws: with no source, no voices or a useless answer
    /// it is the language default, and `fallbackReason` says why.
    static func suggest(for document: ImportedDocument, languageDefault: String, sources: [ModelSource],
                        available: [String], executor: @escaping ModelRouter.Executor) async -> VoiceSuggestion {
        let router = ModelRouter(sources: sources)
        let complete: VoiceCaster.Complete? = sources.isEmpty ? nil : { @Sendable system, user in
            try await router.complete(.voiceSuggestion, system: system, user: user, executor: executor)
        }
        return await VoiceCaster.suggest(for: document, available: available, languageDefault: languageDefault,
                                         complete: complete)
    }

    /// The live path: detect, list voices, suggest. The agent's key is the only secret, read from
    /// its own settings and handed to the HTTP client for that source alone.
    @MainActor
    static func suggestLive(for document: ImportedDocument, languageDefault: String) async -> VoiceSuggestion {
        let agent = RemoteControlSettings().naturalLanguage
        async let ollama = detectOllamaModel()
        async let voices = availableVoices()
        let model = await ollama
        let list = await voices
        let sources = sources(agent: agent, ollamaModel: model, saved: LocalModelSources.configuredSources())
        let agentKey = agent.apiKey
        let agentBase = agent.baseURL.trimmingCharacters(in: .whitespaces)
        let executor = HTTPModelClient.executor(apiKey: { source in source.baseURL == agentBase ? agentKey : nil })
        return await suggest(for: document, languageDefault: languageDefault, sources: sources,
                             available: list, executor: executor)
    }

    /// The first few sentences of the book, to hear a voice in the book's own words.
    static func previewText(for document: ImportedDocument, limit: Int = 220) -> String {
        let opening = document.chapters.lazy.flatMap(\.paragraphs).prefix(3).joined(separator: " ")
        let redacted = SecretRedactor.redact(opening)
        guard redacted.count > limit else { return redacted }
        let cut = redacted.prefix(limit)
        if let end = cut.lastIndex(where: { ".!?".contains($0) }) { return String(cut[...end]) }
        return String(cut) + "…"
    }
}

/// Plays one voice preview at a time on this Mac, through the configured Kokoro host.
@MainActor
@Observable
final class VoicePreviewPlayer {
    private(set) var playing: String?
    private(set) var failure: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var task: Task<Void, Never>?

    func toggle(_ voice: String, text: String) {
        if playing == voice { stop(); return }
        stop()
        playing = voice
        failure = nil
        task = Task {
            do {
                let wav = try await ConfiguredSpeechSynthesizer().synthesize(text: text, voice: voice, speed: nil)
                guard !Task.isCancelled, playing == voice else { return }
                let player = try AVAudioPlayer(data: wav)
                self.player = player
                player.play()
                try? await Task.sleep(for: .seconds(player.duration + 0.2))
                if playing == voice { playing = nil }
            } catch {
                if playing == voice {
                    playing = nil
                    failure = "That voice could not be played: \((error as? SynthesisError)?.listenerReason ?? error.localizedDescription)."
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        playing = nil
    }
}
