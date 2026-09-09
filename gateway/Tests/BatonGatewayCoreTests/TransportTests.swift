import BatonMCPProtocol
import Foundation
import XCTest
@testable import BatonGatewayCore

#if canImport(Glibc)
import Glibc
private let clientSocketType = Int32(SOCK_STREAM.rawValue)
#else
import Darwin
private let clientSocketType = SOCK_STREAM
#endif

/// The POSIX transport, over real sockets.
///
/// **These tests could not exist before this card.** The transport lived in the executable target,
/// which no test target can import, and the POSIX half was behind `#else` — so on a Mac it was not
/// merely untested, it was never compiled. Both defects below shipped for that reason. Moving it
/// into `BatonGatewayCore` is what makes them assertable, and the fixes are the same code on Linux
/// and here: the guarantee is `signal(SIGPIPE, SIG_IGN)`, not a per-socket Darwin option, so what
/// passes on this Mac is the mechanism the gateway actually runs with.
///
/// Every test is deliberately **not** `async`: the client half does blocking socket reads, and on
/// the cooperative pool that would compete for the very threads the server's connection tasks need.
final class TransportTests: XCTestCase {

    // MARK: - Harness

    /// Log lines the transport wrote, collected from whichever thread wrote them.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func write(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private var staging: URL!
    private var listener: POSIXTransport.Listener?

    override func setUpWithError() throws {
        staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-transport-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        listener?.stop()
        listener = nil
        try? FileManager.default.removeItem(at: staging)
    }

