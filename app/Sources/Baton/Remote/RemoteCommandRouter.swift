import Foundation

// MARK: - Wire types

/// One inbound chat message, normalized across platforms.
struct RemoteInbound: Sendable {
    var platform: RemotePlatform
    /// Platform user id. This — not the display name — is what the allowlist holds.
    var senderID: String
    var senderName: String
    /// Telegram chat id / Discord channel id; where the reply goes.
    var channelID: String
    var text: String
}

/// What to send back.
struct RemoteReply: Sendable {
    var text: String
    /// The tool reported failure. Used to decide whether a literal reading is
    /// worth a second opinion from the model.
    var isFailure: Bool = false
    /// Whether to attach transport buttons (⏮ ⏯ ⏭ 🔉 🔊). Set for anything that
    /// leaves the user looking at playback state.
    var showsTransport: Bool = false

    static func plain(_ text: String) -> RemoteReply { RemoteReply(text: text) }
    static func player(_ text: String) -> RemoteReply { RemoteReply(text: text, showsTransport: true) }

    /// Chat platforms hard-cap message length (Telegram 4096, Discord 2000) and
    /// refuse anything over it — so an unclamped long reply is a LOST reply.
    /// Cuts on a line boundary where one is near, so a truncated list ends with
    /// a whole row rather than half a title.
    static func clamped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n…"
        var cut = String(text.prefix(limit - marker.count))
        if let lastLine = cut.lastIndex(of: "\n"),
           cut.distance(from: lastLine, to: cut.endIndex) < 120 {
            cut = String(cut[cut.startIndex..<lastLine])
        }
        return cut + marker
    }
}

// MARK: - Router

/// The shared brain behind both bridges: authorize, parse, dispatch, format.
/// Platform adapters own transport only, so Telegram and Discord can never drift
/// apart in what they accept or what they permit.
@MainActor
final class RemoteCommandRouter {
    private let music: MusicModel
    private let focus: BatonAudioFocusRegistry
    private let settings: RemoteControlSettings
    /// Short per-chat memory, so "select one of them" has something to select
    /// from. In memory only, and never sent for typed commands — only the
    /// natural-language path needs the context.
    let conversation: RemoteConversationLog

    /// Injectable so tests can exercise routing without a network call.
    var resolveNaturalLanguage: (
        String, RemoteControlSettings.NaturalLanguageConfig, RemoteToolSchemas,
        [RemoteConversationLog.Turn], String?
    ) async throws -> RemoteNaturalLanguage.Resolution = {
        try await RemoteNaturalLanguage.resolve(
            $0, config: $1, tools: $2, history: $3, playerContext: $4)
    }

    init(
        music: MusicModel,
        focus: BatonAudioFocusRegistry,
        settings: RemoteControlSettings,
        conversation: RemoteConversationLog = RemoteConversationLog()
    ) {
        self.music = music
        self.focus = focus
        self.settings = settings
        self.conversation = conversation
    }

    // MARK: Entry point

    func handle(_ inbound: RemoteInbound) async -> RemoteReply? {
        let reply = await route(inbound)
        // Remember the exchange whatever produced it: a follow-up to a *typed*
        // command ("play dido" → "actually, the live one") needs the same
        // context as a follow-up to a spoken one.
        if let reply {
            conversation.record(
                key: RemoteConversationLog.key(for: inbound),
                user: inbound.text,
                assistant: reply.text
            )
        }
        return reply
    }

