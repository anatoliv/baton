import XCTest
@testable import BatonPlaybackKit

/// Coverage for the MPL-adapted download-integrity layer (Packages/BatonPlaybackKit/…/MPL):
/// container sniffing by magic bytes, and rejection of Subsonic error-as-200 envelopes and
/// truncated transcodes before they poison the download store or the gapless prefetch cache.
final class AudioIntegrityTests: XCTestCase {
    // MARK: - Container sniffing

    func testSniffRecognizesEveryContainer() {
        XCTAssertEqual(AudioContainer.sniff(magic: Array("fLaC....".utf8)), .flac)
        XCTAssertEqual(AudioContainer.sniff(magic: Array("OggS....".utf8)), .ogg)
        XCTAssertEqual(AudioContainer.sniff(magic: Array("RIFF....WAVE".utf8)), .wav)
        XCTAssertEqual(AudioContainer.sniff(magic: Array("FORM....AIFF".utf8)), .aiff)
        XCTAssertEqual(AudioContainer.sniff(magic: Array("FORM....AIFC".utf8)), .aiff)
        XCTAssertEqual(AudioContainer.sniff(magic: [0, 0, 0, 0x18] + Array("ftypM4A ".utf8)), .mp4)
        XCTAssertEqual(AudioContainer.sniff(magic: Array("ID3.....".utf8)), .mp3)
        XCTAssertEqual(AudioContainer.sniff(magic: [0xFF, 0xFB, 0x90, 0x00]), .mp3) // bare MPEG frame sync
    }

    func testSniffRejectsNonAudio() {
        XCTAssertNil(AudioContainer.sniff(magic: Array("<?xml ve".utf8)))
        XCTAssertNil(AudioContainer.sniff(magic: Array(#"{"subson"#.utf8)))
        XCTAssertNil(AudioContainer.sniff(magic: []))
        XCTAssertNil(AudioContainer.sniff(magic: [0x00]))
    }

    /// The bug this exists for: a server declaring one container while sending another.
    /// The file must be named after its bytes, so the parser matches the content.
    func testSniffOnDiskCorrectsMislabeledFLAC() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mislabeled.m4a")
        try Data("fLaC".utf8 + [0, 0, 0, 0x22] + Data(count: 64)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AudioContainer.sniff(atPath: url.path), .flac)
    }

    // MARK: - Response validation

    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func response(length: Int64 = -1, mime: String? = nil) -> URLResponse {
        HTTPURLResponse(
            url: URL(string: "https://music.example.com/rest/stream.view")!,
            statusCode: 200, httpVersion: nil,
            headerFields: mime.map { ["Content-Type": $0] }
        ).map { http in
            // expectedContentLength on HTTPURLResponse comes from Content-Length; build a
            // plain URLResponse when a specific length is needed.
            length >= 0
                ? URLResponse(url: http.url!, mimeType: mime, expectedContentLength: Int(length), textEncodingName: nil)
                : http
        }!
    }

    func testValidatorRejectsEmptyBody() throws {
        let file = try tempFile(Data())
        XCTAssertThrowsError(try AudioResponseValidator.validate(
            fileAt: file, response: response(), songId: "s", logger: .init(subsystem: "t", category: "t")
        ))
    }

    func testValidatorRejectsTruncatedTranscode() throws {
        let file = try tempFile(Data(count: 500))
        XCTAssertThrowsError(try AudioResponseValidator.validate(
            fileAt: file, response: response(length: 1000), songId: "s", logger: .init(subsystem: "t", category: "t")
        ))
    }

    func testValidatorRejectsErrorEnvelopeDespiteAudioContentType() throws {
        // The hard case: proxy declares audio/mpeg but the body is a Subsonic XML error.
        let file = try tempFile(Data("  <subsonic-response status=\"failed\"/>".utf8))
        XCTAssertThrowsError(try AudioResponseValidator.validate(
            fileAt: file, response: response(mime: "audio/mpeg"), songId: "s", logger: .init(subsystem: "t", category: "t")
        ))
    }

    func testValidatorRejectsJSONEnvelopeAfterBOM() throws {
        let file = try tempFile(Data([0xEF, 0xBB, 0xBF]) + Data(#"{"subsonic-response":{}}"#.utf8))
        XCTAssertThrowsError(try AudioResponseValidator.validate(
            fileAt: file, response: response(), songId: "s", logger: .init(subsystem: "t", category: "t")
        ))
    }

    func testValidatorAcceptsRealAudioWithoutContentType() throws {
        // Valid MP3 bytes behind a proxy that stripped the Content-Type: must pass.
        let file = try tempFile(Data([0xFF, 0xFB, 0x90, 0x00]) + Data(count: 2048))
        XCTAssertNoThrow(try AudioResponseValidator.validate(
            fileAt: file, response: response(), songId: "s", logger: .init(subsystem: "t", category: "t")
        ))
    }
}
