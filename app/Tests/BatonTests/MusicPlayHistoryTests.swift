import Foundation
import Testing
@testable import Baton

@MainActor
@Suite("Play history")
struct MusicPlayHistoryTests {
    private func store() -> MusicPlayHistory {
        let suite = UserDefaults(suiteName: "test.history.\(UUID().uuidString)")!
        return MusicPlayHistory(defaults: suite, clock: { Date(timeIntervalSince1970: 1_000_000) })
    }

    private func song(_ id: String, artist: String? = nil) -> NavidromeSong {
        NavidromeSong(id: id, title: "T\(id)", artist: artist, album: nil, albumID: nil, duration: nil, coverArtID: nil)
    }

    @Test("Recently played is distinct, most-recent first")
    func recent() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = MusicPlayHistory(defaults: UserDefaults(suiteName: "t.\(UUID())")!, clock: { now })
        h.record(song("a")); now.addTimeInterval(120)
        h.record(song("b")); now.addTimeInterval(120)
        h.record(song("a")); now.addTimeInterval(120) // replay a later
        #expect(h.recentlyPlayed.map(\.id) == ["a", "b"])
    }

    @Test("An immediate repeat within a minute isn't double-logged")
    func dedupImmediate() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = MusicPlayHistory(defaults: UserDefaults(suiteName: "t.\(UUID())")!, clock: { now })
        h.record(song("a"))
        now.addTimeInterval(10)
        h.record(song("a")) // seek-to-0 / replay re-fire
        #expect(h.entries.count == 1)
    }

    @Test("Top tracks ranks by play count")
    func topTracks() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = MusicPlayHistory(defaults: UserDefaults(suiteName: "t.\(UUID())")!, clock: { now })
        for _ in 0 ..< 3 { h.record(song("a")); now.addTimeInterval(120) }
        for _ in 0 ..< 1 { h.record(song("b")); now.addTimeInterval(120) }
        let top = h.topTracks(since: .distantPast)
        #expect(top.first?.song.id == "a")
        #expect(top.first?.count == 3)
    }

    @Test("Top artists aggregates across tracks")
    func topArtists() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = MusicPlayHistory(defaults: UserDefaults(suiteName: "t.\(UUID())")!, clock: { now })
        h.record(song("a", artist: "X")); now.addTimeInterval(120)
        h.record(song("b", artist: "X")); now.addTimeInterval(120)
        h.record(song("c", artist: "Y")); now.addTimeInterval(120)
        let top = h.topArtists(since: .distantPast)
        #expect(top.first?.artist == "X")
        #expect(top.first?.count == 2)
    }

    @Test("Persists across instances")
    func persists() {
        let suite = UserDefaults(suiteName: "t.\(UUID())")!
        let h1 = MusicPlayHistory(defaults: suite, clock: { Date(timeIntervalSince1970: 1_000_000) })
        h1.record(song("a"))
        let h2 = MusicPlayHistory(defaults: suite, clock: { Date(timeIntervalSince1970: 1_000_000) })
        #expect(h2.recentlyPlayed.map(\.id) == ["a"])
    }
}
