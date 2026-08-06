// Apple-only: this file is a chat transport for the desktop app and speaks to the router,
// which needs the playback engine. The gateway needs neither.
#if canImport(AVFoundation)
import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// Discord control surface.
///
/// Discord can't be long-polled, so this speaks the **Gateway**: a WebSocket
/// that Baton dials out to and then reads. Like the Telegram bridge it needs no
/// inbound port and no public URL — which also rules out the interactions-webhook
/// style of slash command, since that requires Discord to reach *you*. Buttons
/// still work: component interactions arrive over the same socket, and the
/// response is an ordinary outbound POST.
///
/// Requires the **Message Content** privileged intent (Developer Portal → Bot),
/// without which message text arrives empty — which looks like Baton ignoring
/// commands, so it's called out in the setup hint.
@MainActor
public final class DiscordBridge {
    private let router: RemoteCommandRouter
    private let token: String
    private let onStateChange: (RemoteConnectionState) -> Void

    private var task: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private let session: URLSession

    private var sequence: Int?
    private var sessionID: String?
    private var resumeURL: String?
    private var lastHeartbeatAcked = true

    /// GUILD_MESSAGES (1<<9) | DIRECT_MESSAGES (1<<12) | MESSAGE_CONTENT (1<<15).
    private static let intents = 512 | 4096 | 32768
    private static let apiBase = "https://discord.com/api/v10"

