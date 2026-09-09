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
        maximumConcurrentConnections: Int = 128,
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
                                       maximumConcurrentConnections: maximumConcurrentConnections,
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

    /// Twice processor count silent connections, and one ordinary request that must not wait
    /// behind them.
    ///
    /// `SO_RCVTIMEO` bounded the cost of a silent connection; it did not stop one from occupying
    /// a thread while it lasts. With the read running inside `Task.detached` those threads came
    /// from Swift's cooperative pool, which has about one per core, so this many silent peers
    /// left nothing to run the next connection on and `/health` waited for a deadline it had no
    /// part in. The read now runs on a thread of the connection's own, so the pool is never the
    /// thing that runs out.
    ///
    /// The deadline here is deliberately longer than the measurement: the point is that the
    /// ordinary request does not wait for the silent ones to expire, not that they expire.
    func testSilentConnectionsDoNotStallAnOrdinaryRequest() throws {
        let silentCount = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        let port = try start(readTimeout: 30)

        var silent: [Int32] = []
        defer { for fd in silent { close(fd) } }
        for _ in 0 ..< silentCount {
            silent.append(try open(port, receiveTimeout: 5))
        }
        // Long enough for the accept loop to have taken all of them and for each to be sitting
        // in its own blocking read.
        Thread.sleep(forTimeInterval: 0.5)

        let started = Date()
        let response = try request(port)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"),
                      "a normal request must still be answered with \(silentCount) silent "
                      + "connections open, got: \(response.prefix(40))")
        XCTAssertLessThan(elapsed, 1,
                          "and answered straight away, not after the silent connections' read "
                          + "deadline: took \(String(format: "%.2f", elapsed))s")
    }

    /// The cap on live connections answers rather than drops.
    ///
    /// A thread per connection needs a ceiling, and a ceiling needs to be reachable in a test or
    /// it is a branch nobody has run. Two silent peers fill a cap of two; the third is told what
    /// happened instead of getting a bare reset it cannot tell from a dead gateway.
    func testPastTheConnectionCapAClientIsToldRatherThanDropped() throws {
        let port = try start(readTimeout: 30, maximumConcurrentConnections: 2)

        var silent: [Int32] = []
        defer { for fd in silent { close(fd) } }
        for _ in 0 ..< 2 {
            silent.append(try open(port, receiveTimeout: 5))
        }
        Thread.sleep(forTimeInterval: 0.3)

        let response = try request(port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 503 Service Unavailable"),
                      "past the cap the gateway must say so, got: \(response.prefix(40))")

        // And the cap is a ceiling on what is live, not a total: a slot freed by a finished
        // connection is usable again.
        for fd in silent { close(fd) }
        silent = []
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(try request(port).hasPrefix("HTTP/1.1 200 OK"),
                      "a connection that ended must give its slot back")
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

    // MARK: - TBX-5325: a `session_id` in the request has to reach the seed store, over the wire

    /// The gateway's `/v1/agent` handler reads `session_id` from the JSON body and threads it
    /// through to whatever tool ran (`main.swift`'s `route`, then `GatewayToolSurface.run`); that
    /// code lives in the executable target, which no test target can import — the same reason
    /// `Transport.swift` itself had no tests before TBX-5308. This test cannot reach
    /// `GatewayToolSurface` directly, so it drives the same shape end to end instead: a real HTTP
    /// POST over a real socket, through `HTTPRequestMessage` parsing, into a JSON body decode of
    /// `session_id`, keying the same `SearchSeedStore` the real tool surface uses. What it proves
    /// is the wiring PR #53 promised and TBX-5325 found missing on the phone's end: two
    /// conversations that each send their own `session_id` do not see each other's seed.
    /// `SearchSeedStore` documents itself as not thread-safe on purpose — in production it is
    /// only ever touched from the `@MainActor` tool surface. The `handle` closure here runs on
    /// whichever pool thread accepted the connection, so this test locks around it rather than
    /// capturing the store bare, the same pattern `Recorder` above uses for the request log.
    final class SerializedSeeds: @unchecked Sendable {
        private let lock = NSLock()
        private let store = SearchSeedStore<String>()
        func remember(_ value: String, for sessionID: String?) {
            lock.lock(); defer { lock.unlock() }
            store.remember(value, for: sessionID)
        }
        func seed(for sessionID: String?) -> String? {
            lock.lock(); defer { lock.unlock() }
            return store.seed(for: sessionID)
        }
    }

    func testTwoSessionIDsOnTheWireKeepIndependentSeeds() throws {
        let seeds = SerializedSeeds()
        let port = try start(handle: { request in
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let message = json["message"] as? String else {
                return httpResponse(status: "400 Bad Request", body: #"{"error":"bad body"}"#)
            }
            let sessionID = json["session_id"] as? String
            if message.hasPrefix("remember:") {
                seeds.remember(String(message.dropFirst("remember:".count)), for: sessionID)
                return httpResponse(status: "200 OK", body: #"{"ok":true}"#)
            }
            let seed = seeds.seed(for: sessionID) ?? "none"
            return httpResponse(status: "200 OK", body: jsonObject(["text": seed]))
        })

        func post(_ body: [String: Any]) throws -> String {
            let payload = try JSONSerialization.data(withJSONObject: body)
            let fd = try open(port)
            defer { close(fd) }
            write(fd, "POST /v1/agent HTTP/1.1\r\nHost: x\r\nContent-Length: \(payload.count)\r\n\r\n")
            write(fd, String(decoding: payload, as: UTF8.self))
            let response = readAll(fd)
            let bodyText = response.components(separatedBy: "\r\n\r\n").dropFirst().joined()
            let parsed = (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any]
            return parsed?["text"] as? String ?? bodyText
        }

        _ = try post(["session_id": "alpha", "message": "remember:Debussy"])
        _ = try post(["session_id": "beta", "message": "remember:Autechre"])

        XCTAssertEqual(try post(["session_id": "alpha", "message": "recall"]), "Debussy",
                       "alpha's own search must come back for alpha")
        XCTAssertEqual(try post(["session_id": "beta", "message": "recall"]), "Autechre",
                       "and beta's own search for beta, not alpha's")
        XCTAssertEqual(try post(["message": "recall"]), "none",
                       "a caller sending no session id must not inherit either conversation's seed")
    }
}
