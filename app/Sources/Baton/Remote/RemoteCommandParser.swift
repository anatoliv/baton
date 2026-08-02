import Foundation

// MARK: - Tool call

/// A JSON value narrow enough to describe every argument Baton's MCP tools take.
/// Typed (rather than `[String: Any]`) so parsing stays `Sendable` and directly
/// equatable in tests; it widens to the catalog's `[String: Any]` at dispatch.
enum RemoteArgument: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    var jsonValue: Any {
        switch self {
        case let .string(s): s
        case let .int(i): i
        case let .bool(b): b
        }
    }
}

/// One resolved call against `BatonMCPToolCatalog` — the same tool surface an AI
/// agent drives, so a chat command and an agent command take identical paths.
struct RemoteToolCall: Equatable, Sendable {
    var name: String
    var arguments: [String: RemoteArgument] = [:]

    var jsonArguments: [String: Any] { arguments.mapValues(\.jsonValue) }
}

// MARK: - Action

/// What an inbound chat message resolves to.
enum RemoteAction: Equatable, Sendable {
    /// Run a tool and reply with its result.
    case tool(RemoteToolCall)
    /// Print the command list.
    case help
    /// `/link <code>` — authorize this sender.
    case link(code: String)
    /// Not a recognized command; hand to the LLM tool-picker if one is configured.
    case natural(String)
    /// Message was empty or contained only a bot mention.
    case ignore
}

// MARK: - Parser

/// Text → action. Deterministic, offline, and allocation-cheap: the common
/// remote-control verbs never pay LLM latency or cost, and everything else falls
/// through to `.natural` for the model to route.
///
/// Case-insensitive, leading `/` optional (Telegram sends `/pause`, a Discord
/// message is more likely to say `pause`), and Telegram's `/pause@BotName`
/// suffix is stripped.
enum RemoteCommandParser {
    static func parse(_ raw: String) -> RemoteAction {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignore }

        // Split verb from the rest, normalizing `/verb@BotName`.
        var (verb, rest) = split(text)
        if verb.hasPrefix("/") { verb.removeFirst() }
        if let at = verb.firstIndex(of: "@") { verb = String(verb[verb.startIndex..<at]) }
        verb = verb.lowercased()

