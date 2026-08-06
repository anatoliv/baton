import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// A short, in-memory record of what was said in each chat, so a follow-up can
/// refer to what came before — "select one of them", "the second one", "actually
/// skip it". Without it every message is its own universe, and the model quite
/// reasonably searches for the literal words "one of them".
///
/// Deliberately small and forgetful:
/// - **Never persisted.** It lives for the run of the app and dies with it; chat
///   history is not something a music player should keep on disk.
/// - **Bounded** to the last few exchanges, because context costs tokens on every
///   request and a stale reference is worse than none.
/// - **Expires** after a quiet period, so tomorrow's "play it again" doesn't
///   resolve against something you said last week.
@MainActor
public final class RemoteConversationLog {
    public struct Turn: Sendable, Equatable {
        /// "user" or "assistant" — the role names both API dialects share.
        public let role: String
        public let text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// Exchanges kept per chat (one exchange = user message + Baton's reply).
    private let maxExchanges: Int
    /// A gap longer than this starts a fresh conversation.
    private let idleTimeout: TimeInterval
    private let now: () -> Date

    private struct Thread {
        public var turns: [Turn] = []
        public var lastActivity: Date
    }
    private var threads: [String: Thread] = [:]

    public init(
        maxExchanges: Int = 4,
        idleTimeout: TimeInterval = 30 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.maxExchanges = maxExchanges
        self.idleTimeout = idleTimeout
        self.now = now
    }

    public static func key(for inbound: RemoteInbound) -> String {
        "\(inbound.platform.rawValue):\(inbound.channelID)"
    }

    /// The prior turns worth sending, oldest first. Returns nothing once the
    /// thread has gone quiet long enough to be stale.
    public func history(for key: String) -> [Turn] {
        guard let thread = threads[key] else { return [] }
        guard now().timeIntervalSince(thread.lastActivity) <= idleTimeout else {
            threads[key] = nil
            return []
        }
        return thread.turns
    }

    /// Record one complete exchange. Replies are truncated because a long search
    /// result is useful as a *referent* ("the third one") without needing to be
    /// carried in full for the rest of the conversation.
    public func record(key: String, user: String, assistant: String) {
        var thread = threads[key] ?? Thread(lastActivity: now())
        if now().timeIntervalSince(thread.lastActivity) > idleTimeout {
            thread = Thread(lastActivity: now())
        }
        thread.turns.append(Turn(role: "user", text: user))
        thread.turns.append(Turn(role: "assistant", text: String(assistant.prefix(1500))))

        let maxTurns = maxExchanges * 2
        if thread.turns.count > maxTurns {
            thread.turns.removeFirst(thread.turns.count - maxTurns)
        }
        thread.lastActivity = now()
        threads[key] = thread
    }

    public func forget(key: String) {
        threads[key] = nil
    }

    public var isEmpty: Bool { threads.isEmpty }
}
