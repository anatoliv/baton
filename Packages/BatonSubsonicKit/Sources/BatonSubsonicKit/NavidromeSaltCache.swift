import Foundation

/// One server's Subsonic salt and token, held in memory so every `NavidromeClient` built for
/// that server signs its URLs the same way.
///
/// **Why this is not on the client.** `NavidromeClient` is a `Sendable` value type that every
/// call site builds on demand: 30 `NavidromeConfig.makeClient()` sites plus one direct
/// construction, and not one of them keeps the client afterwards. A salt cached on the
/// instance therefore never survives to a second request. The TBX-5349 agent measured the
/// consequence in the owner's live on-disk `URLCache`: 645 cover-art entries carrying 645
/// distinct salts for 456 distinct covers, so no HTTP cache could ever match a repeat URL.
///
/// **Why reuse is safe.** Subsonic's scheme is `t = md5(password + salt)`, and both `t` and
/// `s` travel in the clear in the query string of every request. A salt is a public value
/// there, not a secret, and reusing one leaks nothing that the first request did not already
/// put on the wire. The salt exists so the password itself is never sent, and that still
/// holds. The spec sets no freshness requirement, and Navidrome accepts a repeated salt.
///
/// **What is deliberately not done here.** Nothing is written to disk, so a salt lasts for
/// the life of the process and no token outlives it. No secret and no digest of a secret is
/// stored either: an entry holds the salt and the token, both of which are already in every
/// URL Baton sends. A changed password is detected by recomputing the token from the stored
/// salt and comparing it with the stored token, which costs the one md5 the old per-instance
/// code paid anyway and gives a credential change a fresh salt on the very next client.
enum NavidromeSaltCache {
    /// The pair a client signs with.
    struct Signature: Equatable {
        var salt: String
        var token: String
    }

    /// At most this many servers are remembered. The list is a handful in practice, and a
    /// bound means a long-running process cannot accumulate tokens for servers it has left.
    private static let limit = 8

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Signature] = [:]
    /// Keys in insertion order, oldest first, so the bound evicts the least recently minted.
    nonisolated(unsafe) private static var order: [String] = []

    /// Identifies the server session: the base URL and the username. The secret is not part
    /// of the key, by design. A changed secret is caught by the token check below instead,
    /// which keeps every password and every password digest out of this store.
    private static func key(for credentials: NavidromeCredentials) -> String {
        credentials.baseURL.absoluteString + "\u{0}" + credentials.username
    }

    /// The salt and token for these credentials, minting a fresh pair on the first request to
    /// a server and again whenever the password behind it has changed.
    static func signature(for credentials: NavidromeCredentials) -> Signature {
        let key = key(for: credentials)
        lock.lock()
        defer { lock.unlock() }

        if let existing = entries[key],
           NavidromeClient.token(password: credentials.secret, salt: existing.salt) == existing.token {
            return existing
        }

        let salt = NavidromeClient.makeSalt()
        let fresh = Signature(salt: salt, token: NavidromeClient.token(password: credentials.secret, salt: salt))
        if entries[key] == nil {
            order.append(key)
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
        }
        entries[key] = fresh
        return fresh
    }

    /// Drops everything. Called when the saved servers change, so a server that has been
    /// removed or re-pointed leaves no token behind, and used by tests that need a known
    /// starting state.
    static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries = [:]
        order = []
    }

    /// The stored pair for these credentials, without minting one. Tests only.
    static func storedSignature(for credentials: NavidromeCredentials) -> Signature? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key(for: credentials)]
    }
}
