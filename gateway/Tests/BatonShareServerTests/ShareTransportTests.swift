@testable import BatonGatewayCore
import BatonShareKit
@testable import BatonShareServer
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import XCTest

/// The share service behind the real POSIX transport, over a real socket: the path production
/// takes, including the streaming upload predicate that sends a song to disk instead of memory.
final class ShareTransportTests: XCTestCase {
    func testASongGoesUpAndComesBackOverHTTP() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-http-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try ShareService(config: ShareConfiguration(
            dataDirectory: directory, publicBase: URL(string: "http://127.0.0.1")!, blobDelivery: .direct))
        let transport = POSIXTransport(stagingDirectory: service.stagingDirectory,
                                       maximumBodyBytes: ShareLimits.standard.maxAudioBytes,
                                       streamsBody: ShareService.streamsBody, log: { _ in })
        let listener = try transport.start(
            port: 0,
            handle: { service.handle($0).data },
            upload: { service.handleUpload($0, file: $1).data })
        defer { listener.stop() }
        let base = "http://127.0.0.1:\(listener.port)"
        let secret = Base64URL.encode(Data(repeating: 3, count: 32))

        // 2 MB: well past the 1 MB a buffered request may carry, so only the streaming path can take it.
        let key = ShareCrypto.newKey()
        let song = Data((0 ..< 2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) })
        let sealed = try ShareCrypto.seal(song, key: key, purpose: .audio)
        let create = CreateShareRequest(
            expiresInSeconds: 86400, playCap: 5,
            preview: ShareMetadata(title: "Over the wire", durationSeconds: 120),
            encryptedMeta: nil, durationBucket: nil, audioBytes: sealed.count,
            audioSHA256: ShareHash.sha256Hex(sealed), client: ShareClientInfo(platform: "macos", appVersion: "0.20"))

        let (createStatus, createBody) = try send("POST", "\(base)/v1/share/shares", body: try JSONEncoder().encode(create),
                                                  secret: secret)
        XCTAssertEqual(createStatus, 201)
        let created = try JSONDecoder().decode(CreateShareResponse.self, from: createBody)

        XCTAssertEqual(try send("PUT", base + created.uploads.audio, body: sealed, secret: secret).status, 200)
        XCTAssertEqual(try send("POST", "\(base)/v1/share/shares/\(created.id)/finalize", secret: secret).status, 200)

        let (status, body) = try send("GET", "\(base)/v1/share/p/\(created.id)/audio")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try ShareCrypto.open(body, key: key, purpose: .audio), song)

        let page = try send("GET", "\(base)/s/\(created.id)")
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("Over the wire"))
        let asset = try send("GET", "\(base)/s/_/share-crypto.mjs")
        XCTAssertEqual(asset.status, 200)
        XCTAssertTrue(String(decoding: asset.body, as: UTF8.self).contains("export async function open"))
    }

    func testPlayerCachePolicyIsPreservedOverHTTPForMutableAndOldQueryUrls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-cache-http-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try ShareService(config: ShareConfiguration(dataDirectory: directory, blobDelivery: .direct))
        let transport = POSIXTransport(stagingDirectory: service.stagingDirectory, loopbackOnly: true, log: { _ in })
        let listener = try transport.start(port: 0, handle: { service.handle($0).data },
                                           upload: { service.handleUpload($0, file: $1).data })
        defer { listener.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for name in ["player.css", "player.mjs", "share-crypto.mjs", "icon.svg"] {
            var current: Data?
            for marker in ["", "?v=" + service.page.version, "?v=retired-deployment-hash"] {
                let url = URL(string: "http://127.0.0.1:\(listener.port)/s/_/" + name + marker)!
                let (body, response) = try await session.data(from: url)
                let http = try XCTUnwrap(response as? HTTPURLResponse)
                XCTAssertEqual(http.statusCode, 200)
                XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "public, no-cache")
                if let current { XCTAssertEqual(body, current) } else { current = body }
            }
        }
    }

    /// The client the apps will use (`BatonShareKit.ShareClient`), against the real service: what
    /// the composer does on Share, what Shared Links does afterwards, and how a refusal surfaces.
    func testTheAppClientSharesListsExtendsAndRevokes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-client-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try ShareService(config: ShareConfiguration(
            dataDirectory: directory, publicBase: URL(string: "http://127.0.0.1")!, blobDelivery: .direct))
        let transport = POSIXTransport(stagingDirectory: service.stagingDirectory,
                                       maximumBodyBytes: ShareLimits.standard.maxAudioBytes,
                                       streamsBody: ShareService.streamsBody, log: { _ in })
        let listener = try transport.start(port: 0, handle: { service.handle($0).data },
                                           upload: { service.handleUpload($0, file: $1).data })
        defer { listener.stop() }
        let base = URL(string: "http://127.0.0.1:\(listener.port)")!
        let client = ShareClient(base: base, secret: ShareClient.newSecret())

        let config = try await client.config()
        XCTAssertEqual(config.defaultPlayCap, 100)

        let song = Data((0 ..< 400_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(count: 2000)
        let meta = ShareMetadata(title: "Client Song", artist: "Kit", durationSeconds: 222, from: "Anatoli",
                                 note: "from the client", accent: "#112233", peaks: [1, 2, 3])
        let info = ShareClientInfo(platform: "ios", appVersion: "1.3 (400)")

        // Public, with art and a card.
        let prepared = try PreparedShare.make(audio: song, metadata: meta, isPrivate: false, expiresInSeconds: 604_800,
                                              playCap: 100, client: info, artwork: jpeg, card: jpeg)
        let progress = ProgressLog()
        let (link, summary) = try await client.share(prepared, progress: { progress.append($0) })
        XCTAssertEqual(summary.status, .ready)
        XCTAssertEqual(progress.values.last, 1)
        let parsed = try XCTUnwrap(ShareLink(url: link, allowedHosts: nil))
        XCTAssertEqual(parsed.key, prepared.key)
        XCTAssertEqual("\(link.scheme!)://\(link.host!)", "http://127.0.0.1", "the link uses the service's public base")
        XCTAssertNil(link.port, "the public base, not the address the client happened to reach")
        let audio = try await URLSession.shared.data(from: base.appendingPathComponent("v1/share/p/\(parsed.id)/audio")).0
        XCTAssertEqual(try ShareCrypto.open(audio, key: parsed.key, purpose: .audio), song)

        // Private: details and artwork sealed, no card even if one is offered.
        let hidden = try PreparedShare.make(audio: song, metadata: meta, isPrivate: true, expiresInSeconds: 86400,
                                            playCap: 3, client: info, artwork: jpeg, card: jpeg)
        XCTAssertNil(hidden.request.preview)
        XCTAssertNil(hidden.card)
        XCTAssertEqual(hidden.request.durationBucket, .threeToFive)
        let (_, hiddenSummary) = try await client.share(hidden)
        XCTAssertNil(hiddenSummary.preview)

        // Shared Links.
        var mine = try await client.list()
        XCTAssertEqual(mine.map(\.id).sorted(), [summary.id, hiddenSummary.id].sorted())
        let extended = try await client.extend(summary.id, bySeconds: 86400)
        XCTAssertGreaterThan(ShareDate.date(extended.expiresAt)!, ShareDate.date(summary.expiresAt)!)
        let recapped = try await client.setPlayCap(hiddenSummary.id, 10)
        XCTAssertEqual(recapped.playCap, 10)
        try await client.revoke(summary.id)
        mine = try await client.list()
        XCTAssertEqual(mine.first { $0.id == summary.id }?.status, .revoked)

        // A refusal arrives as the spec's code, and maps to the reason the next create reports.
        do {
            _ = try await ShareClient(base: base, secret: "nope").list()
            XCTFail("a malformed secret must be refused")
        } catch let failure as ShareClient.Failure {
            XCTAssertEqual(failure, .service(status: 401, code: "unauthorized", message: "Missing or malformed install secret."))
            XCTAssertEqual(failure.reportReason, "other")
        }
        do {
            _ = try await ShareClient(base: URL(string: "http://127.0.0.1:1")!, secret: ShareClient.newSecret()).config()
            XCTFail("nothing listens on port 1")
        } catch let failure as ShareClient.Failure {
            XCTAssertEqual(failure.reportReason, "network")
        }
        XCTAssertThrowsError(try PreparedShare.make(audio: song, metadata: ShareMetadata(title: "", durationSeconds: 1),
                                                    isPrivate: false, expiresInSeconds: 604_800, playCap: 100, client: info))
    }

    private func send(_ method: String, _ url: String, body: Data? = nil, secret: String? = nil) throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body
        if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        let done = expectation(description: "\(method) \(url)")
        nonisolated(unsafe) var result: (Int, Data)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result)
    }
}

/// Progress callbacks arrive off the test's thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}