    private func route(_ inbound: RemoteInbound) async -> RemoteReply? {
        let action = RemoteCommandParser.parse(inbound.text)
        if case .ignore = action { return nil }

        // Authorization first — an unknown sender may do exactly one thing.
        guard isAuthorized(inbound) else {
            if case let .link(code) = action {
                guard settings.matchesLinkCode(code) else {
                    remoteLog.error("Rejected a bad link code from \(inbound.platform.rawValue, privacy: .public)")
                    return .plain("That link code isn't right. Baton → Settings → Remote shows the current one.")
                }
                settings.authorize(sender: inbound.senderID, on: inbound.platform)
                return .player("Linked. You can control Baton from here now — send `help` for the commands.")
            }
            remoteLog.notice("Ignoring message from unauthorized \(inbound.platform.rawValue, privacy: .public) sender")
            return .plain(
                "This chat isn't authorized to control Baton. Open Baton → Settings → Remote "
                    + "and send me `/link` followed by the code shown there."
            )
        }

        switch action {
        case .ignore:
            return nil

        case .help:
            return .plain(Self.helpText)

        case .forget:
            conversation.forget(key: RemoteConversationLog.key(for: inbound))
            return .plain("Forgotten — the next message starts fresh.")

        case .link:
            return .plain("This chat is already linked.")

        case let .tool(call):
            let reply = await run(call)
            // A command matched, but its literal reading found nothing. When the
            // words could have meant something else — "play the second one" is a
            // reference, not a song title — the model has the conversation and
            // can say which. Only for tools that resolve a free-text query, and
            // only once: the retry's own result stands.
            if reply.isFailure,
               Self.queryTools.contains(call.name),
               settings.naturalLanguage.isConfigured,
               case let .success(second) = await askTheModel(inbound.text, inbound) {
                return second
            }
            return reply

        case let .natural(text):
            guard settings.naturalLanguage.isConfigured else {
                return .plain(
                    "I don't know `\(firstWord(of: text))`. Send `help` for the command list — "
                        + "or turn on natural language in Baton → Settings → Remote to say it in your own words."
                )
            }
            // Here the model is the only interpreter, so its failure is the
            // answer — say exactly what went wrong rather than a generic shrug.
            switch await askTheModel(text, inbound) {
            case let .success(reply): return reply
            case let .failure(error): return .plain(error.localizedDescription)
            }
        }
    }

