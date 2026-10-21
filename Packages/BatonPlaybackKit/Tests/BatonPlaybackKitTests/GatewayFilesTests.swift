import CryptoKit
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// Moving a file between devices through the home gateway.
///
/// The transfer itself needs a gateway, so what is asserted here is the part that decides whether
/// a transfer can be trusted: the digest. It is computed on the sender, carried as a header, and
/// re-checked by the receiver, because the gateway cannot verify content — CryptoKit is Apple-only
/// and it runs on Linux. If this hashing is wrong, every file "verifies" and the check is theatre.
final class GatewayFilesTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-gwfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent("\(UUID().uuidString).bin")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    /// The digest is read in 1 MB slices so hashing a large file costs a buffer rather than the
    /// whole file. That is only worth doing if the streamed result equals the one-shot result, and
    /// the interesting sizes are the ones around the slice boundary.
    func testStreamedHashingMatchesHashingItAllAtOnce() throws {
        let slice = 1024 * 1024
        for size in [0, 1, 1024, slice - 1, slice, slice + 1, slice * 2 + 7] {
            let url = try write(size)
            let streamed = try GatewayFiles.sha256(of: url)
            let oneShot = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(streamed, oneShot, "streamed hashing diverged at \(size) bytes")
        }
    }

    /// Lower-case hex, 64 characters — the form the gateway's id whitelist accepts. A digest
    /// formatted any other way would be refused as a bad id, and the failure would look like a
    /// gateway problem rather than a formatting one.
    func testTheDigestIsLowercaseHexAndUsableAsAFileID() throws {
        let digest = try GatewayFiles.sha256(of: try write(4096))
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, digest.lowercased())
        XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) }, digest)
    }

    /// Two identical files hash the same, which is what makes an upload idempotent: re-sending
    /// after a dropped connection replaces one entry instead of accumulating a second.
    func testIdenticalContentGivesTheSameIDAndDifferentContentDoesNot() throws {
        let a = try write(2048)
        let b = dir.appendingPathComponent("copy.bin")
        try FileManager.default.copyItem(at: a, to: b)
        XCTAssertEqual(try GatewayFiles.sha256(of: a), try GatewayFiles.sha256(of: b))

        let c = try write(2049)
        XCTAssertNotEqual(try GatewayFiles.sha256(of: a), try GatewayFiles.sha256(of: c))
    }

    /// The message a person sees says what to do; the digests go to the log. Two hex strings in
    /// an alert are not something anyone can act on.
    func testACorruptedTransferSaysSomethingActionable() {
        let error = GatewayFiles.TransferError.corrupted(expected: "aaa", got: "bbb")
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("damaged"), message)
        XCTAssertFalse(message.contains("aaa"), "raw digests belong in the log, not in the message")
    }

    func testAnUnconfiguredGatewaySaysWhereToSetItUp() {
        let message = GatewayFiles.TransferError.notConfigured.errorDescription ?? ""
        XCTAssertTrue(message.contains("Settings"), message)
    }

    /// The phone and the Mac put a listed id into a file path. The gateway only ever issues hex
    /// and dashes, so anything else in a listing (an id like `../x`) is dropped rather than
    /// trusted to stay inside a temporary folder (TBX-1000000480 B-19).
    func testAListingDropsIDsTheGatewayWouldNeverIssue() async throws {
        let good = String(repeating: "ab", count: 32)
        ListingStub.body = Data("""
        [{"id":"\(good)","name":"a.md","contentType":"text/markdown","size":1,"createdAt":"2026-10-21T10:00:00Z"},
         {"id":"x/../../y","name":"b.md","contentType":"text/markdown","size":1,"createdAt":"2026-10-21T10:00:00Z"},
         {"id":"../x","name":"c.md","contentType":"text/markdown","size":1,"createdAt":"2026-10-21T10:00:00Z"},
         {"id":"","name":"d.md","contentType":"text/markdown","size":1,"createdAt":"2026-10-21T10:00:00Z"}]
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ListingStub.self]
        let files = GatewayFiles(gatewayURL: URL(string: "http://gateway-files-listing.test")!, token: "t",
                                 session: URLSession(configuration: configuration))
        let listed = try await files.list()
        XCTAssertEqual(listed.map(\.id), [good])
    }
}

private final class ListingStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
