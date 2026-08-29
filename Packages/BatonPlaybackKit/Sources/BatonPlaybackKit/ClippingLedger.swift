import Foundation

/// What every device agrees is true about a clipping: what it is called, and whether it still
/// exists anywhere.
///
/// **The gateway is a bag of files, not a shared list.** Its blob store is content-addressed and
/// immutable by design — that is what makes a truncated transfer detectable and a double-collect
/// impossible — so it cannot carry a name that changes or the fact that something was thrown
/// away. Those facts live here instead, and travel over `PreferenceSync`, which both devices
/// already run and which already knows how to merge a key per entry rather than per document.
///
/// **The tombstone is the source of truth, not the blob's absence.** A file missing from the
/// gateway is ambiguous: it may have been deleted, or it may have aged out after
/// `FileStore.defaultMaximumAge`. A device returning after a fortnight cannot tell those apart
/// by looking at the store, and guessing wrong either resurrects something you deleted or
/// silently drops something you kept. Only an explicit record distinguishes them.
///
/// **One departure from `PodcastSubscriptionLedger`, which this otherwise copies: per-field
/// timestamps.** A feed has a single fact — subscribed or not — so one clock suffices. A clipping
/// has two that move independently. With a single `at`, renaming on the Mac at 10:04 after
/// deleting on the phone at 10:02 would resurrect the clipping, because the rename's newer stamp
/// would win the whole record. Each field is therefore merged against its own clock.
///
/// Deletion stays revivable, exactly as a re-subscribe is: keep the same reading again and it
/// re-uploads to the same digest, so a later `removed: false` beats the tombstone. That is the
/// behaviour you want, and the precedent already covers it.
public struct ClippingLedger: Codable, Equatable, Sendable {

    /// One clipping's shared state, as this device last understood it.
    public struct Record: Codable, Equatable, Sendable {
        /// The stable id **across devices**: the content digest.
        ///
        /// Not the local UUID. Those are minted per device, so the same audio has a different
        /// one on the Mac and the phone and could never be matched up. The digest is the only
        /// name both ends already agree on, and it is what the gateway files itself under.
        public var sha256: String

        /// What it is called, and when that was last stated. Nil title means no device has ever
        /// named it — which is different from "named to the empty string".
        public var title: String?
        public var titleAt: Date?

        /// Where it came from. Carried for the same reason as the title: the phone shows it, and
        /// a clipping collected before the Mac started sending a real source would otherwise be
        /// stuck with whatever it first received.
        public var source: String?
        public var sourceAt: Date?

        /// Deleted everywhere, and when that was decided.
        ///
        /// Distinct from a device deciding it does not want its own copy — see
        /// `ClippingStore.dismissedDigests`, which is deliberately local and never written here.
        /// Conflating them would make "remove from this iPhone" delete the Mac's copy too.
        public var removed: Bool
        public var removedAt: Date?

        public init(sha256: String, title: String? = nil, titleAt: Date? = nil,
                    source: String? = nil, sourceAt: Date? = nil,
                    removed: Bool = false, removedAt: Date? = nil) {
            self.sha256 = sha256
            self.title = title
            self.titleAt = titleAt
            self.source = source
            self.sourceAt = sourceAt
            self.removed = removed
            self.removedAt = removedAt
        }

        /// The most recent thing said about this clipping by anyone, for retention decisions.
        var lastStated: Date {
            [titleAt, sourceAt, removedAt].compactMap { $0 }.max() ?? .distantPast
        }
    }

    public var records: [Record]

    public init(records: [Record] = []) { self.records = records }

    /// How long a tombstone is kept.
    ///
    /// The same six months `PodcastSubscriptionLedger` uses, and for the same reason: drop it the
    /// moment it is applied and any device that still holds the clipping and has not synced since
    /// re-uploads it, undoing the deletion. Six months is far longer than any plausible gap
    /// between a phone and a Mac being switched on, and comfortably longer than the gateway's own
    /// fourteen-day blob retention, so the file is always gone well before the record of its going.
    public static let tombstoneRetention: TimeInterval = 180 * 24 * 60 * 60

    /// A ceiling, so a long-lived install cannot grow this without bound. Oldest tombstones go
    /// first, because a live record still describes something a device may be holding.
    public static let maximumRecords = 1_000

    // MARK: - Reading

    public func record(for sha256: String) -> Record? {
        records.first { $0.sha256 == sha256 }
    }

