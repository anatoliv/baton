import Foundation

/// Which downloaded audio to remove, and which removals to suggest
/// (`specs/document-clippings.md`, *Storage*).
///
/// Pure, so the rules are decided once and tested once, and the Mac and the phone apply the
/// same ones. Three properties are the point and each has a test:
/// - **nothing is removed without a rule the person chose**: with no rules, this only suggests;
/// - **the book in progress and anything marked Keep are never removed**, by any rule;
/// - **removal is of the download only** ("offload"): the book, its text, its voice and its
///   place in it stay, so it can be downloaded or rendered again.
public enum StoragePolicy {
    public struct Item: Sendable, Equatable {
        public var id: String
        public var title: String
        public var bytes: Int
        public var isBook: Bool
        public var addedAt: Date
        public var lastPlayedAt: Date?
        public var finishedAt: Date?
        /// Started and not finished: never removed.
        public var inProgress: Bool
        /// Pinned with Keep: never removed.
        public var keep: Bool
        /// Audio on this device now. Only downloaded items take space or can be offloaded.
        public var downloaded: Bool

        public init(id: String, title: String, bytes: Int, isBook: Bool, addedAt: Date, lastPlayedAt: Date? = nil,
                    finishedAt: Date? = nil, inProgress: Bool = false, keep: Bool = false, downloaded: Bool = true) {
            self.id = id
            self.title = title
            self.bytes = bytes
            self.isBook = isBook
            self.addedAt = addedAt
            self.lastPlayedAt = lastPlayedAt
            self.finishedAt = finishedAt
            self.inProgress = inProgress
            self.keep = keep
            self.downloaded = downloaded
        }

        var removable: Bool { downloaded && !keep && !inProgress }
    }

    /// The person's rules for this device. Each `nil` means "keep" (no rule).
    public struct Rules: Codable, Sendable, Equatable {
        /// Remove a finished item's download this long after finishing (0 = right away).
        public var afterFinished: TimeInterval?
        /// Remove a download not played (or, if never played, not added) for this long.
        public var unplayedFor: TimeInterval?
        /// Keep books and clippings on this device under this many bytes.
        public var spaceLimit: Int?

        public init(afterFinished: TimeInterval? = nil, unplayedFor: TimeInterval? = nil, spaceLimit: Int? = nil) {
            self.afterFinished = afterFinished
            self.unplayedFor = unplayedFor
            self.spaceLimit = spaceLimit
        }

        public static let none = Rules()
        /// The spec's defaults: remove a finished item's download a week after finishing.
        public static let defaults = Rules(afterFinished: 7 * day)

        public var isEmpty: Bool { afterFinished == nil && unplayedFor == nil && spaceLimit == nil }

        /// The choices Settings offers, as (label, value). Labels are user copy: no em dashes.
        public static let afterFinishedChoices: [(String, TimeInterval?)] = [
            ("Keep", nil), ("Right away", 0), ("After 1 day", day), ("After 7 days", 7 * day), ("After 30 days", 30 * day),
        ]
        public static let unplayedChoices: [(String, TimeInterval?)] = [
            ("Keep", nil), ("After 1 month", 30 * day), ("After 3 months", 91 * day),
            ("After 6 months", 182 * day), ("After 1 year", 365 * day),
        ]
        public static let spaceChoices: [(String, Int?)] = [
            ("No limit", nil), ("1 GB", 1_000_000_000), ("2 GB", 2_000_000_000), ("5 GB", 5_000_000_000),
            ("10 GB", 10_000_000_000),
        ]
    }

    public static let day: TimeInterval = 86_400

    public enum Reason: Equatable, Sendable {
        case finished(daysAgo: Int)
        case unplayed(daysAgo: Int)
        case overSpaceLimit
    }

    public struct Removal: Equatable, Sendable {
        public var id: String
        public var bytes: Int
        public var reason: Reason
    }

