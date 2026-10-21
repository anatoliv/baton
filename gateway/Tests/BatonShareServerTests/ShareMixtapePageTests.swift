import BatonMCPProtocol
import BatonShareKit
import BatonShareServer
import Foundation
import XCTest

final class ShareMixtapePageTests: XCTestCase {
    private var directory: URL!
    private var service: ShareService!
    private let owner = Base64URL.encode(Data(repeating: 25, count: 32))
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mixtape-page-" + UUID().uuidString)
        var config = ShareConfiguration(dataDirectory: directory, publicBase: URL(string: "http://127.0.0.1:18976")!, blobDelivery: .direct)
        config.mixtapesEnabled = true
        service = try ShareService(config: config)
    }
    override func tearDownWithError() throws { service = nil; try? FileManager.default.removeItem(at: directory) }
    private func send(_ path: String, method: String = "GET", body: Data = Data(), crawler: Bool = false) -> ShareResponse {
        service.handle(.init(method: method, path: path, query: [:], headers: ["authorization": "Bearer " + owner,
            "user-agent": crawler ? "Slackbot-LinkExpanding 1.0" : "Synthetic page browser"], body: body))
    }
    private func pending(preview: MixtapePreview? = nil) throws -> String {
        struct Vector: Decodable { let trackID: String?; let ciphertext: String; let ciphertextSHA256: String }
        struct Vectors: Decodable { let positive: [Vector] }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: repo.appendingPathComponent("specs/share-crypto/mixtape-vectors.json"))).positive
        let tracks = Dictionary(uniqueKeysWithValues: vectors.prefix(2).map { ($0.trackID!, MixtapeTrackDescriptor(audioBytes: Data(base64Encoded: $0.ciphertext)!.count, audioSHA256: $0.ciphertextSHA256)) })
        let request = CreateMixtapeRequest(encryptedManifest: vectors[2].ciphertext, tracks: tracks, totalDurationSeconds: 20, expiresInSeconds: 86400, playCap: 2, preview: preview, client: .init(platform: "macos", appVersion: "synthetic"))
        let response = send("/v1/share/mixtapes", method: "POST", body: try JSONEncoder().encode(request))
        XCTAssertEqual(response.status, 201)
        return try JSONDecoder().decode(CreateMixtapeResponse.self, from: response.body).id
    }
    func testPrivateUnfurlContainsNoTrackOrEncryptedMaterialAndSecurityHeaders() throws {
        let id = try pending()
        let response = send("/m/" + id, crawler: true)
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(html.contains("Someone sent you a mixtape"))
        XCTAssertTrue(html.contains("http://127.0.0.1:18976/m/" + id))
        XCTAssertFalse(html.contains("encryptedManifest")); XCTAssertFalse(html.contains("audioSHA256"))
        XCTAssertFalse(html.contains("music.song")); XCTAssertFalse(html.contains("og:image"))
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")
        XCTAssertEqual(response.headers["Referrer-Policy"], "no-referrer")
        XCTAssertTrue(response.headers["Content-Security-Policy"]?.contains("connect-src 'self'") == true)
        XCTAssertTrue(response.headers["Content-Security-Policy"]?.contains("frame-ancestors 'none'") == true)
    }
    func testPublicPreviewEscapesOnlyContainerFieldsAndEndsWithoutPreview() throws {
        let id = try pending(preview: .init(title: "Container <title>", from: "Sender", note: "Note </script>"))
        let html = String(decoding: send("/m/" + id, crawler: true).body, as: UTF8.self)
        XCTAssertTrue(html.contains("Container &lt;title&gt;")); XCTAssertTrue(html.contains("Note &lt;/script&gt;"))
        XCTAssertFalse(html.contains("artist")); XCTAssertFalse(html.contains("encryptedManifest"))
        XCTAssertEqual(send("/v1/share/mixtapes/" + id, method: "DELETE").status, 204)
        let ended = send("/m/" + id)
        XCTAssertEqual(ended.status, 410)
        XCTAssertFalse(String(decoding: ended.body, as: UTF8.self).contains("Container"))
    }
    func testPlaceholderTextInAPreviewIsNotExpanded() throws {
        let id = try pending(preview: .init(title: "{{DATA}}", from: "{{OG_TAGS}}", note: "{{V}}"))
        let html = String(decoding: send("/m/" + id).body, as: UTF8.self)
        XCTAssertEqual(html.components(separatedBy: #""state":"#).count, 2, "the data block appears once: \(html)")
        XCTAssertTrue(html.contains("<title>{{OG_TAGS}} sent you {{DATA}}</title>"), html)
    }
    func testCanonicalRouteAndSeparateMutableAssetsDoNotBecomeSongLinks() throws {
        let id = try pending()
        XCTAssertEqual(send("/m//" + id).status, 404)
        XCTAssertEqual(send("/m/" + id + "/").status, 404)
        XCTAssertEqual(send("/s/" + id).status, 404)
        XCTAssertEqual(send("/m/" + id, method: "POST").status, 405)
        for asset in ["mixtape.mjs", "mixtape.css", "mixtape-manifest.mjs", "share-mixtape-crypto.mjs", "share-crypto.mjs", "icon.svg"] {
            let response = send("/m/_/" + asset)
            XCTAssertEqual(response.status, 200, asset)
            XCTAssertEqual(response.headers["Cache-Control"], "public, no-cache", asset)
        }
        let missing = send("/m/_/missing.mjs")
        XCTAssertEqual(missing.status, 404); XCTAssertEqual(missing.headers["Cache-Control"], "no-store")
        XCTAssertEqual(send("/s/_/mixtape.mjs").status, 404)
    }
    func testDefaultOffPageRevealsNoContainer() throws {
        let id = try pending(preview: .init(title: "Private container"))
        service = nil
        service = try ShareService(config: .init(dataDirectory: directory, blobDelivery: .direct))
        let response = send("/m/" + id)
        XCTAssertEqual(response.status, 409)
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("Mixtapes are unavailable here")); XCTAssertFalse(html.contains(id)); XCTAssertFalse(html.contains("Private container"))
        let config = send("/v1/share/config")
        XCTAssertFalse(String(decoding: config.body, as: UTF8.self).contains("mixtapes"))
    }
}
