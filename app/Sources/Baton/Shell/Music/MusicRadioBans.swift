import Foundation
import Observation

/// Tracks the user has told us to keep **out of radio/autoplay** ("don't play this in
/// radio"). A ban keeps the song in your library and playlists — it only excludes it from
/// Related results and the continuous-radio auto-queue, so those suggestions learn your
/// taste. Persisted locally.
@MainActor
@Observable
final class MusicRadioBans {
    private(set) var ids: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored static let storageKey = "tonebox.music.radioBans"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set((defaults.array(forKey: Self.storageKey) as? [String]) ?? [])
    }

    func isBanned(_ id: String) -> Bool { ids.contains(id) }

    func ban(_ id: String) { ids.insert(id); save() }
    func unban(_ id: String) { ids.remove(id); save() }
    func toggle(_ id: String) { if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }; save() }
    func clear() { ids.removeAll(); defaults.removeObject(forKey: Self.storageKey) }

    /// Drop banned tracks from a suggestion list (radio / autoplay / Related).
    func filtered(_ songs: [NavidromeSong]) -> [NavidromeSong] {
        ids.isEmpty ? songs : songs.filter { !ids.contains($0.id) }
    }

    private func save() { defaults.set(Array(ids), forKey: Self.storageKey) }
}
