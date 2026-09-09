import BatonAgentKit
import BatonSubsonicKit
import BatonSubsonicModels
import BatonGatewayCore
import Foundation

// MARK: - The server-side tool surface

/// Curation tools bound straight to Navidrome. Playback verbs exist so the model
/// never invents them — they answer that playback lives on the user's devices
/// (dispatching to a connected phone/Mac is the next step).
@MainActor
final class GatewayToolSurface: RemoteToolSurface {
    private let client: NavidromeClient
    private let devices: DeviceLink
    /// The last search, per conversation. One shared field made `music_similar_songs` seed from
    /// whoever searched most recently (TBX-5308, S-F26).
    private let lastResults = SearchSeedStore<[NavidromeSong]>()

    init(client: NavidromeClient, devices: DeviceLink) {
        self.client = client
        self.devices = devices
    }

    func definitions() -> [[String: Any]] {
        [
            ["name": "music_search", "description": "Search the library for songs, albums, artists.",
             "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
            ["name": "music_similar_songs", "description": "Songs similar to the most recent search's first result.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_list_playlists", "description": "The user's playlists.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_list_genres", "description": "Genres in the library.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_random", "description": "Random songs, optionally by genre.",
             "inputSchema": ["type": "object", "properties": ["genre": ["type": "string"]]]],
            ["name": "music_play", "description": "Play something on the user's device — pass what to play.",
             "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
            ["name": "music_pause", "description": "Pause playback on the user's device.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_next", "description": "Skip to the next track on the user's device.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_now_playing", "description": "What is playing on the user's device right now.",
             "inputSchema": ["type": "object", "properties": [:]]],
        ]
    }

    func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) {
        switch name {
        case "music_search":
            let query = arguments["query"] as? String ?? ""
            guard let results = try? await client.search3(query: query) else {
                return ("The library didn't answer — is Navidrome up?", true)
            }
            lastResults.remember(results.songs, for: sessionID)
            if results.songs.isEmpty { return ("Nothing matched \"\(query)\".", false) }
            let listing = results.songs.prefix(10).enumerated()
                .map { "\($0.offset + 1). \($0.element.title) — \($0.element.artist ?? "?")" }
                .joined(separator: "\n")
            return ("Found \(results.songs.count) songs:\n\(listing)", false)
        case "music_similar_songs":
            guard let seed = lastResults.seed(for: sessionID)?.first else {
                return ("Search first, then ask for similar.", false)
            }
            let similar = (try? await client.getSimilarSongs(id: seed.id)) ?? []
            if similar.isEmpty { return ("The server has no similarity data for \(seed.title).", false) }
            return ("Similar to \(seed.title):\n" + similar.prefix(10).map { "• \($0.title) — \($0.artist ?? "?")" }.joined(separator: "\n"), false)
        case "music_list_playlists":
            let lists = (try? await client.getPlaylists()) ?? []
            return (lists.isEmpty ? "No playlists yet." : lists.map { "• \($0.name) (\($0.songCount))" }.joined(separator: "\n"), false)
        case "music_list_genres":
            let genres = (try? await client.getGenres()) ?? []
            return (genres.prefix(30).map(\.name).joined(separator: ", "), false)
        case "music_random":
            let genre = arguments["genre"] as? String
            let songs = (try? await client.getRandomSongs(count: 10, genre: genre)) ?? []
            lastResults.remember(songs, for: sessionID)
            return (songs.map { "• \($0.title) — \($0.artist ?? "?")" }.joined(separator: "\n"), false)
        case "music_play", "music_pause", "music_next", "music_now_playing":
            // Playback belongs to the device with the speakers. Dispatch and wait;
            // if nothing is listening, say so instead of claiming success.
            let argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
            guard let result = await devices.dispatch(name: name, argumentsJSON: argumentsJSON) else {
                return ("No Baton device is connected right now — open Baton on your phone and I'll play it there. I can still search and build you something from here.", false)
            }
            return result
        default:
            return ("The gateway doesn't have \(name).", true)
        }
    }
}