    /// Digests deleted everywhere. A collector skips these.
    public var removedDigests: Set<String> {
        Set(records.filter(\.removed).map(\.sha256))
    }

    // MARK: - Writing

    /// Note this device's title for a clipping, replacing whatever it believed before.
    public mutating func setTitle(_ title: String, for sha256: String, at now: Date = Date()) {
        update(sha256) { record in
            record.title = title
            record.titleAt = now
            // A rename is a statement that the thing exists. Without this, renaming something
            // another device had deleted would leave a live title on a tombstoned record, and
            // the two would disagree about whether it is there at all.
            if record.removed, (record.removedAt ?? .distantPast) < now {
                record.removed = false
                record.removedAt = now
            }
        }
    }

    public mutating func setSource(_ source: String?, for sha256: String, at now: Date = Date()) {
        update(sha256) { record in
            record.source = source
            record.sourceAt = now
        }
    }

    /// Note that a clipping is gone everywhere.
    public mutating func remove(_ sha256: String, at now: Date = Date()) {
        update(sha256) { record in
            record.removed = true
            record.removedAt = now
        }
    }

    /// Note that a clipping exists — used when one is kept again after having been deleted.
    public mutating func restore(_ sha256: String, at now: Date = Date()) {
        update(sha256) { record in
            record.removed = false
            record.removedAt = now
        }
    }

    private mutating func update(_ sha256: String, _ change: (inout Record) -> Void) {
        if let index = records.firstIndex(where: { $0.sha256 == sha256 }) {
            change(&records[index])
        } else {
            var record = Record(sha256: sha256)
            change(&record)
            records.append(record)
        }
    }

    // MARK: - Merging

    /// Combine two devices' understandings, field by field.
    ///
    /// Per field rather than per record, which is the whole point: two devices that each changed
    /// a *different* thing about the same clipping must both survive, and a device that renamed
    /// something must not thereby win an argument about whether it was deleted.
    public static func merged(_ lhs: ClippingLedger, _ rhs: ClippingLedger,
                              now: Date = Date()) -> ClippingLedger {
        var byDigest: [String: Record] = [:]
        for record in lhs.records + rhs.records {
            guard var existing = byDigest[record.sha256] else {
                byDigest[record.sha256] = record
                continue
            }
            if newer(record.titleAt, than: existing.titleAt) {
                existing.title = record.title
                existing.titleAt = record.titleAt
            }
            if newer(record.sourceAt, than: existing.sourceAt) {
                existing.source = record.source
                existing.sourceAt = record.sourceAt
            }
            if newer(record.removedAt, than: existing.removedAt) {
                existing.removed = record.removed
                existing.removedAt = record.removedAt
            } else if record.removedAt == existing.removedAt, record.removed {
                // An exact tie goes to the removal. Two devices with skewed clocks can land on
                // the same instant, and losing something you deleted is worse than keeping
                // something you meant to delete: the first is silent, the second is visible and
                // can be repeated.
                existing.removed = true
            }
            byDigest[record.sha256] = existing
        }

        let kept = byDigest.values.filter { record in
            // Live records are kept regardless of age; only tombstones expire.
            !record.removed || now.timeIntervalSince(record.removedAt ?? now) < tombstoneRetention
        }
        // Newest statement first, so the cap drops the least interesting records.
        var ordered = kept.sorted { $0.lastStated > $1.lastStated }
        if ordered.count > maximumRecords {
            // Tombstones before live records: a live record may still describe a file a device
            // is holding, while a tombstone that falls off simply stops suppressing something
            // that is almost certainly gone from the gateway too.
            let live = ordered.filter { !$0.removed }
            let dead = ordered.filter(\.removed)
            ordered = Array((live + dead).prefix(maximumRecords))
        }
        return ClippingLedger(records: ordered.sorted { $0.sha256 < $1.sha256 })
    }

    /// Nil means "never stated", which loses to any statement at all.
    private static func newer(_ lhs: Date?, than rhs: Date?) -> Bool {
        guard let lhs else { return false }
        guard let rhs else { return true }
        return lhs > rhs
    }

    // MARK: - Encoding

    /// The `UserDefaults` key this rides in, and therefore what `PreferenceSync.mergedKeys` names.
    public static let storageKey = "tonebox.clippings.ledger"

    public static func decode(_ data: Data?) -> ClippingLedger? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(ClippingLedger.self, from: data)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
