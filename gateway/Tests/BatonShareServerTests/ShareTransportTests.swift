@testable import BatonGatewayCore
import BatonShareKit
@testable import BatonShareServer
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import XCTest
#if canImport(Glibc)
import Glibc
private let clientStream = Int32(SOCK_STREAM.rawValue)
#else
import Darwin
private let clientStream = SOCK_STREAM
#endif

/// The share service behind the real POSIX transport, over a real socket: the path production
/// takes, including the streaming upload predicate that sends a song to disk instead of memory.
final class ShareTransportTests: XCTestCase {
    func testASongGoesUpAndComesBackOverHTTP() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-http-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try ShareService(config: ShareConfiguration(
            dataDirectory: directory, publicBase: URL(string: "http://127.0.0.1")!, blobDelivery: .direct))
        let transport = Self.transport(for: service)
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

    /// One sharer's own pending share must not let it hold the staging ceiling (TBX-1000000496 D-15
    /// review). Ten 25 MiB uploads to that one share, each sending its head and then nothing, used
    /// to reserve 250 of the 256 MiB, so another sharer's 24 MB song was turned away with 503.
    func testSlowUploadsToOneOwnShareCannotHoldTheStagingCeiling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-slow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try ShareService(config: ShareConfiguration(
            dataDirectory: directory, publicBase: URL(string: "http://127.0.0.1")!, blobDelivery: .direct))
        let listener = try Self.transport(for: service).start(
            port: 0, handle: { service.handle($0).data }, upload: { service.handleUpload($0, file: $1).data })
        defer { listener.stop() }
        let base = "http://127.0.0.1:\(listener.port)"
        let info = ShareClientInfo(platform: "macos", appVersion: "0.20")

        let holder = Base64URL.encode(Data(repeating: 4, count: 32))
        let declared = ShareLimits.standard.maxAudioBytes
        let big = CreateShareRequest(expiresInSeconds: 86400, playCap: 5, preview: ShareMetadata(title: "Held", durationSeconds: 120),
                                     encryptedMeta: nil, durationBucket: nil, audioBytes: declared,
                                     audioSHA256: String(repeating: "a", count: 64), client: info)
        let (bigStatus, bigBody) = try send("POST", "\(base)/v1/share/shares", body: try JSONEncoder().encode(big), secret: holder)
        XCTAssertEqual(bigStatus, 201)
        let held = try JSONDecoder().decode(CreateShareResponse.self, from: bigBody)
        var slow: [Int32] = []
        defer { slow.forEach { close($0) } }
        for _ in 0 ..< 10 {
            let fd = try Self.connect(listener.port)
            slow.append(fd)
            let head = "PUT \(held.uploads.audio) HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(holder)\r\nContent-Length: \(declared)\r\n\r\n"
            _ = Array(head.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        }
        // Until every slow head has been taken in (or 3 s), then count what they hold.
        let staging = service.stagingDirectory.path
        func staged() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: staging)) ?? []).filter { $0.hasPrefix("upload-") }.count }
        for _ in 0 ..< 30 where staged() < 10 { Thread.sleep(forTimeInterval: 0.1) }
        var answers: [String] = []
        for fd in slow {
            var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 200)
            let got = read(fd, &buffer, buffer.count)
            answers.append(got > 0 ? String(decoding: buffer[0 ..< got], as: UTF8.self).components(separatedBy: "\r\n")[0] : "waiting")
        }
        XCTAssertLessThanOrEqual(staged(), 1, "slow uploads to one share holding staging: \(answers)")

        let other = Base64URL.encode(Data(repeating: 5, count: 32))
        let key = ShareCrypto.newKey()
        let sealed = try ShareCrypto.seal(Data(count: 24_000_000), key: key, purpose: .audio)
        let create = CreateShareRequest(expiresInSeconds: 86400, playCap: 5, preview: ShareMetadata(title: "Real", durationSeconds: 120),
                                        encryptedMeta: nil, durationBucket: nil, audioBytes: sealed.count,
                                        audioSHA256: ShareHash.sha256Hex(sealed), client: info)
        let (createStatus, createBody) = try send("POST", "\(base)/v1/share/shares", body: try JSONEncoder().encode(create), secret: other)
        XCTAssertEqual(createStatus, 201)
        let created = try JSONDecoder().decode(CreateShareResponse.self, from: createBody)
        XCTAssertEqual(try send("PUT", base + created.uploads.audio, body: sealed, secret: other).status, 200,
                       "another sharer's song still goes up while the slow uploads hang")
    }

    static func connect(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, clientStream, 0)
        guard fd >= 0 else { throw XCTSkip("no socket") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { close(fd); throw XCTSkip("could not connect") }
        return fd
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

    /// Wired as baton-share's main.swift wires it (TBX-1000000496 D-15).
    static func transport(for service: ShareService) -> POSIXTransport {
        POSIXTransport(stagingDirectory: service.stagingDirectory, maximumBodyBytes: ShareLimits.standard.maxAudioBytes,
                       streamsBody: ShareService.streamsBody,
                       admitsUpload: { service.admitUpload($0) }, uploadDeadline: 900, log: { _ in })
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
