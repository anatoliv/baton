import Foundation

/// What each conversation last searched for, so "something like that" means that conversation's
/// results and not somebody else's (TBX-5308, S-F26).
///
/// The gateway held one `lastResults` field on one instance, so `music_similar_songs` seeded from
/// whatever the most recent search had been, whoever made it. Harmless in a household of one and
/// wrong the moment two conversations overlap.
///
/// Bounded, oldest-use first. A map keyed by session id with nothing evicting it is a slow leak in
/// a process that runs for months, and the bound is what makes the fix safe to leave alone.
///
/// **Not thread-safe by itself, and does not pretend to be**: it is held by the tool surface,
/// which is `@MainActor`, so every use is already serialised. Adding a lock here would suggest a
/// guarantee the type cannot make about the values it hands back.
public final class SearchSeedStore<Value> {

    /// Sessions remembered at once. Small on purpose: this is a seed for the next question, not a
    /// history, and a household gateway has a handful of conversations open at the very most.
    public let limit: Int

    private var values: [String: Value] = [:]
    /// Least recently used first.
    private var order: [String] = []

    public init(limit: Int = 16) {
        self.limit = max(1, limit)
    }

    /// The key for a caller that sent no session id.
    ///
    /// One shared slot rather than a refusal: a client that does not identify its conversation
    /// still gets the old single-slot behaviour, which is what it had before, and clients that do
    /// identify themselves are separated from it and from each other.
    public static var anonymousKey: String { "-" }

    public func remember(_ value: Value, for sessionID: String?) {
        let key = Self.key(sessionID)
        values[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    public func seed(for sessionID: String?) -> Value? {
        let key = Self.key(sessionID)
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    public var count: Int { values.count }

    private static func key(_ sessionID: String?) -> String {
        guard let sessionID, !sessionID.isEmpty else { return anonymousKey }
        return String(sessionID.prefix(128))
    }
}