    /// What the rules remove now. With no rules, nothing.
    public static func removals(_ items: [Item], rules: Rules, now: Date) -> [Removal] {
        var out: [Removal] = []
        var taken = Set<String>()
        for item in items where item.removable {
            if let after = rules.afterFinished, let finished = item.finishedAt, now.timeIntervalSince(finished) >= after {
                out.append(Removal(id: item.id, bytes: item.bytes, reason: .finished(daysAgo: days(now, finished))))
                taken.insert(item.id)
            } else if let unplayed = rules.unplayedFor {
                let last = item.lastPlayedAt ?? item.addedAt
                if now.timeIntervalSince(last) >= unplayed {
                    out.append(Removal(id: item.id, bytes: item.bytes, reason: .unplayed(daysAgo: days(now, last))))
                    taken.insert(item.id)
                }
            }
        }
        if let limit = rules.spaceLimit {
            var used = items.filter { $0.downloaded && !taken.contains($0.id) }.reduce(0) { $0 + $1.bytes }
            // Finished first, least recently played first; then unfinished-but-not-started
            // items the same way. Never the book in progress, never Keep.
            let order = items.filter { $0.removable && !taken.contains($0.id) }.sorted {
                let a = ($0.finishedAt == nil ? 1 : 0, $0.lastPlayedAt ?? $0.addedAt)
                let b = ($1.finishedAt == nil ? 1 : 0, $1.lastPlayedAt ?? $1.addedAt)
                return a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
            }
            for item in order where used > limit {
                out.append(Removal(id: item.id, bytes: item.bytes, reason: .overSpaceLimit))
                used -= item.bytes
            }
        }
        return out
    }

    public struct Suggestion: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// One finished item, offered with "Always do this", which sets `afterFinished`.
            case finishedItem(daysAgo: Int)
            /// Device space is low: the largest finished items, removable in one tap.
            case lowDeviceSpace(freeBytes: Int)
        }
        public var kind: Kind
        public var ids: [String]
        public var bytes: Int
    }

    public static let suggestionInterval: TimeInterval = 7 * day
    public static let lowSpaceThreshold = 2_000_000_000

    /// What to offer in the Clippings view: at most once a week, and only for what the rules
    /// would not already remove. Low device space is offered whatever the rules say, because a
    /// full phone is worth one interruption.
    public static func suggestions(_ items: [Item], rules: Rules, now: Date, freeBytes: Int?,
                                   lastSuggestedAt: Date?) -> [Suggestion] {
        if let last = lastSuggestedAt, now.timeIntervalSince(last) < suggestionInterval { return [] }
        let ruled = Set(removals(items, rules: rules, now: now).map(\.id))
        let finished = items.filter { $0.removable && $0.finishedAt != nil && !ruled.contains($0.id) }
        var out: [Suggestion] = []
        if let free = freeBytes, free < lowSpaceThreshold, !finished.isEmpty {
            let largest = finished.sorted { $0.bytes > $1.bytes }.prefix(3)
            out.append(Suggestion(kind: .lowDeviceSpace(freeBytes: free), ids: largest.map(\.id),
                                  bytes: largest.reduce(0) { $0 + $1.bytes }))
        }
        if rules.afterFinished == nil,
           let oldest = finished.filter({ now.timeIntervalSince($0.finishedAt!) >= 7 * day })
            .min(by: { $0.finishedAt! < $1.finishedAt! }),
           !out.contains(where: { $0.ids.contains(oldest.id) }) {
            out.append(Suggestion(kind: .finishedItem(daysAgo: days(now, oldest.finishedAt!)), ids: [oldest.id],
                                  bytes: oldest.bytes))
        }
        return out
    }

    /// Removed items stay restorable ("Download again") for this long in "Recently removed".
    public static let recentlyRemovedFor: TimeInterval = 7 * day

    static func days(_ now: Date, _ then: Date) -> Int { Int(now.timeIntervalSince(then) / day) }
}
