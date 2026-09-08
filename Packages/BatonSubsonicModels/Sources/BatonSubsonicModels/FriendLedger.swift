import Foundation

/// What every device agrees the music friend has been told, and what it has been corrected on
///.
///
/// **Why a ledger and not the files themselves.** `SettingsTransfer` carries
/// `remote-memory.json` and `music-friend-learned.json` wholesale, which is right for a
/// one-shot setup: there is no second device's copy to lose at the moment it runs. Ongoing
/// sync is the opposite case — two devices each learning something between syncs is the
/// normal case, and whole-document last-write-wins silently discards one side. So the facts
/// that need reconciling live here, per entry, and travel over `PreferenceSync`, which
/// already knows how to merge a key rather than overwrite it. That is exactly the split
/// `ClippingLedger` made for the same reason, and this copies it deliberately.
///
/// **`GatewayFiles` is the wrong vehicle and was considered.** It is content-addressed and
/// immutable, which is what makes a truncated audio transfer detectable — and precisely what
/// a mutable, mergeable document must not be. A new digest per edit would make every change
/// a new file with no way to say which superseded which.
///
/// **The identity is the text, not the id, and that is not a shortcut.** Memory entries are
/// numbered `max(id) + 1` *per device*, so both ends independently mint 1, 2, 3 for unrelated
/// memories; merging on that id would fuse things that have nothing to do with each other.
/// Corrections do carry a UUID, but every operation in `FriendLearningStore` matches on the
/// **request** case-insensitively — a newer correction for the same request replaces the older
/// one — so the UUID is a local record id, not the thing the app treats as identity. Both
/// stores already dedupe on their text; this uses the key they already behave as if they had.
///
/// **Retirement needs a tombstone or it cannot cross.** Approving an answer *deletes* the
/// correction (`FriendLearningStore.retireIfApproved`), and a deletion that leaves no trace is
/// indistinguishable from "this device never heard about it" — so the other device would push
/// the correction straight back. Same lesson `ClippingLedger` records: only an explicit record
/// tells a deletion apart from an absence.
public struct FriendLedger: Codable, Equatable, Sendable {

    /// How long a tombstone is kept before it stops suppressing. Matches `ClippingLedger`:
    /// long enough for a device that was away for a season, short enough to not accumulate.
    public static let tombstoneRetention: TimeInterval = 180 * 24 * 60 * 60

    /// Caps, per kind, mirroring what the stores themselves keep so the ledger cannot grow
    /// past what either end would hold anyway.
    public static let maximumMemories = 60
    public static let maximumCorrections = 60

    /// The `UserDefaults` key this rides in, and therefore what `PreferenceSync.mergedKeys`
    /// names. Under `baton.` so `SettingsTransfer` carries it too — a device set up from a
    /// Mac then starts sync already agreeing rather than re-deriving.
    public static let storageKey = "baton.friend.ledger"

    /// One thing the friend was told, as this device last understood it.
    public struct Memory: Codable, Equatable, Sendable {
        /// The normalised text — the identity both devices already agree on. See the type's
        /// note: the numeric `id` is per-device and cannot be used here.
        public var key: String
        /// The text as written, preserved for display. `key` is for matching only.
        public var text: String
        public var kind: String
        public var quote: String
        public var created: Date
        /// Forgotten everywhere, and when that was decided.
        public var removed: Bool
        public var removedAt: Date?
        /// When this device last stated anything about it — the clock the merge uses.
        public var statedAt: Date

        public init(key: String, text: String, kind: String, quote: String, created: Date,
                    removed: Bool = false, removedAt: Date? = nil, statedAt: Date) {
            self.key = key
            self.text = text
            self.kind = kind
            self.quote = quote
            self.created = created
            self.removed = removed
            self.removedAt = removedAt
            self.statedAt = statedAt
        }
    }

    /// One correction, keyed by the request it is about.
    public struct Correction: Codable, Equatable, Sendable {
        /// The normalised request. `FriendLearningStore` already treats this as the identity.
        public var key: String
        public var request: String
        public var note: String?
        public var fault: String
        public var resolution: String
        public var date: Date
        /// Retired — the friend got this right afterwards, so the complaint no longer applies.
        /// A deletion with a record, because a silent one cannot cross a sync.
        public var removed: Bool
        public var removedAt: Date?
        public var statedAt: Date

