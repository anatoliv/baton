import Darwin
import Network
import XCTest
@testable import BatonPlaybackKit

/// Reading a pairing payload off a real socket.
///
/// The existing pairing tests round-trip encrypt → `applyImport` **in memory**, and the live
/// host tests only check that the listener starts. Nothing sent a payload across an actual
/// connection, so a short read was invisible to a green suite — and a short read is exactly
/// what happened: `receive(minimumIncompleteLength: 1, …)` resumes on the first byte, so
/// pairing returned whatever was in the first TCP segment and threw the rest away.
///
/// The failure is size-dependent, which is why it can look like flakiness rather than a bug:
/// a small settings export fits in one segment and pairs fine. These tests therefore care
/// about a payload much larger than a segment.
final class PairingTransportReadTests: XCTestCase {

    /// A loopback server that writes `payload` and closes, exactly as the pairing host does —
    /// built on plain BSD sockets rather than `NWListener`.
    ///
    /// **Un-parked 2026-09-09.** The three tests below were skipped since TBX-3846
    /// because the client's `NWConnection` never reached `.ready` against an in-process
    /// `NWListener` — confirmed again here: with the old `NWListener`-backed `serve()`, the
    /// client hung past 90 seconds and was killed by hand (never reached `.ready`, `.failed`,
    /// or `.cancelled`). Swapping only the *server* side to a raw BSD socket bound to
    /// `127.0.0.1` — the client is still the genuine `NWConnection`-based
    /// `PairingClient.receiveAll`, unchanged — reaches `.ready` immediately, in this same test
    /// process. The likely reason: `NWListener(using:.tcp, on: .any)` binds `0.0.0.0`, which on
    /// this macOS version is the shape that engages the Local Network permission / listener
    /// sandboxing that an in-process xctest run never grants; a socket bound directly to the
    /// loopback address is not asking for that permission at all. This is a harness fix, not a
    /// production-code change — `PairingHost` (the Mac's real server) keeps using `NWListener`
    /// because it has to bind the LAN interface, not loopback, for a phone to reach it.
    private func serve(_ payload: Data) throws -> (port: UInt16, fd: Int32) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("couldn't open a BSD socket in this environment") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0   // ask the OS to pick a port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw XCTSkip("couldn't bind a loopback socket (errno \(errno))")
        }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: actual.sin_port)
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw XCTSkip("couldn't listen on the loopback socket (errno \(errno))")
        }

        // One connection, one payload, then closed — matches what the real pairing host does
        // (`connection.send(... .contentProcessed { connection.cancel() })`).
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            if !payload.isEmpty {
                payload.withUnsafeBytes { buf in
                    var offset = 0
                    let base = buf.bindMemory(to: UInt8.self).baseAddress!
                    while offset < buf.count {
                        let n = write(client, base + offset, buf.count - offset)
                        if n <= 0 { break }
                        offset += n
                    }
                }
            }
            close(client)
        }
        return (port, fd)
    }

    private func read(fromPort port: UInt16) async throws -> Data? {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }

        // Wait for `.ready` before receiving. Without this the test says "nothing arrived" for
        // a connection that never actually came up — which is a fact about the harness, not
        // about the code under test, and it is exactly what the first run reported.
        let ready = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, Error>) in
            nonisolated(unsafe) var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true; c.resume(returning: true)
                case .failed(let error):
                    resumed = true; c.resume(throwing: error)
                case .cancelled:
                    resumed = true; c.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
        guard ready else { throw XCTSkip("connection was cancelled before it came up") }
        return await PairingClient.receiveAll(connection, timeout: 8)
    }

    /// The regression. 512 KB is many segments; the old single read returned one of them.
    func testAPayloadLargerThanOneSegmentArrivesWhole() async throws {
        let payload = Data((0 ..< 512 * 1024).map { UInt8($0 % 251) })
        let (port, fd) = try serve(payload)
        defer { close(fd) }

        let received = try await read(fromPort: port)
        XCTAssertEqual(received?.count, payload.count, "the payload was truncated to one segment")
        XCTAssertEqual(received, payload, "bytes must arrive in order and intact")
    }

    /// Stated as the symptom the user actually saw: a truncated JSON export does not parse,
    /// and surfaces as "this isn't a Baton settings backup".
    func testATruncatedPayloadIsWhatBrokeTheFormatCheck() throws {
        let whole = try JSONSerialization.data(withJSONObject: [
            "format": "baton-settings", "version": 1, "encrypted": true,
            "payload": String(repeating: "A", count: 100_000),
        ])
        let firstSegment = whole.prefix(1400)   // roughly one MTU
        XCTAssertNil(try? JSONSerialization.jsonObject(with: firstSegment),
                     "a truncated export cannot parse — which is why the error blamed the format")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: whole))
    }

    /// Small payloads still work — this is what made the bug look intermittent.
    func testASmallPayloadStillArrives() async throws {
        let payload = Data("{\"format\":\"baton-settings\"}".utf8)
        let (port, fd) = try serve(payload)
        defer { close(fd) }

        let received = try await read(fromPort: port)
        XCTAssertEqual(received, payload)
    }

    /// A sender that closes without writing yields nil rather than empty data, so `redeem`
    /// reports "empty" instead of handing zero bytes to the decoder.
    func testAClosedConnectionWithNothingSentIsNil() async throws {
        let (port, fd) = try serve(Data())
        defer { close(fd) }

        let received = try await read(fromPort: port)
        XCTAssertNil(received)
    }
}
