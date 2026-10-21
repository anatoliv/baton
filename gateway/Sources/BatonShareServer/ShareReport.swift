import BatonShareKit
import Foundation

/// The admin report (spec §4.3): who is sharing, how often, and what happens to the links.
///
/// Built from the events table for one window. `scripts/adoption.py share` asks for two adjacent
/// windows and prints the change; a trend line can come later, once there is a trend.
public struct ShareReport: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var since: String
        public var until: String
        public var days: Int
    }

    public struct Sharers: Codable, Equatable, Sendable {
        /// Distinct sharers who created at least one share in the window. "Weekly sharers" when
        /// the window is 7 days.
        public var active = 0
        /// Sharers whose first share fell in the window.
        public var new = 0
        /// Active sharers who created two or more shares in the window.
        public var repeating = 0
        public var byPlatform: [String: Int] = [:]
        /// Of all shares in the window, the fraction made by the top 10% of sharers (at least
        /// one sharer). Near 1.0 means "one enthusiast", not "a feature people use".
        public var topDecileShareFraction = 0.0
        /// Shares per active sharer, as a distribution: 1, 2–3, 4–9, 10+.
        public var sharesPerSharer: [String: Int] = [:]
    }

    public struct Shares: Codable, Equatable, Sendable {
        public var created = 0
        public var finalized = 0
        public var byMode: [String: Int] = [:]
        public var byExpirySeconds: [String: Int] = [:]
        public var byDuration: [String: Int] = [:]
        public var withNote = 0
        public var revoked = 0
        public var extended = 0
        public var expired = 0
        public var capped = 0
        /// Ready shares right now, not just in the window.
        public var liveNow = 0
    }

    public struct Recipients: Codable, Equatable, Sendable {
        public var pageOpens = 0
        public var uniqueOpeners = 0
        /// Distinct shares opened at least once by a person (not a crawler).
        public var sharesOpened = 0
        public var openedAfterEnd: [String: Int] = [:]
        public var byDevice: [String: Int] = [:]
        public var unfurlsByApp: [String: Int] = [:]
        public var openedInApp = 0
        public var audioFetches = 0
    }

    public struct Listening: Codable, Equatable, Sendable {
        public var playsStarted = 0
        public var uniqueListeners = 0
        public var listened30s = 0
        public var completed = 0
        public var timeToFirstSoundMsP50: Int?
        public var timeToFirstSoundMsP95: Int?
        public var decryptFailures: [String: Int] = [:]
    }

    public struct Engagement: Codable, Equatable, Sendable {
        public var reactions = 0
        public var reactionsByEmoji: [String: Int] = [:]
        public var reactionsWithReply = 0
        public var getBatonClicks: [String: Int] = [:]
        public var foundInLibrary = 0
        public var notFoundInLibrary = 0
    }

    /// Whole-book links (`/b/`), counted apart from the totals they are also part of: the
    /// service labels a book's events `kind: book`. `listeners` is admitted listening sessions.
    public struct Books: Codable, Equatable, Sendable {
        public var created = 0
        public var finalized = 0
        public var revoked = 0
        public var pageOpens = 0
        public var unfurls = 0
        public var listeners = 0
    }

    public struct Health: Codable, Equatable, Sendable {
        public var failuresByReason: [String: Int] = [:]
        public var rateLimitedByScope: [String: Int] = [:]
        public var storedBytes: Int64 = 0
        public var quotaBytes: Int64 = 0
    }

    /// The headline ratios, each with its definition beside it in the spec. `nil` when the
    /// denominator is zero: "no data" is not "0%".
    public struct Rates: Codable, Equatable, Sendable {
        /// Shares opened by a person ÷ shares finalized.
        public var openRate: Double?
        /// Unique listeners ÷ unique openers.
        public var playRate: Double?
        /// Listened ≥30 s ÷ plays started.
        public var listenRate: Double?
        /// Completed ÷ plays started.
        public var completionRate: Double?
        /// Reactions ÷ unique listeners.
        public var reactionRate: Double?
        /// Get Baton clicks ÷ unique openers.
        public var getBatonRate: Double?
    }

    public var window: Window
    public var sharers = Sharers()
    public var shares = Shares()
    public var recipients = Recipients()
    public var listening = Listening()
    public var engagement = Engagement()
    public var books = Books()
    public var health = Health()
    public var rates = Rates()

    static func build(store: ShareStore, since: Int64, until: Int64, quotaBytes: Int64) throws -> ShareReport {
        func iso(_ t: Int64) -> String { ShareDate.string(Date(timeIntervalSince1970: TimeInterval(t))) }
        var report = ShareReport(window: Window(since: iso(since), until: iso(until),
                                                days: Int((until - since) / 86400)))
        var sharesBySharer: [String: Int] = [:]
        var platformBySharer: [String: String] = [:]
        var openers = Set<String>(), listeners = Set<String>(), openedShares = Set<String>()
        var firstSound: [Int] = []

        for row in try store.eventRows(since: since, until: until) {
            let type = row["type"]?.text ?? ""
            let props = row["props"]?.text
                .flatMap { try? JSONDecoder().decode([String: PropValue].self, from: Data($0.utf8)) } ?? [:]
            func text(_ key: String) -> String {
                switch props[key] {
                case let .string(v)?: v
                case let .int(v)?: String(v)
                case let .bool(v)?: String(v)
                case nil: "unknown"
                }
            }
            let visitor = row["visitor"]?.text
            let share = row["share_id"]?.text
            if props["kind"] == .string("book") {
                switch type {
                case "share_created": report.books.created += 1
                case "share_finalized": report.books.finalized += 1
                case "share_revoked": report.books.revoked += 1
                case "page_opened" where text("state") == "ready": report.books.pageOpens += 1
                case "link_unfurled": report.books.unfurls += 1
                case "audio_fetched": report.books.listeners += 1
                default: break
                }
            }
            switch type {
            case "share_created":
                report.shares.created += 1
                if let sharer = row["sharer_id"]?.text {
                    sharesBySharer[sharer, default: 0] += 1
                    platformBySharer[sharer] = text("platform")
                }
                if props["newSharer"] == .bool(true) { report.sharers.new += 1 }
                report.shares.byMode[text("mode"), default: 0] += 1
                report.shares.byExpirySeconds[text("expirySeconds"), default: 0] += 1
                report.shares.byDuration[text("durationBucket"), default: 0] += 1
                if props["hasNote"] == .bool(true) { report.shares.withNote += 1 }
            case "share_finalized": report.shares.finalized += 1
            case "share_revoked": report.shares.revoked += 1
            case "share_extended": report.shares.extended += 1
            case "share_expired": report.shares.expired += 1
            case "share_capped": report.shares.capped += 1
            case "share_failed": report.health.failuresByReason[text("reason"), default: 0] += 1
            case "rate_limited": report.health.rateLimitedByScope[text("scope"), default: 0] += 1
            case "link_unfurled": report.recipients.unfurlsByApp[text("app"), default: 0] += 1
            case "page_opened":
                let state = text("state")
                if state == "ready" {
                    report.recipients.pageOpens += 1
                    report.recipients.byDevice[text("device"), default: 0] += 1
                    if let visitor { openers.insert(visitor) }
                    if let share { openedShares.insert(share) }
                } else {
                    report.recipients.openedAfterEnd[state, default: 0] += 1
                }
            case "opened_in_app": report.recipients.openedInApp += 1
            case "audio_fetched": report.recipients.audioFetches += 1
            case "play_started":
                report.listening.playsStarted += 1
                if let visitor { listeners.insert(visitor) }
                if case let .int(ms)? = props["ms"] { firstSound.append(ms) }
            case "play_30s": report.listening.listened30s += 1
            case "play_completed": report.listening.completed += 1
            case "decrypt_failed": report.listening.decryptFailures[text("reason"), default: 0] += 1
            case "reaction_sent":
                report.engagement.reactions += 1
                report.engagement.reactionsByEmoji[text("emoji"), default: 0] += 1
                if props["hasReply"] == .bool(true) { report.engagement.reactionsWithReply += 1 }
            case "get_baton_clicked": report.engagement.getBatonClicks[text("target"), default: 0] += 1
            case "found_in_library":
                if props["found"] == .bool(true) { report.engagement.foundInLibrary += 1 }
                else { report.engagement.notFoundInLibrary += 1 }
            default: break
            }
        }

        report.sharers.active = sharesBySharer.count
        report.sharers.repeating = sharesBySharer.values.filter { $0 >= 2 }.count
        for platform in platformBySharer.values { report.sharers.byPlatform[platform, default: 0] += 1 }
        let counts = sharesBySharer.values.sorted(by: >)
        if !counts.isEmpty {
            let top = max(1, counts.count / 10)
            report.sharers.topDecileShareFraction = Double(counts.prefix(top).reduce(0, +)) / Double(counts.reduce(0, +))
        }
        for count in counts {
            let bucket = switch count { case 1: "1"; case 2 ... 3: "2-3"; case 4 ... 9: "4-9"; default: "10+" }
            report.sharers.sharesPerSharer[bucket, default: 0] += 1
        }

        report.recipients.uniqueOpeners = openers.count
        report.recipients.sharesOpened = openedShares.count
        report.listening.uniqueListeners = listeners.count
        firstSound.sort()
        if !firstSound.isEmpty {
            report.listening.timeToFirstSoundMsP50 = firstSound[(firstSound.count - 1) / 2]
            report.listening.timeToFirstSoundMsP95 = firstSound[min(firstSound.count - 1,
                                                                    Int((Double(firstSound.count) * 0.95).rounded(.up)) - 1)]
        }
        report.shares.liveNow = try store.liveShareCount()
        report.health.storedBytes = try store.storedBytes()
        report.health.quotaBytes = quotaBytes

        func ratio(_ a: Int, _ b: Int) -> Double? { b == 0 ? nil : (Double(a) / Double(b) * 1000).rounded() / 1000 }
        report.rates = Rates(
            openRate: ratio(report.recipients.sharesOpened, report.shares.finalized),
            playRate: ratio(report.listening.uniqueListeners, report.recipients.uniqueOpeners),
            listenRate: ratio(report.listening.listened30s, report.listening.playsStarted),
            completionRate: ratio(report.listening.completed, report.listening.playsStarted),
            reactionRate: ratio(report.engagement.reactions, report.listening.uniqueListeners),
            getBatonRate: ratio(report.engagement.getBatonClicks.values.reduce(0, +), report.recipients.uniqueOpeners))
        return report
    }
}
