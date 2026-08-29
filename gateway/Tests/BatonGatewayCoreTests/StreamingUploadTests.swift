import Foundation
import XCTest
@testable import BatonGatewayCore

/// Receiving a large body straight to disk.
///
/// **Splitting is the entire risk in this kind of code**, and it is the reason these tests feed
/// the sink by hand rather than over a socket. The pairing short read shipped exactly
/// because nothing ever checked that a payload arriving in several pieces reassembled: its socket
/// tests would not come up in the time available and were parked as skipped, so a single-segment
/// read looked correct until a real export outgrew one TCP segment. A sink that takes `Data` and
/// says "need more" can be split at every byte boundary in a loop, with no sockets involved.
final class StreamingUploadTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-upload-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sink(max: Int = 1_000_000) -> StreamingUpload {
        StreamingUpload(stagingDirectory: dir, maximumBodyBytes: max)
    }

    private func request(body: Data, path: String = "/v1/files/abc123",
                         extra: String = "") -> Data {
        var head = "PUT \(path) HTTP/1.1\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Content-Type: audio/mp4\r\n"
        head += extra
        head += "\r\n"
        return Data(head.utf8) + body
    }

    // MARK: - Reassembly

    func testABodyArrivingInOnePieceLandsOnDisk() throws {
        let body = Data(repeating: 0x41, count: 5000)
        let upload = sink()
        guard case let .complete(url, req) = upload.consume(request(body: body)) else {
            return XCTFail("did not complete")
        }
        XCTAssertEqual(try Data(contentsOf: url), body)
        XCTAssertEqual(req.method, "PUT")
        XCTAssertEqual(req.path, "/v1/files/abc123")
        XCTAssertEqual(req.header("Content-Type"), "audio/mp4")
        XCTAssertEqual(req.contentLength, 5000)
    }

    /// The one that matters. Every split point, including inside the header block and across the
    /// blank line that ends it.
    func testTheBodyReassemblesNoMatterWhereTheSegmentsFall() throws {
        let body = Data((0..<3000).map { UInt8($0 % 251) })
        let whole = request(body: body)

        for split in stride(from: 1, to: whole.count, by: 37) {
            let upload = sink()
            var result = upload.consume(whole.prefix(split))
            if case .needMore = result {
                result = upload.consume(whole.suffix(from: split))
            }
            guard case let .complete(url, _) = result else {
                return XCTFail("split at \(split) never completed: \(result)")
            }
            XCTAssertEqual(try Data(contentsOf: url), body, "split at \(split) reassembled wrongly")
        }
    }

    /// A byte at a time is the pathological case, and the cheapest proof that nothing depends on
    /// arriving in convenient pieces.
    func testItReassemblesOneByteAtATime() throws {
        let body = Data(repeating: 0x42, count: 300)
        let whole = request(body: body)
        let upload = sink()
        var final: StreamingUpload.Step = .needMore
        for byte in whole {
            final = upload.consume(Data([byte]))
            if case .complete = final { break }
        }
        guard case let .complete(url, _) = final else { return XCTFail("never completed") }
        XCTAssertEqual(try Data(contentsOf: url), body)
    }

    func testAnEmptyBodyIsAllowedAndCompletesImmediately() throws {
        let upload = sink()
        guard case let .complete(url, req) = upload.consume(request(body: Data())) else {
            return XCTFail("did not complete")
        }
        XCTAssertEqual(req.contentLength, 0)
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    // MARK: - Refusals, and what they leave behind

    /// Refused from the declared length, before any body is read. Checking after the fact would
    /// make the limit a way to fill the disk rather than a guard against it.
    func testTooLargeIsRefusedFromContentLengthBeforeAnythingIsWritten() {
        let upload = sink(max: 1000)
        let head = Data("PUT /v1/files/abc HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)
        guard case let .rejected(status, _) = upload.consume(head) else {
            return XCTFail("a body over the cap was accepted")
        }
        XCTAssertTrue(status.hasPrefix("413"))
        XCTAssertNil(upload.stagingURL, "a refused upload staged a file anyway")
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0)
    }

    /// A PUT with no length is a client bug. Storing an empty file would be the least helpful
    /// possible response to it.
    func testAMissingContentLengthIsRefused() {
        let upload = sink()
        let head = Data("PUT /v1/files/abc HTTP/1.1\r\nContent-Type: audio/mp4\r\n\r\n".utf8)
        guard case let .rejected(status, _) = upload.consume(head) else {
            return XCTFail("accepted a request with no content-length")
        }
        XCTAssertTrue(status.hasPrefix("411"))
    }

    /// Without this a peer could open a connection, dribble header bytes forever, and hold a
    /// staging slot with no `Content-Length` ever reached and no cap ever tested.
    func testEndlessHeadersAreRefused() {
        let upload = sink()
        var step: StreamingUpload.Step = .needMore
        // No terminator, ever.
        for _ in 0...(StreamingUpload.maximumHeaderBytes / 1000 + 2) {
            step = upload.consume(Data(repeating: 0x41, count: 1000))
            if case .rejected = step { break }
        }
        guard case let .rejected(status, _) = step else { return XCTFail("headers grew unbounded") }
        XCTAssertTrue(status.hasPrefix("431"))
    }

    /// A peer that sends more than it promised must not grow the file past the size the limit was
    /// checked against.
    func testExtraBytesBeyondContentLengthAreNotWritten() throws {
        let body = Data(repeating: 0x43, count: 100)
        let upload = sink()
        var message = request(body: body)
        message.append(Data(repeating: 0x44, count: 5000))   // a liar

        guard case let .complete(url, _) = upload.consume(message) else {
            return XCTFail("did not complete")
        }
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written.count, 100, "wrote past the declared length")
        XCTAssertFalse(written.contains(0x44), "content past content-length reached the file")
    }

    func testCancelRemovesThePartialFile() throws {
        let body = Data(repeating: 0x45, count: 4000)
        let whole = request(body: body)
        let upload = sink()
        _ = upload.consume(whole.prefix(200))          // headers plus a little body
        let staged = try XCTUnwrap(upload.stagingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        upload.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path),
                       "an abandoned upload left its partial file on the gateway's disk")
    }

    // MARK: - Head parsing

    func testHeaderNamesAreCaseInsensitive() {
        let head = Data("put /v1/files/AB HTTP/1.1\r\nCONTENT-LENGTH: 7\r\nX-Baton-Name: a.m4a\r\n\r\n".utf8)
        let parsed = StreamingUpload.parseHead(head.prefix(head.count - 2))
        XCTAssertEqual(parsed?.contentLength, 7)
        XCTAssertEqual(parsed?.method, "PUT", "the method should be normalised")
        XCTAssertEqual(parsed?.header("x-baton-name"), "a.m4a")
        XCTAssertEqual(parsed?.header("X-Baton-Name"), "a.m4a")
    }

    func testAMalformedRequestLineIsRefused() {
        let upload = sink()
        guard case .rejected = upload.consume(Data("garbage\r\n\r\n".utf8)) else {
            return XCTFail("accepted a malformed request line")
        }
    }
}
