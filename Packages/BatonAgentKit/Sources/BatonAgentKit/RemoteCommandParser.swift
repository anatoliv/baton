import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

// MARK: - Tool call

/// A JSON value narrow enough to describe every argument Baton's MCP tools take.
/// Typed (rather than `[String: Any]`) so parsing stays `Sendable` and directly
/// equatable in tests; it widens to the catalog's `[String: Any]` at dispatch.
public enum RemoteArgument: Equatable, Sendable {
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
public struct RemoteToolCall: Equatable, Sendable {
    public var name: String
    public var arguments: [String: RemoteArgument] = [:]

    public var jsonArguments: [String: Any] { arguments.mapValues(\.jsonValue) }
}

// MARK: - Action

/// What an inbound chat message resolves to.
public enum RemoteAction: Equatable, Sendable {
    /// Run a tool and reply with its result.
    case tool(RemoteToolCall)
    /// Print the command list.
    case help
    /// `/link <code>` — authorize this sender.
    case link(code: String)
    /// Not a recognized command; hand to the LLM tool-picker if one is configured.
    case natural(String)
    /// Drop the remembered conversation for this chat.
    case forget
    /// A known verb whose argument didn't fit its narrow grammar — "rate 4 this
    /// track and list similar by the same artist". The words plainly mean
    /// something; they just aren't the two-token shape the verb expects.
    case malformed(verb: String, text: String, hint: String)
    /// Show the durable memories Baton keeps.
    case memories
    /// Delete one durable memory, or all of them.
    case forgetMemory(id: Int?)
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
public enum RemoteCommandParser {
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
            guard !rest.isEmpty else { return malformed(verb, text, "`playnext` needs something to slot in — like `playnext dido`.") }
            return .tool(.init(name: "music_play_next", arguments: ["query": .string(rest)]))

        // — volume & position ----------------------------------------------
        case "vol", "volume", "v":
            guard let percent = Int(rest.trimmingCharacters(in: .whitespaces)),
                  (0...100).contains(percent) else { return malformed(verb, text, "`vol` takes a number from 0 to 100 — like `vol 40`.") }
            return .tool(.init(name: "music_set_volume", arguments: ["percent": .int(percent)]))

        case "seek":
            guard let seconds = parseDuration(rest) else { return malformed(verb, text, "`seek` takes a position — `seek 1:30`, `seek 90`, or `seek 1m30s`.") }
            return .tool(.init(name: "music_seek", arguments: ["seconds": .int(seconds)]))

        // — status ----------------------------------------------------------
        case "np", "now", "nowplaying", "status", "playing":
            return .tool(.init(name: "music_now_playing"))

        case "search", "find", "s":
            // "search for dido" is not a search for the word "for". Navidrome
            // ANDs the terms, so a preposition carried into the query silently
            // narrows the result set: it drops every Dido album and artist and
            // keeps only tracks that also have a word starting "for"
            // ("Forgotten Love"). Dropping a term can only widen an AND query,
            // so the thing actually wanted stays in the results.
            let query = withoutLeadingConnector(rest)
            guard !query.isEmpty else { return malformed(verb, text, "`search` needs something to look for — like `search dido`.") }
            return .tool(.init(name: "music_search", arguments: ["query": .string(query)]))

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
            guard let stars = Int(rest.trimmingCharacters(in: .whitespaces)),
                  (0...5).contains(stars) else { return malformed(verb, text, "`rate` takes a number from 0 to 5 — like `rate 4`.") }
            return .tool(.init(name: "music_rate", arguments: ["rating": .int(stars)]))

        case "playlists": return .tool(.init(name: "music_list_playlists"))

        case "playlist":
            guard !rest.isEmpty else { return .tool(.init(name: "music_list_playlists")) }
            return .tool(.init(name: "music_play_playlist", arguments: ["name": .string(rest)]))

        case "mix":
            guard !rest.isEmpty else { return malformed(verb, text, "`mix` needs a vibe — like `mix upbeat focus`.") }
            return .tool(.init(name: "music_build_mix", arguments: ["prompt": .string(rest)]))

        case "radio":
            guard !rest.isEmpty else { return malformed(verb, text, "`radio` needs something to seed from — or just `radio` while something plays.") }
            return .tool(.init(name: "music_start_radio", arguments: ["query": .string(rest)]))

        // — modes -------------------------------------------------------------
        case "shuffle":
            guard let on = parseSwitch(rest) else { return malformed(verb, text, "`shuffle` takes on or off.") }
            return .tool(.init(name: "music_set_shuffle", arguments: ["enabled": .bool(on)]))

        case "repeat":
            let mode = rest.trimmingCharacters(in: .whitespaces).lowercased()
            let normalized: String
            switch mode {
            case "off", "none", "no": normalized = "off"
            case "all", "queue", "on": normalized = "all"
            case "one", "single", "track", "song": normalized = "one"
            default: return malformed(verb, text, "`repeat` takes off, all, or one.")
            }
            return .tool(.init(name: "music_set_repeat", arguments: ["mode": .string(normalized)]))

        case "sleep":
            // `sleep off` cancels; `sleep 30` sets 30 minutes. The tool treats
            // 0 minutes as "cancel any armed timer".
            let arg = rest.trimmingCharacters(in: .whitespaces).lowercased()
            if arg == "off" || arg == "cancel" {
                return .tool(.init(name: "music_sleep_timer", arguments: ["minutes": .int(0)]))
            }
            guard let minutes = Int(arg), minutes > 0 else { return malformed(verb, text, "`sleep` takes minutes — `sleep 30` — or `sleep off` to cancel.") }
            return .tool(.init(name: "music_sleep_timer", arguments: ["minutes": .int(minutes)]))

        // — meta ---------------------------------------------------------------
        case "memories", "memory":
            return .memories

        case "forget", "reset", "clear", "nevermind":
            // Bare `forget` has always meant "drop this conversation". With an
            // argument it means the durable store instead — distinct things,
            // and the word people reach for is the same for both.
            let argument = rest.trimmingCharacters(in: .whitespaces).lowercased()
            if argument.isEmpty { return .forget }
            if argument == "everything" || argument == "all" || argument == "memories" {
                return .forgetMemory(id: nil)
            }
            if let id = Int(argument) { return .forgetMemory(id: id) }
            return .forget

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

    /// A verb matched but its argument didn't. Dumping the command list here is
    /// what made "rate 4 this track and list similar by the same artist" answer
    /// with the help screen: the parser claimed `rate`, failed to read "4 this
    /// track…" as a bare integer, and gave up somewhere the model could never
    /// be reached. Anything with words in it goes to the model instead; the
    /// hint is what a person sees when there is no model to ask.
    private static func malformed(_ verb: String, _ text: String, _ hint: String) -> RemoteAction {
        .malformed(verb: verb, text: text, hint: hint)
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

    /// Words the search verb itself implies — "search **for** x", "find **me** x".
    /// Deliberately tiny: anything less obviously grammatical belongs to the
    /// query, because a wrongly-dropped term is a wrongly-answered search.
    private static let leadingConnectors: Set<String> = ["for", "me", "us"]

    private static func withoutLeadingConnector(_ rest: String) -> String {
        var words = rest.split(separator: " ")
        guard words.count > 1, leadingConnectors.contains(words[0].lowercased()) else { return rest }
        words.removeFirst()
        return words.joined(separator: " ")
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
