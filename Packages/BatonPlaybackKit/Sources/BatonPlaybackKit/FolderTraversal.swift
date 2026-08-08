import Foundation
import BatonSubsonicModels

/// Walks a Subsonic folder tree and collects its songs, depth-first.
///
/// "Play this folder" has to mean *everything under it* — an artist folder is albums-as-
/// subfolders, and playing only the loose files at its top level plays nothing. So the
/// collector recurses; and because it recurses over server data it must survive the two
/// things servers do to naive walkers: cycles (symlinked trees produce them) and sheer
/// size (a root like "Compilations" can hold thousands of directories).
///
/// Order: a directory's own songs first, then each subfolder in server order. That reads
/// the folder the way Finder shows it — the detail view lists the same way — and for the
/// common artist/album shape it yields album-by-album playback.
///
/// Pure logic over an injected `fetch`, so it tests without a server and the store can
/// hand it its cached directory lookup.
public enum FolderTraversal {
    public struct Result: Sendable {
        public let songs: [NavidromeSong]
        /// True when a limit stopped the walk early. Callers surface this — a silent cap
        /// reads as "the folder only had this much".
        public let truncated: Bool

        public init(songs: [NavidromeSong], truncated: Bool) {
            self.songs = songs
            self.truncated = truncated
        }
    }

    /// Ceilings, not targets: high enough that a real library never meets them, low
    /// enough that a pathological tree can't spin forever.
    public static let maxDirectories = 500
    public static let maxSongs = 5000

    public static func collect(
        rootID: String,
        maxDirectories: Int = maxDirectories,
        maxSongs: Int = maxSongs,
        fetch: @Sendable (String) async -> NavidromeDirectory?
    ) async -> Result {
        var songs: [NavidromeSong] = []
        var visited: Set<String> = []
        var truncated = false

        // An explicit stack rather than recursion: the depth of a hostile tree shouldn't
        // become our call-stack depth. Depth-first order is preserved by pushing a
        // directory's subfolders in reverse.
        var stack: [String] = [rootID]

        while let id = stack.popLast() {
            guard !visited.contains(id) else { continue }   // cycle: been here, skip
            visited.insert(id)

            if visited.count > maxDirectories { truncated = true; break }
            guard let directory = await fetch(id) else { continue }

            for song in directory.songs {
                if songs.count >= maxSongs { truncated = true; break }
                songs.append(song)
            }
            if truncated { break }

            for sub in directory.folders.reversed() { stack.append(sub.id) }
        }

        return Result(songs: songs, truncated: truncated)
    }
}