        public init(key: String, request: String, note: String?, fault: String,
                    resolution: String, date: Date,
                    removed: Bool = false, removedAt: Date? = nil, statedAt: Date) {
            self.key = key
            self.request = request
            self.note = note
            self.fault = fault
            self.resolution = resolution
            self.date = date
            self.removed = removed
            self.removedAt = removedAt
            self.statedAt = statedAt
        }
    }

    public var memories: [Memory] = []
    public var corrections: [Correction] = []

    public init(memories: [Memory] = [], corrections: [Correction] = []) {
        self.memories = memories
        self.corrections = corrections
    }

    /// The matching key for a piece of text: trimmed, case-folded, whitespace-collapsed.
    ///
    /// Case-insensitive because both stores already compare that way. Whitespace-collapsed
    /// because the same sentence typed on a phone and dictated on a Mac differs by a space
    /// far more often than it differs in meaning, and two records for one preference is the
    /// failure this key exists to prevent.
    public static func key(for text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Combine two devices' understandings, per entry.
    ///
    /// The assertion this exists to satisfy: two devices that each learned something between
    /// syncs both keep what they learned. Whole-document last-write-wins fails that, and it
    /// fails it silently, which is why it is the first test written.
    public static func merged(_ lhs: FriendLedger, _ rhs: FriendLedger,
                              now: Date = Date()) -> FriendLedger {
        var memories: [String: Memory] = [:]
        for record in lhs.memories + rhs.memories {
            guard let existing = memories[record.key] else {
                memories[record.key] = record
                continue
            }
            memories[record.key] = resolve(existing, record)
        }

        var corrections: [String: Correction] = [:]
        for record in lhs.corrections + rhs.corrections {
            guard let existing = corrections[record.key] else {
                corrections[record.key] = record
                continue
            }
            corrections[record.key] = resolve(existing, record)
        }

        let liveMemories = memories.values
            .filter { !$0.removed || now.timeIntervalSince($0.removedAt ?? now) < tombstoneRetention }
            .sorted { $0.statedAt > $1.statedAt }
        let liveCorrections = corrections.values
            .filter { !$0.removed || now.timeIntervalSince($0.removedAt ?? now) < tombstoneRetention }
            .sorted { $0.statedAt > $1.statedAt }

        return FriendLedger(
            memories: Array(cap(liveMemories, at: maximumMemories, removed: \.removed))
                .sorted { $0.key < $1.key },
            corrections: Array(cap(liveCorrections, at: maximumCorrections, removed: \.removed))
                .sorted { $0.key < $1.key }
        )
    }

    /// The newer statement wins; an exact tie goes to the removal.
    ///
    /// The tie rule is `ClippingLedger`'s and the reasoning carries over unchanged: two
    /// devices with skewed clocks can land on the same instant, and losing something you
    /// deleted is worse than keeping something you meant to delete — the first is silent, the
    /// second is visible and can simply be repeated.
    private static func resolve(_ a: Memory, _ b: Memory) -> Memory {
        if a.statedAt == b.statedAt { return a.removed ? a : b }
        return a.statedAt > b.statedAt ? a : b
    }

    private static func resolve(_ a: Correction, _ b: Correction) -> Correction {
        if a.statedAt == b.statedAt { return a.removed ? a : b }
        return a.statedAt > b.statedAt ? a : b
    }

    /// Drop tombstones before live records when capping: a live record still says something
    /// the friend uses, while a tombstone falling off merely stops suppressing something that
    /// has almost certainly aged out of both devices anyway.
    private static func cap<T>(_ records: [T], at limit: Int, removed: KeyPath<T, Bool>) -> [T] {
        guard records.count > limit else { return records }
        let live = records.filter { !$0[keyPath: removed] }
        let dead = records.filter { $0[keyPath: removed] }
        return Array((live + dead).prefix(limit))
    }

    // MARK: - Encoding

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data?) -> FriendLedger? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(FriendLedger.self, from: data)
    }
}
