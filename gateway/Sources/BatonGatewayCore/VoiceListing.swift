import BatonDocuments
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The voices this gateway can render with, for `GET /v1/voices`: the phone has no
/// voice server of its own, so this is how it offers the same narrators as the Mac.
///
/// Each configured engine (`BATON_TTS_KOKORO_URL`, and `BATON_TTS_CHATTERBOX_URL` when set) is
/// asked for its own `/v1/audio/voices`, the listing Kokoro-FastAPI and Chatterbox-TTS-Server
/// both serve. When Kokoro does not answer, its English voices as Kokoro ships them stand in
/// (`VoiceCatalogue.kokoroEnglishVoices`); a Chatterbox that does not answer has no list, since
/// its voices are whatever reference files its owner put there. The answer is kept for `ttl`
/// seconds, so an import screen opened twice does not ask the voice server twice.
public actor VoiceListing {
    /// One GET, returning the body and the HTTP status. The gateway passes `URLSession`; tests
    /// pass a stand-in voice server.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    public let engines: [String: URL]
    public let ttl: TimeInterval
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var cached: (list: GatewayVoiceList, at: Date)?

    public static let defaultTTL: TimeInterval = 60

    public init(engines: [String: URL], ttl: TimeInterval = VoiceListing.defaultTTL,
                fetch: Fetch? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.engines = engines
        self.ttl = ttl
        self.now = now
        self.fetch = fetch ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func list() async -> GatewayVoiceList {
        if let cached, now().timeIntervalSince(cached.at) < ttl { return cached.list }
        var voices: [GatewayVoiceList.Voice] = []
        var sources: [String: String] = [:]
        for (engine, base) in engines.sorted(by: { $0.key < $1.key }) {
            if let ids = await listed(base) {
                voices += ids.map { GatewayVoiceList.Voice(engine: engine, id: $0, language: Self.language(engine, $0)) }
                sources[engine] = "server"
            } else if engine == "kokoro" {
                voices += VoiceCatalogue.kokoroEnglishVoices.map { spec in
                    let id = String(spec.dropFirst("kokoro:".count))
                    return GatewayVoiceList.Voice(engine: engine, id: id, language: Self.language(engine, id))
                }
                sources[engine] = "built-in"
            } else {
                sources[engine] = "unavailable"
            }
        }
        let list = GatewayVoiceList(voices: voices, sources: sources)
        cached = (list, now())
        return list
    }

    /// The engine's own list, or nil when it does not answer with one.
    private func listed(_ base: URL) async -> [String]? {
        var request = URLRequest(url: base.appendingPathComponent("v1/audio/voices"))
        request.timeoutInterval = 5
        guard let (data, status) = try? await fetch(request), (200..<300).contains(status),
              let ids = try? KokoroAPI.parseVoices(data) else { return nil }
        return ids
    }

    private static func language(_ engine: String, _ id: String) -> String? {
        VoiceCatalogue.declaredLanguage("\(engine):\(id)")
    }
}
