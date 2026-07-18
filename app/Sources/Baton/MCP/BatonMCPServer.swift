import Foundation
import Network
import Observation
import OSLog

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
    /// Polls the player for state changes to emit `resources/updated` notifications.
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Last-seen state signatures so a poll only notifies on an actual change.
    @ObservationIgnored private var lastNowPlayingSignature = ""
    @ObservationIgnored private var lastQueueSignature = ""

    private let queueLabel = "io.tonebox.baton.mcp"

    init(music: MusicModel, focus: BatonAudioFocusRegistry = BatonAudioFocusRegistry()) {
        self.music = music
        self.focus = focus
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: BatonMCPConstants.tokenDefaultsKey), !existing.isEmpty {
            token = existing
        } else {
            let fresh = BatonMCPAuth.generateToken()
            defaults.set(fresh, forKey: BatonMCPConstants.tokenDefaultsKey)
            token = fresh
        }
    }

    // MARK: - Lifecycle

    /// Starts the listener (scanning upward from the default port if it's taken),
    /// begins the change-poll, and writes the discovery file. Idempotent.
    func start() {
        guard listener == nil else { return }
        for offset in 0 ..< BatonMCPConstants.portScanRange {
            let port = BatonMCPConstants.defaultPort + UInt16(offset)
            if bind(port: port) {
                boundPort = port
                isRunning = true
                lastError = nil
                startPolling()
                writeDiscoveryFile(port: port)
                batonServerLog.info("MCP server listening on 127.0.0.1:\(port)")
                return
            }
        }
        lastError = "No free port in \(BatonMCPConstants.defaultPort)…\(BatonMCPConstants.defaultPort + UInt16(BatonMCPConstants.portScanRange))."
        batonServerLog.error("MCP server failed to bind any port")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for (_, conn) in streams { conn.cancel() }
        streams.removeAll()
        streamSessions.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        boundPort = nil
    }

    private func bind(port: UInt16) -> Bool {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback // loopback-only: unreachable off-device
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort)
        else { return false }

        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(err) = state {
                Task { @MainActor in
                    self?.lastError = "Listener failed: \(err.localizedDescription)"
                    batonServerLog.error("MCP listener failed: \(err.localizedDescription)")
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        // NWListener.start is async; if the port was taken it transitions to .failed
        // shortly after (surfaced via stateUpdateHandler). For the common case the
        // first port is free; a busy port is rare on loopback for a per-user app.
        return true
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

        switch request.method {
        case "GET":
            // Open an SSE stream for server→client notifications.
            openStream(conn, sessionID: request.sessionID)
        case "POST":
            handlePost(request, on: conn)
        case "DELETE":
            // Session teardown — nothing persistent to clean up beyond the stream.
            sendAndClose(conn, HTTPResponse.empty(status: "200 OK"))
        default:
            sendAndClose(conn, HTTPResponse.empty(status: "405 Method Not Allowed"))
        }
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

        // Notifications (no id) get a 202 with no body.
        if id == nil {
            sendAndClose(conn, HTTPResponse.empty(status: "202 Accepted"))
            return
        }

        Task { @MainActor in
            let response = await self.dispatch(
                method: method, id: id, params: params, sessionID: request.sessionID)
            self.sendAndClose(conn, HTTPResponse.json(response, sessionID: request.sessionID))
        }
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
                try? await Task.sleep(for: .milliseconds(500))
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
        return "\(p.queue.count)|\(p.queue.first?.id ?? "-")|\(p.queue.last?.id ?? "-")|\(p.queueSource?.id ?? "-")"
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
            try data.write(to: url, options: .atomic)
            // Token is a secret — restrict to the owner (0600).
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            batonServerLog.error("failed to write discovery file: \(error.localizedDescription)")
        }
    }

    private func discoveryDirectory() -> URL? {
        FileManager.default
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
