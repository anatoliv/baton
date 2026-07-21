import Foundation

/// Per-screen recent-filter history, persisted in `UserDefaults`. Each filter field
/// passes a stable `key` (e.g. "albums", "search") so every screen keeps its own list —
/// most-recent-first, de-duplicated (case-insensitively), and capped to the user's
/// "Filter history size" setting (default 15).
enum FilterHistory {
    static let sizeKey = "tonebox.filterHistorySize"
    static let defaultSize = 15

    /// Backing store. Injectable so tests exercise the dedup/cap/remove logic without touching
    /// (and overwriting) the developer's real filter history. (W-49 / TEST-13)
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Max entries kept per screen. Clamped to a sane range so a bad default can't make
    /// the list unbounded or empty.
    static var maxSize: Int {
        let stored = defaults.object(forKey: sizeKey) as? Int
        return min(100, max(1, stored ?? defaultSize))
    }

    private static func storageKey(_ key: String) -> String { "tonebox.filterHistory.\(key)" }

    /// The saved terms for a screen, most-recent first.
    static func items(_ key: String) -> [String] {
        (defaults.array(forKey: storageKey(key)) as? [String]) ?? []
    }

    /// Record `term` as the most recent for `key` (trimmed; empty ignored). Any existing
    /// case-insensitive match is moved to the front rather than duplicated, and the list
    /// is trimmed to `maxSize`.
    static func add(_ term: String, to key: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = items(key).filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > maxSize { list = Array(list.prefix(maxSize)) }
        defaults.set(list, forKey: storageKey(key))
    }

    /// Remove one saved term from a screen's history.
    static func remove(_ term: String, from key: String) {
        let list = items(key).filter { $0 != term }
        if list.isEmpty { defaults.removeObject(forKey: storageKey(key)) }
        else { defaults.set(list, forKey: storageKey(key)) }
    }

    /// Wipe a single screen's history.
    static func clear(_ key: String) {
        defaults.removeObject(forKey: storageKey(key))
    }

    /// The screens that keep filter history — used by Settings to clear them all at once.
    static let allKeys = ["albums", "artists", "playlists", "artistSongs", "liked", "search"]

    /// Wipe every screen's history (Settings → "Clear filter history").
    static func clearAll() { allKeys.forEach(clear) }
}
