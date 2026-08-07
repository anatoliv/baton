import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// Per-screen recent-filter history, persisted in `UserDefaults`. Each filter field
/// passes a stable `key` (e.g. "albums", "search") so every screen keeps its own list —
/// most-recent-first, de-duplicated (case-insensitively), and capped to the user's
/// "Filter history size" setting (default 15).
public enum FilterHistory {
    public static let sizeKey = "tonebox.filterHistorySize"
    public static let defaultSize = 15

    /// Backing store. Injectable so tests exercise the dedup/cap/remove logic without touching
    /// (and overwriting) the developer's real filter history.
    public nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Max entries kept per screen. Clamped to a sane range so a bad default can't make
    /// the list unbounded or empty.
    public static var maxSize: Int {
        let stored = defaults.object(forKey: sizeKey) as? Int
        return min(100, max(1, stored ?? defaultSize))
    }

    /// Public so `PreferenceSync` can name these keys without duplicating the format.
    public static func storageKey(_ key: String) -> String { "tonebox.filterHistory.\(key)" }

    /// The saved terms for a screen, most-recent first.
    public static func items(_ key: String) -> [String] {
        (defaults.array(forKey: storageKey(key)) as? [String]) ?? []
    }

    /// Record `term` as the most recent for `key` (trimmed; empty ignored). Any existing
    /// case-insensitive match is moved to the front rather than duplicated, and the list
    /// is trimmed to `maxSize`.
    public static func add(_ term: String, to key: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = items(key).filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > maxSize { list = Array(list.prefix(maxSize)) }
        defaults.set(list, forKey: storageKey(key))
    }

    /// Remove one saved term from a screen's history.
    public static func remove(_ term: String, from key: String) {
        let list = items(key).filter { $0 != term }
        if list.isEmpty { defaults.removeObject(forKey: storageKey(key)) }
        else { defaults.set(list, forKey: storageKey(key)) }
    }

    /// Wipe a single screen's history.
    public static func clear(_ key: String) {
        defaults.removeObject(forKey: storageKey(key))
    }

    /// The screens that keep filter history — used by Settings to clear them all at once.
    public static let allKeys = ["albums", "artists", "playlists", "artistSongs", "liked", "search"]

    /// Wipe every screen's history (Settings → "Clear filter history").
    public static func clearAll() { allKeys.forEach(clear) }

    /// Union two devices' lists instead of letting one replace the other.
    ///
    /// Last-write-wins is right for a scalar and wrong for a list that accumulates — it
    /// would drop everything typed on the quieter device the moment the other one wrote.
    /// There are no per-term timestamps to order by, so position stands in for recency:
    /// both lists are most-recent-first, so a term's best (lowest) index across the two is
    /// the strongest claim either device makes about how recently it was used. Ties break
    /// on the term itself, so the result is stable rather than dependent on dictionary
    /// ordering — an unstable merge would rewrite the list on every sync and push forever.
    public static func merge(_ a: [String], _ b: [String], cap: Int) -> [String] {
        var best: [String: (rank: Int, term: String)] = [:]
        for list in [a, b] {
            for (index, term) in list.enumerated() {
                let folded = term.lowercased()
                if let existing = best[folded], existing.rank <= index { continue }
                best[folded] = (index, term)
            }
        }
        return best.values
            .sorted { $0.rank == $1.rank ? $0.term < $1.term : $0.rank < $1.rank }
            .prefix(max(0, cap))
            .map(\.term)
    }
}
