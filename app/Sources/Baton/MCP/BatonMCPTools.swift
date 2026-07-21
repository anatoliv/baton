import Foundation
import OSLog

private let batonMCPLog = Logger(subsystem: "io.tonebox.baton", category: "MCPTools")

/// A tool-level failure surfaced to the client as a tool result with `isError: true`
/// (not a JSON-RPC protocol error).
struct BatonMCPToolError: Error {
    let message: String
}

/// Baton's MCP music-control tool catalog + dispatch. Names and semantics mirror
/// Tonebox's `music_*` tools so any client is compatible across the two apps; every
/// handler runs on the main actor and is bound to the injected `MusicModel`. Adds the
/// cross-process `audio_suspend` / `audio_resume` focus primitives.
@MainActor
enum BatonMCPToolCatalog {
    // MARK: - Definitions (tools/list)

    static func definitions() -> [[String: Any]] {
        annotate([
            tool(
                "music_search",
                "Search the connected Navidrome music library for songs, albums, and artists matching a query. Returns matching songs (with ids you can pass to music_play) plus album/artist matches.",
                properties: [
                    "query": ["type": "string", "description": "What to search for — song title, artist, album, or keyword."],
                    "limit": ["type": "integer", "description": "Max songs to return (default 20, max 100)."],
                ],
                required: ["query"]
            ),
            tool(
                "music_play",
                "Search the music library for `query` and immediately start playing the matching songs on this Mac, replacing the current queue. Use for requests like 'play some jazz' or 'play Kind of Blue'.",
                properties: [
                    "query": ["type": "string", "description": "What to play — artist, album, song, or vibe keyword."],
                    "limit": ["type": "integer", "description": "Max songs to queue (default 25, max 100)."],
                ],
                required: ["query"]
            ),
            tool(
                "music_queue_add",
                "Search the music library for `query` and append the matching songs to the end of the current play queue (without interrupting what's playing).",
                properties: [
                    "query": ["type": "string", "description": "What to add to the queue."],
                    "limit": ["type": "integer", "description": "Max songs to add (default 25, max 100)."],
                ],
                required: ["query"]
            ),
            tool("music_pause", "Pause music playback.", properties: [:], required: []),
            tool("music_resume", "Resume paused music playback.", properties: [:], required: []),
            tool("music_stop", "Stop music playback.", properties: [:], required: []),
            tool("music_next", "Skip to the next track in the music queue.", properties: [:], required: []),
            tool("music_previous", "Go to the previous track (or restart the current one).", properties: [:], required: []),
            tool(
                "music_set_volume",
                "Set the music player volume (0–100). This only affects Baton's music player, not the macOS system volume.",
                properties: [
                    "percent": ["type": "integer", "description": "Volume from 0 (silent) to 100 (full)."],
                ],
                required: ["percent"]
            ),
            tool(
                "music_now_playing",
                "Report what's currently playing: the track, play/pause state, and queue position.",
                properties: [:],
                required: []
            ),
            tool(
                "music_list_playlists",
                "List the playlists on the connected Navidrome server.",
                properties: [:],
                required: []
            ),
            tool(
                "music_play_playlist",
                "Play a Navidrome playlist by name or id, replacing the current queue with the playlist's tracks.",
                properties: [
                    "name": ["type": "string", "description": "Playlist name (case-insensitive). Provide this or `playlist_id`."],
                    "playlist_id": ["type": "string", "description": "Exact playlist id. Provide this or `name`."],
                ],
                required: []
            ),
            tool(
                "music_like",
                "Like (favorite) or unlike a track on the music server. Likes are stored per-user on Navidrome. Without `query`, acts on the currently-playing track.",
                properties: [
                    "query": ["type": "string", "description": "Song to like — searches and uses the top match. Omit to like the current track."],
                    "unlike": ["type": "boolean", "description": "Set true to remove the like instead of adding it."],
                ],
                required: []
            ),
            tool(
                "music_rate",
                "Set a 1–5 star rating on a track (0 clears it). Ratings are stored per-user on the server. Without `query`, rates the currently-playing track.",
                properties: [
                    "rating": ["type": "integer", "description": "0–5. 0 clears the rating."],
                    "query": ["type": "string", "description": "Song to rate — top search match. Omit for the current track."],
                ],
                required: ["rating"]
            ),
            tool(
                "music_create_playlist",
                "Create a new playlist, optionally seeded with songs matching a query.",
                properties: [
                    "name": ["type": "string", "description": "Playlist name."],
                    "query": ["type": "string", "description": "Optional — add the songs matching this search to the new playlist."],
                ],
                required: ["name"]
            ),
            tool(
                "music_add_to_playlist",
                "Add the songs matching a query to an existing playlist (by name or id).",
                properties: [
                    "name": ["type": "string", "description": "Playlist name (case-insensitive). Provide this or `playlist_id`."],
                    "playlist_id": ["type": "string", "description": "Exact playlist id. Provide this or `name`."],
                    "query": ["type": "string", "description": "Songs to add — the search matches are appended."],
                ],
                required: ["query"]
            ),
            tool(
                "music_delete_playlist",
                "Delete a playlist by name or id.",
                properties: [
                    "name": ["type": "string", "description": "Playlist name (case-insensitive). Provide this or `playlist_id`."],
                    "playlist_id": ["type": "string", "description": "Exact playlist id. Provide this or `name`."],
                ],
                required: []
            ),
            tool(
                "music_seek",
                "Seek the currently-playing track to an absolute position (in seconds from the start). Clamped to the track's length. Use for 'skip to 1:30' or 'go back to the start'.",
                properties: [
                    "seconds": ["type": "integer", "description": "Absolute position in seconds from the start of the track."],
                ],
                required: ["seconds"]
            ),
            tool(
                "music_set_repeat",
                "Set the repeat mode: 'off' (stop at the end of the queue), 'all' (loop the whole queue), or 'one' (replay the current track).",
                properties: [
                    "mode": ["type": "string", "description": "'off', 'all', or 'one'."],
                ],
                required: ["mode"]
            ),
            tool(
                "music_set_shuffle",
                "Turn shuffle on or off. Turning on keeps the current track first and shuffles the rest; turning off restores the original order.",
                properties: [
                    "enabled": ["type": "boolean", "description": "true to shuffle, false to restore order."],
                ],
                required: ["enabled"]
            ),
            tool(
                "music_get_queue",
                "Return the current play queue: each track's index, id, title, artist, album, and duration, plus the current index, total length, and where the queue was started from.",
                properties: [:],
                required: []
            ),
            tool(
                "music_reorder_queue",
                "Move a track within the play queue from one index to another (drag-and-drop reorder). Indices are 0-based; `to` is the destination slot.",
                properties: [
                    "from": ["type": "integer", "description": "0-based index of the track to move."],
                    "to": ["type": "integer", "description": "0-based destination index."],
                ],
                required: ["from", "to"]
            ),
            tool(
                "music_remove_from_queue",
                "Remove a track from the play queue by its 0-based index. Returns the new queue length.",
                properties: [
                    "index": ["type": "integer", "description": "0-based index of the track to remove."],
                ],
                required: ["index"]
            ),
            tool(
                "music_play_next",
                "Search the library for `query` and insert the matches immediately after the current track so they play next (without clearing the rest of the queue).",
                properties: [
                    "query": ["type": "string", "description": "What to play next — artist, album, song, or keyword."],
                    "limit": ["type": "integer", "description": "Max songs to insert (default 25, max 100)."],
                ],
                required: ["query"]
            ),
            tool(
                "music_start_radio",
                "Start an endless 'more like this' radio: seed from the current track (or from `query` if given), fetch similar songs from the server, and play them. Great for 'play something like this' / 'start a radio'.",
                properties: [
                    "query": ["type": "string", "description": "Seed the radio from this song (top search match). Omit to seed from what's currently playing."],
                ],
                required: []
            ),
            tool(
                "music_sleep_timer",
                "Arm a sleep timer that pauses playback after `minutes`, or cancel it. Pass null or 0 to cancel.",
                properties: [
                    "minutes": ["type": "integer", "description": "Minutes until playback pauses. Null or 0 cancels any armed timer."],
                ],
                required: []
            ),
            tool(
                "music_set_eq",
                "Control the music equalizer: enable/disable it and/or apply a named preset. Applying an unknown preset returns the list of valid names.",
                properties: [
                    "enabled": ["type": "boolean", "description": "Turn the equalizer on or off."],
                    "preset": ["type": "string", "description": "Name of an EQ preset to apply (e.g. 'Flat', 'Bass Boost', 'Vocal')."],
                ],
                required: []
            ),
            BatonMCPMixTools.definition(),
            tool(
                "audio_suspend",
                "Cooperative audio focus: pause (or duck) Baton's playback for an owner so it can be auto-resumed later only if the user didn't intervene. Coordination primitive for dictation/recording ducking — a client should NOT surface it as a user-facing action. Returns a `handle` to pass to audio_resume.",
                properties: [
                    "owner": ["type": "string", "description": "Stable id of the suspender, e.g. 'tonebox.dictation'."],
                    "mode": ["type": "string", "description": "'pause' (default) or 'duck' (lower player volume to duckToPercent, restored on resume)."],
                    "duckToPercent": ["type": "integer", "description": "Target volume percent for mode='duck'. Omit to use the user's configured duck level (Settings → Playback); pass a value only when the context needs a different level. An explicit value is floored to 5% (duck stays audible) — for true silence use mode='pause', not duck."],
                ],
                required: ["owner"]
            ),
            tool(
                "audio_resume",
                "Release an audio-focus suspend and resume playback — but only if the owner still holds focus and the user hasn't changed playback since. Idempotent. Coordination primitive; not a user-facing action.",
                properties: [
                    "handle": ["type": "string", "description": "The handle returned by audio_suspend. Provide this, or owner+generation."],
                    "owner": ["type": "string", "description": "Owner id (alternative to handle; pair with generation)."],
                    "generation": ["type": "integer", "description": "The generation from audio_suspend (pair with owner)."],
                ],
                required: []
            ),
            BatonMCPSpeakTools.definition(),
        ])
    }

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ],
        ]
    }

    private static let readOnlyTools: Set<String> = [
        "music_search", "music_now_playing", "music_list_playlists", "music_get_queue",
    ]

    /// All music tools reach the Navidrome server; the audio-focus tools are local.
    private static let openWorldTools: Set<String> = [
        "music_search", "music_play", "music_queue_add", "music_pause",
        "music_resume", "music_stop", "music_next", "music_previous",
        "music_set_volume", "music_now_playing", "music_list_playlists",
        "music_play_playlist", "music_like", "music_rate",
        "music_create_playlist", "music_add_to_playlist", "music_delete_playlist",
        "music_build_mix",
        "music_seek", "music_set_repeat", "music_set_shuffle", "music_get_queue",
        "music_reorder_queue", "music_remove_from_queue", "music_play_next",
        "music_start_radio", "music_sleep_timer", "music_set_eq",
        "speak_summary",
    ]

    private static func annotate(_ defs: [[String: Any]]) -> [[String: Any]] {
        defs.map { def in
            guard let name = def["name"] as? String else { return def }
            var d = def
            let readOnly = readOnlyTools.contains(name)
            var ann: [String: Any] = [
                "title": name,
                "readOnlyHint": readOnly,
                "destructiveHint": name == "music_delete_playlist",
                "openWorldHint": openWorldTools.contains(name),
            ]
            if readOnly { ann["idempotentHint"] = true }
            d["annotations"] = ann
            return d
        }
    }

    // MARK: - Dispatch

    static func run(
        name: String,
        arguments: [String: Any],
        music: MusicModel,
        focus: BatonAudioFocusRegistry,
        sessionID: String? = nil
    ) async -> (text: String, isError: Bool) {
        do {
            let text: String
            switch name {
            case "music_search": text = try await musicSearch(arguments)
            case "music_play": text = try await musicPlay(arguments, music)
            case "music_queue_add": text = try await musicQueueAdd(arguments, music)
            case "music_pause": text = musicPause(music)
            case "music_resume": text = musicResume(music)
            case "music_stop": text = musicStop(music)
            case "music_next": text = musicNext(music)
            case "music_previous": text = musicPrevious(music)
            case "music_set_volume": text = try musicSetVolume(arguments, music)
            case "music_now_playing": text = musicNowPlaying(music)
            case "music_list_playlists": text = try await musicListPlaylists()
            case "music_play_playlist": text = try await musicPlayPlaylist(arguments, music)
            case "music_like": text = try await musicLike(arguments, music)
            case "music_rate": text = try await musicRate(arguments, music)
            case "music_create_playlist": text = try await musicCreatePlaylist(arguments, music)
            case "music_add_to_playlist": text = try await musicAddToPlaylist(arguments, music)
            case "music_delete_playlist": text = try await musicDeletePlaylist(arguments, music)
            case "music_build_mix": text = try await BatonMCPMixTools.run(arguments, music)
            case "music_seek": text = try musicSeek(arguments, music)
            case "music_set_repeat": text = try musicSetRepeat(arguments, music)
            case "music_set_shuffle": text = try musicSetShuffle(arguments, music)
            case "music_get_queue": text = musicGetQueue(music)
            case "music_reorder_queue": text = try musicReorderQueue(arguments, music)
            case "music_remove_from_queue": text = try musicRemoveFromQueue(arguments, music)
            case "music_play_next": text = try await musicPlayNext(arguments, music)
            case "music_start_radio": text = try await musicStartRadio(arguments, music)
            case "music_sleep_timer": text = musicSleepTimer(arguments, music)
            case "music_set_eq": text = musicSetEq(arguments, music)
            case "speak_summary": text = try await BatonMCPSpeakTools.run(arguments, music)
            case "audio_suspend": text = audioSuspend(arguments, music, focus, sessionID: sessionID)
            case "audio_resume": text = try audioResume(arguments, music, focus)
            default:
                return ("Unknown tool \"\(name)\".", true)
            }
            return (text, false)
        } catch let error as BatonMCPToolError {
            return (error.message, true)
        } catch {
            batonMCPLog.error("tool \(name) failed: \(error.localizedDescription)")
            return (error.localizedDescription, true)
        }
    }

    // MARK: - Music helpers

    private static func musicClient() throws -> NavidromeClient {
        do {
            return try NavidromeConfig.makeClient()
        } catch {
            throw BatonMCPToolError(message: "No music server is configured. Add one in Settings → Music.")
        }
    }

    private static func musicError(_ error: any Error) -> BatonMCPToolError {
        if let mcp = error as? BatonMCPToolError { return mcp }
        if let nav = error as? NavidromeError {
            return BatonMCPToolError(message: nav.errorDescription ?? "Music server error.")
        }
        return BatonMCPToolError(message: error.localizedDescription)
    }

    static func songJSON(_ song: NavidromeSong) -> [String: Any] {
        var out: [String: Any] = ["id": song.id, "title": song.title]
        if let artist = song.artist { out["artist"] = artist }
        if let display = song.displayArtist, display != song.artist { out["display_artist"] = display }
        if let album = song.album { out["album"] = album }
        if let duration = song.duration { out["duration_seconds"] = duration }
        if let track = song.track { out["track"] = track }
        if let disc = song.discNumber { out["disc"] = disc }
        if let year = song.year { out["year"] = year }
        let genres = song.genres.isEmpty ? [song.genre].compactMap { $0 } : song.genres
        if !genres.isEmpty { out["genres"] = genres }
        if let quality = song.qualityLabel { out["quality"] = quality }
        if let suffix = song.suffix { out["format"] = suffix }
        if let bitRate = song.bitRate { out["bit_rate_kbps"] = bitRate }
        if let rate = song.samplingRate { out["sampling_rate_hz"] = rate }
        if let depth = song.bitDepth { out["bit_depth"] = depth }
        if let channels = song.channelCount { out["channels"] = channels }
        if let type = song.contentType { out["content_type"] = type }
        if let size = song.size { out["size_bytes"] = size }
        if let plays = song.playCount { out["play_count"] = plays }
        if let rating = song.userRating, rating > 0 { out["rating"] = rating }
        out["liked"] = song.isLiked
        if let bpm = song.bpm { out["bpm"] = bpm }
        if let comment = song.comment, !comment.isEmpty { out["comment"] = comment }
        if let played = song.played { out["last_played"] = ISO8601DateFormatter().string(from: played) }
        if let mbid = song.musicBrainzID { out["musicbrainz_id"] = mbid }
        return out
    }

    static func musicStateLabel(_ state: StreamingPlaybackController.State) -> String {
        switch state {
        case .idle: "stopped"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case let .error(message): "error: \(message)"
        }
    }

    /// Resolve a play query into an ordered song list. An exact/prefix album-name
    /// match plays the album in track order; otherwise loose song hits. Reimplemented
    /// here because Tonebox's `AppModel.resolvePlayQueue` didn't get lifted into Baton.
    private static func resolvePlayQueue(
        query: String,
        client: NavidromeClient,
        songCount: Int
    ) async throws -> [NavidromeSong] {
        let results = try await client.search3(query: query, songCount: songCount)
        if let album = bestAlbumMatch(query: query, albums: results.albums) {
            let albumSongs = try await client.getAlbum(id: album.id)
            if !albumSongs.isEmpty { return albumSongs }
        }
        return results.songs
    }

    private static func bestAlbumMatch(query: String, albums: [NavidromeAlbum]) -> NavidromeAlbum? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return nil }
        if let exact = albums.first(where: { $0.name.lowercased() == q }) { return exact }
        return albums.first { album in
            let name = album.name.lowercased()
            return name.hasPrefix(q) || q.hasPrefix(name)
        }
    }

    // MARK: - Music tool implementations

    private static func musicSearch(_ args: [String: Any]) async throws -> String {
        let query = try requireString(args, "query")
        let limit = min(max(optionalInt(args, "limit") ?? 20, 1), 100)
        let client = try musicClient()
        do {
            let results = try await client.search3(query: query, songCount: limit)
            return jsonText([
                "songs": results.songs.map(songJSON),
                "albums": results.albums.map { ["id": $0.id, "name": $0.name, "artist": $0.artist ?? ""] },
                "artists": results.artists.map { ["id": $0.id, "name": $0.name] },
            ])
        } catch {
            throw musicError(error)
        }
    }

    private static func musicPlay(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let query = try requireString(args, "query")
        let limit = min(max(optionalInt(args, "limit") ?? 25, 1), 100)
        let client = try musicClient()
        let songs: [NavidromeSong]
        do {
            songs = try await resolvePlayQueue(query: query, client: client, songCount: limit)
        } catch {
            throw musicError(error)
        }
        guard !songs.isEmpty else {
            throw BatonMCPToolError(message: "No songs matched \"\(query)\".")
        }
        music.music.play(songs, source: .init(label: query, kind: .search, id: nil))
        return jsonText(["playing": songJSON(songs[0]), "queued": songs.count])
    }

    private static func musicQueueAdd(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let query = try requireString(args, "query")
        let limit = min(max(optionalInt(args, "limit") ?? 25, 1), 100)
        let client = try musicClient()
        let songs: [NavidromeSong]
        do {
            songs = try await client.search3(query: query, songCount: limit).songs
        } catch {
            throw musicError(error)
        }
        guard !songs.isEmpty else {
            throw BatonMCPToolError(message: "No songs matched \"\(query)\".")
        }
        music.music.enqueue(songs)
        return jsonText([
            "added": songs.count,
            "queue_length": music.music.queue.count,
            "summary": music.music.nowPlayingSummary,
        ])
    }

    private static func musicPause(_ music: MusicModel) -> String {
        music.music.pause()
        return music.music.nowPlayingSummary
    }

    private static func musicResume(_ music: MusicModel) -> String {
        music.music.resume()
        return music.music.nowPlayingSummary
    }

    private static func musicStop(_ music: MusicModel) -> String {
        music.music.stop()
        return "Stopped."
    }

    private static func musicNext(_ music: MusicModel) -> String {
        music.music.next()
        return music.music.nowPlayingSummary
    }

    private static func musicPrevious(_ music: MusicModel) -> String {
        music.music.previous()
        return music.music.nowPlayingSummary
    }

    private static func musicSetVolume(_ args: [String: Any], _ music: MusicModel) throws -> String {
        guard let percent = optionalInt(args, "percent") else {
            throw BatonMCPToolError(message: "Missing required argument 'percent' (0–100).")
        }
        music.music.setVolume(percent: percent)
        return "Music volume set to \(music.music.volumePercent)."
    }

    static func musicNowPlaying(_ music: MusicModel) -> String {
        let player = music.music
        var out: [String: Any] = [
            "state": musicStateLabel(player.state),
            "summary": player.nowPlayingSummary,
            "queue_length": player.queue.count,
            "queue_index": player.currentIndex,
            "volume_percent": player.volumePercent,
        ]
        if let song = player.nowPlaying { out["now_playing"] = songJSON(song) }
        return jsonText(out)
    }

    private static func musicListPlaylists() async throws -> String {
        let client = try musicClient()
        do {
            let playlists = try await client.getPlaylists()
            return jsonText([
                "playlists": playlists.map { ["id": $0.id, "name": $0.name, "song_count": $0.songCount] },
            ])
        } catch {
            throw musicError(error)
        }
    }

    private static func musicPlayPlaylist(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let client = try musicClient()
        let playlistID: String
        do {
            if let id = optionalString(args, "playlist_id") {
                playlistID = id
            } else if let name = optionalString(args, "name") {
                let all = try await client.getPlaylists()
                let lowered = name.lowercased()
                guard let match = all.first(where: { $0.name.lowercased() == lowered })
                    ?? all.first(where: { $0.name.lowercased().contains(lowered) })
                else {
                    throw BatonMCPToolError(message: "No playlist named \"\(name)\".")
                }
                playlistID = match.id
            } else {
                throw BatonMCPToolError(message: "Provide either 'name' or 'playlist_id'.")
            }
            let playlist = try await client.getPlaylist(id: playlistID)
            guard !playlist.songs.isEmpty else {
                throw BatonMCPToolError(message: "Playlist \"\(playlist.name)\" is empty.")
            }
            music.music.play(playlist.songs, source: .init(label: playlist.name, kind: .playlist, id: playlist.id))
            return jsonText([
                "playing_playlist": playlist.name,
                "tracks": playlist.songs.count,
                "now_playing": songJSON(playlist.songs[0]),
            ])
        } catch {
            throw musicError(error)
        }
    }

    /// The song a rating/like tool acts on: the top hit for `query`, or the current
    /// track when `query` is absent.
    private static func resolveMusicSong(_ args: [String: Any], _ music: MusicModel) async throws -> NavidromeSong {
        if let query = optionalString(args, "query") {
            let client = try musicClient()
            do {
                guard let song = try await client.search3(query: query, songCount: 1).songs.first else {
                    throw BatonMCPToolError(message: "No song matched \"\(query)\".")
                }
                return song
            } catch { throw musicError(error) }
        }
        guard let current = music.music.nowPlaying else {
            throw BatonMCPToolError(message: "Nothing is playing — provide a 'query' to pick a song.")
        }
        return current
    }

    private static func musicLike(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let song = try await resolveMusicSong(args, music)
        let unlike = (args["unlike"] as? Bool) ?? false
        _ = try musicClient() // fail fast if no server is configured
        // Route through the library store (not the raw client) so the optimistic @Observable
        // `ratingOverrides` cache updates and the on-screen heart refreshes immediately — the same
        // path the in-app like button uses. `toggleLike` flips, so only toggle when the desired
        // state differs, keeping an explicit like/unlike idempotent. (write-through to the server
        // happens inside the store)
        if music.musicLibrary.isLiked(song) != !unlike {
            await music.musicLibrary.toggleLike(song)
        }
        return "\(unlike ? "Unliked" : "Liked") \(song.displayLine)."
    }

    private static func musicRate(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        guard let rating = optionalInt(args, "rating"), (0 ... 5).contains(rating) else {
            throw BatonMCPToolError(message: "Provide 'rating' as an integer 0–5 (0 clears).")
        }
        let song = try await resolveMusicSong(args, music)
        _ = try musicClient() // fail fast if no server is configured
        // Route through the library store so the optimistic @Observable `ratingOverrides` cache
        // updates and the on-screen stars refresh immediately — the same path the in-app star
        // control uses. (write-through to the server happens inside the store)
        await music.musicLibrary.setRating(song, rating: rating)
        return rating == 0 ? "Cleared the rating on \(song.displayLine)." : "Rated \(song.displayLine) \(rating)★."
    }

    private static func musicCreatePlaylist(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let name = try requireString(args, "name")
        let client = try musicClient()
        do {
            var songIDs: [String] = []
            if let query = optionalString(args, "query") {
                songIDs = try await client.search3(query: query, songCount: 50).songs.map(\.id)
            }
            let playlist = try await client.createPlaylist(name: name, songIDs: songIDs)
            await music.musicLibrary.loadPlaylists()
            return jsonText(["created_playlist": playlist.name, "id": playlist.id, "songs": songIDs.count])
        } catch { throw musicError(error) }
    }

    private static func musicAddToPlaylist(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let query = try requireString(args, "query")
        let client = try musicClient()
        do {
            let id = try await resolvePlaylistID(args, client: client)
            let songIDs = try await client.search3(query: query, songCount: 50).songs.map(\.id)
            guard !songIDs.isEmpty else { throw BatonMCPToolError(message: "No songs matched \"\(query)\".") }
            try await client.updatePlaylist(id: id, songIDsToAdd: songIDs)
            await music.musicLibrary.loadPlaylists()
            return "Added \(songIDs.count) song\(songIDs.count == 1 ? "" : "s") to the playlist."
        } catch { throw musicError(error) }
    }

    private static func musicDeletePlaylist(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let client = try musicClient()
        do {
            // Destructive: never fuzzy-match (see exactPlaylistToDelete). Echo what
            // was deleted so the agent has confirmation of the exact target.
            let all = try await client.getPlaylists()
            let target = try exactPlaylistToDelete(
                name: optionalString(args, "name"),
                playlistID: optionalString(args, "playlist_id"),
                from: all
            )
            try await client.deletePlaylist(id: target.id)
            await music.musicLibrary.loadPlaylists()
            return "Deleted the playlist \"\(target.name)\" [\(target.id)]."
        } catch { throw musicError(error) }
    }

    /// Resolves the single playlist a destructive delete may target. Exact id or
    /// exact (case-insensitive) name only — a substring-only match refuses and lists
    /// candidates rather than deleting the wrong one. Pure (no client) so it's unit
    /// testable.
    static func exactPlaylistToDelete(
        name: String?, playlistID: String?, from all: [NavidromePlaylist]
    ) throws -> NavidromePlaylist {
        if let id = playlistID {
            guard let match = all.first(where: { $0.id == id }) else {
                throw BatonMCPToolError(message: "No playlist with id \"\(id)\".")
            }
            return match
        }
        guard let name else {
            throw BatonMCPToolError(message: "Provide either 'name' or 'playlist_id'.")
        }
        let lowered = name.lowercased()
        let exact = all.filter { $0.name.lowercased() == lowered }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 {
            let list = exact.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")
            throw BatonMCPToolError(message: "Multiple playlists are named \"\(name)\" — pass 'playlist_id' to choose: \(list).")
        }
        let near = all.filter { $0.name.lowercased().contains(lowered) }
        if near.isEmpty { throw BatonMCPToolError(message: "No playlist named \"\(name)\".") }
        let list = near.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")
        throw BatonMCPToolError(message: "No playlist is exactly named \"\(name)\". Delete requires an exact name or 'playlist_id'. Did you mean: \(list)?")
    }

    private static func resolvePlaylistID(_ args: [String: Any], client: NavidromeClient) async throws -> String {
        if let id = optionalString(args, "playlist_id") { return id }
        guard let name = optionalString(args, "name") else {
            throw BatonMCPToolError(message: "Provide either 'name' or 'playlist_id'.")
        }
        let all = try await client.getPlaylists()
        let lowered = name.lowercased()
        guard let match = all.first(where: { $0.name.lowercased() == lowered })
            ?? all.first(where: { $0.name.lowercased().contains(lowered) })
        else { throw BatonMCPToolError(message: "No playlist named \"\(name)\".") }
        return match.id
    }

    // MARK: - Gap-filler transport / queue tools

    private static func musicSeek(_ args: [String: Any], _ music: MusicModel) throws -> String {
        guard let seconds = optionalInt(args, "seconds") else {
            throw BatonMCPToolError(message: "Missing required argument 'seconds'.")
        }
        guard music.music.nowPlaying != nil else {
            throw BatonMCPToolError(message: "Nothing is playing — start a track before seeking.")
        }
        music.music.seek(to: TimeInterval(max(0, seconds)))
        return jsonText([
            "seeked_to_seconds": Int(music.music.currentTime.rounded()),
            "summary": music.music.nowPlayingSummary,
        ])
    }

    private static func musicSetRepeat(_ args: [String: Any], _ music: MusicModel) throws -> String {
        let raw = try requireString(args, "mode").lowercased()
        guard let target = StreamingPlaybackController.RepeatMode(rawValue: raw) else {
            throw BatonMCPToolError(message: "Unknown repeat mode \"\(raw)\" — use 'off', 'all', or 'one'.")
        }
        // The setter is private(set); cycle (off → all → one → off) until it matches. Bounded
        // to the number of modes so a mismatch can't loop forever.
        var guardCount = 0
        while music.music.repeatMode != target, guardCount < StreamingPlaybackController.RepeatMode.allCases.count {
            music.music.cycleRepeat()
            guardCount += 1
        }
        return jsonText(["repeat_mode": music.music.repeatMode.rawValue])
    }

    private static func musicSetShuffle(_ args: [String: Any], _ music: MusicModel) throws -> String {
        guard let enabled = args["enabled"] as? Bool else {
            throw BatonMCPToolError(message: "Missing required argument 'enabled' (true/false).")
        }
        if music.music.isShuffled != enabled { music.music.toggleShuffle() }
        return jsonText(["shuffle": music.music.isShuffled])
    }

    static func musicGetQueue(_ music: MusicModel) -> String {
        let player = music.music
        let items = player.queue.enumerated().map { index, song -> [String: Any] in
            var out = songJSON(song)
            out["index"] = index
            return out
        }
        var out: [String: Any] = [
            "queue": items,
            "current_index": player.currentIndex,
            "length": player.queue.count,
        ]
        if let source = player.queueSource { out["source"] = source.label }
        return jsonText(out)
    }

    private static func musicReorderQueue(_ args: [String: Any], _ music: MusicModel) throws -> String {
        guard let from = optionalInt(args, "from"), let to = optionalInt(args, "to") else {
            throw BatonMCPToolError(message: "Provide integer 'from' and 'to' indices.")
        }
        let count = music.music.queue.count
        guard music.music.queue.indices.contains(from) else {
            throw BatonMCPToolError(message: "'from' index \(from) is out of range (queue has \(count) tracks).")
        }
        // `move(fromOffsets:toOffset:)` accepts a destination up to `count` (append-at-end).
        guard (0 ... count).contains(to) else {
            throw BatonMCPToolError(message: "'to' index \(to) is out of range (0…\(count)).")
        }
        music.music.moveQueueItem(from: IndexSet(integer: from), to: to)
        return jsonText([
            "moved_from": from,
            "moved_to": to,
            "queue": music.music.queue.map { $0.title },
            "current_index": music.music.currentIndex,
        ])
    }

    private static func musicRemoveFromQueue(_ args: [String: Any], _ music: MusicModel) throws -> String {
        guard let index = optionalInt(args, "index") else {
            throw BatonMCPToolError(message: "Missing required argument 'index'.")
        }
        guard music.music.queue.indices.contains(index) else {
            throw BatonMCPToolError(message: "Index \(index) is out of range (queue has \(music.music.queue.count) tracks).")
        }
        music.music.removeFromQueue(at: IndexSet(integer: index))
        return jsonText([
            "removed_index": index,
            "queue_length": music.music.queue.count,
        ])
    }

    private static func musicPlayNext(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let query = try requireString(args, "query")
        let limit = min(max(optionalInt(args, "limit") ?? 25, 1), 100)
        let client = try musicClient()
        let songs: [NavidromeSong]
        do {
            songs = try await client.search3(query: query, songCount: limit).songs
        } catch {
            throw musicError(error)
        }
        guard !songs.isEmpty else {
            throw BatonMCPToolError(message: "No songs matched \"\(query)\".")
        }
        music.music.playNext(songs)
        return jsonText([
            "inserted": songs.count,
            "queue_length": music.music.queue.count,
            "summary": music.music.nowPlayingSummary,
        ])
    }

    private static func musicStartRadio(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        // Seed from an explicit query's top hit, else from the currently-playing track.
        let seed: NavidromeSong
        if let query = optionalString(args, "query") {
            let client = try musicClient()
            do {
                guard let hit = try await client.search3(query: query, songCount: 1).songs.first else {
                    throw BatonMCPToolError(message: "No song matched \"\(query)\".")
                }
                seed = hit
            } catch { throw musicError(error) }
        } else if let current = music.music.nowPlaying {
            seed = current
        } else {
            throw BatonMCPToolError(message: "Nothing is playing — provide a 'query' to seed the radio.")
        }

        // Prefer the wired "more like this" provider (radio-ban-filtered); fall back to a
        // direct getSimilarSongs call when it isn't wired.
        var similar: [NavidromeSong]
        if let provider = music.music.relatedProvider {
            similar = await provider(seed)
        } else {
            do {
                similar = try await musicClient().getSimilarSongs(id: seed.id, count: 50)
            } catch { throw musicError(error) }
        }
        // Lead with the seed so the radio starts on the requested/current track.
        var queue = [seed]
        var seen: Set<String> = [seed.id]
        for song in similar where seen.insert(song.id).inserted { queue.append(song) }
        guard queue.count > 1 else {
            throw BatonMCPToolError(message: "Couldn't find any songs similar to \(seed.displayLine).")
        }
        music.music.play(queue, source: .init(label: "\(seed.title) Radio", kind: .radio, id: nil))
        return jsonText([
            "seed": songJSON(seed),
            "queued": queue.count,
            "now_playing": songJSON(queue[0]),
        ])
    }

    private static func musicSleepTimer(_ args: [String: Any], _ music: MusicModel) -> String {
        let minutes = optionalInt(args, "minutes")
        music.music.setSleepTimer(minutes: minutes)
        var out: [String: Any] = ["armed": music.music.sleepTimerArmed]
        if let endsAt = music.music.sleepTimerEndsAt {
            out["ends_at"] = ISO8601DateFormatter().string(from: endsAt)
            out["minutes"] = minutes ?? 0
        }
        return jsonText(out)
    }

    private static func musicSetEq(_ args: [String: Any], _ music: MusicModel) -> String {
        let eq = music.musicEqualizer
        if let enabled = args["enabled"] as? Bool { eq.isEnabled = enabled }
        var unknownPreset: String?
        if let preset = optionalString(args, "preset") {
            if MusicEqualizer.presets.contains(where: { $0.name == preset }) {
                eq.apply(preset: preset)
            } else {
                unknownPreset = preset
            }
        }
        var out: [String: Any] = [
            "enabled": eq.isEnabled,
            "preset": eq.preset,
        ]
        if let unknownPreset {
            out["error"] = "Unknown preset \"\(unknownPreset)\"."
            out["available_presets"] = MusicEqualizer.presets.map(\.name)
        }
        return jsonText(out)
    }

    // MARK: - Audio-focus tools

    private static func audioSuspend(
        _ args: [String: Any],
        _ music: MusicModel,
        _ focus: BatonAudioFocusRegistry,
        sessionID: String? = nil
    ) -> String {
        let owner = optionalString(args, "owner") ?? "unknown"
        let mode: StreamingPlaybackController.AudioFocusToken.Mode =
            optionalString(args, "mode") == "duck" ? .duck : .pause
        // An agent's explicit level is floored (duck stays audible); omitting it uses the user's
        // own configured level, which they may set all the way to silence.
        let duckTo = optionalInt(args, "duckToPercent").map(BatonAudioFocusRegistry.clampAgentDuck) ?? music.music.duckPercent
        // Scope the handle to the caller's MCP session so it auto-expires when that
        // session's SSE stream closes (spec §4.3), not just via the 10-min sweep.
        let out = focus.suspend(
            owner: owner, mode: mode, duckToPercent: duckTo, connectionID: sessionID, on: music.music)
        return jsonText(out)
    }

    private static func audioResume(
        _ args: [String: Any],
        _ music: MusicModel,
        _ focus: BatonAudioFocusRegistry
    ) throws -> String {
        if let handle = optionalString(args, "handle") {
            return jsonText(focus.resume(handle: handle, on: music.music))
        }
        // Fast-path variant: reconstruct from owner + generation.
        if let owner = optionalString(args, "owner"), let generation = optionalInt(args, "generation") {
            let didSuspend = (args["didSuspend"] as? Bool) ?? true
            return jsonText(focus.resume(
                owner: owner, generation: generation, didSuspend: didSuspend, on: music.music
            ))
        }
        throw BatonMCPToolError(message: "Provide 'handle', or 'owner' + 'generation'.")
    }

    // MARK: - Argument helpers

    private static func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw BatonMCPToolError(message: "Missing required argument '\(key)'.")
        }
        return value
    }

    private static func optionalString(_ args: [String: Any], _ key: String) -> String? {
        guard let value = args[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func optionalInt(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let n = args[key] as? NSNumber { return n.intValue }
        if let s = args[key] as? String { return Int(s) }
        return nil
    }

    static func jsonText(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
