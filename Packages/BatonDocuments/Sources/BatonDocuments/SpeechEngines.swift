import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The voice engines a book can be read by, what each can do, and where each one is
///.
///
/// Kokoro and Chatterbox were the only engines, named in a voice spec (`"kokoro:bf_emma"`).
/// The third is any speech server that answers OpenAI's `POST /v1/audio/speech`, configured by
/// base URL, a model name and an optional key. Its spec prefix is `openai`
/// (`"openai:Ryan"`). Qwen3-TTS is the first target: in the TBX-11102 bake-off its narration
/// had audiobook pace and more pitch movement than Kokoro's. Unlike Kokoro, it takes a
/// natural-language instruction for how each line is delivered.
public struct SpeechEngineEndpoint: Sendable, Equatable {
    /// `kokoro`, `chatterbox` or `openai`: the prefix of the voice specs it reads.
    public var engine: String
    public var baseURL: URL
    /// What is sent as `model`. Kokoro and Chatterbox are sent their engine name, as before.
    public var model: String?
    /// Sent as `Authorization: Bearer`, for a server that asks for one. Never logged.
    public var apiKey: String?

    public init(engine: String, baseURL: URL, model: String? = nil, apiKey: String? = nil) {
        self.engine = engine
        // An address copied from an OpenAI client ends in /v1; Kokoro's and Chatterbox's are
        // kept exactly as they were typed.
        self.baseURL = engine == SpeechEngines.openAI ? SpeechEngines.serverRoot(baseURL) : baseURL
        self.model = model
        self.apiKey = apiKey
    }

    /// The model this endpoint is sent, never blank.
    public var requestModel: String {
        let trimmed = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return engine == SpeechEngines.openAI ? SpeechEngines.defaultOpenAIModel : engine
    }

    /// Whether this endpoint is a Qwen3-TTS server, whose preset voices are known.
    public var isQwen3: Bool { requestModel.lowercased().replacingOccurrences(of: "-", with: "").contains("qwen3") }
}

public enum SpeechEngines {
    public static let kokoro = "kokoro"
    public static let chatterbox = "chatterbox"
    /// An OpenAI-compatible speech server (`POST /v1/audio/speech`).
    public static let openAI = "openai"

    /// The model a new expressive server is sent until someone names another.
    public static let defaultOpenAIModel = "qwen3-tts"

    /// The engine a spec names: `"openai:Ryan"` → `openai`; a bare voice is Kokoro's.
    public static func engine(of spec: String) -> String { HTTPSpeechSynthesizer.split(spec).engine }

    /// Whether the engine takes a delivery instruction with each request (Qwen3-TTS's
    /// `instruct`, OpenAI's `instructions`).
    public static func takesInstructions(_ engine: String) -> Bool { engine == openAI }

    /// Whether the engine is read one sentence per request with a reader's pauses between them
    /// (`SpeechPacing`). Kokoro is not: in the bake-off, Kokoro asked for a paragraph moved its
    /// pitch more (4.3 semitones SD) than sentence by sentence (3.2), so its packed chunks stay.
    public static func readsBySentence(_ engine: String) -> Bool { engine == openAI }

    /// The engine's name in a voice list.
    public static func title(_ engine: String) -> String {
        switch engine {
        case kokoro: "Kokoro"
        case chatterbox: "Chatterbox"
        case openAI: "Expressive voices"
        default: engine
        }
    }

    /// Where the engine's own list of engines is ordered: Kokoro, the expressive server,
    /// Chatterbox, then anything else by name.
    static func order(_ engine: String) -> Int {
        switch engine {
        case kokoro: 0
        case openAI: 1
        case chatterbox: 2
        default: 3
        }
    }

    /// The server's root, from what someone typed. OpenAI's own clients take a base URL that
    /// ends in `/v1`, so an address copied from one is accepted as it is.
    public static func serverRoot(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1") { text.removeLast(3) }
        return URL(string: text) ?? url
    }

    // MARK: - Qwen3-TTS

    /// One of Qwen3-TTS CustomVoice's preset speakers.
    public struct Preset: Sendable, Equatable {
        public var id: String
        public var gender: String
        /// The language the speaker is native in. Every preset speaks all of the model's
        /// languages; a speaker reading another one is told which (`DeliveryHints`).
        public var language: String
        public var tags: [String]
    }

    /// The nine preset speakers of Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice, as its model card
    /// lists them. A server that lists its own voices is believed over this list.
    public static let qwen3Presets: [Preset] = [
        Preset(id: "Aiden", gender: "male", language: "en", tags: ["clear", "bright", "good for narration and dialogue"]),
        Preset(id: "Ryan", gender: "male", language: "en", tags: ["lively", "good for narration and dialogue"]),
        Preset(id: "Vivian", gender: "female", language: "zh", tags: ["bright", "youthful", "good for dialogue"]),
        Preset(id: "Serena", gender: "female", language: "zh", tags: ["warm", "soft", "youthful", "good for dialogue"]),
        Preset(id: "Uncle_Fu", gender: "male", language: "zh", tags: ["deep", "mature", "good for dialogue"]),
        Preset(id: "Dylan", gender: "male", language: "zh", tags: ["clear", "youthful", "good for dialogue"]),
        Preset(id: "Eric", gender: "male", language: "zh", tags: ["husky", "lively", "good for dialogue"]),
        Preset(id: "Ono_Anna", gender: "female", language: "ja", tags: ["bright", "lively", "good for dialogue"]),
        Preset(id: "Sohee", gender: "female", language: "ko", tags: ["warm", "good for dialogue"]),
    ]

