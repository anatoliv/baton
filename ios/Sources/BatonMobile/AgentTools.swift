import BatonShareKit
import Foundation

/// The music friend's hands: a compact tool set bound to the phone's player and
/// library. Names and shapes follow the Mac's MCP tool catalog (music_*) so the
/// same conversations transfer when the shared BatonAgentKit lands; destructive
/// tools (playlist deletion) are deliberately absent, and ids never enter the
/// schemas the model sees — both lessons from the desktop eval.
@MainActor
final class AgentTools: RemoteToolSurface {
    private let model: MobileModel
    private let canShare: @MainActor () -> Bool

    init(model: MobileModel, canShare: @escaping @MainActor () -> Bool = { SongSharing.hasSharedBefore }) {
        self.model = model
        self.canShare = canShare
    }

    static let systemPrompt = """
    You are Baton, a friendly music companion living in the user's own music app, \
    playing from THEIR Navidrome library, not a streaming catalog. Keep replies to \
    a sentence or two; you're a friend, not a manual. When asked to play something, \
    search first, then play from the results. Never claim playback you didn't do. \
    If a search finds nothing, say so and suggest something nearby in spirit.
    """

    /// MCP-shaped definitions — the shape `RemoteAgent`/`RemoteNaturalLanguage`
    /// translate into whichever provider dialect is in play, exactly as the Mac's
    /// catalog does.
    func definitions() -> [[String: Any]] { Self.definitions }

