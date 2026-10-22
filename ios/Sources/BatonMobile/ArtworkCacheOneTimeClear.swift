import Foundation

/// Covers stored before a800db0b (TBX-1000000480 C3-2) kept the signed Subsonic URL, with its
/// username and password-derived token, as the stored response's URL in the artwork cache's
/// `Cache.db`. The fix stops new entries carrying it, but entries already on disk keep it until
/// they are refetched or evicted. Clearing the artwork cache once removes them; covers are
/// fetched again as they appear.
enum ArtworkCacheOneTimeClear {
    static let doneKey = "baton.artworkCache.signedURLsCleared"

    /// Clears `cache` the first time it runs for these defaults, and never again. Returns whether
    /// it cleared.
    @discardableResult
    static func run(defaults: UserDefaults, cache: URLCache) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        cache.removeAllCachedResponses()
        defaults.set(true, forKey: doneKey)
        return true
    }
}
