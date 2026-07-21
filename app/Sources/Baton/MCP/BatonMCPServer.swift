import Foundation
import Network
import Observation
import OSLog
// The MCP transport protocol (JSON-RPC, HTTP parsing/framing, token compare) is the fourth
// leaf of the W-51 module split. Re-exported so every call site stays unqualified; the server
// itself (which ties into MusicModel) stays in the app.
@_exported import BatonMCPProtocol

private let batonServerLog = Logger(subsystem: "io.tonebox.baton", category: "MCPServer")

/// Baton's embedded MCP control server. Speaks **MCP Streamable HTTP** on
/// `127.0.0.1`: a single `POST /mcp` endpoint carrying JSON-RPC 2.0
/// (`initialize`, `tools/list`, `tools/call`, `resources/list`, `resources/read`,
/// `notifications/*`), and a `GET /mcp` that a client opens to receive
/// server→client notifications as an SSE (`text/event-stream`) stream. Multi-client:
/// every open SSE stream gets track/queue-change notifications.
///
/// Auth is a bearer token (persisted in UserDefaults, generated on first run);
/// discovery is an `mcp.json` file in Application Support. The listener binds
/// loopback-only so it's unreachable off-device.
@MainActor
@Observable
final class BatonMCPServer {
    private let music: MusicModel
    /// The audio-focus registry. Exposed so the Unix-socket fast-path (`BatonControlSocket`)
    /// shares the SAME registry — a socket suspend and an MCP resume interoperate (§7).
    let focus: BatonAudioFocusRegistry

    /// The bearer token every request must carry. Generated once, persisted.
    private(set) var token: String
    /// The port the listener actually bound (may differ from the default if taken).
    private(set) var boundPort: UInt16?
    /// Whether the listener is currently up.
    private(set) var isRunning = false
    private(set) var lastError: String?

    @ObservationIgnored private var listener: NWListener?
    /// Open SSE streams keyed by a per-connection id — the notification fan-out set.
    @ObservationIgnored private var streams: [ObjectIdentifier: NWConnection] = [:]
    /// The MCP session id each open SSE stream belongs to (when the client sent one) — used
    /// to auto-expire that session's audio-focus handles when its stream closes (§4.3).
    @ObservationIgnored private var streamSessions: [ObjectIdentifier: String] = [:]
    /// Server-minted session ids currently valid. The server assigns one at `initialize` (spec:
    /// server-assigned, so a client can't forge or guess one — SEC-15); later POST/GET/DELETE must
    /// carry a known id or get 404. Capped as a backstop against a client that never DELETEs.
    @ObservationIgnored private var activeSessions: Set<String> = []
    static let maxActiveSessions = 64
    /// Polls the player for state changes to emit `resources/updated` notifications.
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Last-seen state signatures so a poll only notifies on an actual change.
    @ObservationIgnored private var lastNowPlayingSignature = ""
    @ObservationIgnored private var lastQueueSignature = ""

    private let queueLabel = "io.tonebox.baton.mcp"

    /// Overridable for hermetic tests so the discovery file + second-instance guard use a temp
    /// dir instead of the shared app-support location (which a running app owns). (W-46)
    @ObservationIgnored private let discoveryDirOverride: URL?

    init(music: MusicModel, focus: BatonAudioFocusRegistry = BatonAudioFocusRegistry(), discoveryDirectory: URL? = nil) {
        self.music = music
        self.focus = focus
        self.discoveryDirOverride = discoveryDirectory
        // The bearer token grants full remote control, so it lives in the Keychain, not
        // plaintext UserDefaults (migrate-on-read handles existing installs). (W-13)
        if let existing = NavidromeKeychain.secret(account: BatonMCPConstants.tokenDefaultsKey) {
            token = existing
        } else {
            let fresh = BatonMCPAuth.generateToken()
            NavidromeKeychain.setSecret(fresh, account: BatonMCPConstants.tokenDefaultsKey)
            token = fresh
        }
    }

    // MARK: - Lifecycle

    /// Starts the listener (scanning upward from the default port if it's taken),
    /// begins the change-poll, and writes the discovery file. Idempotent.
    func start() {
        guard listener == nil else { return }
        // Don't steal a live instance's control surface: if another Baton process already
        // owns the endpoint (its pid is alive), refuse rather than overwrite its mcp.json /
        // control.sock and cause split-brain control. A dead pid means a stale file — proceed. (W-14)
        if let pid = liveForeignOwnerPid() {
            lastError = "Another Baton instance (pid \(pid)) already owns the MCP endpoint."
            batonServerLog.error("MCP server not started: pid \(pid) already owns the endpoint")
            return
        }
        Task { @MainActor in await self.startScanning() }
    }

