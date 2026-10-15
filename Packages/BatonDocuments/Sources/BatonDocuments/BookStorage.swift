import Foundation

/// What one device remembers about its book storage, and the words it uses for it
/// (`specs/document-clippings.md`, *Storage*; board M6.3 to M6.5).
///
/// `StoragePolicy` decides; this keeps what the deciding needs between launches: the person's
/// rules, the books marked Keep, the one suggestion on offer and when it was offered, and the
/// "Recently removed" list. Pure and Foundation only, like the rest of the package, so the Mac
/// and the iPhone keep the same record in the same shape and say the same things about it.
///
/// Per device and never synced: storage is per device, and a Mac with a large disk and a full
/// iPhone want different rules.
public enum BookStorage {
    // MARK: - Settings

    /// The `UserDefaults` key the settings live under. Not in `PreferenceSync.syncedKeys`.
    public static let settingsKey = "baton.books.storage"

    public struct Settings: Codable, Equatable, Sendable {
        /// Nothing is removed until the person chooses a rule; until then Baton only suggests.
        public var rules: StoragePolicy.Rules
        /// Books marked Keep, by document id: never removed by any rule or suggestion.
        public var keep: Set<String>
        /// When a suggestion was last offered, so they come at most once a week.
        public var lastSuggestedAt: Date?
        /// The suggestion on offer now, kept until it is answered.
        public var pending: Suggestion?
        /// Books whose suggestion was answered Keep or dismissed: not suggested again.
        public var declined: Set<String>

        public init(rules: StoragePolicy.Rules = .none, keep: Set<String> = [], lastSuggestedAt: Date? = nil,
                    pending: Suggestion? = nil, declined: Set<String> = []) {
            self.rules = rules
            self.keep = keep
            self.lastSuggestedAt = lastSuggestedAt
            self.pending = pending
            self.declined = declined
        }
    }

    public static func loadSettings(from defaults: UserDefaults) -> Settings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    public static func save(_ settings: Settings, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    // MARK: - Suggestions (M6.5)

    /// A suggestion as it is kept until answered: `StoragePolicy.Suggestion`, plus when it was
    /// offered and the numbers its words need.
    public struct Suggestion: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// One finished book, offered with "Always do this".
            case finishedBook
            /// Little space left on the device: the largest finished books, in one tap.
            case lowDeviceSpace
        }

        public var kind: Kind
        public var ids: [String]
        public var bytes: Int
        public var daysAgo: Int?
        public var freeBytes: Int?
        public var offeredAt: Date

        public init(kind: Kind, ids: [String], bytes: Int, daysAgo: Int? = nil, freeBytes: Int? = nil, offeredAt: Date) {
            self.kind = kind
            self.ids = ids
            self.bytes = bytes
            self.daysAgo = daysAgo
            self.freeBytes = freeBytes
            self.offeredAt = offeredAt
        }

