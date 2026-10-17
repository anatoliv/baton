import BatonDocuments
import BatonMCPProtocol
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonGatewayCore

/// The expressive voice server on the Baton server: configured from the environment,
/// listed for the phone's pickers beside Kokoro, and previewed the way it narrates. Not
/// `@MainActor` as a class, for Linux test discovery; the tests that dispatch are main-actor one
/// by one.
final class ExpressiveEngineGatewayTests: XCTestCase {
    func testTheEnvironmentNamesTheServerItsModelAndAKeyFromAFile() throws {
        let endpoints = SpeechEngineConfig.endpoints([
            "BATON_TTS_KOKORO_URL": "http://kokoro.test:8880",
            "BATON_TTS_OPENAI_URL": "http://qwen.test:8190/v1",
            "BATON_TTS_OPENAI_KEY_FILE": "/run/secrets/tts",
        ], readFile: { path in
            guard path == "/run/secrets/tts" else { throw SpeechEngineConfig.KeyFileError.unreadable }
            return "file-key\n"
        })
        XCTAssertEqual(endpoints.map(\.engine), ["kokoro", "openai"])
        let expressive = try XCTUnwrap(endpoints.last)
        XCTAssertEqual(expressive.baseURL, URL(string: "http://qwen.test:8190"), "an OpenAI client's /v1 address works")
        XCTAssertEqual(expressive.requestModel, "qwen3-tts")
        XCTAssertEqual(expressive.apiKey, "file-key")

        let plain = SpeechEngineConfig.endpoints(["BATON_TTS_OPENAI_URL": "http://qwen.test:8190", "BATON_TTS_OPENAI_MODEL": "my-tts",
                                                  "BATON_TTS_OPENAI_KEY": "env-key", "BATON_TTS_CHATTERBOX_URL": "http://cb.test:8004"])
        XCTAssertEqual(plain.map(\.engine), ["kokoro", "chatterbox", "openai"])
        XCTAssertEqual(plain[0].baseURL, URL(string: "http://127.0.0.1:8880"), "Kokoro's default, as before")
        XCTAssertEqual(plain[2].requestModel, "my-tts")
        XCTAssertEqual(plain[2].apiKey, "env-key")
        XCTAssertEqual(SpeechEngineConfig.endpoints(["BATON_TTS_OPENAI_URL": "not a url"]).map(\.engine), ["kokoro"])
    }

    /// Only http and https, as on the Mac: anything else is not used, and the log says so.
    func testAnAddressMustBeHTTPOrHTTPS() {
        let loaded = SpeechEngineConfig.load(["BATON_TTS_OPENAI_URL": "ftp://qwen.test:8190",
                                              "BATON_TTS_CHATTERBOX_URL": "file:///etc/passwd",
                                              "BATON_TTS_KOKORO_URL": "gopher://kokoro.test:70"])
        XCTAssertEqual(loaded.endpoints.map(\.engine), ["kokoro"])
        XCTAssertEqual(loaded.endpoints[0].baseURL, URL(string: "http://127.0.0.1:8880"), "Kokoro's default instead")
        XCTAssertEqual(loaded.problems.count, 3)
        XCTAssertTrue(loaded.problems.allSatisfy { $0.contains("not an http or https address") })
        XCTAssertEqual(SpeechEngineConfig.endpoints(["BATON_TTS_OPENAI_URL": "HTTPS://qwen.test"]).map(\.engine), ["kokoro", "openai"])
    }

