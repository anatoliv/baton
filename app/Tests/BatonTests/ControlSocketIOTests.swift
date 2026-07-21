import XCTest
@testable import Baton

/// W-03: a control-socket client that sends a request then closes before reading
/// the reply must not crash the app (unhandled SIGPIPE on `write`). Exercises the
/// SIGPIPE-safe write helper directly over a socketpair.
final class ControlSocketIOTests: XCTestCase {
    func testWriteAllToClosedPeerReturnsFalseWithoutCrashing() throws {
        var fds: [Int32] = [0, 0]
        try XCTSkipUnless(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair failed")
        let a = fds[0], b = fds[1]
        BatonControlSocket.setNoSigPipe(a)
        close(b) // peer vanishes, mimicking a client that closed immediately

        // Without SO_NOSIGPIPE the first EPIPE write would terminate the process.
        // Fifty attempts guarantees the send buffer fills and EPIPE surfaces.
        for _ in 0 ..< 50 {
            _ = BatonControlSocket.writeAll(a, "SUSPEND owner=x duck 0\n")
        }
        XCTAssertFalse(BatonControlSocket.writeAll(a, "again\n"), "write to a gone peer should report failure")
        close(a)
    }

    func testWriteAllDeliversFullPayload() throws {
        var fds: [Int32] = [0, 0]
        try XCTSkipUnless(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair failed")
        let a = fds[0], b = fds[1]
        defer { close(a); close(b) }
        let payload = String(repeating: "x", count: 4096) + "\n"
        XCTAssertTrue(BatonControlSocket.writeAll(a, payload))
        let want = payload.utf8.count
        var buf = [UInt8](repeating: 0, count: want)
        var got = 0
        while got < want {
            let n = read(b, &buf[got], want - got)
            if n <= 0 { break }
            got += n
        }
        XCTAssertEqual(got, want, "full payload should round-trip")
    }
}
