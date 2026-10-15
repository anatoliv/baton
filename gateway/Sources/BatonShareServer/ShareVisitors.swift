#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import BatonMCPProtocol
import BatonShareKit
import Foundation

/// Counting people without keeping anything that identifies them (spec §5).
///
/// The salt lives in memory only and is replaced at 00:00 UTC, so a visitor hash means "the same
/// browser on the same share on the same day" and nothing more: it cannot be joined across days or
/// across shares, and it cannot be reversed to an address once the salt is gone. A restart also
/// replaces it, which over-counts a little on that day. That is the right direction to be wrong in.
public final class DailySalt: @unchecked Sendable {
    private let lock = NSLock()
    private var day: Int64 = -1
    private var salt = Data()
    private let random: @Sendable () -> Data

    public init(random: @escaping @Sendable () -> Data = { ShareCrypto.newKey() + ShareCrypto.newKey() }) {
        self.random = random
    }

    /// The salt for the UTC day containing `now`, and that day's number.
    public func current(now: Int64) -> (salt: Data, day: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let today = now / 86400
        if today != day {
            day = today
            salt = random()
        }
        return (salt, day)
    }

    /// First 16 hex of `SHA-256(salt ‖ parts joined by "\n")`.
    public func hash(_ parts: [String], now: Int64) -> String {
        var hasher = SHA256()
        hasher.update(data: current(now: now).salt)
        hasher.update(data: Data(parts.joined(separator: "\n").utf8))
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

/// Who is asking, as far as the service is allowed to know.
public struct ShareRequester: Sendable {
    /// The client address, from the proxy chain. Used for hashing only, never stored.
    public let address: String
    public let userAgent: String

    /// Whether any proxy header was present. The admin route refuses such requests: a request
    /// that came through `baton_web` came from outside.
    public let viaProxy: Bool

    public init(headers: [String: String]) {
        let forwarded = headers["x-forwarded-for"]?.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        address = headers["cf-connecting-ip"] ?? headers["x-real-ip"] ?? forwarded ?? "unknown"
        userAgent = headers["user-agent"] ?? ""
        viaProxy = headers["cf-connecting-ip"] != nil || headers["x-real-ip"] != nil
            || headers["x-forwarded-for"] != nil
    }
}

/// What kind of client fetched a page, for `link_unfurled` and `page_opened`.
public enum ClientClass {
    /// The messaging app whose crawler built a preview, or `nil` for a person's browser.
    ///
    /// Order matters: iMessage's preview fetcher announces itself as Safari *plus* the Facebook
    /// and Twitter crawler tokens, so it has to be recognised before either of those.
    public static func crawler(userAgent: String) -> String? {
        let ua = userAgent.lowercased()
        if ua.isEmpty { return "other_bot" }
        if ua.contains("facebookexternalhit"), ua.contains("twitterbot") { return "imessage" }
        let known: [(String, String)] = [
            ("whatsapp", "whatsapp"), ("slackbot", "slack"), ("slack-imgproxy", "slack"),
            ("discordbot", "discord"), ("telegrambot", "telegram"), ("facebookexternalhit", "facebook"),
            ("facebot", "facebook"), ("twitterbot", "twitter"), ("signal", "signal"),
        ]
        for (token, app) in known where ua.contains(token) { return app }
        for token in ["bot", "crawler", "spider", "preview", "curl/", "wget/", "python-requests", "headless"]
            where ua.contains(token) {
            return "other_bot"
        }
        return nil
    }

    public static func device(userAgent: String) -> String {
        let ua = userAgent.lowercased()
        if ua.contains("iphone") || ua.contains("ipad") || ua.contains("ipod") { return "ios" }
        if ua.contains("android") { return "android" }
        if ua.contains("macintosh") || ua.contains("mac os x") { return "mac" }
        if ua.contains("windows") { return "windows" }
        if ua.contains("linux") || ua.contains("x11") { return "linux" }
        return "other"
    }
}

/// In-memory counters for the per-network and per-visitor limits (spec §6).
///
/// Per-sharer limits are counted from the database instead, because a sharer's day should not
/// reset when the container restarts. These are keyed by salted hashes that themselves reset
/// daily, so persisting them would preserve nothing meaningful.
public final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [String: (start: Int64, count: Int)] = [:]
    private var lastPrune: Int64 = 0

    public init() {}

    /// Counts one hit against `key` in a window of `seconds`, and says whether it was allowed.
    /// A refused hit does not count, so a client that backs off is let back in on time.
    public func allow(_ key: String, limit: Int, per seconds: Int64, now: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneIfDue(now)
        let start = now - now % seconds
        var entry = windows[key] ?? (start, 0)
        if entry.start != start { entry = (start, 0) }
        guard entry.count < limit else {
            windows[key] = entry
            return false
        }
        entry.count += 1
        windows[key] = entry
        return true
    }

    /// Whether `key` still has room, without counting.
    public func peek(_ key: String, limit: Int, per seconds: Int64, now: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let start = now - now % seconds
        guard let entry = windows[key], entry.start == start else { return true }
        return entry.count < limit
    }

    private func pruneIfDue(_ now: Int64) {
        guard now - lastPrune > 600 else { return }
        lastPrune = now
        windows = windows.filter { now - $0.value.start < 86400 }
    }
}