    /// Start a transport on a port the kernel picks, so tests never collide.
    private func start(
        readTimeout: TimeInterval = 15,
        log: @escaping @Sendable (String) -> Void = { _ in },
        handle: @escaping @Sendable (HTTPRequestMessage) async -> Data = { _ in
            httpResponse(status: "200 OK", body: #"{"ok":true}"#)
        },
        upload: @escaping @Sendable (StreamingUpload.Request, URL) async -> Data = { _, staged in
            try? FileManager.default.removeItem(at: staged)
            return httpResponse(status: "201 Created", body: #"{"ok":true}"#)
        }
    ) throws -> UInt16 {
        let transport = POSIXTransport(stagingDirectory: staging,
                                       maximumBodyBytes: 1024 * 1024,
                                       readTimeout: readTimeout,
                                       log: log)
        let started = try transport.start(port: 0, handle: handle, upload: upload)
        listener = started
        return started.port
    }

    /// A connected client socket, with its own receive deadline so a broken server fails the test
    /// instead of hanging it.
    private func open(_ port: UInt16, receiveTimeout: TimeInterval = 5) throws -> Int32 {
        let fd = socket(AF_INET, clientSocketType, 0)
        try XCTSkipIf(fd < 0, "could not open a client socket")
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected >= 0 else {
            close(fd)
            throw XCTSkip("could not connect to the test transport on :\(port)")
        }
        var timeout = timeval(tv_sec: Int(receiveTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Whether this process would survive a write to a dead peer. Read by setting and putting
    /// back, because there is no portable way to read a disposition without touching it.
    private func sigpipeIsIgnored() -> Bool {
        let previous = signal(SIGPIPE, SIG_IGN)
        signal(SIGPIPE, previous)
        return unsafeBitCast(previous, to: UInt.self) == unsafeBitCast(SIG_IGN, to: UInt.self)
    }

    /// Named so it does not shadow the C `send`, which this then calls unqualified — module
    /// qualification would have to differ between Darwin and Glibc for no gain.
    private func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Read until the server closes, which it always does — every response says `Connection: close`.
    private func readAll(_ fd: Int32) -> String {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytes = read(fd, &chunk, chunk.count)
            if bytes <= 0 { break }
            out.append(contentsOf: chunk[0 ..< bytes])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func request(_ port: UInt16, _ head: String = "GET /health HTTP/1.1\r\nHost: x\r\n\r\n") throws -> String {
        let fd = try open(port)
        defer { close(fd) }
        write(fd, head)
        return readAll(fd)
    }

    // MARK: - S-F4: a client that closes early must not take the gateway with it

    /// Fifty connections that send a request and hang up before the answer, then one that waits.
    ///
    /// A phone cancelling a download, a curl that is Ctrl-C'd, or a client giving up on a slow
    /// agent turn all produce this, unauthenticated, and on Linux the write that follows raised
    /// SIGPIPE whose default disposition terminates the process.
    ///
    /// **What this can and cannot prove, said plainly.** The disposition assertion is the real
    /// check: with the fix reverted it fails with this exact line, on this Mac, in 0.4 seconds.
    /// The fifty closes did *not* kill the process here even with SIGPIPE set back to its default
    /// first — Darwin buffered the writes rather than failing them — so this half is a guard
    /// against a regression in behaviour rather than a reproduction of the crash. Reproducing that
    /// wants a Linux run, which the Docker build does not do for tests.
    func testAClientThatClosesEarlyDoesNotKillTheProcess() throws {
        // Start from the disposition a fresh process has. Foundation leaves SIGPIPE ignored in a
        // test host, which would make this pass without the fix — the gateway's own binary gets no
        // such favour, so the test does not take one either.
        signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, SIG_IGN) }

        let port = try start()
        XCTAssertTrue(sigpipeIsIgnored(), "serving must disarm SIGPIPE before it writes anything")

        for _ in 0 ..< 50 {
            let fd = try open(port)
            write(fd, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
            close(fd)   // gone before the response can be written
        }
        // The peers are dead; give their writes time to land on a closed socket.
        Thread.sleep(forTimeInterval: 0.3)

        let response = try request(port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"),
                      "the gateway must still be serving after fifty early closes, got: \(response.prefix(40))")
    }

    // MARK: - S-F13: a silent connection must not hold a thread for ever

    /// One socket that connects and says nothing, and one that asks a question.
    ///
    /// Before `SO_RCVTIMEO` the silent one was never dropped: the blocking `read` sat inside a
    /// detached task, so roughly processor-count silent connections left no thread to start the
    /// next one, and the device link's actor jobs stopped with them. No token needed — the
    /// connection is held before a byte is parsed.
    func testASilentConnectionIsDroppedAtTheReadDeadline() throws {
        let port = try start(readTimeout: 0.5)

        let silent = try open(port, receiveTimeout: 5)
        defer { close(silent) }
        let started = Date()
        var chunk = [UInt8](repeating: 0, count: 16)
        let bytes = read(silent, &chunk, chunk.count)      // returns 0 when the server closes
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(bytes, 0, "a silent connection must be closed by the server, not held")
        XCTAssertLessThan(elapsed, 3, "it must be closed at the read deadline, not eventually")
        XCTAssertGreaterThan(elapsed, 0.2, "and not before the deadline it was given")

        let response = try request(port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), "an ordinary request still answers")
    }

    /// The deadline is per read, so a body arriving in slow pieces is not cut off mid-upload.
    func testASlowButTalkingClientIsNotCutOff() throws {
        let port = try start(readTimeout: 0.5)
        let fd = try open(port)
        defer { close(fd) }

        // Head, then the body a piece at a time, each well inside the deadline but together
        // beyond it. A per-request deadline would have refused this.
        write(fd, "POST /v1/agent HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\n")
        for piece in ["{\"a\":", "\"b", "\"}"] {
            Thread.sleep(forTimeInterval: 0.3)
            write(fd, piece)
        }
        XCTAssertTrue(readAll(fd).hasPrefix("HTTP/1.1 200 OK"),
                      "a client that keeps sending resets the clock with every chunk")
    }

    // MARK: - S-F26: the request log has to cover the upload route

    /// The one route that writes caller-controlled bytes to disk before checking a token was the
    /// one route with no log line: the logging wrapper sat around the router, and an upload never
    /// reaches the router. A phone whose uploads were all refused looked identical to one that
    /// never tried.
    func testAnUploadIsWrittenToTheRequestLog() throws {
        let recorder = Recorder()
        let id = "0123456789abcdef"
        let port = try start(log: { recorder.write($0) })

        let fd = try open(port)
        defer { close(fd) }
        write(fd, "PUT /v1/files/\(id) HTTP/1.1\r\nHost: x\r\nUser-Agent: Baton/1.0\r\nContent-Length: 5\r\n\r\nhello")
        XCTAssertTrue(readAll(fd).hasPrefix("HTTP/1.1 201"), "the upload itself must succeed")

        let uploadLines = recorder.all.filter { $0.hasPrefix("PUT /v1/files/") }
        XCTAssertEqual(uploadLines.count, 1, "an upload must leave exactly one line, got \(recorder.all)")
        guard let line = uploadLines.first else { return }
        XCTAssertTrue(line.hasPrefix("PUT /v1/files/\(id) 201"), "got: \(line)")
        XCTAssertTrue(line.hasSuffix("Baton/1.0"), "the caller belongs in the line: \(line)")
    }

    /// A refused upload is worth a line too — that is the case the route exists to make visible.
    func testARefusedUploadIsLoggedWithItsStatus() throws {
        let recorder = Recorder()
        let port = try start(log: { recorder.write($0) })

        let fd = try open(port)
        defer { close(fd) }
        // Two megabytes declared against this transport's one-megabyte cap: refused from the
        // length, before a byte of body is read.
        write(fd, "PUT /v1/files/abc HTTP/1.1\r\nHost: x\r\nContent-Length: 2097152\r\n\r\n")
        XCTAssertTrue(readAll(fd).hasPrefix("HTTP/1.1 413"))

        XCTAssertEqual(recorder.all.filter { $0.contains(" 413 ") }.count, 1,
                       "a refusal must be visible in the log, got \(recorder.all)")
    }

    /// An ordinary request still logs exactly one line, and the empty poll is still dropped.
    func testOrdinaryRequestsAreLoggedOnceAndTheEmptyPollIsStillDropped() throws {
        let recorder = Recorder()
        let port = try start(log: { recorder.write($0) }, handle: { request in
            request.path == "/v1/device/poll"
                ? httpResponse(status: "204 No Content", body: "")
                : httpResponse(status: "200 OK", body: #"{"ok":true}"#)
        })

        _ = try request(port, "GET /health HTTP/1.1\r\nHost: x\r\nUser-Agent: curl/8.4\r\n\r\n")
        _ = try request(port, "GET /v1/device/poll HTTP/1.1\r\nHost: x\r\n\r\n")

        XCTAssertEqual(recorder.all.count, 1, "got \(recorder.all)")
        XCTAssertTrue(recorder.all[0].hasPrefix("GET /health 200 "), "got: \(recorder.all[0])")
    }

    // MARK: - S-F26: a stored name must not be able to write a second header

    /// `X-Baton-Name` is echoed from whatever an upload stored, into a head built by string
    /// concatenation. A value carrying CRLF used to emit two headers; a bare LF got through the
    /// parser's `.whitespaces` trim to do it.
    func testAHeaderValueCannotBecomeASecondHeader() {
        let response = httpResponse(
            status: "200 OK", contentType: "text/plain", payload: Data("x".utf8),
            extraHeaders: ["X-Baton-Name": "quiet.txt\r\nX-Evil: yes"]
        )
        let head = String(decoding: response, as: UTF8.self)
            .components(separatedBy: "\r\n\r\n").first ?? ""

        let lines = head.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("X-Evil") }.count, 0,
                       "an injected header must not become a line of its own:\n\(head)")
        XCTAssertEqual(lines.filter { $0.hasPrefix("X-") }.count, 1, "exactly one X- header:\n\(head)")
        XCTAssertTrue(head.contains("X-Baton-Name: quiet.txtX-Evil: yes"),
                      "the text stays, minus the control characters that made it a header:\n\(head)")
    }

    func testAHeaderValueIsCappedRatherThanUnbounded() {
        let response = httpResponse(status: "200 OK", contentType: "text/plain", payload: Data(),
                                    extraHeaders: ["X-Baton-Name": String(repeating: "n", count: 30_000)])
        let head = String(decoding: response, as: UTF8.self)
        XCTAssertLessThan(head.count, 2_000, "a 30 KB name must not become a 30 KB response head")
    }

    // MARK: - S-F26: the error body has to be JSON whatever the message says

    /// The 502 path passed `String(describing: error)`, and provider failures carry quotes and
    /// newlines, so the body was not JSON and the phone showed a generic message instead of the
    /// reason — "your credit balance is too low" never reached anybody.
    func testAnErrorBodyIsJSONEvenWhenTheMessageIsNot() throws {
        let message = "provider said \"no\": credit balance\nis too low\\here"
        let response = httpErrorResponse(status: "502 Bad Gateway", message: message)
        let body = String(decoding: response, as: UTF8.self)
            .components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
            "the body must parse as JSON, got: \(body)")
        XCTAssertEqual(parsed["error"] as? String, message, "and must carry the message unchanged")
    }
}