    /// The kit's execution seam. `sessionID` is unused here: the phone has one
    /// player and one user, so there is no session to disambiguate.
    func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) {
        if name == "music_share" {
            do { return (try await musicShare(arguments), false) }
            catch { return (error.localizedDescription, true) }
        }
        let text = await dispatch(name: name, input: arguments)
        return (text, false)
    }

    static let definitions: [[String: Any]] = [
        [
            "name": "music_search",
            "description": "Search the user's library for songs, albums and artists.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "What to look for"]],
                "required": ["query"],
            ],
        ],
        [
            "name": "music_play_results",
            "description": "Play the songs from the most recent search, optionally starting at a given result number (1-based).",
            "inputSchema": [
                "type": "object",
                "properties": ["start_at": ["type": "integer", "description": "1-based index into the results"]],
            ],
        ],
        [
            "name": "music_now_playing",
            "description": "What is currently playing, and whether playback is running.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "music_pause",
            "description": "Pause playback.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "music_resume",
            "description": "Resume playback.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "music_next",
            "description": "Skip to the next track.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "music_queue_add",
            "description": "Add the most recent search's songs to the end of the queue instead of replacing it.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "music_start_radio",
            "description": "Start endless radio from what's currently playing (similar songs from the library).",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "music_share",
            "description": "Create a link a friend outside the home network can open to play one song in a browser, with no app and no account. The song is encrypted on this iPhone and uploaded to Baton's share service; the key is in the link. Returns the link to send. Without query, shares the currently-playing track. Refuses until the owner has shared a song once from Baton itself, so they have seen where a shared song goes. \(ShareToolHandoff.agentInstructions)",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Song to share. Uses the top search match. Omit for the current track."],
                    "note": ["type": "string", "description": "A short note shown with the song, up to 280 characters."],
                    "expires_days": ["type": "integer", "description": "How long the link lasts: 1, 7 (default) or 30 days."],
                    "hide_details": ["type": "boolean", "description": "Set true to encrypt the title, artist and artwork too, so link previews only say a song was sent."],
                    "recipient": ["type": "string", "description": ShareToolHandoff.recipientDescription],
                ],
                "required": [String](),
            ],
        ],
        [
            "name": "music_set_volume",
            "description": "Set the player volume, 0 to 100.",
            "inputSchema": [
                "type": "object",
                "properties": ["percent": ["type": "integer"]],
                "required": ["percent"],
            ],
        ],
    ]

    /// The model's last search — `music_play_results` plays from here, so the model
    /// never needs (or sees) raw ids it could fabricate.
    /// The last search's songs. Internal (not private) so tests can stand in for a search.
    var lastResults: [NavidromeSong] = []
    private var lastQuery = ""

    func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "music_search":
            let query = input["query"] as? String ?? ""
            await model.musicLibrary.search(query)
            lastResults = model.musicLibrary.searchResults.songs
            lastQuery = query
            if lastResults.isEmpty { return "No songs matched \"\(query)\"." }
            let listing = lastResults.prefix(10).enumerated()
                .map { "\($0.offset + 1). \(DisplayName.titleWithArtist(title: $0.element.title, artist: $0.element.artist))" }
                .joined(separator: "\n")
            return "Found \(lastResults.count) songs:\n\(listing)"

        case "music_play_results":
            guard !lastResults.isEmpty else { return "There are no search results to play. Search first." }
            let start = max(1, input["start_at"] as? Int ?? 1) - 1
            guard start < lastResults.count else { return "Only \(lastResults.count) results exist." }
            model.music.play(lastResults, startAt: start, source: .init(label: lastQuery, kind: .search))
            return "Playing \(lastResults[start].title)."

        case "music_now_playing":
            guard let song = model.music.nowPlaying else { return "Nothing is playing." }
            return "\(model.music.isPlaying ? "Playing" : "Paused"): "
                + DisplayName.titleWithArtist(title: song.title, artist: song.artist)

        case "music_pause":
            model.music.pause(); return "Paused."

        case "music_resume":
            model.music.resume(); return "Resumed."

        case "music_next":
            model.music.next(); return "Skipped."

        case "music_queue_add":
            guard !lastResults.isEmpty else { return "Nothing searched yet." }
            // Appended, as the Mac's `music_queue_add` does: re-playing the whole queue reset
            // shuffle and counted the search results as part of the playing collection.
            model.music.enqueue(lastResults)
            return "Added \(lastResults.count) songs to the queue."

        case "music_start_radio":
            guard let seed = model.music.nowPlaying else { return "Play something first to seed the radio." }
            // Through the bans list, like every other way of starting a radio. Asking the
            // music friend for a radio is not a reason to hear tracks you have told Baton
            // to keep out of one.
            let similar = model.radioBans.filtered(await model.musicLibrary.similarSongs(seedID: seed.id))
            guard !similar.isEmpty else { return "The music server has no similarity data for this track." }
            model.music.play([seed] + similar, source: .init(label: "\(seed.title) Radio", kind: .radio))
            return "Radio started from \(seed.title) with \(similar.count) similar songs."

        case "music_share":
            return await run(name: name, arguments: input, sessionID: nil).text

        case "music_set_volume":
            let percent = max(0, min(100, input["percent"] as? Int ?? 70))
            // The person's own change (by voice), so a gentle alarm's rise stops, as the slider does.
            model.music.setVolume(percent: percent)
            return "Volume set to \(percent)."

        default:
            return "Unknown tool \(name)."
        }
    }

    struct ShareToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func sharingOptions(_ args: [String: Any], from: String) throws -> SongSharing.Options {
        try SongSharing.toolOptions(args, from: from)
    }

    private func musicShare(_ args: [String: Any]) async throws -> String {
        guard canShare() else {
            throw ShareToolError(message: SongSharing.consentRequiredMessage)
        }
        let options = try Self.sharingOptions(args, from: BatonStorage.defaults.string(forKey: SongSharing.fromKey) ?? "")
        let song: NavidromeSong
        if let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await model.musicLibrary.search(query)
            guard let found = model.musicLibrary.searchResults.songs.first else {
                throw ShareToolError(message: "No songs matched \"\(query)\".")
            }
            song = found
        } else if let current = model.music.nowPlaying {
            song = current
        } else {
            throw ShareToolError(message: "Nothing is playing. Provide a query for the song to share.")
        }
        do {
            let record = try await SongSharing.shared.share(song, options: options,
                coverArtURL: song.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 600) })
            let result = ShareToolHandoff.result(
                link: record.link, title: record.title, artist: record.artist,
                expiresAt: record.expiresAt, recipient: try ShareToolHandoff.recipient(from: args))
            return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
        } catch {
            throw ShareToolError(message: SongShareError(error).errorDescription ?? "Sharing didn't work.")
        }
    }

}