    init(
        token: String,
        router: RemoteCommandRouter,
        onStateChange: @escaping (RemoteConnectionState) -> Void
    ) {
        self.token = token
        self.router = router
        self.onStateChange = onStateChange

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    // MARK: - Lifecycle

    func start() {
        guard task == nil else { return }
        onStateChange(.connecting)
        task = Task { [weak self] in await self?.supervise() }
    }

    func stop() {
        task?.cancel()
        task = nil
        teardownConnection()
        session.invalidateAndCancel()
        onStateChange(.off)
    }

    /// Reconnect loop. The Gateway drops connections routinely (op 7, server
    /// restarts, network changes) — treating that as normal rather than as an
    /// error is what keeps the bridge up for days at a time.
    private func supervise() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            do {
                try await connectAndRead()
                backoff = 1 // clean close; reconnect promptly
            } catch is CancellationError {
                return
            } catch let error as BridgeError {
                if case .authFailed = error {
                    // A bad token will never fix itself — stop instead of
                    // hammering the Gateway (which bans on repeated bad auth).
                    onStateChange(.failed(error.localizedDescription))
                    remoteLog.error("Discord authentication failed; bridge stopped")
                    return
                }
                guard !Task.isCancelled else { return }
                onStateChange(.failed(error.localizedDescription))
                try? await Task.sleep(for: .seconds(Double(backoff)))
                backoff = min(backoff * 2, 60)
            } catch {
                guard !Task.isCancelled else { return }
                remoteLog.error("Discord gateway error: \(error.localizedDescription, privacy: .public)")
                onStateChange(.failed(Self.describe(error)))
                try? await Task.sleep(for: .seconds(Double(backoff)))
                backoff = min(backoff * 2, 60)
            }
            teardownConnection()
            guard !Task.isCancelled else { return }
            onStateChange(.connecting)
        }
    }

    // MARK: - Gateway connection

    /// Opens the socket and reads until it closes. Returns normally on a clean
    /// close (so the supervisor reconnects immediately); throws on failure.
    private func connectAndRead() async throws {
        // Resume where possible: it replays events missed during the drop.
        // A fresh session loses anything sent while disconnected.
        let canResume = sessionID != nil && resumeURL != nil
        let endpoint = canResume ? resumeURL! : try await fetchGatewayURL()

        guard let url = URL(string: endpoint + "?v=10&encoding=json") else {
            throw BridgeError.malformed
        }
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        lastHeartbeatAcked = true

        while !Task.isCancelled {
            let message = try await socket.receive()
            guard let payload = Self.decode(message) else { continue }
            let op = payload["op"] as? Int ?? -1

            if let seq = payload["s"] as? Int { sequence = seq }

            switch op {
            case 10: // HELLO
                let data = payload["d"] as? [String: Any]
                let interval = (data?["heartbeat_interval"] as? Int) ?? 41250
                startHeartbeat(intervalMilliseconds: interval)
                if canResume, let sessionID {
                    try await send(op: 6, data: [
                        "token": token, "session_id": sessionID, "seq": sequence ?? 0,
                    ])
                } else {
                    try await identify()
                }

            case 11: // HEARTBEAT ACK
                lastHeartbeatAcked = true

            case 1: // server asked for an immediate heartbeat
                try await send(op: 1, rawData: sequence)

            case 7: // RECONNECT — resume against the same session
                return

            case 9: // INVALID SESSION
                // `d: false` means the session is unrecoverable; drop it so the
                // next attempt identifies fresh rather than looping on a resume
                // Discord will keep rejecting.
                if payload["d"] as? Bool != true { sessionID = nil; resumeURL = nil }
                return

            case 0: // DISPATCH
                await dispatch(payload)

            default:
                continue
            }
        }
    }

    private func identify() async throws {
        try await send(op: 2, data: [
            "token": token,
            "intents": Self.intents,
            "properties": ["os": "macOS", "browser": "Baton", "device": "Baton"],
            "presence": [
                "status": "online",
                "afk": false,
                "activities": [["name": "your library", "type": 2]], // 2 = Listening to
            ],
        ])
    }

    private func dispatch(_ payload: [String: Any]) async {
        let type = payload["t"] as? String ?? ""
        let data = payload["d"] as? [String: Any] ?? [:]

        switch type {
        case "READY":
            sessionID = data["session_id"] as? String
            resumeURL = data["resume_gateway_url"] as? String
            let user = data["user"] as? [String: Any]
            let name = user?["username"] as? String ?? "connected"
            onStateChange(.connected(account: "@\(name)"))
            remoteLog.notice("Discord bridge connected")

        case "RESUMED":
            onStateChange(.connected(account: "resumed"))

        case "MESSAGE_CREATE":
            await handleMessage(data)

        case "INTERACTION_CREATE":
            await handleInteraction(data)

        default:
            break
        }
    }

    /// Heartbeats keep the socket alive; a missed ACK means the connection is a
    /// zombie (still open, no longer delivering) — the documented remedy is to
    /// close it and reconnect rather than keep waiting on a dead socket.
    private func startHeartbeat(intervalMilliseconds: Int) {
        heartbeatTask?.cancel()
        let interval = Double(intervalMilliseconds) / 1000
        heartbeatTask = Task { [weak self] in
            // Discord asks for a random offset on the first beat so fleets of
            // clients don't synchronize into a thundering herd.
            try? await Task.sleep(for: .seconds(interval * Double.random(in: 0...1)))
            while !Task.isCancelled {
                guard let self else { return }
                let alive = await MainActor.run { () -> Bool in
                    guard self.lastHeartbeatAcked else { return false }
                    self.lastHeartbeatAcked = false
                    return true
                }
                guard alive else {
                    await MainActor.run { self.socket?.cancel(with: .abnormalClosure, reason: nil) }
                    return
                }
                do {
                    try await self.send(op: 1, rawData: await MainActor.run { self.sequence })
                } catch {
                    return
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: - Inbound

    private func handleMessage(_ data: [String: Any]) async {
        guard let author = data["author"] as? [String: Any],
              author["bot"] as? Bool != true, // never react to bots, including ourselves
              let senderID = author["id"] as? String,
              let channelID = data["channel_id"] as? String,
              let content = (data["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else { return }

        // Strip a leading mention so "@Baton pause" works in a busy channel.
        let text = Self.stripLeadingMention(content)

        let inbound = RemoteInbound(
            platform: .discord,
            senderID: senderID,
            senderName: author["username"] as? String ?? senderID,
            channelID: channelID,
            text: text
        )
        // Same reasoning as the Telegram bridge: a local model takes seconds,
        // and silence reads as breakage. Discord's typing indicator runs ~10s.
        _ = try? await rest("POST", "/channels/\(channelID)/typing", body: [:])
        guard let reply = await router.handle(inbound) else { return }
        await postMessage(reply, channelID: channelID)
    }

    private func handleInteraction(_ data: [String: Any]) async {
        // Component (button) interactions only — slash commands would need a
        // publicly reachable interactions endpoint, which is exactly what this
        // design avoids.
        guard let id = data["id"] as? String,
              let interactionToken = data["token"] as? String,
              let payload = data["data"] as? [String: Any],
              let customID = payload["custom_id"] as? String,
              let channelID = data["channel_id"] as? String
        else { return }

        // In a guild the user is nested under `member`; in a DM it's top-level.
        let user = (data["member"] as? [String: Any])?["user"] as? [String: Any]
            ?? data["user"] as? [String: Any]
        guard let senderID = user?["id"] as? String else { return }

        let inbound = RemoteInbound(
            platform: .discord,
            senderID: senderID,
            senderName: user?["username"] as? String ?? senderID,
            channelID: channelID,
            text: customID
        )
        let reply = await router.handle(inbound)
        await respondToInteraction(
            id: id,
            token: interactionToken,
            reply: reply ?? .plain("Nothing to do.")
        )
    }

    // MARK: - Outbound (REST)

    /// Send without an interaction to respond to — see the Telegram note.
    func push(_ reply: RemoteReply, to channelID: String) async {
        await postMessage(reply, channelID: channelID)
    }

    private func postMessage(_ reply: RemoteReply, channelID: String) async {
        // Discord's cap is half of Telegram's, 2000 chars, and an oversized
        // message is refused with a 400 — the user would get nothing at all.
        var body: [String: Any] = ["content": RemoteReply.clamped(Self.emphasize(reply.text), to: 1990)]
        if !reply.choices.isEmpty {
            body["components"] = Self.choiceComponents(reply.choices)
        } else if reply.showsTransport {
            body["components"] = Self.transportComponents
        }
        do {
            try await rest("POST", "/channels/\(channelID)/messages", body: body)
        } catch {
            remoteLog.error("Discord send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Interaction responses must go out within 3 seconds or Discord shows the
    /// user "This interaction failed", so this is a plain reply rather than a
    /// deferred-then-edited one — every transport action resolves well inside it.
    private func respondToInteraction(id: String, token: String, reply: RemoteReply) async {
        var data: [String: Any] = ["content": Self.emphasize(reply.text)]
        if !reply.choices.isEmpty {
            data["components"] = Self.choiceComponents(reply.choices)
        } else if reply.showsTransport {
            data["components"] = Self.transportComponents
        }
        do {
            try await rest("POST", "/interactions/\(id)/\(token)/callback", body: [
                "type": 4, // CHANNEL_MESSAGE_WITH_SOURCE
                "data": data,
            ])
        } catch {
            remoteLog.error("Discord interaction reply failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The agent's options, one row of buttons. `custom_id` carries `pick N`
    /// (see the Telegram note): short, and identical to what typing "2" sends.
    private static func choiceComponents(_ choices: [RemoteChoice]) -> [[String: Any]] {
        [[
            "type": 1, // action row
            "components": choices.enumerated().map { index, choice in
                [
                    "type": 2,
                    "style": index == 0 ? 1 : 2,
                    "label": String(choice.label.prefix(80)),
                    "custom_id": RemoteChoicePrompt.payload(for: index),
                ]
            },
        ]]
    }

    /// Button `custom_id`s are ordinary command strings, so a tap and a typed
    /// message converge on `RemoteCommandParser` — one code path, one meaning.
    private static let transportComponents: [[String: Any]] = [[
        "type": 1, // action row
        "components": [
            ["type": 2, "style": 2, "label": "⏮", "custom_id": "prev"],
            ["type": 2, "style": 2, "label": "❚❚", "custom_id": "pause"],
            ["type": 2, "style": 1, "label": "▶︎", "custom_id": "resume"],
            ["type": 2, "style": 2, "label": "⏭", "custom_id": "next"],
            ["type": 2, "style": 2, "label": "🔊", "custom_id": "np"],
        ],
    ]]

    @discardableResult
    private func rest(_ method: String, _ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: Self.apiBase + path) else { throw BridgeError.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Discord blocks requests without a User-Agent it recognizes as a client.
        request.setValue("DiscordBot (https://baton.tonebox.io, 1.0)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.malformed }
        if http.statusCode == 401 { throw BridgeError.authFailed }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { $0["message"] as? String }
            throw BridgeError.api(detail ?? "HTTP \(http.statusCode)")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func fetchGatewayURL() async throws -> String {
        guard let url = URL(string: Self.apiBase + "/gateway/bot") else { throw BridgeError.malformed }
        var request = URLRequest(url: url)
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("DiscordBot (https://baton.tonebox.io, 1.0)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw BridgeError.authFailed }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = root["url"] as? String
        else { throw BridgeError.malformed }
        return gateway
    }

    // MARK: - Frames

    private func send(op: Int, data: [String: Any]) async throws {
        try await sendFrame(["op": op, "d": data])
    }

    /// `op 1` carries a bare sequence number (or null), not an object.
    private func send(op: Int, rawData: Int?) async throws {
        try await sendFrame(["op": op, "d": rawData as Any? ?? NSNull()])
    }

    private func sendFrame(_ frame: [String: Any]) async throws {
        guard let socket else { throw BridgeError.malformed }
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard let text = String(data: data, encoding: .utf8) else { throw BridgeError.malformed }
        try await socket.send(.string(text))
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data?
        switch message {
        case let .string(text): data = text.data(using: .utf8)
        case let .data(raw): data = raw
        @unknown default: data = nil
        }
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func teardownConnection() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    // MARK: - Text

    /// Replies are authored in Telegram's flavour (`*bold*`); on Discord a single
    /// asterisk is italic, so promote it to `**bold**`.
    nonisolated static func emphasize(_ text: String) -> String {
        var out = ""
        var isOpen = false
        var previous: Character?
        for character in text {
            if character == "*", previous != "*" {
                out += "**"
                isOpen.toggle()
            } else {
                out.append(character)
            }
            previous = character
        }
        // Unbalanced markers would swallow the rest of the message in bold.
        return isOpen ? text : out
    }

    nonisolated static func stripLeadingMention(_ text: String) -> String {
        guard text.hasPrefix("<@"), let end = text.firstIndex(of: ">") else { return text }
        return String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    enum BridgeError: LocalizedError {
        case api(String)
        case malformed
        case authFailed

        var errorDescription: String? {
            switch self {
            case let .api(message): message
            case .malformed: "Unexpected response from Discord"
            case .authFailed: "Discord rejected the bot token. Check it in Settings → Remote."
            }
        }
    }
}
#endif
