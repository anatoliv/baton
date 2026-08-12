import Foundation

/// What each device believes about each podcast subscription, and when it started
/// believing it.
///
/// The old synced shape was a plain list of feed URLs merged by union. That converges for
/// *subscribing* — two devices adding different shows end up with both — and is simply
/// unable to express *unsubscribing*. Drop a show on the Mac and the phone, which still has
/// it, hands it straight back on the next sync. The union was chosen deliberately, on the
/// grounds that losing a subscription you didn't ask to lose is worse than keeping one you
/// meant to drop, and that was the right call for a merge rule that had no way to tell an
/// unsubscribe from a device that simply hadn't heard yet.
///
/// A ledger can tell the difference. Each feed carries the moment it was last subscribed or
/// unsubscribed, so "I removed this at 10:04" beats "I still had it as of 09:12" without
/// either device needing to know what the other did — and a *later* resubscribe beats the
/// removal in turn. Union's real failure was never that it preferred keeping things; it was
/// that it had no clock.
public struct PodcastSubscriptionLedger: Codable, Equatable, Sendable {
    /// One feed's current state on one device.
    public struct Record: Codable, Equatable, Sendable {
        /// The stable id. A feed URL, normalised, so the same show subscribed on two
        /// devices is one entry rather than two near-identical ones.
        public var feed: String
        /// True when this is a tombstone: the show was unsubscribed, and that fact has to
        /// travel just as a subscription does.
        public var removed: Bool
        /// When this device last changed its mind about this feed.
        public var at: Date

        public init(feed: String, removed: Bool, at: Date) {
            self.feed = feed
            self.removed = removed
            self.at = at
        }
    }

    public var records: [Record]

    public init(records: [Record] = []) { self.records = records }

    /// How long a tombstone is kept.
    ///
    /// It cannot be dropped as soon as it is applied: the moment it disappears, any device
    /// that still holds the subscription and hasn't synced since re-adds the show, and the
    /// unsubscribe undoes itself. It also cannot be kept forever without the ledger growing
    /// without bound. Six months is far longer than any plausible gap between a phone and a
    /// Mac being switched on, and small enough that the list stays a list.
    public static let tombstoneRetention: TimeInterval = 180 * 24 * 60 * 60

    /// The feeds currently subscribed, tombstones excluded.
    public var liveFeeds: [String] {
        records.filter { !$0.removed }.map(\.feed)
    }

    public func record(for feed: String) -> Record? {
        records.first { $0.feed == PodcastSubscriptionLedger.normalize(feed) }
    }

    /// Note a subscribe or an unsubscribe, replacing whatever this device believed before.
    public mutating func note(feed: String, removed: Bool, at: Date = Date()) {
        let id = PodcastSubscriptionLedger.normalize(feed)
        guard !id.isEmpty else { return }
        if let index = records.firstIndex(where: { $0.feed == id }) {
            records[index].removed = removed
            records[index].at = at
        } else {
            records.append(Record(feed: id, removed: removed, at: at))
        }
    }

    /// Bring the ledger into line with what this device actually holds.
    ///
    /// Two rules, and the asymmetry between them is deliberate:
    ///
    /// - A feed the ledger has **never heard of** becomes a live record. That covers a new
    ///   subscription and the first run after upgrading.
    /// - A feed the ledger lists as **live** and the device no longer holds was unsubscribed
    ///   here, and becomes a tombstone rather than simply vanishing.
    ///
    /// What it deliberately does *not* do is flip an existing tombstone back to live merely
    /// because the show is still on disk. Between another device unsubscribing and this one
    /// getting round to applying it, the show is still present here — and a rule that read
    /// "present, therefore subscribed" would stamp a fresh subscription over the incoming
    /// tombstone and quietly undo the unsubscribe. Every persist would do it, so the race
    /// would be won by whichever device saved a file last rather than by whoever acted last.
    ///
    /// A deliberate re-subscribe still beats a tombstone: `subscribe(to:)` says so
    /// explicitly rather than leaving it to be inferred from the file system.
    public mutating func reconcile(withSubscribed feeds: [String], at date: Date = Date()) {
        let present = Set(feeds.map(PodcastSubscriptionLedger.normalize))
        for feed in present where record(for: feed) == nil {
            note(feed: feed, removed: false, at: date)
        }
        for existing in records where !existing.removed && !present.contains(existing.feed) {
            note(feed: existing.feed, removed: true, at: date)
        }
    }

    /// Merge two devices' ledgers. Per feed, the most recent statement wins — which is the
    /// whole point: a removal at 10:04 beats a subscription last confirmed at 09:12, and a
    /// resubscribe at 10:30 beats the removal.
    ///
    /// Ties keep the tombstone. Two edits sharing a timestamp to the second is either a
    /// clock collision or the same edit arriving twice, and in both cases honouring the
    /// removal is the choice that doesn't silently resurrect something.
    public static func merged(_ lhs: PodcastSubscriptionLedger,
                              _ rhs: PodcastSubscriptionLedger,
                              now: Date = Date()) -> PodcastSubscriptionLedger {
        var byFeed: [String: Record] = [:]
        for record in lhs.records + rhs.records {
            guard let existing = byFeed[record.feed] else {
                byFeed[record.feed] = record
                continue
            }
            if record.at > existing.at {
                byFeed[record.feed] = record
            } else if record.at == existing.at, record.removed {
                byFeed[record.feed] = record
            }
        }
        let kept = byFeed.values.filter { record in
            // Live entries are kept regardless of age; only tombstones expire.
            !record.removed || now.timeIntervalSince(record.at) < tombstoneRetention
        }
        return PodcastSubscriptionLedger(records: kept.sorted { $0.feed < $1.feed })
    }

    // MARK: - Encoding

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data?) -> PodcastSubscriptionLedger? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(PodcastSubscriptionLedger.self, from: data)
    }

    /// A ledger built from the old plain list of feed URLs.
    ///
    /// Dated to the distant past on purpose. A device still running the old build keeps
    /// writing that list, and its entries must never outrank a real tombstone — otherwise
    /// upgrading one device would resurrect every show the other had ever dropped. An
    /// entry that is genuinely new still arrives, because no tombstone exists to outrank.
    public static func fromLegacyFeeds(_ feeds: [String]) -> PodcastSubscriptionLedger {
        PodcastSubscriptionLedger(records: feeds.map {
            Record(feed: normalize($0), removed: false, at: .distantPast)
        })
    }

    /// The stable id for a feed.
    ///
    /// Two devices that subscribed to the same show by hand can easily hold
    /// `https://example.com/feed` and `https://example.com/feed/` — the same feed, and
    /// under a naive key, two subscriptions that never converge. Case and a trailing slash
    /// are the differences that carry no meaning; everything else is left alone, because a
    /// query string in a feed URL usually *is* the show.
    public static func normalize(_ feed: String) -> String {
        var text = feed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text) else { return text.lowercased() }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? text.lowercased()
    }
}
