import Foundation

/// Playlist name → id, for the short window an agent works in.
///
/// Deliberately time-boxed rather than invalidated on write. Playlists are created and
/// renamed by other clients too — the web UI, another Baton, a script — so any cache here is
/// guessing about a world it does not own. Thirty seconds is long enough to collapse a burst
/// of related tool calls into one fetch and short enough that a rename made elsewhere is
/// visible before anybody notices.
///
/// A stale *hit* is the failure worth thinking about: it would add songs to a playlist that
/// has since been renamed. That is survivable — the id is still valid and still points at
/// the same playlist, which is the thing the user meant — where a stale *miss* would only
/// cost one refetch.
@MainActor
final class PlaylistIDCache {
    static let shared = PlaylistIDCache()

    private var entries: [String: String] = [:]
    private var storedAt: Date?
    private let lifetime: TimeInterval = 30

    private init() {}

    func id(forLoweredName name: String) -> String? {
        guard let storedAt, Date().timeIntervalSince(storedAt) < lifetime else {
            entries = [:]
            return nil
        }
        if let exact = entries[name] { return exact }
        // Same fallback the resolver uses, so a cache hit and a cache miss agree about
        // which playlist "focus" means.
        return entries.first { $0.key.contains(name) }?.value
    }

    func store(_ pairs: [(String, String)]) {
        entries = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        storedAt = Date()
    }

    /// Drops everything — used when the server changes underneath us.
    func reset() {
        entries = [:]
        storedAt = nil
    }
}
