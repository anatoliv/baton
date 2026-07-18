import Foundation
import OSLog

private let controlSocketLog = Logger(subsystem: "io.tonebox.baton", category: "ControlSocket")

/// The native **fast-path** for latency-critical audio focus (§7 of the integration spec).
///
/// A Unix-domain-socket listener at `~/Library/Application Support/Baton/control.sock`
/// (perms `0600`) speaking a tiny line protocol that mirrors the MCP `audio_suspend` /
/// `audio_resume` tools:
///
/// ```
/// SUSPEND <owner> <mode> <duckPct>\n   →  HANDLE <handle>\n
/// RESUME  <handle>\n                    →  OK\n   |  SKIP <reason>\n
/// ```
///
/// `<owner>` is a token with no spaces (e.g. `tonebox.dictation`); `<mode>` is `pause` or
/// `duck`; `<duckPct>` is optional (default 20). One request per line; the connection may
/// carry many. It shares the SAME `BatonAudioFocusRegistry` as the MCP path, so a socket
/// suspend and an MCP resume interoperate — the handle/owner/generation live in Baton
/// regardless of transport (§7 correctness note).
///
/// Why a raw POSIX socket rather than `Network.framework`: `NWListener` doesn't bind
/// `AF_UNIX` paths, and the round-trip must be well under a frame — so this uses a tiny
/// blocking accept loop on a background thread and hops to the main actor only for the
/// (already-fast) registry call.
final class BatonControlSocket: @unchecked Sendable {
    /// The shared audio-focus registry (main-actor isolated) and the player it drives.
    private let focus: BatonAudioFocusRegistry
    /// The playback controller the focus commands act on (`MusicModel.music` in the app).
    private let controller: StreamingPlaybackController

    /// Listening socket fd (-1 when down).
    private var listenFD: Int32 = -1
    private let socketURL: URL
    private var acceptThread: Thread?
    private var stopped = false

    /// The canonical socket path inside the app-support `dir` (the same directory `mcp.json`
    /// lives in). Static so the discovery-file writer can advertise it without an instance.
    static func socketPath(in dir: URL) -> URL {
        dir.appendingPathComponent("control.sock")
    }

    @MainActor
    convenience init(focus: BatonAudioFocusRegistry, music: MusicModel, directory: URL? = nil) {
        self.init(focus: focus, controller: music.music, directory: directory)
    }

    @MainActor
    init(focus: BatonAudioFocusRegistry, controller: StreamingPlaybackController, directory: URL? = nil) {
        self.focus = focus
        self.controller = controller
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Baton", isDirectory: true)
        self.socketURL = Self.socketPath(in: dir)
    }

    #if DEBUG
    /// Test seam: a socket bound to a specific controller (never actually starts listening),
    /// so `dispatchLine` can be exercised in-process without a real Unix socket.
    @MainActor
    static func makeForTesting(
        focus: BatonAudioFocusRegistry, controller: StreamingPlaybackController
    ) -> BatonControlSocket {
        BatonControlSocket(focus: focus, controller: controller)
    }
    #endif

    // MARK: - Lifecycle