    /// Bind the first free port, walking upward on a conflict. Awaits the listener actually
    /// reaching `.ready` before declaring success and advertising it — NWListener.start is
    /// async, so the old synchronous "return true" could publish a port the server never
    /// owned. (W-38 / MCP-02)
    private func startScanning() async {
        for offset in 0 ..< BatonMCPConstants.portScanRange {
            let port = BatonMCPConstants.defaultPort + UInt16(offset)
            if let listener = await bind(port: port) {
                self.listener = listener
                boundPort = port
                isRunning = true
                lastError = nil
                startPolling()
                writeDiscoveryFile(port: port)
                batonServerLog.info("MCP server listening on 127.0.0.1:\(port)")
                return
            }
        }
        isRunning = false
        lastError = "No free port in \(BatonMCPConstants.defaultPort)…\(BatonMCPConstants.defaultPort + UInt16(BatonMCPConstants.portScanRange))."
        batonServerLog.error("MCP server failed to bind any port")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for (_, conn) in streams { conn.cancel() }
        streams.removeAll()
        streamSessions.removeAll()
        activeSessions.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        boundPort = nil
        // Remove the discovery file so a stale token+port doesn't linger after quit/crash
        // for another process to harvest. (W-14)
        if let dir = discoveryDirectory() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("mcp.json"))
        }
    }

    /// Try to bind `port`, returning the listener only once it reaches `.ready`, or nil on
    /// `.failed`/`.cancelled` (so the caller advances to the next port). (W-38 / MCP-02)
    private func bind(port: UInt16) async -> NWListener? {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback // loopback-only: unreachable off-device
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort)
        else { return nil }

        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        let ready: Bool = await withCheckedContinuation { continuation in
            // Network.framework invokes stateUpdateHandler serially on the listener's queue
            // (`.main` below), so this single-resume guard is never touched concurrently — hence
            // `nonisolated(unsafe)` rather than a lock. Guards against resuming the continuation
            // more than once (ready→failed, or a late .cancelled).
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume(returning: true) }
                case let .failed(err):
                    Task { @MainActor in
                        self?.lastError = "Listener failed: \(err.localizedDescription)"
                        batonServerLog.error("MCP listener failed on port \(port): \(err.localizedDescription)")
                    }
                    if !resumed { resumed = true; continuation.resume(returning: false) }
                case .cancelled:
                    if !resumed { resumed = true; continuation.resume(returning: false) }
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
        if ready { return listener }
        listener.cancel()
        return nil
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    /// Accumulate bytes until a full HTTP request is parsed, then route it.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data, !data.isEmpty { buffer.append(data) }

                switch HTTPRequestMessage.parse(buffer) {
                case .incomplete:
                    if error != nil || isComplete {
                        conn.cancel()
                    } else {
                        self.receive(conn, buffer: buffer)
                    }
                case .tooLarge:
                    self.sendAndClose(conn, HTTPResponse.empty(status: "413 Payload Too Large"))
                case .malformed:
                    self.sendAndClose(conn, HTTPResponse.empty(status: "400 Bad Request"))
                case let .complete(request):
                    self.route(request, on: conn)
                }
            }
        }
    }

    private func route(_ request: HTTPRequestMessage, on conn: NWConnection) {
        // DNS-rebinding defense (the listener is loopback-bound, but a rebinding web page
        // sends the attacker's Host/Origin): require a loopback Host and reject a
        // cross-origin Origin before doing anything else. (W-14)
        guard Self.isLoopbackHost(request.headers["host"]),
              Self.isAllowedOrigin(request.headers["origin"])
        else {
            sendAndClose(conn, HTTPResponse.empty(status: "403 Forbidden"))
            return
        }
        // Auth gate — constant-time compare; loopback + token both required.
        guard let provided = request.bearerToken,
              BatonMCPAuth.constantTimeEquals(provided, token)
        else {
            sendAndClose(conn, HTTPResponse.empty(status: "401 Unauthorized"))
            return
        }

        guard request.path == "/mcp" else {
            sendAndClose(conn, HTTPResponse.empty(status: "404 Not Found"))
            return
        }

        // A request that carries a session id must carry a *known* one (GET/DELETE never carry
        // `initialize`, which mints the id, so validating them here is safe). (W-39 / SEC-15)
        if request.method != "POST", let sid = request.sessionID, !activeSessions.contains(sid) {
            sendAndClose(conn, HTTPResponse.empty(status: "404 Not Found"))
            return
        }

        switch request.method {
        case "GET":
            // The SSE stream requires an `Accept: text/event-stream`; a plain GET is a client
            // error, not a stream to open. (W-39 / MCP-10)
            guard request.acceptsEventStream else {
                sendAndClose(conn, HTTPResponse.empty(status: "405 Method Not Allowed"))
                return
            }
            // Open an SSE stream for server→client notifications.
            openStream(conn, sessionID: request.sessionID)
        case "POST":
            handlePost(request, on: conn)
        case "DELETE":
            // Session teardown: cancel the session's streams and expire its audio-focus handles.
            if let sid = request.sessionID { endSession(sid) }
            sendAndClose(conn, HTTPResponse.empty(status: "200 OK"))
        default:
            sendAndClose(conn, HTTPResponse.empty(status: "405 Method Not Allowed"))
        }
    }

    /// A Host header naming loopback (or absent, for HTTP/1.0 clients — the socket is
    /// loopback-bound anyway). Rejects `Host: evil.com` from a DNS-rebinding page. (W-14)
    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return true }
        let name = host.hasPrefix("[") // [::1]:port
            ? String(host.dropFirst().prefix(while: { $0 != "]" }))
            : host.split(separator: ":").first.map(String.init) ?? host
        return name == "127.0.0.1" || name == "localhost" || name == "::1"
    }

    /// An Origin that's absent, `null`, or loopback. Rejects a cross-origin browser page. (W-14)
    static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin = origin?.lowercased(), origin != "null" else { return true }
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    // MARK: - POST (JSON-RPC)

    private func handlePost(_ request: HTTPRequestMessage, on conn: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) else {
            sendAndClose(conn, HTTPResponse.json(
                JSONRPC.error(id: nil, code: JSONRPCError.parseError, message: "Invalid JSON.")
            ))
            return
        }

        // A single request object. (Batching is not required by the spec for our use.)
        guard let dict = object as? [String: Any], let method = dict["method"] as? String else {
            sendAndClose(conn, HTTPResponse.json(
                JSONRPC.error(id: nil, code: JSONRPCError.invalidRequest, message: "Not a JSON-RPC request.")
            ))
            return
        }
        let id = dict["id"]
        let params = (dict["params"] as? [String: Any]) ?? [:]

        // A non-initialize POST carrying a session id must carry a known one. (W-39 / SEC-15)
        if method != "initialize", let sid = request.sessionID, !activeSessions.contains(sid) {
            sendAndClose(conn, HTTPResponse.json(
                JSONRPC.error(id: id, code: JSONRPCError.invalidRequest, message: "Unknown or expired session."),
                status: "404 Not Found"))
            return
        }

        // Notifications (no id) get a 202 with no body.
        if id == nil {
            sendAndClose(conn, HTTPResponse.empty(status: "202 Accepted"))
            return
        }

        Task { @MainActor in
            let response = await self.dispatch(
                method: method, id: id, params: params, sessionID: request.sessionID)
            // The server mints the session id at `initialize` and returns it in the response
            // header; other methods echo the client's id back unchanged. (W-39)
            let responseSession = method == "initialize" ? self.mintSession() : request.sessionID
            self.sendAndClose(conn, HTTPResponse.json(response, sessionID: responseSession))
        }
    }

    /// Mint and register a new session id (returned to the client at `initialize`). Backstop-capped
    /// so a client that never issues DELETE can't grow the set without bound.
    private func mintSession() -> String {
        if activeSessions.count >= Self.maxActiveSessions, let evict = activeSessions.first {
            endSession(evict)
        }
        let sid = UUID().uuidString
        activeSessions.insert(sid)
        return sid
    }

    /// Tear a session down: forget it, cancel any SSE stream it owns (which expires that session's
    /// audio-focus handles via `handleStreamClosed`), and expire any focus handles it still holds.
    private func endSession(_ sessionID: String) {
        activeSessions.remove(sessionID)
        for (key, sid) in streamSessions where sid == sessionID {
            streams[key]?.cancel()
        }
        _ = focus.expireHandles(forConnection: sessionID, on: music.music)
    }

    private func dispatch(
        method: String, id: Any?, params: [String: Any], sessionID: String? = nil
    ) async -> [String: Any] {
        switch method {
        case "initialize":
            return JSONRPC.result(id: id, [
                "protocolVersion": BatonMCPConstants.protocolVersion,
                "capabilities": [
                    "tools": [:] as [String: Any],
                    "resources": ["subscribe": false, "listChanged": false],
                ],
                "serverInfo": [
                    "name": BatonMCPConstants.serverName,
                    "version": BatonMCPConstants.serverVersion,
                ],
            ])

        case "ping":
            return JSONRPC.result(id: id, [:] as [String: Any])

        case "tools/list":
            return JSONRPC.result(id: id, ["tools": BatonMCPToolCatalog.definitions()])

        case "tools/call":
            let name = (params["name"] as? String) ?? ""
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            let (text, isError) = await BatonMCPToolCatalog.run(
                name: name, arguments: arguments, music: music, focus: focus, sessionID: sessionID
            )
            // Any tool that mutates playback may have changed now-playing/queue.
            emitStateChangeIfNeeded()
            return JSONRPC.result(id: id, [
                "content": [["type": "text", "text": text]],
                "isError": isError,
            ])

        case "resources/list":
            return JSONRPC.result(id: id, ["resources": BatonMCPResources.list()])

        case "resources/read":
            let uri = (params["uri"] as? String) ?? ""
            guard let payload = BatonMCPResources.read(uri: uri, music: music) else {
                return JSONRPC.error(id: id, code: JSONRPCError.invalidParams, message: "Unknown resource \"\(uri)\".")
            }
            return JSONRPC.result(id: id, payload)

        case _ where method.hasPrefix("notifications/"):
            // Client→server notification arriving as a request-with-id (rare) — ack.
            return JSONRPC.result(id: id, [:] as [String: Any])

        default:
            return JSONRPC.error(id: id, code: JSONRPCError.methodNotFound, message: "Unknown method \"\(method)\".")
        }
    }

    // MARK: - SSE notification streams

    private func openStream(_ conn: NWConnection, sessionID: String?) {
        conn.send(content: HTTPResponse.sseHeaders(sessionID: sessionID), completion: .contentProcessed { _ in })
        let key = ObjectIdentifier(conn)
        streams[key] = conn
        if let sessionID { streamSessions[key] = sessionID }
        // Drop the stream when the client disconnects so a crashed client can't hold a
        // slot forever — and auto-expire any audio-focus handle that session was holding, so
        // a crashed/killed dictation client can't leave Baton paused or ducked forever (§4.3).
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { @MainActor in self?.handleStreamClosed(key) }
            default:
                break
            }
        }
        // Prime the client with the current now-playing so it need not poll immediately.
        send(notification: resourceUpdated(BatonMCPConstants.nowPlayingURI), to: conn)
    }

    /// An SSE stream closed. Drop it from the fan-out set and expire any audio-focus handle
    /// the session was holding — a crashed dictation client's suspend/duck auto-resumes
    /// (subject to the controller's generation guard, so it never fights a user who took
    /// over). Handles created without a session id fall back to the time-bound sweep.
    private func handleStreamClosed(_ key: ObjectIdentifier) {
        streams[key] = nil
        if let sessionID = streamSessions.removeValue(forKey: key) {
            let expired = focus.expireHandles(forConnection: sessionID, on: music.music)
            if expired > 0 {
                batonServerLog.info("SSE session \(sessionID) closed — expired \(expired) audio-focus handle(s)")
            }
        }
    }

    private func broadcast(_ notification: [String: Any]) {
        let frame = HTTPResponse.sseEvent(notification)
        for (_, conn) in streams {
            conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func send(notification: [String: Any], to conn: NWConnection) {
        conn.send(content: HTTPResponse.sseEvent(notification), completion: .contentProcessed { _ in })
    }

    private func resourceUpdated(_ uri: String) -> [String: Any] {
        JSONRPC.notification(method: "notifications/resources/updated", params: ["uri": uri])
    }

    // MARK: - State-change polling

    /// A lightweight 0.5 s poll that compares a signature of now-playing / queue and
    /// broadcasts `resources/updated` on change. Simpler and more robust across the
    /// Network.framework callback hops than re-registering `withObservationTracking`.
    private func startPolling() {
        pollTask?.cancel()
        lastNowPlayingSignature = nowPlayingSignature()
        lastQueueSignature = queueSignature()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // With no SSE client listening (the common case) there are no notifications to
                // emit, so poll slowly — just often enough to keep the focus-expiry safety net
                // live — instead of waking the main actor at 500 ms forever. (W-40 / ARCH-17)
                let hasStreams = self?.streams.isEmpty == false
                try? await Task.sleep(for: .milliseconds(hasStreams ? 500 : 2000))
                self?.emitStateChangeIfNeeded()
                // Belt-and-braces for a client that vanished without a clean stream-close:
                // auto-expire any focus handle past the time-bound so music can't stay
                // suspended forever (§4.3).
                if let self { self.focus.expireStaleHandles(on: self.music.music) }
            }
        }
    }

    private func emitStateChangeIfNeeded() {
        guard !streams.isEmpty else {
            // Keep signatures current so a newly-connected client doesn't get a
            // spurious "changed" on its first real poll.
            lastNowPlayingSignature = nowPlayingSignature()
            lastQueueSignature = queueSignature()
            return
        }
        let np = nowPlayingSignature()
        if np != lastNowPlayingSignature {
            lastNowPlayingSignature = np
            broadcast(resourceUpdated(BatonMCPConstants.nowPlayingURI))
        }
        let q = queueSignature()
        if q != lastQueueSignature {
            lastQueueSignature = q
            broadcast(resourceUpdated(BatonMCPConstants.queueURI))
        }
    }

    private func nowPlayingSignature() -> String {
        let p = music.music
        // Include the seek marker so a seek on the current track (same state/id/index)
        // still changes the signature and fires a now-playing notification (spec §5.2).
        return "\(BatonMCPToolCatalog.musicStateLabel(p.state))|\(p.nowPlaying?.id ?? "-")|\(p.currentIndex)|\(p.seekMarker)"
    }

    private func queueSignature() -> String {
        let p = music.music
        // Order-sensitive: sampling only count/first/last missed a middle-of-queue reorder (same
        // ends, same count) so agent UIs went stale after a reorder (W-40 / MCP-06). Fold every id
        // in order into a stable digest instead.
        return "\(p.queue.count)|\(Self.queueDigest(ids: p.queue.map(\.id)))|\(p.queueSource?.id ?? "-")"
    }

    /// A stable, order-sensitive digest of the queue's ids. FNV-1a — deterministic (unlike the
    /// per-process-seeded `Hasher`), so it's directly testable and consistent enough for the poll
    /// to compare successive snapshots. An id separator byte keeps `["ab","c"]` ≠ `["a","bc"]`.
    static func queueDigest(ids: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        let prime: UInt64 = 0x0000_0100_0000_01b3 // FNV prime
        for id in ids {
            for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* prime }
            hash = (hash ^ 0x2f) &* prime // "/" separator between ids
        }
        return String(hash, radix: 16)
    }

    // MARK: - Discovery file

    private func writeDiscoveryFile(port: UInt16) {
        guard let dir = discoveryDirectory() else { return }
        let url = dir.appendingPathComponent("mcp.json")
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "name": BatonMCPConstants.serverName,
            "transport": "streamable-http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "token": token,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "app": [
                "bundleId": Bundle.main.bundleIdentifier ?? "io.tonebox.baton",
                "version": BatonMCPConstants.serverVersion,
            ],
            // Native fast-path for latency-critical audio focus (§7): a Unix-domain socket
            // mirroring audio_suspend/audio_resume, sharing this server's focus registry.
            "fastPath": [
                "unixSocket": BatonControlSocket.socketPath(in: dir).path,
            ],
        ]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            // Create the file 0600 from the start — the token is a secret and a
            // write-then-chmod leaves a brief world-readable window. (W-14)
            try? FileManager.default.removeItem(at: url)
            if !FileManager.default.createFile(atPath: url.path, contents: data,
                                               attributes: [.posixPermissions: 0o600]) {
                batonServerLog.error("failed to write discovery file at \(url.path, privacy: .public)")
            }
        } catch {
            batonServerLog.error("failed to write discovery file: \(error.localizedDescription)")
        }
    }

    /// The pid recorded in an existing discovery file, if that process is still alive and
    /// isn't us — i.e. another Baton instance already owns the MCP endpoint. (W-14)
    private func liveForeignOwnerPid() -> Int32? {
        guard let dir = discoveryDirectory(),
              let data = try? Data(contentsOf: dir.appendingPathComponent("mcp.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int, pid > 0 else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        guard Int32(pid) != me else { return nil }
        return kill(pid_t(pid), 0) == 0 ? Int32(pid) : nil // ESRCH ⇒ dead ⇒ stale, ignore
    }

    private func discoveryDirectory() -> URL? {
        if let discoveryDirOverride { return discoveryDirOverride }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Baton", isDirectory: true)
    }

    // MARK: - Send helpers

    private func sendAndClose(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
