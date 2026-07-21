import XCTest
@testable import Baton

///  / TEST-04: SpeechService takes an injectable URLSession, so its request shaping and
/// response handling are testable against a stubbed transport instead of a live TTS host.
final class SpeechServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SpeechConfig.defaults = UserDefaults(suiteName: "speech-svc-\(UUID().uuidString)")!
        SpeechConfig.kokoroBaseURL = "https://tts.example.com"
    }

    override func tearDown() {
        NavidromeMockURLProtocol.handler = nil
        SpeechConfig.defaults = .standard
        super.tearDown()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testSynthesizePostsToTheSpeechEndpointAndReturnsAudio() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        NavidromeMockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("RIFF....WAVEdata".utf8))
        }
        let voice = SpeechConfig.Voice(engine: .kokoro, voice: "af_sky")
        let data = try await SpeechService.synthesize(text: "hello", voice: voice, session: mockSession())
        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedPath, "/v1/audio/speech", "OpenAI-schema speech endpoint under the configured host")
        XCTAssertFalse(data.isEmpty)
    }

    func testSynthesizeMapsHTTPErrorToSynthError() async {
        NavidromeMockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("model loading".utf8))
        }
        let voice = SpeechConfig.Voice(engine: .kokoro, voice: "af_sky")
        do {
            _ = try await SpeechService.synthesize(text: "hi", voice: voice, session: mockSession())
            XCTFail("a 503 should throw")
        } catch let error as SpeechService.SynthError {
            XCTAssertTrue(error.message.contains("503"), "the status code should surface in the error")
        } catch {
            XCTFail("expected SynthError, got \(error)")
        }
    }
}