    /// Bind the socket and start the accept loop on a background thread. Idempotent.
    func start() {
        guard listenFD < 0 else { return }
        let path = socketURL.path
        do {
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            controlSocketLog.error("control socket: mkdir failed: \(error.localizedDescription)")
            return
        }
        // A stale socket file from a previous run would make bind() fail with EADDRINUSE.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            controlSocketLog.error("control socket: socket() failed errno \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            controlSocketLog.error("control socket: path too long (\(pathBytes.count))")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let bound = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            controlSocketLog.error("control socket: bind() failed errno \(errno)")
            close(fd)
            return
        }
        // Owner-only (0600) — same trust model as the MCP token file.
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            controlSocketLog.error("control socket: listen() failed errno \(errno)")
            close(fd)
            unlink(path)
            return
        }
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "io.tonebox.baton.control-socket"
        thread.start()
        acceptThread = thread
        controlSocketLog.info("control socket listening at \(path, privacy: .public)")
    }

    func stop() {
        stopped = true
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketURL.path)
    }

    // MARK: - Accept loop (background thread)

    private func acceptLoop() {
        while !stopped, listenFD >= 0 {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if stopped { break }
                if errno == EINTR { continue }
                break
            }
            handleClient(clientFD)
        }
    }

    /// Serve one client connection: read lines, dispatch each, reply. Blocking; one client at
    /// a time is plenty for a single-consumer audio-focus fast-path.
    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        // Each socket connection is one fast-path "session": when it closes, expire its
        // handles so a crashed caller can't leave Baton suspended.
        let connectionID = "sock-\(UInt64(fd)):\(UInt64(bitPattern: Int64(Date().timeIntervalSince1970 * 1000)))"
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)
        while !stopped {
            let n = read(fd, &readBuf, readBuf.count)
            if n <= 0 { break }
            buffer.append(contentsOf: readBuf[0 ..< n])
            // A well-formed command is a short single line; if a client floods us with no
            // newline, abort rather than grow the buffer without bound.
            if buffer.count > 65_536 { break }
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex ..< nl]
                buffer.removeSubrange(buffer.startIndex ... nl)
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                let reply = dispatchLine(line, connectionID: connectionID)
                _ = reply.withCString { cstr in write(fd, cstr, strlen(cstr)) }
            }
        }
        // Connection dropped — expire this session's focus handles (crash safety).
        expireConnection(connectionID)
    }

    // MARK: - Protocol dispatch

    /// Parse and execute one protocol line, returning the reply line (newline-terminated).
    /// The parse is pure/nonisolated; the registry mutation hops to the main actor. Public so
    /// tests can drive the protocol in-process without a real socket, and time the round-trip.
    func dispatchLine(_ line: String, connectionID: String) -> String {
        runOnMain { MainActor.assumeIsolated { self.reply(to: line, connectionID: connectionID) } }
    }

    /// Compute the reply for one protocol line. Main-actor isolated: touches the registry + player.
    @MainActor
    private func reply(to line: String, connectionID: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let verb = parts.first?.uppercased() else { return "ERR empty\n" }

        switch verb {
        case "SUSPEND":
            // SUSPEND <owner> [mode] [duckPct]
            guard parts.count >= 2 else { return "ERR usage: SUSPEND <owner> [mode] [duckPct]\n" }
            let owner = parts[1]
            let mode: StreamingPlaybackController.AudioFocusToken.Mode =
                (parts.count >= 3 && parts[2].lowercased() == "duck") ? .duck : .pause
            let duckPct = (parts.count >= 4 ? Int(parts[3]) : nil) ?? 20
            let result = focus.suspend(
                owner: owner, mode: mode, duckToPercent: duckPct,
                connectionID: connectionID, on: controller
            )
            let handle = (result["handle"] as? String) ?? "?"
            return "HANDLE \(handle)\n"

        case "RESUME":
            guard parts.count >= 2 else { return "ERR usage: RESUME <handle>\n" }
            let handle = parts[1]
            let result = focus.resume(handle: handle, on: controller)
            if (result["resumed"] as? Bool) == true { return "OK\n" }
            let reason = (result["reason"] as? String) ?? "unknown"
            return "SKIP \(reason)\n"

        default:
            return "ERR unknown verb \(verb)\n"
        }
    }

    private func expireConnection(_ connectionID: String) {
        _ = runOnMain {
            MainActor.assumeIsolated {
                _ = self.focus.expireHandles(forConnection: connectionID, on: self.controller)
            }
            return ""
        }
    }

    /// Hop to the main actor and run `body` synchronously, returning its `String` result. The
    /// socket accept/read loop runs on a background thread but the registry + player are
    /// main-actor isolated. The registry call is trivial, so blocking the socket thread on the
    /// hop keeps the whole round-trip well under a frame. `String` is `Sendable`, so it ferries
    /// back across the `DispatchQueue.main.sync` boundary without a box.
    private func runOnMain(_ body: @escaping @Sendable () -> String) -> String {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }
}
