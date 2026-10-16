import Foundation

/// Identity matching uses the existing library song type. Search never starts playback and
/// never silently chooses one of several copies of the same recording.
public enum SharedSongFinder {
    public enum Basis: String, Sendable { case recording, titleAndArtist }
    public struct Result: Sendable {
        public let songs: [NavidromeSong]
        public let basis: Basis
        public let complete: Bool
        public let scanned: Int
    }
    public static func matches(_ songs: [NavidromeSong], title: String, artist: String,
                               recordingID: String?, complete: Bool = true) -> Result {
        let unique = songs.reduce(into: [String: NavidromeSong]()) { $0[$1.id] = $1 }
            .values.sorted { $0.id < $1.id }
        let identity = recordingID.flatMap { UUID(uuidString: $0) }
        if let identity {
            let exact = unique.filter { $0.musicBrainzID.flatMap(UUID.init(uuidString:)) == identity }
            if !exact.isEmpty { return Result(songs: exact, basis: .recording, complete: complete, scanned: unique.count) }
            // A partial catalog cannot establish that a recording is absent. Do not fall back
            // to a different release before the identity search has finished.
            if !complete { return Result(songs: [], basis: .recording, complete: false, scanned: unique.count) }
        }
        let normalizedTitle = normalize(title), normalizedArtist = normalize(artist)
        let exact = unique.filter { song in
            guard !normalizedTitle.isEmpty, !normalizedArtist.isEmpty,
                  normalize(song.title) == normalizedTitle,
                  normalize(song.displayArtistName ?? "") == normalizedArtist else { return false }
            // A known different recording is stronger evidence than matching display text.
            if let identity, let candidate = song.musicBrainzID.flatMap(UUID.init(uuidString:)) {
                return identity == candidate
            }
            return true
        }
        return Result(songs: exact, basis: .titleAndArtist, complete: complete, scanned: unique.count)
    }
    private static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// Empty-query search3 is the OpenSubsonic catalog API. Bounded pages make cancellation
    /// useful on large libraries; reaching the bound is reported as incomplete, never "absent".
    public static func find(title: String, artist: String, recordingID: String?,
                            maximumSongs: Int = 20_000,
                            page: @Sendable (_ query: String, _ offset: Int, _ count: Int) async throws -> [NavidromeSong]) async throws -> Result {
        let hasIdentity = recordingID.flatMap(UUID.init(uuidString:)) != nil
        let query = hasIdentity ? "" : title + " " + artist
        let cap = max(1, maximumSongs)
        var songs: [NavidromeSong] = [], offset = 0
        var complete = false
        while offset < cap {
            try Task.checkCancellation()
            let count = min(500, cap - offset)
            let received = try await page(query, offset, count)
            try Task.checkCancellation()
            songs.append(contentsOf: received.prefix(count))
            if received.count < count { complete = true; break }
            offset += count
        }
        return matches(songs, title: title, artist: artist, recordingID: recordingID, complete: complete)
    }
}

extension NavidromeClient {
    public func findSharedSong(title: String, artist: String, recordingID: String?) async throws -> SharedSongFinder.Result {
        try await SharedSongFinder.find(title: title, artist: artist, recordingID: recordingID) { query, offset, count in
            try await self.search3(query: query, songCount: count, albumCount: 0, artistCount: 0, songOffset: offset).songs
        }
    }
}