        init(_ suggestion: StoragePolicy.Suggestion, at now: Date) {
            switch suggestion.kind {
            case let .finishedItem(daysAgo):
                self.init(kind: .finishedBook, ids: suggestion.ids, bytes: suggestion.bytes, daysAgo: daysAgo, offeredAt: now)
            case let .lowDeviceSpace(freeBytes):
                self.init(kind: .lowDeviceSpace, ids: suggestion.ids, bytes: suggestion.bytes, freeBytes: freeBytes, offeredAt: now)
            }
        }
    }

    /// The rule "Always do this" sets: a finished book's download leaves a week after finishing,
    /// the same delay the suggestion waited for.
    public static let alwaysRule: TimeInterval = 7 * StoragePolicy.day

    /// What the Clippings view offers now, and the settings to keep afterwards.
    ///
    /// A suggestion already on offer stays until it is answered, while its books can still be
    /// removed. Otherwise `StoragePolicy.suggestions` decides (at most once a week, never for
    /// what a rule would remove anyway), less the books whose suggestion was declined; offering
    /// one starts the week.
    public static func offer(_ items: [StoragePolicy.Item], settings: Settings, now: Date,
                             freeBytes: Int?) -> (suggestion: Suggestion?, settings: Settings) {
        var settings = settings
        let removable = Set(items.filter { $0.downloaded && !$0.keep && !$0.inProgress }.map(\.id))
        if let pending = settings.pending {
            if !pending.ids.isEmpty, pending.ids.allSatisfy(removable.contains) { return (pending, settings) }
            settings.pending = nil
        }
        let candidates = items.filter { !settings.declined.contains($0.id) }
        let made = StoragePolicy.suggestions(candidates, rules: settings.rules, now: now, freeBytes: freeBytes,
                                             lastSuggestedAt: settings.lastSuggestedAt)
        guard let first = made.first else { return (nil, settings) }
        let suggestion = Suggestion(first, at: now)
        settings.pending = suggestion
        settings.lastSuggestedAt = now
        return (suggestion, settings)
    }

    /// How a suggestion was answered.
    public enum Answer: Sendable {
        /// Remove the downloads now.
        case remove
        /// Remove now and set the rule, so it happens by itself from now on.
        case always
        /// Keep these books' downloads, and do not suggest them again.
        case keep
    }

    /// The settings after an answer, and the books whose downloads go now.
    public static func answer(_ answer: Answer, to suggestion: Suggestion,
                              settings: Settings) -> (remove: [String], settings: Settings) {
        var settings = settings
        settings.pending = nil
        switch answer {
        case .remove:
            return (suggestion.ids, settings)
        case .always:
            settings.rules.afterFinished = alwaysRule
            return (suggestion.ids, settings)
        case .keep:
            settings.declined.formUnion(suggestion.ids)
            return ([], settings)
        }
    }

    // MARK: - Recently removed (M6.3)

    /// A book whose audio left this device: offloaded by hand or by a rule (it comes back with
    /// Download again), or deleted (its audio is held here for a week, and Restore brings it
    /// back). After `StoragePolicy.recentlyRemovedFor` the entry goes, and a deleted book's
    /// held audio with it.
    public struct Removed: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case offloaded
            case deleted
        }

        public var id: String
        public var documentID: String
        public var title: String
        public var author: String?
        public var bytes: Int
        public var removedAt: Date
        public var kind: Kind
        /// Removed by a rule rather than by the person.
        public var automatic: Bool
        /// Deleted everywhere rather than from this device only.
        public var everywhere: Bool
        public var chapters: [Int]

        public init(id: String, documentID: String, title: String, author: String? = nil, bytes: Int, removedAt: Date,
                    kind: Kind, automatic: Bool = false, everywhere: Bool = false, chapters: [Int] = []) {
            self.id = id
            self.documentID = documentID
            self.title = title
            self.author = author
            self.bytes = bytes
            self.removedAt = removedAt
            self.kind = kind
            self.automatic = automatic
            self.everywhere = everywhere
            self.chapters = chapters
        }

        /// When the entry, and any held audio, goes for good.
        public var purgeAt: Date { removedAt.addingTimeInterval(StoragePolicy.recentlyRemovedFor) }
    }

    /// The entries a week old or more, which are purged.
    public static func expired(_ entries: [Removed], now: Date) -> [Removed] {
        entries.filter { now >= $0.purgeAt }
    }

    // MARK: - Words

    /// "29 MB", "1.2 GB", "640 KB": decimal units, as Finder counts them.
    public static func sizeText(_ bytes: Int) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000 { return trimmed(value / 1_000_000_000) + " GB" }
        if value >= 1_000_000 { return "\(Int((value / 1_000_000).rounded())) MB" }
        if value >= 1_000 { return "\(Int((value / 1_000).rounded())) KB" }
        return "\(Int(value)) bytes"
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }

    /// "9 days ago", "yesterday", "today".
    public static func daysText(_ days: Int) -> String {
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }

    /// The suggestion in a listener's words. `title` is the book's for a finished book, and
    /// `device` is "this Mac" or "this iPhone". User copy: no dashes.
    public static func suggestionText(_ suggestion: Suggestion, title: String?, device: String) -> String {
        switch suggestion.kind {
        case .finishedBook:
            let when = daysText(suggestion.daysAgo ?? 0)
            let name = title ?? "a book"
            return "You finished \(name) \(when). Remove its download from \(device) to free \(sizeText(suggestion.bytes))? "
                + "You can download it again whenever you like."
        case .lowDeviceSpace:
            let free = sizeText(suggestion.freeBytes ?? 0)
            let count = suggestion.ids.count == 1 ? "your largest finished book" : "your \(suggestion.ids.count) largest finished books"
            return "\(capitalized(device)) has \(free) free. Remove the downloads of \(count) to free \(sizeText(suggestion.bytes))?"
        }
    }

    /// What happened after "Always do this", said once.
    public static func alwaysConfirmation(device: String) -> String {
        "Done. From now on a finished book's download leaves \(device) a week after you finish it. "
            + "You can change this in Settings, under Storage."
    }

    /// One line for a Recently removed row, `device` being "this Mac" or "this iPhone".
    public static func removedText(_ entry: Removed, now: Date, device: String) -> String {
        let days = Int(now.timeIntervalSince(entry.removedAt) / StoragePolicy.day)
        let left = max(1, Int((entry.purgeAt.timeIntervalSince(now) / StoragePolicy.day).rounded(.up)))
        let leftText = left == 1 ? "1 more day" : "\(left) more days"
        switch entry.kind {
        case .offloaded:
            let by = entry.automatic ? " by your storage rule" : ""
            return "Download removed \(daysText(days))\(by), freeing \(sizeText(entry.bytes))."
        case .deleted:
            let whereText = entry.everywhere ? "Deleted everywhere" : "Deleted from \(device)"
            return "\(whereText) \(daysText(days)). You can restore it for \(leftText)."
        }
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
