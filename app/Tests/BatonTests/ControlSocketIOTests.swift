import XCTest
@testable import Baton

/// A control-socket client that sends a request then closes before reading
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

    // MARK: - A second instance and the socket path

    /// A short directory: `sun_path` holds about 104 bytes, and the test host's temp dir eats
    /// half of that.
    private func shortTempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString.prefix(8))")
    }

    /// Whether something is listening at `path`.
    private static func connects(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        return withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private static func inode(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
    }

    /// A Baton refused by the MCP guard still started its control socket, which unlinked the
    /// live instance's `control.sock`, bound its own, and unlinked it again on quit, leaving the
    /// live instance listening on a path nobody can reach.
    @MainActor
    func testASecondInstanceLeavesALiveSocketAlone() throws {
        let dir = shortTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let music = MusicModel()
        let path = BatonControlSocket.socketPath(in: dir).path
        let live = BatonControlSocket(focus: BatonAudioFocusRegistry(), music: music, directory: dir)
        live.start()
        defer { live.stop() }
        XCTAssertTrue(Self.connects(to: path), "the first instance should be listening")
        let inodeBefore = Self.inode(path)

        let second = BatonControlSocket(focus: BatonAudioFocusRegistry(), music: music, directory: dir)
        second.start()
        XCTAssertEqual(Self.inode(path), inodeBefore, "the second instance must not replace the live socket file")
        second.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "stopping the second instance must not unlink the live socket")
        XCTAssertTrue(Self.connects(to: path), "the live instance must still be reachable")
    }

    /// A socket file left by a crash answers nobody, so a new instance still takes it over.
    @MainActor
    func testAStaleSocketFileIsStillReplaced() throws {
        let dir = shortTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = BatonControlSocket.socketPath(in: dir).path
        // Bind and close without unlinking: the file a crashed instance leaves.
        let stale = BatonControlSocket(focus: BatonAudioFocusRegistry(), music: MusicModel(), directory: dir)
        stale.start()
        stale.stop()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let bound = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        XCTAssertEqual(bound, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(Self.connects(to: path), "a closed socket's file answers nobody")

        let fresh = BatonControlSocket(focus: BatonAudioFocusRegistry(), music: MusicModel(), directory: dir)
        fresh.start()
        XCTAssertTrue(Self.connects(to: path), "a stale file must not keep a new instance from listening")
        fresh.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "an instance removes the socket it bound")
    }
}
