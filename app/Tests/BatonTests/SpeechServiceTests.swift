import XCTest
import BatonSpeech
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

/// Naming the failure that cost a day.
///
/// A refused **Local Network** grant makes macOS answer `-1009` for every LAN destination while
/// internet requests carry on succeeding, so the app looks healthy and the server looks asleep.
/// On 2026-08-29 that read as a broken TTS host for hours: a shell reached it in 15 ms, 235 of
/// Baton's own requests succeeded, and every summary quietly used the built-in voice.
///
/// These pin the discrimination, because the whole value is in *not* saying the generic thing.
final class SpeechServiceTransportMessageTests: XCTestCase {

    private func message(_ code: URLError.Code, base: String) -> String {
        SpeechService.transportMessage(URLError(code), engine: "kokoro", base: base)
    }

    func testMinusOneThousandNineOnALANHostNamesTheLocalNetworkSetting() {
        let text = message(.notConnectedToInternet, base: "http://192.168.1.50:8880")
        XCTAssertTrue(text.contains("Local Network"), "did not name the setting: \(text)")
        XCTAssertTrue(text.contains("192.168.1.50"), "did not name the host: \(text)")
        XCTAssertTrue(text.contains("off and on"), "did not say what to do after an update: \(text)")
    }

    /// The same error against an internet host really does mean there is no network, so the
    /// specific advice would be wrong there.
    func testMinusOneThousandNineOnAnInternetHostStaysGeneric() {
        let text = message(.notConnectedToInternet, base: "https://music.example.com")
        XCTAssertFalse(text.contains("Local Network"),
                       "claimed a Local Network problem for an internet host: \(text)")
    }

    /// A host that is genuinely absent gives `-1004`, and must not be relabelled as a
    /// permissions problem. Sending someone to System Settings for a sleeping server is a worse
    /// outcome than the generic message.
    func testCannotConnectToHostStaysGenericEvenOnTheLAN() {
        let text = message(.cannotConnectToHost, base: "http://192.168.1.50:8880")
        XCTAssertFalse(text.contains("Local Network"),
                       "blamed the grant for an ordinary connection failure: \(text)")
    }

    func testPrivateAddressRecognition() {
        for host in ["192.168.1.50", "10.0.0.4", "172.16.0.1", "172.31.255.254", "127.0.0.1",
                     "nas.local", "localhost"] {
            XCTAssertTrue(SpeechService.isPrivateAddress(host), "\(host) should be private")
        }
        for host in ["8.8.8.8", "172.32.0.1", "music.example.com", "example.com"] {
            XCTAssertFalse(SpeechService.isPrivateAddress(host), "\(host) should not be private")
        }
    }
}