    /// The preset an `openai:` voice is, when it is one of Qwen3-TTS's (case is ignored, as the
    /// model ignores it).
    public static func qwen3Preset(_ spec: String) -> Preset? {
        let (engine, id) = HTTPSpeechSynthesizer.split(spec)
        guard engine == openAI else { return nil }
        return qwen3Presets.first { $0.id.lowercased() == id.lowercased() }
    }

    // MARK: - Voices

    /// What one engine offered, and where the list came from.
    public struct EngineVoices: Sendable, Equatable {
        public enum Source: String, Sendable, Equatable {
            /// The engine's own list.
            case server
            /// The voices the engine ships with, because it did not list its own.
            case builtIn = "built-in"
            /// Nothing: the engine did not answer.
            case unavailable
        }

        public var engine: String
        /// `"engine:voice"` specs.
        public var voices: [String]
        public var source: Source

        public init(engine: String, voices: [String], source: Source) {
            self.engine = engine
            self.voices = voices
            self.source = source
        }
    }

    /// One GET: the body and the HTTP status. Throws when the server does not answer at all.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    /// The live GET, read only up to `CappedDownload.listingLimit`.
    public static let liveFetch: Fetch = { request in
        let (data, response) = try await CappedDownload.data(for: request, limit: CappedDownload.listingLimit)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The voices to offer, from every configured engine, one entry per engine, in a stable
    /// order (Kokoro, the expressive server, Chatterbox). This is the one listing behind the
    /// narrator, cast and Change Voice pickers on the Mac and behind the Baton server's
    /// `GET /v1/voices`, which the iPhone's pickers read.
    ///
    /// Each engine is asked for `/v1/audio/voices` (Kokoro-FastAPI and Chatterbox-TTS-Server
    /// serve it; an expressive server may serve it or `/v1/voices`). An expressive server that
    /// answers but lists nothing offers Qwen3-TTS's presets when its model is Qwen3-TTS. One
    /// that does not answer at all offers nothing, so a picker never offers a voice that cannot
    /// be made. `kokoroFallback` keeps the Baton server's rule: a Kokoro that does
    /// not answer offers the English voices Kokoro ships with.
    public static func listVoices(_ endpoints: [SpeechEngineEndpoint], kokoroFallback: Bool = false,
                                  timeout: TimeInterval = 5, fetch: Fetch = liveFetch) async -> [EngineVoices] {
        var out: [EngineVoices] = []
        for endpoint in endpoints.sorted(by: { (order($0.engine), $0.engine) < (order($1.engine), $1.engine) }) {
            let engine = endpoint.engine
            let paths = engine == openAI ? ["v1/audio/voices", "v1/voices"] : ["v1/audio/voices"]
            var answered = false
            var listed: [String]?
            for path in paths where listed == nil {
                var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path))
                request.timeoutInterval = timeout
                if let key = endpoint.apiKey, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                guard let (data, status) = try? await fetch(request) else { break }
                answered = true
                if (200..<300).contains(status), let ids = parseVoices(data), !ids.isEmpty { listed = ids }
            }
            if let listed {
                out.append(EngineVoices(engine: engine, voices: listed.map { "\(engine):\($0)" }, source: .server))
            } else if engine == openAI, answered, endpoint.isQwen3 {
                out.append(EngineVoices(engine: engine, voices: qwen3Presets.map { "\(openAI):\($0.id)" }, source: .builtIn))
            } else if engine == kokoro, kokoroFallback {
                out.append(EngineVoices(engine: engine, voices: VoiceCatalogue.kokoroEnglishVoices, source: .builtIn))
            } else {
                out.append(EngineVoices(engine: engine, voices: [], source: .unavailable))
            }
        }
        return out
    }

    /// Kokoro-FastAPI's `{"voices": [...]}`, or OpenAI's list shape `{"data": [{"id": ...}]}`.
    static func parseVoices(_ data: Data) -> [String]? {
        if let ids = try? KokoroAPI.parseVoices(data) { return ids }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["data"] as? [[String: Any]] else { return nil }
        return raw.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
    }
}

// MARK: - Pacing

/// The pauses an expressive engine is read with: one sentence per request, about
/// 0.45 s between sentences and 0.9 s between paragraphs, the pacing the TBX-11102 bake-off
/// rendered its sentence-by-sentence files with. Kokoro keeps `DocumentSpeech.Pauses` (120 ms
/// between its packed chunks), since its voice carries a sentence boundary itself.
public enum SpeechPacing {
    public static let betweenSentencesMs = 450
    public static let betweenParagraphsMs = 900