    /// A key file its group or anyone else can read is refused, and the server is off until it
    /// is chmod 600; the log line never carries the key.
    func testAKeyFileOthersCanReadIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tts-key")
        try Data("not-a-real-key-123\n".utf8).write(to: file)
        let env = ["BATON_TTS_OPENAI_URL": "http://qwen.test:8190", "BATON_TTS_OPENAI_KEY_FILE": file.path]

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let open = SpeechEngineConfig.load(env)
        XCTAssertEqual(open.endpoints.map(\.engine), ["kokoro"], "off until the file is private")
        XCTAssertEqual(open.problems.count, 1)
        XCTAssertTrue(open.problems[0].contains("chmod 600") && open.problems[0].contains("644"), open.problems[0])
        XCTAssertFalse(open.problems[0].contains("not-a-real-key"))
        XCTAssertThrowsError(try SpeechEngineConfig.readPrivateFile(file.path)) {
            XCTAssertEqual($0 as? SpeechEngineConfig.KeyFileError, .tooOpen(mode: 0o644))
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        XCTAssertEqual(SpeechEngineConfig.load(env).endpoints.map(\.engine), ["kokoro"], "group-readable is refused too")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let closed = SpeechEngineConfig.load(env)
        XCTAssertEqual(closed.problems, [])
        XCTAssertEqual(closed.endpoints.last?.apiKey, "not-a-real-key-123")

        let missing = SpeechEngineConfig.load(["BATON_TTS_OPENAI_URL": "http://qwen.test:8190",
                                               "BATON_TTS_OPENAI_KEY_FILE": dir.appendingPathComponent("absent").path])
        XCTAssertEqual(missing.endpoints.map(\.engine), ["kokoro"])
        XCTAssertEqual(missing.problems.count, 1)
    }

    /// A Qwen3-TTS server that answers without a voice list offers its presets; every engine is
    /// listed, Kokoro first.
    func testTheExpressiveServersVoicesAreListedBesideKokoros() async {
        let servers = VoiceListingTests.StandIns([
            "kokoro.test": Data(#"{"voices":["af_heart"]}"#.utf8),
            "qwen.test": Data("{}".utf8),
        ])
        let listing = BatonGatewayCore.VoiceListing(endpoints: [
            SpeechEngineEndpoint(engine: "openai", baseURL: URL(string: "http://qwen.test:8190")!),
            SpeechEngineEndpoint(engine: "kokoro", baseURL: URL(string: "http://kokoro.test:8880")!),
        ], fetch: { try servers.fetch($0) })
        let list = await listing.list()
        XCTAssertEqual(list.specs.first, "kokoro:af_heart")
        XCTAssertTrue(list.specs.contains("openai:Aiden"))
        XCTAssertEqual(list.voices.filter { $0.engine == "openai" }.count, 9)
        XCTAssertEqual(list.sources, ["kokoro": "server", "openai": "built-in"])
    }

    @MainActor
    func testAnExpressiveVoiceIsPreviewedAsItNarrates() async throws {
        final class Recorder: SpeechSynthesizing, @unchecked Sendable {
            private let lock = NSLock()
            private var _instructions: [String?] = []
            var instructions: [String?] { lock.withLock { _instructions } }
            func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
                try await synthesize(text: text, voice: voice, speed: speed, style: nil, instruction: nil)
            }
            func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?, instruction: String?) async throws -> Data {
                lock.withLock { _instructions.append(instruction) }
                return FakeSynthesizer.tone(seconds: 0.05)
            }
        }
        let recorder = Recorder()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("expressive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Router(token: "t", routes: BookRoutes(renderer: nil, store: BookStore(directory: dir), synthesizer: recorder,
                                                          unavailableReason: nil).routes())
        func preview(_ body: [String: Any]) async -> Data {
            await router.dispatch(HTTPRequestMessage(method: "POST", path: "/v1/speech/preview", query: [:],
                                                     headers: ["authorization": "Bearer t"],
                                                     body: try! JSONSerialization.data(withJSONObject: body)))
        }
        _ = await preview(["text": "Imagine a small room.", "voice": "openai:Ryan"])
        // A caller's own instruction is not taken: the preview says what the gateway says.
        _ = await preview(["text": "Imagine a small room.", "voice": "openai:Ryan",
                           "instruction": "Whisper it. " + String(repeating: "x", count: 10_000)])
        _ = await preview(["text": "Imagine a small room.", "voice": "kokoro:af_heart"])
        XCTAssertEqual(recorder.instructions.count, 3)
        XCTAssertTrue(recorder.instructions[0]?.contains("audiobook narrator") == true)
        XCTAssertEqual(recorder.instructions[1], recorder.instructions[0])
        XCTAssertNil(recorder.instructions[2], "Kokoro is sent no instruction")
    }
}
