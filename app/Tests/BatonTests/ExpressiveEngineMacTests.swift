import BatonDocuments
import BatonSubsonicKit
import Foundation
import Testing
@testable import Baton

/// The expressive voice server on the Mac: its settings, the Mac's book synthesizer
/// passing each line's delivery instruction through to it, and its voices in the Mac's pickers
/// beside Kokoro's. The package's own tests (`ExpressiveEngineTests`) pin the request, the
/// listing and the pacing against a loopback server; these pin the Mac's side.
@MainActor
@Suite("Expressive voice server", .serialized)
struct ExpressiveEngineMacTests {
    private func withSettings(_ body: () async throws -> Void) async rethrows {
        let suite = ThrowawayDefaults.name("expressive")
        let defaults = UserDefaults(suiteName: suite)!
        let savedBooks = BookVoiceSettings.defaults, savedSpeech = SpeechConfig.defaults
        BookVoiceSettings.defaults = defaults
        SpeechConfig.defaults = defaults
        defer {
            BookVoiceSettings.defaults = savedBooks
            SpeechConfig.defaults = savedSpeech
            defaults.removePersistentDomain(forName: suite)
        }
        try await body()
    }

    @Test("The server comes from Settings: an OpenAI client's /v1 address works, and a blank or odd one is none")
    func endpointFromSettings() async {
        await withSettings {
            #expect(BookVoiceSettings.expressiveEndpoint(key: nil) == nil)
            BookVoiceSettings.expressiveURL = "  http://qwen.test:8190/v1 "
            let endpoint = BookVoiceSettings.expressiveEndpoint(key: "a-key")
            #expect(endpoint?.baseURL == URL(string: "http://qwen.test:8190"))
            #expect(endpoint?.requestModel == "qwen3-tts")
            #expect(endpoint?.apiKey == "a-key")
            BookVoiceSettings.expressiveModel = "Qwen3-TTS-12Hz-1.7B-CustomVoice"
            #expect(BookVoiceSettings.expressiveEndpoint(key: "")?.apiKey == nil, "an empty key is no key")
            #expect(BookVoiceSettings.expressiveEndpoint(key: nil)?.requestModel == "Qwen3-TTS-12Hz-1.7B-CustomVoice")
            BookVoiceSettings.expressiveURL = "ftp://qwen.test"
            #expect(BookVoiceSettings.expressiveEndpoint(key: nil) == nil)
        }
    }

    @Test("An expressive voice goes to its server with the line's instruction and key; a Kokoro chunk never reads the Keychain")
    func instructionReachesTheServer() async throws {
        try await withSettings {
            SpeechConfig.kokoroBaseURL = "http://\(ExpressiveStubProtocol.host):8880"
            BookVoiceSettings.expressiveURL = "http://\(ExpressiveStubProtocol.host):8190"
            #expect(ConfiguredSpeechSynthesizer.engines()[SpeechEngines.openAI] == URL(string: "http://\(ExpressiveStubProtocol.host):8190"))
            #expect(BookVoiceSettings.route(voice: "openai:Ryan", engine: .automatic, builtIn: nil) == .server("openai"))

            final class Reads: @unchecked Sendable { var count = 0 }
            let reads = Reads()
            let savedReader = BookVoiceSettings.readExpressiveKey
            BookVoiceSettings.readExpressiveKey = { reads.count += 1; return "stub-key" }
            CappedDownload.testProtocolClasses = [ExpressiveStubProtocol.self]
            defer {
                CappedDownload.testProtocolClasses = []
                BookVoiceSettings.readExpressiveKey = savedReader
            }
            _ = ConfiguredSpeechSynthesizer.engines()
            #expect(reads.count == 0, "naming the engines reads no key")
            var synthesizer = ConfiguredSpeechSynthesizer()
            synthesizer.engineSetting = { .server }
            synthesizer.localEngine = { nil }
            let book: any SpeechSynthesizing = synthesizer
            let wav = try await book.synthesize(text: "I am busy.", voice: "openai:Serena", speed: nil, style: nil,
                                                instruction: "An elderly woman, speaking a line of dialogue.")
            #expect(WAV.parse(wav) != nil)
            let body = try #require(ExpressiveStubProtocol.lastBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["voice"] as? String == "Serena")
            #expect(json["instructions"] as? String == "An elderly woman, speaking a line of dialogue.")
            #expect(json["model"] as? String == "qwen3-tts")
            #expect(ExpressiveStubProtocol.lastAuthorization == "Bearer stub-key")
            #expect(reads.count == 1)

            let kokoro = try await book.synthesize(text: "Hello.", voice: "kokoro:af_heart", speed: nil, style: nil, instruction: nil)
            #expect(WAV.parse(kokoro) != nil)
            #expect(ExpressiveStubProtocol.lastAuthorization == nil, "Kokoro is sent no key")
            #expect(reads.count == 1, "and a Kokoro chunk does not read the Keychain")
        }
    }

    @Test("The pickers list the expressive server's voices after Kokoro's, under every engine setting but Built-in")
    func pickersListEveryEngine() async {
        let kokoroBody = #"{"voices":["af_heart","bm_george"]}"#
        let fetch: DocumentImporter.Fetch = { request in
            let host = request.url?.host ?? ""
            if host == "kokoro.test" {
                return (Data(kokoroBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if host == "qwen.test" {   // answers, with no voice list of its own
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            throw URLError(.cannotConnectToHost)
        }
        let qwen = [SpeechEngineEndpoint(engine: "openai", baseURL: URL(string: "http://qwen.test:8190")!)]
        let builtIn = ["kokoro:af_heart", "kokoro:bf_emma"]
        let server = await VoiceSuggestions.availableVoices(kokoroBase: "http://kokoro.test:8880", others: qwen, builtIn: builtIn,
                                                            engine: .server, fetch: fetch)
        #expect(Array(server.prefix(2)) == ["kokoro:af_heart", "kokoro:bm_george"])
        #expect(server.count == 2 + 9)
        #expect(server.contains("openai:Aiden"))
        let kokoroDown = await VoiceSuggestions.availableVoices(kokoroBase: "http://down.test:8880", others: qwen, builtIn: builtIn,
                                                                engine: .automatic, fetch: fetch)
        #expect(Array(kokoroDown.prefix(2)) == builtIn, "Automatic still falls back to the built-in voices for Kokoro")
        #expect(kokoroDown.contains("openai:Ryan"))
        let onlyBuiltIn = await VoiceSuggestions.availableVoices(kokoroBase: "http://kokoro.test:8880", others: qwen, builtIn: builtIn,
                                                                 engine: .builtIn, fetch: fetch)
        #expect(onlyBuiltIn == builtIn, "Built-in voices on this Mac asks no server")
        #expect(VoiceDirectory.byEngine(server).map(\.title) == ["Kokoro", "Expressive voices"])
    }
}

/// Answers `POST /v1/audio/speech` for one test host only, so nothing else that runs at the same
/// time is intercepted, and keeps the last body it was sent.
final class ExpressiveStubProtocol: URLProtocol, @unchecked Sendable {
    static let host = "expressive.stub.test"
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastAuthorization: String?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(contentsOf: buffer[0..<n])
            }
            stream.close()
        }
        Self.lastBody = body
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        var pcm = Data()
        for i in 0..<1_200 { withUnsafeBytes(of: Int16(2000 * sin(Double(i) / 8)).littleEndian) { pcm.append(contentsOf: $0) } }
        let wav = WAV.header(format: WAV.Format(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16),
                             dataBytes: pcm.count) + pcm
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/wav"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: wav)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