    /// The silence before a segment read by sentences: at least a paragraph's pause when it
    /// starts a paragraph, at least a sentence's otherwise. The first segment of a chapter keeps
    /// what it has (none).
    public static func pauseBefore(_ segment: SpeechSegment, after previous: SpeechSegment?) -> Int {
        guard let previous else { return segment.pauseBeforeMs }
        let floor = previous.paragraph != segment.paragraph ? betweenParagraphsMs : betweenSentencesMs
        return max(segment.pauseBeforeMs, floor)
    }
}

// MARK: - Delivery

/// How the book's tone and a character's gender and age travel with a book, for an engine
/// that takes a delivery instruction. Kept only when some voice in the plan takes
/// one, so a Kokoro book's plan, and so its job id, are what they always were.
public struct VoiceDirection: Codable, Sendable, Equatable {
    /// The voice suggestion's judgement of the book ("dry, ominous").
    public var tone: String?
    /// Character name → who they are, for the characters read by an instruction-taking voice.
    public var characters: [String: CharacterTraits]

    public init(tone: String? = nil, characters: [String: CharacterTraits] = [:]) {
        self.tone = tone
        self.characters = characters
    }
}

public struct CharacterTraits: Codable, Sendable, Equatable {
    /// "f", "m" or "x", as the cast sheet says.
    public var gender: String
    /// "child", "young", "adult" or "old".
    public var age: String

    public init(gender: String, age: String) {
        self.gender = gender
        self.age = age
    }
}

/// The instruction sent with each line to an engine that takes one: plain words, as Qwen3-TTS's
/// `instruct` and OpenAI's `instructions` expect. The bake-off's instructions ("Narrate calmly,
/// like an audiobook narrator, with natural pauses and expressive intonation."; "A grave, earnest
/// young man pleading quietly with his mother.") are the model for these.
public enum DeliveryHints {
    /// For the narrator (`speaker` nil) or a character.
    public static func instruction(speaker: String?, direction: VoiceDirection?, voice: String,
                                   bookLanguage: String?) -> String {
        var parts: [String] = []
        if let speaker, let traits = direction?.characters[speaker] {
            parts.append("\(who(traits)), speaking a line of dialogue in an audiobook. Natural and in character, never theatrical.")
        } else if speaker != nil {
            parts.append("A character speaking a line of dialogue in an audiobook. Natural and in character, never theatrical.")
        } else {
            parts.append("Narrate like an audiobook narrator: unhurried, with natural pauses and expressive intonation.")
        }
        if let tone = cleanTone(direction?.tone) {
            parts.append("The story's tone is \(tone).")
        }
        if let language = languageLine(voice: voice, bookLanguage: bookLanguage) { parts.append(language) }
        return parts.joined(separator: " ")
    }

    /// The longest tone an instruction carries.
    public static let maximumToneCharacters = 80

    /// The book's tone as an instruction may carry it: free text from the voice model or from a
    /// book a client sent, so it is kept to one line of at most 80 characters, cut at a word,
    /// with control characters gone and whitespace runs made single spaces. Nil when nothing is
    /// left.
    public static func cleanTone(_ tone: String?) -> String? {
        guard let tone else { return nil }
        let visible = String(String.UnicodeScalarView(tone.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        var words = visible.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var line = words.joined(separator: " ")
        while line.count > maximumToneCharacters, words.count > 1 {
            words.removeLast()
            line = words.joined(separator: " ")
        }
        if line.count > maximumToneCharacters { line = String(line.prefix(maximumToneCharacters)) }
        return line.isEmpty ? nil : line
    }

    /// "An elderly woman", "A young man", "A child", "An adult".
    static func who(_ traits: CharacterTraits) -> String {
        let noun: String
        switch (traits.gender, traits.age) {
        case (_, "child"): return traits.gender == "f" ? "A girl" : (traits.gender == "m" ? "A boy" : "A child")
        case ("f", _): noun = "woman"
        case ("m", _): noun = "man"
        default: noun = "person"
        }
        switch traits.age {
        case "young": return "A young \(noun)"
        case "old": return "An elderly \(noun)"
        default: return noun == "person" ? "An adult" : "A \(noun)"
        }
    }

    /// "Speak English." when the voice is native in another language than the book's, as the
    /// bake-off told its Chinese-native Serena; nil when they match or either is unknown.
    static func languageLine(voice: String, bookLanguage: String?) -> String? {
        guard let preset = SpeechEngines.qwen3Preset(voice),
              let book = bookLanguage.map({ String($0.prefix(2)).lowercased() }), !book.isEmpty,
              book != preset.language, let name = languageNames[book] else { return nil }
        return "Speak \(name)."
    }

    static let languageNames: [String: String] = [
        "en": "English", "zh": "Chinese", "ja": "Japanese", "ko": "Korean", "de": "German", "fr": "French",
        "ru": "Russian", "pt": "Portuguese", "es": "Spanish", "it": "Italian",
    ]
}
