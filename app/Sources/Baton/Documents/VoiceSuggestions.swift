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
/// cloud provider). A cloud source is used only for what the person allowed it in the consent
/// ledger (M4.6, `ModelConsentLedger`); `ModelRouter` makes that call, and skips it otherwise.
/// The sheet says which source answered, or why none did.
enum VoiceSuggestions {
    /// Where the suggestion's model calls go, built from what is configured and reachable:
    /// Apple's on-device model when it can answer (M7.1; the spec's default order puts it
    /// first), the models saved in Settings → Models on this Mac (M7.2 to M7.4), in the person's
    /// order, then a model Ollama has that is not among them, then the music friend's model.
    static func sources(agent: RemoteControlSettings.NaturalLanguageConfig, ollamaModel: String?,
                        saved: [ModelSource] = [], onDevice: ModelSource? = nil) -> [ModelSource] {
        var sources = (onDevice.map { [$0] } ?? []) + saved
        if let ollamaModel, !saved.contains(where: { $0.provider == .ollama && $0.model == ollamaModel }) {
            sources.append(ModelSource(name: "\(ollamaModel) on this Mac", provider: .ollama,
                                       baseURL: ollamaBase.absoluteString, model: ollamaModel, contextTokens: 8_192))
        }
        let base = agent.baseURL.trimmingCharacters(in: .whitespaces)
        if agent.isEnabled, !base.isEmpty, !agent.model.isEmpty {
            var source = ModelSource(name: "", provider: agent.provider == .anthropic ? .anthropic : .openAICompatible,
                                     baseURL: base, model: agent.model, contextTokens: 8_192)
            source.name = source.isLocal ? "the Baton server" : (agent.provider == .anthropic ? "Anthropic" : "\(URL(string: base)?.host ?? base)")
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

    /// The voices a book made on this Mac can use, as `"engine:voice"` specs, under Voice engine
    /// for books, for the narrator, cast and Change Voice pickers:
    /// - Automatic: the Kokoro host's voices, or when none answers the built-in "This Mac" voices
    /// if their model is downloaded, so import still offers a choice; then every
    ///   other configured engine's voices.
    /// - Built-in voices on this Mac: the built-in voices only, never asking a server.
    /// - Voice server: the Kokoro host's voices, then every other configured engine's.
    /// The engines are listed by `SpeechEngines.listVoices`, the same listing the Baton server
    /// answers `GET /v1/voices` with, so both apps offer an engine's voices the same way.
    /// `others` defaults to the Chatterbox host when one was entered and the expressive server
    /// when it is set; `builtIn` to what this Mac has and `engine` to the setting; tests pass
    /// their own.
    static func availableVoices(kokoroBase: String = SpeechConfig.kokoroBaseURL,
                                others: [SpeechEngineEndpoint]? = nil,
                                builtIn: [String]? = nil,
                                engine: BookVoiceSettings.Engine? = nil,
                                fetch: DocumentImporter.Fetch = { try await URLSession.shared.data(for: $0) }) async -> [String] {
        let local = builtIn ?? BuiltInVoices.shared.availableVoiceIDs
        let engine = engine ?? BookVoiceSettings.engine
        if engine == .builtIn { return local }
        var endpoints = others ?? configuredOtherEngines()
        if let kokoro = URL(string: kokoroBase), kokoro.host != nil {
            endpoints.insert(SpeechEngineEndpoint(engine: SpeechEngines.kokoro, baseURL: kokoro), at: 0)
        }
        let listed = await SpeechEngines.listVoices(endpoints, fetch: { request in
            let (data, response) = try await fetch(request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
        })
        let server = listed.first { $0.engine == SpeechEngines.kokoro }?.voices ?? []
        let rest = listed.filter { $0.engine != SpeechEngines.kokoro }.flatMap(\.voices)
        return (server.isEmpty && engine == .automatic ? local : server) + rest
    }

    /// The engines other than Kokoro that this Mac has an address for: Chatterbox when someone
    /// entered its host (its placeholder is not a server), and the expressive server.
    static func configuredOtherEngines() -> [SpeechEngineEndpoint] {
        ConfiguredSpeechSynthesizer.endpoints(withKey: true).filter {
            $0.engine == SpeechEngines.openAI || ($0.engine == SpeechEngines.chatterbox && SpeechConfig.hasStoredHost(for: .chatterbox))
        }
    }

    /// `availableVoices` for the voice picker: this Mac's voices, or why there are
    /// none.
    static func thisMacListing() async -> VoiceListing {
        let voices = await availableVoices()
        guard voices.isEmpty else { return VoiceListing(voices: voices) }
        return VoiceListing(voices: nil, problem: BookVoiceSettings.engine == .builtIn
            ? "Only the suggested voices are here, because the built-in voices are not downloaded. Download them in Settings, under Speech."
            : "Only the suggested voices are here, because no voice server answered. Check it in Settings, under Speech.")
    }

    /// A suggestion for `document`. Never throws: with no source, no voices or a useless answer
    /// it is the language default, and `fallbackReason` says why.
    static func suggest(for document: ImportedDocument, languageDefault: String, sources: [ModelSource],
                        consent: ModelConsent = ModelConsent(),
                        available: [String], executor: @escaping ModelRouter.Executor) async -> VoiceSuggestion {
        let router = ModelRouter(sources: sources, consent: consent)
        let complete: VoiceCaster.Complete? = sources.isEmpty ? nil : { @Sendable system, user in
            try await router.complete(.voiceSuggestion, system: system, user: user, executor: executor)
        }
        return await VoiceCaster.suggest(for: document, available: available, languageDefault: languageDefault,
                                         complete: complete)
    }

    /// Where a book task can go right now: the sources, what the person allowed the cloud ones,
    /// and the executor that reaches them.
    struct Routing {
        var sources: [ModelSource]
        var consent: ModelConsent
        var executor: ModelRouter.Executor

        func router(allowingOnce once: (source: ModelSource, content: ModelContent)? = nil) -> ModelRouter {
            ModelRouter(sources: sources, consent: once.map { consent.granting($0.source, $0.content) } ?? consent)
        }
    }

    /// The sources this Mac can route a book task to right now, the consent the person gave the
    /// cloud ones on this Mac, and the executor that reaches them. The agent's key is the only
    /// secret, read from its own settings and handed to the HTTP client for that source alone.
    /// Shared by the voice suggestion, the pronunciation proposal (M8.6) and the resume recap
    /// (M8.4).
    @MainActor
    static func liveRouting() async -> Routing {
        let agent = RemoteControlSettings().naturalLanguage
        let model = await detectOllamaModel()
        let sources = sources(agent: agent, ollamaModel: model, saved: LocalModelSources.configuredSources(),
                              onDevice: AppleOnDeviceModel.sourceIfAvailable())
        let agentKey = agent.apiKey
        let agentBase = agent.baseURL.trimmingCharacters(in: .whitespaces)
        let executor = AppleOnDeviceModel.executor(
            otherwise: HTTPModelClient.executor(apiKey: { source in source.baseURL == agentBase ? agentKey : nil }))
        return Routing(sources: sources, consent: CloudModelConsent.ledger().consent, executor: executor)
    }

    /// The live path: detect, list voices, suggest. `allowingOnce` is the import sheet's
    /// "Allow once", good for this suggestion only.
    @MainActor
    static func suggestLive(for document: ImportedDocument, languageDefault: String,
                            allowingOnce once: ModelSource? = nil) async -> (suggestion: VoiceSuggestion, routing: Routing) {
        async let voices = availableVoices()
        var routing = await liveRouting()
        let list = await voices
        if let once { routing.consent = routing.consent.granting(once, ModelTask.voiceSuggestion.content) }
        let suggestion = await suggest(for: document, languageDefault: languageDefault, sources: routing.sources,
                                       consent: routing.consent, available: list, executor: routing.executor)
        return (suggestion, routing)
    }

    /// The cloud source to ask about on the import sheet, if any: only when nothing local gave a
    /// suggestion (it fell back), a cloud source is waiting for consent to excerpts, and the
    /// person has not answered for it yet.
    static func sourceToAsk(fellBack: Bool, routing: Routing,
                            hasAnswered: (ModelSource) -> Bool) -> ModelSource? {
        guard fellBack else { return nil }
        return routing.router().awaitingConsent(for: .voiceSuggestion).first { !hasAnswered($0) }
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

/// Plays one voice preview at a time on this Mac, through the configured voice engines.
@MainActor
@Observable
final class VoicePreviewPlayer {
    /// A sound that is playing: how long it lasts, and how to cut it short.
    struct Sound {
        var duration: TimeInterval
        var stop: @MainActor () -> Void
    }
    typealias Synthesize = @Sendable (_ text: String, _ voice: String) async throws -> Data
    typealias Play = @MainActor (_ wav: Data) throws -> Sound

    private(set) var playing: String?
    private(set) var failure: String?
    @ObservationIgnored private var sound: Sound?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let synthesize: Synthesize
    @ObservationIgnored private let play: Play

    /// The seams are for tests (M4.4): a fake voice server and a fake speaker.
    init(synthesize: @escaping Synthesize = { text, voice in
             // An expressive voice is heard as it would narrate.
             let instruction = SpeechEngines.takesInstructions(SpeechEngines.engine(of: voice))
                 ? DeliveryHints.instruction(speaker: nil, direction: nil, voice: voice, bookLanguage: nil) : nil
             return try await ConfiguredSpeechSynthesizer().synthesize(text: text, voice: voice, speed: nil, style: nil,
                                                                       instruction: instruction)
         },
         play: @escaping Play = VoicePreviewPlayer.playAloud) {
        self.synthesize = synthesize
        self.play = play
    }

    /// Previews made by the Baton server (`POST /v1/speech/preview`), for a book it makes: its
    /// voices are not always this Mac's.
    static func batonServer() -> VoicePreviewPlayer {
        VoicePreviewPlayer(synthesize: { text, voice in
            guard let client = await MainActor.run(body: { DocumentLibrary.configuredGateway() }) else {
                throw SynthesisError.transient("the Baton server is not set up in Settings")
            }
            return try await client.preview(text: text, voice: voice)
        })
    }

    static func playAloud(_ wav: Data) throws -> Sound {
        let player = try AVAudioPlayer(data: wav)
        player.play()
        return Sound(duration: player.duration, stop: { player.stop() })
    }

    /// Hear a voice; pressed again while it plays, stop it. Starting another voice stops the
    /// one playing, so only one is ever heard.
    func toggle(_ voice: String, text: String) {
        if playing == voice { stop(); return }
        stop()
        playing = voice
        failure = nil
        let synthesize = synthesize
        task = Task {
            do {
                let wav = try await synthesize(text, voice)
                guard !Task.isCancelled, playing == voice else { return }
                let sound = try play(wav)
                self.sound = sound
                try? await Task.sleep(for: .seconds(sound.duration + 0.2))
                if !Task.isCancelled, playing == voice { playing = nil }
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
        sound?.stop()
        sound = nil
        playing = nil
    }
}
