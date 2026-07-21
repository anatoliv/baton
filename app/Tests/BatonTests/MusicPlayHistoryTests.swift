import Foundation
import Testing
@testable import Baton

@MainActor
@Suite("Play history")
struct MusicPlayHistoryTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("phist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func make(clock: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000_000) }, dir: URL? = nil) -> MusicPlayHistory {
        MusicPlayHistory(defaults: UserDefaults(suiteName: "t.\(UUID())")!, clock: clock, directory: dir ?? tempDir())
    }
    private func song(_ id: String, artist: String? = nil) -> NavidromeSong {
        NavidromeSong(id: id, title: "T\(id)", artist: artist, album: nil, albumID: nil, duration: nil, coverArtID: nil)
    }

    @Test("Recently played is distinct, most-recent first")
    func recent() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = make(clock: { now })
        h.record(song("a")); now.addTimeInterval(120)
        h.record(song("b")); now.addTimeInterval(120)
        h.record(song("a")); now.addTimeInterval(120) // replay a later
        #expect(h.recentlyPlayed.map(\.id) == ["a", "b"])
    }

    @Test("lastPlayedByID keeps each id's most recent listen (W-33 LRU eviction)")
    func lastPlayedPerID() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = make(clock: { now })
        h.record(song("a")); now.addTimeInterval(120)
        h.record(song("b")); now.addTimeInterval(120)
        h.record(song("a")) // "a" replayed later — its last-played must be the newer time
        let map = h.lastPlayedByID()
        #expect(map["a"] == Date(timeIntervalSince1970: 1_000_000 + 240))
        #expect(map["b"] == Date(timeIntervalSince1970: 1_000_000 + 120))
    }

    @Test("An immediate repeat within a minute isn't double-logged")
    func dedupImmediate() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = make(clock: { now })
        h.record(song("a")); now.addTimeInterval(10); h.record(song("a"))
        #expect(h.entries.count == 1)
    }

    @Test("Top tracks ranks by play count")
    func topTracks() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = make(clock: { now })
        for _ in 0 ..< 3 { h.record(song("a")); now.addTimeInterval(120) }
        for _ in 0 ..< 1 { h.record(song("b")); now.addTimeInterval(120) }
        let top = h.topTracks(since: .distantPast)
        #expect(top.first?.song.id == "a")
        #expect(top.first?.count == 3)
    }

    @Test("Top artists aggregates across tracks")
    func topArtists() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = make(clock: { now })
        h.record(song("a", artist: "X")); now.addTimeInterval(120)
        h.record(song("b", artist: "X")); now.addTimeInterval(120)
        h.record(song("c", artist: "Y")); now.addTimeInterval(120)
        let top = h.topArtists(since: .distantPast)
        #expect(top.first?.artist == "X")
        #expect(top.first?.count == 2)
    }

    @Test("W-32: persists across instances via the append-only JSONL file, newest-first")
    func persists() {
        let dir = tempDir()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h1 = make(clock: { now }, dir: dir)
        h1.record(song("a")); now.addTimeInterval(120); h1.record(song("b"))
        let h2 = make(clock: { now }, dir: dir)
        #expect(h2.recentlyPlayed.map(\.id) == ["b", "a"])
    }
}