    /// Hand a message to the model and run whatever it picks. The failure is
    /// returned rather than flattened, because the two callers want different
    /// things from it: a natural-language message has no other interpreter, so
    /// the error *is* the answer; a command falling back here already has a
    /// literal answer worth keeping.
    private func askTheModel(
        _ text: String,
        _ inbound: RemoteInbound
    ) async -> Result<RemoteReply, any Error> {
        do {
            let tools = RemoteNaturalLanguage.toolSchemas(from: BatonMCPToolCatalog.definitions())
            let history = conversation.history(for: RemoteConversationLog.key(for: inbound))
            let resolution = try await resolveNaturalLanguage(
                text, settings.naturalLanguage, tools, history, playerContext())
            var reply = await run(resolution.call)
            if let preamble = resolution.preamble, !preamble.isEmpty {
                reply.text = preamble + "\n\n" + reply.text
            }
            return .success(reply)
        } catch {
            remoteLog.error("Natural-language routing failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    /// The player's live state, phrased for the model. This is what makes
    /// "this artist", "queue more of this", "who is this" answerable in one
    /// call: the router is sitting next to the player, so the state travels
    /// with the request instead of costing a second round trip.
    func playerContext() -> String {
        let player = music.music
        guard let song = player.nowPlaying else {
            return "Player state: nothing is playing right now."
        }
        let position = player.queue.isEmpty
            ? "" : " — track \(player.currentIndex + 1) of \(player.queue.count) in the queue"
        // The album is included because its absence was measured to matter:
        // "what album is this from" sent the model searching for the answer
        // instead of to music_now_playing, which displays it.
        let album = (song.album?.isEmpty == false) ? ", from the album \"\(song.album!)\"" : ""
        return "Player state: \"\(song.title)\" by \(song.artist)\(album)\(position)."
    }

    // MARK: Dispatch

    private func run(_ call: RemoteToolCall) async -> RemoteReply {
        let (text, isError) = await BatonMCPToolCatalog.run(
            name: call.name,
            arguments: call.jsonArguments,
            music: music,
            focus: focus
        )
        guard !isError else { return RemoteReply(text: "⚠️ " + text, isFailure: true) }
        return RemoteReply(
            text: RemoteResultFormatter.format(tool: call.name, result: text),
            showsTransport: Self.playerTools.contains(call.name)
        )
    }

    private func isAuthorized(_ inbound: RemoteInbound) -> Bool {
        let config = settings.config(for: inbound.platform)
        // Empty allowlist authorizes nobody. A bot token is not a credential —
        // anyone who can message the bot would otherwise own the speakers.
        guard config.allowedSenders.contains(inbound.senderID) else { return false }
        // An empty channel list means "any channel this bot can see"; senders
        // are still checked, so this narrows rather than grants.
        guard config.allowedChannels.isEmpty || config.allowedChannels.contains(inbound.channelID)
        else { return false }
        return true
    }

    private func firstWord(of text: String) -> String {
        String(text.split(separator: " ").first ?? "that")
    }

    /// Tools that resolve a free-text query, and so can fail on the words
    /// rather than on the intent — the ones worth a second reading.
    private static let queryTools: Set<String> = [
        "music_play", "music_queue_add", "music_play_next", "music_search",
        "music_play_playlist", "music_start_radio", "music_add_to_playlist", "music_like",
    ]

    /// Tools whose result leaves the user looking at playback state, and which
    /// therefore deserve transport buttons under the reply.
    private static let playerTools: Set<String> = [
        "music_play", "music_pause", "music_resume", "music_next", "music_previous",
        "music_now_playing", "music_play_playlist", "music_build_mix", "music_start_radio",
        "music_seek", "music_play_next", "music_queue_add", "music_set_volume",
    ]

    static let helpText = """
    *Baton*

    *Playback* — `play <what>` · `pause` · `resume` · `next` · `prev` · `stop`
    *Queue* — `queue <what>` · `playnext <what>` · `queue` (show it)
    *Sound* — `vol 0–100` · `seek 1:30` · `shuffle on|off` · `repeat off|all|one`
    *Library* — `search <what>` · `like` · `unlike` · `rate 0–5` · `playlists` · `playlist <name>`
    *More* — `mix <vibe>` · `radio <seed>` · `sleep 30` · `np` (now playing) · `forget`

    Anything I don't recognize, I'll read as plain English if natural language \
    is switched on in Baton → Settings → Remote.
    """
}

// MARK: - Result formatting

/// Turns tool output into something worth reading in a chat window. Several
/// tools already return a human sentence ("Music volume set to 70."); the rest
/// return JSON aimed at agents, which is unreadable on a phone. Unknown shapes
/// pass through untouched rather than being mangled.
enum RemoteResultFormatter {
    /// Above this many playlists, listing them stops being useful and the count
    /// plus "name one" is the better answer.
    static let playlistListLimit = 15

    static func format(tool: String, result: String) -> String {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return result } // already a plain sentence

        switch tool {
        case "music_now_playing":
            return nowPlaying(json)

        case "music_play", "music_play_next":
            guard let playing = json["playing"] as? [String: Any] else { return compact(json) }
            let queued = json["queued"] as? Int
            let head = "▶︎ " + describe(playing)
            return queued.map { "\(head)\n\($0) track\($0 == 1 ? "" : "s") queued" } ?? head

        case "music_search":
            return search(json)

        case "music_get_queue":
            return queue(json)

        case "music_play_playlist":
            guard let name = json["playing_playlist"] as? String else { return compact(json) }
            var out = "▶︎ Playlist “\(name)”"
            if let tracks = json["tracks"] as? Int { out += " — \(tracks) track\(tracks == 1 ? "" : "s")" }
            if let track = json["now_playing"] as? [String: Any] {
                out += "\nStarting with " + describe(track)
            }
            return out

        case "music_build_mix":
            guard let mix = json["mix"] as? String ?? json["name"] as? String else { return compact(json) }
            var out = json["action"] as? String == "playlist"
                ? "Saved mix “\(mix)”" : "▶︎ Mix “\(mix)”"
            if let count = json["track_count"] as? Int { out += " — \(count) tracks" }
            if let minutes = json["total_minutes"] as? Int { out += ", \(minutes) min" }
            if let track = json["now_playing"] as? [String: Any] {
                out += "\nStarting with " + describe(track)
            }
            return out

        case "music_list_playlists":
            let playlists = json["playlists"] as? [[String: Any]] ?? []
            guard !playlists.isEmpty else { return "No playlists on the server." }
            func line(_ item: [String: Any]) -> String {
                let name = item["name"] as? String ?? "—"
                let count = item["song_count"] as? Int
                return count.map { "• \(name) (\($0))" } ?? "• \(name)"
            }
            // A short list is worth printing. A long one is not: twenty-five rows
            // of "02 - Classic Trance (Pt 17)" and "…and 296 more" is a wall of
            // text you cannot act on. Past that, the count and *how to open one*
            // are the useful facts — and partial names match, so saying so is
            // more use than any subset of the names could be.
            guard playlists.count > Self.playlistListLimit else {
                return playlists.map(line).joined(separator: "\n")
            }
            let sample = playlists.prefix(5).map(line).joined(separator: "\n")
            return """
            *\(playlists.count) playlists* — too many to list.

            Play one by name: `playlist <name>`. Part of the name is enough, so             `playlist trance` finds the first playlist with "trance" in it.

            \(sample)
            …and \(playlists.count - 5) more
            """

        default:
            return compact(json)
        }
    }

    private static func nowPlaying(_ json: [String: Any]) -> String {
        let state = json["state"] as? String ?? "unknown"
        guard let track = json["now_playing"] as? [String: Any] else {
            return state == "stopped" ? "Nothing playing." : "Player is \(state)."
        }
        let icon = state == "playing" ? "▶︎" : (state == "paused" ? "❚❚" : "•")
        var out = "\(icon) " + describe(track)
        if let index = json["queue_index"] as? Int, let length = json["queue_length"] as? Int {
            out += "\nTrack \(index + 1) of \(length)"
        }
        return out
    }

    private static func search(_ json: [String: Any]) -> String {
        var sections: [String] = []
        if let songs = json["songs"] as? [[String: Any]], !songs.isEmpty {
            sections.append("*Songs*\n" + songs.prefix(10).map { "• " + describe($0) }.joined(separator: "\n"))
        }
        if let albums = json["albums"] as? [[String: Any]], !albums.isEmpty {
            let lines = albums.prefix(5).map { album -> String in
                let name = album["name"] as? String ?? "—"
                let artist = album["artist"] as? String
                return artist.map { "• \(name) — \($0)" } ?? "• \(name)"
            }
            sections.append("*Albums*\n" + lines.joined(separator: "\n"))
        }
        if let artists = json["artists"] as? [[String: Any]], !artists.isEmpty {
            let names = artists.prefix(5).compactMap { $0["name"] as? String }
            sections.append("*Artists*\n" + names.map { "• \($0)" }.joined(separator: "\n"))
        }
        return sections.isEmpty ? "Nothing matched." : sections.joined(separator: "\n\n")
    }

    private static func queue(_ json: [String: Any]) -> String {
        let tracks = json["tracks"] as? [[String: Any]] ?? json["queue"] as? [[String: Any]] ?? []
        guard !tracks.isEmpty else { return "The queue is empty." }
        let current = json["queue_index"] as? Int ?? json["current_index"] as? Int
        let lines = tracks.prefix(15).enumerated().map { index, track -> String in
            let marker = index == current ? "▶︎" : "\(index + 1)."
            return "\(marker) " + describe(track)
        }
        let more = tracks.count > 15 ? "\n…and \(tracks.count - 15) more" : ""
        return lines.joined(separator: "\n") + more
    }

    private static func describe(_ track: [String: Any]) -> String {
        let title = track["title"] as? String ?? "Unknown"
        let artist = track["artist"] as? String
        let duration = (track["duration_seconds"] as? Int).map(clock)
        var out = artist.map { "\(title) — \($0)" } ?? title
        if let duration { out += " (\(duration))" }
        return out
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Last resort for a shape with no bespoke renderer: flatten the top level
    /// into `key: value` lines rather than showing raw JSON braces.
    private static func compact(_ json: [String: Any]) -> String {
        let lines = json.keys.sorted().compactMap { key -> String? in
            let value = json[key]
            if value is [Any] || value is [String: Any] { return nil }
            let label = key.replacingOccurrences(of: "_", with: " ")
            return "\(label.prefix(1).uppercased() + label.dropFirst()): \(value ?? "")"
        }
        return lines.isEmpty ? "Done." : lines.joined(separator: "\n")
    }
}
