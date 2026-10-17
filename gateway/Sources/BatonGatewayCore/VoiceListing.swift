import BatonDocuments
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The voices this gateway can render with, for `GET /v1/voices`: the phone has no
/// voice server of its own, so this is how it offers the same narrators as the Mac.
///
/// Every configured engine (`BATON_TTS_KOKORO_URL`, and `BATON_TTS_CHATTERBOX_URL` and
/// `BATON_TTS_OPENAI_URL` when set) is listed by `SpeechEngines.listVoices`, the same listing the
/// Mac's pickers use. When Kokoro does not answer, its English voices as Kokoro ships
/// them stand in (`VoiceCatalogue.kokoroEnglishVoices`); a Chatterbox that does not answer has no
/// list, since its voices are whatever reference files its owner put there; an expressive server
/// that answers without a list offers Qwen3-TTS's presets when its model is Qwen3-TTS. The answer
/// is kept for `ttl` seconds, so an import screen opened twice does not ask the voice servers
/// twice.
public actor VoiceListing {
    /// One GET, returning the body and the HTTP status. The gateway passes `URLSession`; tests
    /// pass a stand-in voice server.
    public typealias Fetch = SpeechEngines.Fetch

    public let endpoints: [SpeechEngineEndpoint]
    public var engines: [String: URL] { Dictionary(endpoints.map { ($0.engine, $0.baseURL) }, uniquingKeysWith: { a, _ in a }) }
    public let ttl: TimeInterval
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var cached: (list: GatewayVoiceList, at: Date)?

    public static let defaultTTL: TimeInterval = 60

    public init(engines: [String: URL], ttl: TimeInterval = VoiceListing.defaultTTL,
                fetch: Fetch? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(endpoints: engines.map { SpeechEngineEndpoint(engine: $0.key, baseURL: $0.value) }, ttl: ttl,
                  fetch: fetch, now: now)
    }

    public init(endpoints: [SpeechEngineEndpoint], ttl: TimeInterval = VoiceListing.defaultTTL,
                fetch: Fetch? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.endpoints = endpoints
        self.ttl = ttl
        self.now = now
        self.fetch = fetch ?? SpeechEngines.liveFetch
    }

    public func list() async -> GatewayVoiceList {
        if let cached, now().timeIntervalSince(cached.at) < ttl { return cached.list }
        var voices: [GatewayVoiceList.Voice] = []
        var sources: [String: String] = [:]
        for listed in await SpeechEngines.listVoices(endpoints, kokoroFallback: true, fetch: fetch) {
            voices += listed.voices.map { spec in
                let id = String(spec.dropFirst(listed.engine.count + 1))
                return GatewayVoiceList.Voice(engine: listed.engine, id: id, language: VoiceCatalogue.declaredLanguage(spec))
            }
            sources[listed.engine] = listed.source.rawValue
        }
        let list = GatewayVoiceList(voices: voices, sources: sources)
        cached = (list, now())
        return list
    }
}