        switch verb {
        // — transport ------------------------------------------------------
        case "pause": return .tool(.init(name: "music_pause"))
        case "resume", "unpause", "continue": return .tool(.init(name: "music_resume"))
        case "stop": return .tool(.init(name: "music_stop"))
        case "next", "skip", "n": return .tool(.init(name: "music_next"))
        case "prev", "previous", "back", "b": return .tool(.init(name: "music_previous"))

        case "play", "p":
            // Bare `play` is "resume", not "play nothing" — the button-shaped
            // reading of the word. With an argument it's a search-and-play.
            guard !rest.isEmpty else { return .tool(.init(name: "music_resume")) }
            return .tool(.init(name: "music_play", arguments: ["query": .string(rest)]))

        case "queue", "add", "q":
            guard !rest.isEmpty else { return .tool(.init(name: "music_get_queue")) }
            return .tool(.init(name: "music_queue_add", arguments: ["query": .string(rest)]))

        case "playnext":
            guard !rest.isEmpty else { return .help }
            return .tool(.init(name: "music_play_next", arguments: ["query": .string(rest)]))

        // — volume & position ----------------------------------------------
        case "vol", "volume", "v":
            guard let percent = Int(rest.trimmingCharacters(in: .whitespaces)),
                  (0...100).contains(percent) else { return .help }
            return .tool(.init(name: "music_set_volume", arguments: ["percent": .int(percent)]))

        case "seek":
            guard let seconds = parseDuration(rest) else { return .help }
            return .tool(.init(name: "music_seek", arguments: ["seconds": .int(seconds)]))

        // — status ----------------------------------------------------------
        case "np", "now", "nowplaying", "status", "playing":
            return .tool(.init(name: "music_now_playing"))

        case "search", "find", "s":
            guard !rest.isEmpty else { return .help }
            return .tool(.init(name: "music_search", arguments: ["query": .string(rest)]))

        // — library ---------------------------------------------------------
        case "like", "fav", "favorite", "star":
            var call = RemoteToolCall(name: "music_like")
            if !rest.isEmpty { call.arguments["query"] = .string(rest) }
            return .tool(call)

        case "unlike", "unfav", "unstar":
            var call = RemoteToolCall(name: "music_like", arguments: ["unlike": .bool(true)])
            if !rest.isEmpty { call.arguments["query"] = .string(rest) }
            return .tool(call)

        case "rate":
            guard let stars = Int(rest.trimmingCharacters(in: .whitespaces)), (0...5).contains(stars) else { return .help }
            return .tool(.init(name: "music_rate", arguments: ["rating": .int(stars)]))

        case "playlists": return .tool(.init(name: "music_list_playlists"))

        case "playlist":
            guard !rest.isEmpty else { return .tool(.init(name: "music_list_playlists")) }
            return .tool(.init(name: "music_play_playlist", arguments: ["name": .string(rest)]))

        case "mix":
            guard !rest.isEmpty else { return .help }
            return .tool(.init(name: "music_build_mix", arguments: ["prompt": .string(rest)]))

        case "radio":
            guard !rest.isEmpty else { return .help }
            return .tool(.init(name: "music_start_radio", arguments: ["query": .string(rest)]))

        // — modes -------------------------------------------------------------
        case "shuffle":
            guard let on = parseSwitch(rest) else { return .help }
            return .tool(.init(name: "music_set_shuffle", arguments: ["enabled": .bool(on)]))

        case "repeat":
            let mode = rest.trimmingCharacters(in: .whitespaces).lowercased()
            let normalized: String
            switch mode {
            case "off", "none", "no": normalized = "off"
            case "all", "queue", "on": normalized = "all"
            case "one", "single", "track", "song": normalized = "one"
            default: return .help
            }
            return .tool(.init(name: "music_set_repeat", arguments: ["mode": .string(normalized)]))

        case "sleep":
            // `sleep off` cancels; `sleep 30` sets 30 minutes. The tool treats
            // 0 minutes as "cancel any armed timer".
            let arg = rest.trimmingCharacters(in: .whitespaces).lowercased()
            if arg == "off" || arg == "cancel" {
                return .tool(.init(name: "music_sleep_timer", arguments: ["minutes": .int(0)]))
            }
            guard let minutes = Int(arg), minutes > 0 else { return .help }
            return .tool(.init(name: "music_sleep_timer", arguments: ["minutes": .int(minutes)]))

        // — meta ---------------------------------------------------------------
        case "help", "commands", "start", "h", "?":
            return .help

        case "link":
            let code = rest.trimmingCharacters(in: .whitespaces)
            return code.isEmpty ? .help : .link(code: code)

        case "ask", "hey", "baton":
            // Explicit escape hatch to the language model, so a phrase that
            // collides with a verb ("play something quiet") can still be routed
            // by intent rather than by keyword.
            return rest.isEmpty ? .help : .natural(rest)

        default:
            return .natural(text)
        }
    }

    // MARK: Helpers

    private static func split(_ text: String) -> (verb: String, rest: String) {
        guard let space = text.firstIndex(where: { $0 == " " || $0 == "\n" }) else {
            return (text, "")
        }
        let verb = String(text[text.startIndex..<space])
        let rest = String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (verb, rest)
    }

    private static func parseSwitch(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "on", "yes", "true", "1", "enable", "enabled": true
        case "off", "no", "false", "0", "disable", "disabled": false
        default: nil
        }
    }

    /// `90`, `1:30`, and `1m30s` all mean ninety seconds.
    static func parseDuration(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if let plain = Int(trimmed) { return plain >= 0 ? plain : nil }

        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let minutes = Int(parts[0]), let seconds = Int(parts[1]),
                  minutes >= 0, (0..<60).contains(seconds) else { return nil }
            return minutes * 60 + seconds
        }

        // `1m30s` / `2m` / `45s`
        var total = 0, digits = ""
        var sawUnit = false
        for ch in trimmed {
            if ch.isNumber { digits.append(ch); continue }
            guard let value = Int(digits) else { return nil }
            switch ch {
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            digits = ""
            sawUnit = true
        }
        guard sawUnit, digits.isEmpty else { return nil }
        return total
    }
}
