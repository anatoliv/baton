import Foundation

/// Telegram control surface.
///
/// Transport is `getUpdates` long-polling — Baton holds an outbound HTTPS
/// request open and Telegram answers it when a message arrives. No webhook, no
/// inbound port, nothing for a router or firewall to forward, and it works
/// unchanged behind NAT. That's the whole reason this design leaves the MCP
/// server's loopback-only posture untouched.
///
/// Replies carry an inline keyboard (⏮ ❚❚ ▶︎ ⏭ 🔉 🔊) so the common actions are
/// one tap, and the callback handler routes the tap through the same parser a
/// typed command uses.
@MainActor
final class TelegramBridge {
    private let router: RemoteCommandRouter
    private let token: String
    private let onStateChange: (RemoteConnectionState) -> Void

    private var task: Task<Void, Never>?
    private var offset: Int = 0
    private let session: URLSession

    init(
        token: String,
        router: RemoteCommandRouter,
        onStateChange: @escaping (RemoteConnectionState) -> Void
    ) {
        self.token = token
        self.router = router
        self.onStateChange = onStateChange

        let config = URLSessionConfiguration.ephemeral
        // Comfortably longer than the 25s long-poll so a quiet chat isn't a
        // timeout; Telegram closes the request itself when the window expires.
        config.timeoutIntervalForRequest = 45
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        onStateChange(.connecting)
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
        onStateChange(.off)
    }

    private func run() async {
        // Validate the token once so a typo shows up in Settings immediately
        // rather than as silence.
        do {
            let me = try await call("getMe")
            let username = (me["username"] as? String).map { "@\($0)" } ?? "connected"
            onStateChange(.connected(account: username))
            remoteLog.notice("Telegram bridge connected")
        } catch {
            onStateChange(.failed(Self.describe(error)))
            remoteLog.error("Telegram getMe failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        var backoff: UInt64 = 1
        while !Task.isCancelled {
            do {
                let updates = try await poll()
                backoff = 1
                for update in updates { await handle(update) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                remoteLog.error("Telegram poll failed: \(error.localizedDescription, privacy: .public)")
                onStateChange(.failed(Self.describe(error)))
                // Exponential backoff to 60s: a transient network drop shouldn't
                // become a hot loop against Telegram's rate limiter.
                try? await Task.sleep(for: .seconds(Double(backoff)))
                backoff = min(backoff * 2, 60)
                if !Task.isCancelled { onStateChange(.connecting) }
            }
        }
    }

    // MARK: Polling

    private func poll() async throws -> [[String: Any]] {
        let response = try await call("getUpdates", body: [
            "offset": offset,
            "timeout": 25,
            "allowed_updates": ["message", "callback_query"],
        ], resultIsArray: true)
        let updates = response["result_array"] as? [[String: Any]] ?? []
        if let last = updates.compactMap({ $0["update_id"] as? Int }).max() {
            offset = last + 1 // acknowledge; Telegram won't resend these
        }
        return updates
    }

    private func handle(_ update: [String: Any]) async {
        if let callback = update["callback_query"] as? [String: Any] {
            await handleCallback(callback)
        } else if let message = update["message"] as? [String: Any] {
            await handleMessage(message)
        }
    }

    private func handleMessage(_ message: [String: Any]) async {
        guard let text = message["text"] as? String,
              let chat = message["chat"] as? [String: Any],
              let chatID = (chat["id"] as? Int).map(String.init),
              let from = message["from"] as? [String: Any],
              let senderID = (from["id"] as? Int).map(String.init)
        else { return }

        let inbound = RemoteInbound(
            platform: .telegram,
            senderID: senderID,
            senderName: from["username"] as? String ?? from["first_name"] as? String ?? senderID,
            channelID: chatID,
            text: text
        )
        guard let reply = await router.handle(inbound) else { return }
        await send(reply, to: chatID)
    }

    private func handleCallback(_ callback: [String: Any]) async {
        guard let id = callback["id"] as? String else { return }
        guard let data = callback["data"] as? String,
              let message = callback["message"] as? [String: Any],
              let chat = message["chat"] as? [String: Any],
              let chatID = (chat["id"] as? Int).map(String.init),
              let from = callback["from"] as? [String: Any],
              let senderID = (from["id"] as? Int).map(String.init)
        else {
            _ = try? await call("answerCallbackQuery", body: ["callback_query_id": id])
            return
        }

        let inbound = RemoteInbound(
            platform: .telegram,
            senderID: senderID,
            senderName: from["username"] as? String ?? senderID,
            channelID: chatID,
            text: data
        )
        let reply = await router.handle(inbound)

        // Always answer the callback — an unanswered tap spins Telegram's
        // client-side progress indicator until it times out.
        _ = try? await call("answerCallbackQuery", body: [
            "callback_query_id": id,
            "text": reply.map { String($0.text.prefix(180)) } ?? "",
        ])
        if let reply { await send(reply, to: chatID) }
    }

    // MARK: Sending

    private func send(_ reply: RemoteReply, to chatID: String) async {
        var body: [String: Any] = [
            "chat_id": chatID,
            "text": reply.text,
            "parse_mode": "Markdown",
            "disable_web_page_preview": true,
        ]
        if reply.showsTransport { body["reply_markup"] = Self.transportKeyboard }

        do {
            _ = try await call("sendMessage", body: body)
        } catch {
            // Track and album names are full of `_` and `*`. Telegram rejects the
            // whole message when they don't parse as Markdown, so retry as plain
            // text — a reply with visible asterisks beats no reply at all.
            body.removeValue(forKey: "parse_mode")
            if (try? await call("sendMessage", body: body)) == nil {
                remoteLog.error("Telegram sendMessage failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Button payloads are ordinary command strings, so a tap and a typed
    /// message converge on `RemoteCommandParser` — one code path, one meaning.
    private static let transportKeyboard: [String: Any] = [
        "inline_keyboard": [[
            ["text": "⏮", "callback_data": "prev"],
            ["text": "❚❚", "callback_data": "pause"],
            ["text": "▶︎", "callback_data": "resume"],
            ["text": "⏭", "callback_data": "next"],
            ["text": "🔉", "callback_data": "vol 30"],
            ["text": "🔊", "callback_data": "vol 80"],
        ]],
    ]

    // MARK: HTTP

    private enum BridgeError: LocalizedError {
        case api(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case let .api(message): message
            case .malformed: "Unexpected response from Telegram"
            }
        }
    }

    /// One Bot API call. Telegram wraps everything in `{ok, result, description}`;
    /// `result` is an object for most methods and an array for `getUpdates`, so
    /// array results come back under `result_array`.
    @discardableResult
    private func call(
        _ method: String,
        body: [String: Any] = [:],
        resultIsArray: Bool = false
    ) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw BridgeError.malformed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.malformed
        }
        guard root["ok"] as? Bool == true else {
            throw BridgeError.api(root["description"] as? String ?? "request failed")
        }
        if resultIsArray {
            return ["result_array": root["result"] as? [[String: Any]] ?? []]
        }
        return root["result"] as? [String: Any] ?? [:]
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
