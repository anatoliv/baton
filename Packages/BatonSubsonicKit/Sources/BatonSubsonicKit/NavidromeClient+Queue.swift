import Foundation
import BatonSubsonicModels

// Cross-device play-queue handoff + bookmarks (docs/plan-ios-app.md, Phase 1).
// `savePlayQueue`/`getPlayQueue` is what lets a queue started on the Mac continue
// mid-track on the iPhone (and back); bookmarks persist positions in long tracks
// and server-side podcast episodes. Navidrome supports both endpoint families.

/// The server-persisted play queue (`getPlayQueue`): the songs, which one was
/// current, and how far into it playback was.
public struct NavidromePlayQueue: Sendable, Equatable {
    public let songs: [NavidromeSong]
    /// The id of the song that was playing when the queue was saved.
    public let currentID: String?
    /// Playback position within the current song, in milliseconds.
    public let positionMs: Int?
    /// Which client last saved the queue (`changedBy`) — lets the UI say
    /// "Continue from Baton on Mac".
    public let changedBy: String?

    public init(songs: [NavidromeSong], currentID: String? = nil, positionMs: Int? = nil, changedBy: String? = nil) {
        self.songs = songs
        self.currentID = currentID
        self.positionMs = positionMs
        self.changedBy = changedBy
    }
}

/// A server-side bookmark (`getBookmarks`): a saved position within one song/episode.
public struct NavidromeBookmark: Sendable, Equatable, Identifiable {
    public let song: NavidromeSong
    /// Bookmarked position, in milliseconds.
    public let positionMs: Int
    public let comment: String?

    public var id: String { song.id }

    public init(song: NavidromeSong, positionMs: Int, comment: String? = nil) {
        self.song = song
        self.positionMs = positionMs
        self.comment = comment
    }
}

// MARK: - Wire

/// `getPlayQueue` → `playQueue`.
public struct PlayQueueWire: Decodable {
    public let current: FlexibleID?
    public let position: Int?
    public let changedBy: String?
    public let entry: [SongWire]?
}

/// Subsonic servers vary on whether `playQueue.current` is a string or a number
/// (Navidrome sends the song id string; some servers send an index number).
/// Decode either and normalize to a string.
public struct FlexibleID: Decodable {
    public let value: String

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int.self) {
            value = String(i)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "current is neither string nor int")
            )
        }
    }
}

/// `getBookmarks` → `bookmarks.bookmark[]`.
public struct BookmarksWire: Decodable {
    public let bookmark: [BookmarkWire]?
}

public struct BookmarkWire: Decodable {
    public let position: Int?
    public let comment: String?
    public let entry: SongWire?
}

// MARK: - Endpoints

extension NavidromeClient {
    /// Saves the play queue server-side (`savePlayQueue`): the ordered song ids, the
    /// current song, and the position within it. Overwrites the previous saved queue
    /// (one per user, by design — it's a handoff slot, not a history).
    public func savePlayQueue(songIDs: [String], currentID: String? = nil, positionMs: Int? = nil) async throws {
        var query = songIDs.map { URLQueryItem(name: "id", value: $0) }
        if let currentID { query.append(URLQueryItem(name: "current", value: currentID)) }
        if let positionMs { query.append(URLQueryItem(name: "position", value: String(max(0, positionMs)))) }
        _ = try await performJSON("savePlayQueue.view", query: query)
    }

    /// The last queue any client saved for this user (`getPlayQueue`), or nil when
    /// none exists. The songs come back as full objects, so the receiving device can
    /// rebuild the queue without extra lookups.
    public func getPlayQueue() async throws -> NavidromePlayQueue? {
        let response = try await performJSON("getPlayQueue.view")
        guard let wire = response.playQueue else { return nil }
        return NavidromePlayQueue(
            songs: (wire.entry ?? []).map { $0.toDomain() },
            currentID: wire.current?.value,
            positionMs: wire.position,
            changedBy: wire.changedBy
        )
    }

    /// All bookmarks for the current user (`getBookmarks`).
    public func getBookmarks() async throws -> [NavidromeBookmark] {
        let response = try await performJSON("getBookmarks.view")
        return (response.bookmarks?.bookmark ?? []).compactMap { wire in
            guard let song = wire.entry?.toDomain() else { return nil }
            return NavidromeBookmark(song: song, positionMs: wire.position ?? 0, comment: wire.comment)
        }
    }

    /// Creates (or moves) the bookmark for one song (`createBookmark`). One bookmark
    /// per song per user — saving again overwrites the position.
    public func createBookmark(songID: String, positionMs: Int, comment: String? = nil) async throws {
        var query = [
            URLQueryItem(name: "id", value: songID),
            URLQueryItem(name: "position", value: String(max(0, positionMs))),
        ]
        if let comment { query.append(URLQueryItem(name: "comment", value: comment)) }
        _ = try await performJSON("createBookmark.view", query: query)
    }

    /// Removes the bookmark for one song (`deleteBookmark`).
    public func deleteBookmark(songID: String) async throws {
        _ = try await performJSON("deleteBookmark.view", query: [URLQueryItem(name: "id", value: songID)])
    }
}
