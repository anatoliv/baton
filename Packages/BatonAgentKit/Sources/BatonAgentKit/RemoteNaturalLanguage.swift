import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// The tool catalog, boxed to cross an actor boundary. JSON-as-`[[String: Any]]`
/// isn't `Sendable`, but this value is built once from the MCP catalog and never
/// mutated afterwards, so the unchecked conformance is a statement about that
/// immutability rather than a suppression.
public struct RemoteToolSchemas: @unchecked Sendable {
    public let json: [[String: Any]]

    public var isEmpty: Bool { json.isEmpty }
}

/// Routes free-text ("put on something mellow", "skip this one") to one of
/// Baton's own MCP tools using a language model's tool-use.
///
/// The tool schemas aren't written twice: `BatonMCPToolCatalog.definitions()` is
/// already a JSON-Schema tool catalog, so this re-shapes the same definitions an
/// MCP client sees (`inputSchema` → `input_schema`) and lets the model pick one.
/// Whatever it picks runs through `BatonMCPToolCatalog.run` — the identical path
/// a typed command or Claude Desktop takes, with no second implementation of
/// playback control to drift out of sync.
///
/// This is the **only** part of remote control that talks to a third party, it
/// is off by default, and it sends just the user's sentence plus the tool list —
/// never library contents, credentials, or listening history.
///
/// That last guarantee is what distinguishes this from `RemoteAgent`, which
/// answers far better precisely because it looks things up — and so cannot make
/// the same promise. Both ship; the choice is the user's, and it is off by
/// default. Keep this path free of library content, or the choice is a fiction.
public enum RemoteNaturalLanguage {
    /// Tools withheld from model routing. `audio_*` are cross-process focus
    /// primitives that aren't user-facing actions, `speak_summary` is for agents
    /// with something to narrate, and `music_delete_playlist` is the one
    /// destructive tool in the catalog — too much to hand to a sentence that was
    /// merely *probably* about deleting something. Type the command for that.
    public static let withheldTools: Set<String> = [
        "audio_suspend", "audio_resume", "speak_summary", "music_delete_playlist",
    ]

    private static let systemPrompt = """
    You control a music player for its owner, who is sending you short messages \
    from a chat app. Translate the message into exactly one tool call.

    Guidance:
    - Prefer the most direct tool. "skip"/"next one" is music_next, not a search.
    - Vibe requests ("something mellow", "focus music") are music_play with the \
    vibe as the query, unless the person asks for a mix of a particular length — \
    then use music_build_mix.
    - Playing, queueing and playing-next are three different tools, and the \
    words matter: music_play starts now and replaces the queue ("play X", "put \
    on X"); music_queue_add appends to the end ("add X", "queue X", "queue up \
    X"); music_play_next inserts after the current track, and only for "play X \
    next" or "after this one".
    - music_start_radio is only for an endless stream seeded from what is \
    already playing ("more like this", "keep this going", "start a radio"). \
    Naming an artist or song is music_play, not radio.
    - When the message names an artist, album, or song, pass it through as the \
    query verbatim rather than rewriting it.
    - If the message is a question about what is playing, use music_now_playing.
    - "this song", "this artist", "more of this" refer to the player state given \
    at the end of this prompt — use the name from there, not the words "this \
    artist", as the query.
    - Use music_search only when the person wants to SEE results ("show me", \
    "find", "do I have"). When they want to HEAR something, pick a playing tool. \
    Never fall back to music_search because you are unsure.
    - Earlier turns are there so follow-ups resolve: "select one of them", "the \
    second one", "play that" refer to what you last listed or played. Pick the \
    specific track from that context and pass its exact title as the query, \
    rather than searching for the words the person just used.
    """

    public struct Resolution: Sendable {
        public var call: RemoteToolCall
        /// The model's own words, when it said something alongside the call.
        public var preamble: String?
    }

    public enum Failure: LocalizedError {
        case notConfigured
        case http(status: Int, body: String)
        case refused(String)
        case noToolCall(String)
        case truncated
        case localNetworkBlocked(host: String)
        case unreachable(host: String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Natural language isn't set up. Turn it on in Baton → Settings → Remote."
            case let .http(status, body):
                "The model provider returned \(status). \(body)" + RemoteNaturalLanguage.hint(status: status, body: body)
            case let .refused(reason):
                "The model declined that request. \(reason)"
            case let .noToolCall(text):
                text.isEmpty ? "I couldn't turn that into a playback command." : text
            case .truncated:
                "The model ran out of room before it picked a command. Try a shorter request."
            case let .localNetworkBlocked(host):
                """
                Couldn't reach \(host). Baton is clearly online — this message got through — \
                so macOS is most likely blocking access to your local network. Allow it in \
                System Settings → Privacy & Security → Local Network.
                """
            case let .unreachable(host):
                "Nothing answered at \(host). Check the server is running and the address is right."
            case let .malformed(detail):
                "Unexpected response from the model provider: \(detail)"
            }
        }
    }

    // MARK: - Entry point

    /// Ask the model which tool to run. Throws rather than guessing: a failure
    /// here should tell the user why, not silently do something unintended.
    public static func resolve(
        _ message: String,
        config: RemoteControlSettings.NaturalLanguageConfig,
        tools: RemoteToolSchemas,
        history: [RemoteConversationLog.Turn] = [],
        playerContext: String? = nil,
        session: URLSession = .shared
    ) async throws -> Resolution {
        guard config.isConfigured else { throw Failure.notConfigured }

        let request = try buildRequest(
            message, config: config, tools: tools, history: history, playerContext: playerContext)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // "The Internet connection appears to be offline" is what macOS says
            // when it blocks an app from the *local* network, and it is a lie the
            // user can see through — the chat message that triggered this arrived
            // over the internet moments ago. Name the real gate.
            throw transportFailure(error, host: request.url?.host ?? config.baseURL)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(status: http.statusCode, body: errorMessage(from: data))
        }
        return try parse(data, provider: config.provider)
    }

    /// Distinguish "macOS won't let this app touch the LAN" from "that host
    /// isn't answering" — they look identical from here and need different fixes.
    public static func transportFailure(_ error: URLError, host: String) -> Failure {
        switch error.code {
        case .notConnectedToInternet where isPrivate(host):
            return .localNetworkBlocked(host: host)
        case .cannotConnectToHost, .cannotFindHost, .timedOut:
            return .unreachable(host: host)
        default:
            return .malformed(error.localizedDescription)
        }
    }

    /// RFC-1918, loopback, and the names macOS treats as local.
    public static func isPrivate(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasPrefix("127.") || h.hasPrefix("10.") { return true }
        if h.hasPrefix("192.168.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    /// Not every provider answers an unusable key with a plain 401. LiteLLM —
    /// the most common way to front local models — returns `400 "No connected
    /// db."`, because it falls through to looking the key up in a database it
    /// hasn't got. Relaying that verbatim is accurate and useless; name the
    /// likely cause instead of making the reader learn the provider's internals.
    public static func hint(status: Int, body: String) -> String {
        let text = body.lowercased()
        if text.contains("no connected db") || text.contains("no_db_connection") {
            return " That's how LiteLLM reports a key it can't recognize — check you're using the key that server expects."
        }
        if status == 401 || status == 403 || text.contains("authentication") {
            return " Check the API key."
        }
        if status == 404 || (status == 400 && text.contains("model")) {
            return " Check the model name and the base URL."
        }
        return ""
    }

    // MARK: - Self-test

    /// The result of a connection test, phrased for someone reading Settings.
    public enum TestOutcome: Sendable {
        case ok(String)
        case failed(String)
    }

    /// Catch the settings mistakes that are visible without spending a request.
    /// Worth doing separately: an HTTP error from a wrong URL is far less
    /// legible than being told which field is wrong.
    public static func complaint(about config: RemoteControlSettings.NaturalLanguageConfig) -> String? {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces).lowercased()
        guard !base.isEmpty else { return "The API base URL is empty." }
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else {
            return "The API base URL should start with https:// (or http:// on your own network)."
        }
        // A URL from one dialect with the other one selected is the single most
        // likely misconfiguration, and the resulting 404 explains nothing. The
        // fix is a picker away, so say which way to move it.
        switch config.provider {
        case .anthropic:
            if base.contains("openai.com") || base.contains("/chat/completions") {
                return "That's an OpenAI-style endpoint — set Provider to “OpenAI-compatible”."
            }
        case .openAICompatible:
            if base.contains("api.anthropic.com") {
                return "That's Anthropic's endpoint — set Provider to “Anthropic”."
            }
        }
        if config.apiKey.isEmpty { return "No API key yet." }
        if config.model.trimmingCharacters(in: .whitespaces).isEmpty { return "No model set." }
        return nil
    }

    /// Run one real request end to end and describe what happened. Deliberately
    /// the *production* path — same headers, same body, same parsing — so a pass
    /// means the next chat message will work, not merely that a server answered.
    public static func test(
        config: RemoteControlSettings.NaturalLanguageConfig,
        tools: RemoteToolSchemas,
        session: URLSession = .shared
    ) async -> TestOutcome {
        if let complaint = complaint(about: config) { return .failed(complaint) }
        do {
            // A probe that must resolve to one obvious tool, so a pass proves the
            // model understood the catalog rather than merely returning 200.
            let resolution = try await resolve("pause the music", config: config, tools: tools, session: session)
            guard resolution.call.name == "music_pause" else {
                return .ok("Connected to \(config.model), though it chose \(resolution.call.name) for “pause the music”.")
            }
            return .ok("Connected. \(config.model) understood the test request.")
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Request

    /// The endpoint to POST to. Tolerant of the two ways people naturally paste a
    /// base URL — the bare root, or the full endpoint copied out of a provider's
    /// docs — because silently appending a second path is a 404 with nothing to
    /// explain it.
    public static func endpoint(for config: RemoteControlSettings.NaturalLanguageConfig) throws -> URL {
        var base = config.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }

        let path: String
        switch config.provider {
        case .anthropic:
            for suffix in ["/v1/messages", "/v1"] where base.hasSuffix(suffix) {
                base.removeLast(suffix.count)
                break
            }
            path = "/v1/messages"
        case .openAICompatible:
            if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
            if base.hasSuffix("/v1") { base.removeLast("/v1".count) }
            path = "/v1/chat/completions"
        }

        guard let url = URL(string: base + path) else {
            throw Failure.malformed("bad base URL \(config.baseURL)")
        }
        return url
    }

    public static func buildRequest(
        _ message: String,
        config: RemoteControlSettings.NaturalLanguageConfig,
        tools: RemoteToolSchemas,
        history: [RemoteConversationLog.Turn] = [],
        playerContext: String? = nil
    ) throws -> URLRequest {
        // The player's live state rides at the END of the system prompt: it is
        // the one part that changes per request, and both dialects treat the
        // system prompt's tail as the cheapest place for volatile context.
        let system = playerContext.map { systemPrompt + "\n\n" + $0 } ?? systemPrompt
        // Prior turns first, this message last. Both dialects use the same
        // role names, so the transcript is built once.
        let priorTurns = history.map { ["role": $0.role, "content": $0.text] }
        let transcript = priorTurns + [["role": "user", "content": message]]

        var request = URLRequest(url: try endpoint(for: config))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any]
        switch config.provider {
        case .anthropic:
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            body = [
                "model": config.model,
                "max_tokens": 8192,
                "system": system,
                // Force a tool call: the model's job here is routing, not chatting.
                "tool_choice": ["type": "any"],
                // Routing is a shallow task; low effort keeps a chat reply snappy.
                // (Thinking is left at the model's default rather than disabled —
                // disabling it is what makes some models emit a tool call as plain
                // text instead of a structured one.)
                "output_config": ["effort": "low"],
                "tools": tools.json,
                "messages": transcript,
            ]

        case .openAICompatible:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            // No token cap: this dialect split `max_tokens` into
            // `max_completion_tokens` on newer models, and sending the wrong one
            // is a 400. The reply is a single tool call either way, so the cap
            // buys nothing worth that incompatibility.
            body = [
                "model": config.model,
                "tool_choice": "required",
                // Same schemas, third spelling: MCP says `inputSchema`, Anthropic
                // says `input_schema`, this dialect nests them under `function`
                // and says `parameters`.
                "tools": tools.json.map { schema -> [String: Any] in
                    ["type": "function", "function": [
                        "name": schema["name"] ?? "",
                        "description": schema["description"] ?? "",
                        "parameters": schema["input_schema"] ?? [:],
                    ]]
                },
                "messages": [["role": "system", "content": system]] + transcript,
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Re-shape the MCP catalog into the Messages API's tool format. MCP spells
    /// the schema key `inputSchema`; the Messages API spells it `input_schema`.
    public static func toolSchemas(from definitions: [[String: Any]]) -> RemoteToolSchemas {
        RemoteToolSchemas(json: definitions.compactMap { def in
            guard let name = def["name"] as? String,
                  !withheldTools.contains(name),
                  let description = def["description"] as? String,
                  var schema = def["inputSchema"] as? [String: Any]
            else { return nil }
            // Chat replies never show ids, so any id the model passes here is
            // invented by construction — the evaluation caught it fabricating
            // song_ids. Remove the temptation and it uses `query`/`name`, which
            // the tools resolve properly. (Agents keep the full schemas; this
            // narrowing is only for the chat surface.)
            if var props = schema["properties"] as? [String: Any] {
                props.removeValue(forKey: "song_ids")
                props.removeValue(forKey: "playlist_id")
                schema["properties"] = props
            }
            return ["name": name, "description": description, "input_schema": schema]
        })
    }

    // MARK: - Response

    public static func parse(
        _ data: Data,
        provider: RemoteControlSettings.LLMProvider = .anthropic
    ) throws -> Resolution {
        switch provider {
        case .anthropic: try parseAnthropic(data)
        case .openAICompatible: try parseOpenAI(data)
        }
    }

    /// `choices[0].message.tool_calls[0].function` — and `arguments` is a JSON
    /// *string*, not an object, so it needs a second decode.
    private static func parseOpenAI(_ data: Data) throws -> Resolution {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("response was not a JSON object")
        }
        guard let choice = (root["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw Failure.malformed("response had no choices")
        }

        let text = (message["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let call = (message["tool_calls"] as? [[String: Any]])?.first,
              let function = call["function"] as? [String: Any],
              let name = function["name"] as? String
        else {
            if choice["finish_reason"] as? String == "length" { throw Failure.truncated }
            throw Failure.noToolCall(text)
        }

        var arguments: [String: Any] = [:]
        if let raw = function["arguments"] as? String, !raw.isEmpty,
           let decoded = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            arguments = decoded
        }

        return Resolution(
            call: RemoteToolCall(name: name, arguments: coerce(arguments)),
            preamble: text.isEmpty ? nil : text
        )
    }

    private static func parseAnthropic(_ data: Data) throws -> Resolution {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("response was not a JSON object")
        }
        guard let content = root["content"] as? [[String: Any]] else {
            throw Failure.malformed("response had no content array")
        }

        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A safety decline arrives as a successful response with this stop
        // reason and (usually) empty content — check it before reading content.
        if root["stop_reason"] as? String == "refusal" {
            let detail = (root["stop_details"] as? [String: Any])?["explanation"] as? String
            throw Failure.refused(detail ?? text)
        }

        guard let use = content.first(where: { $0["type"] as? String == "tool_use" }),
              let name = use["name"] as? String
        else {
            // Thinking counts against max_tokens, so a long deliberation can end
            // the response before the tool call is ever emitted. That arrives
            // here as "no tool call", which would otherwise be reported as though
            // the sentence were unroutable — a misleading answer to a budget problem.
            if root["stop_reason"] as? String == "max_tokens" {
                throw Failure.truncated
            }
            throw Failure.noToolCall(text)
        }

        let input = use["input"] as? [String: Any] ?? [:]
        return Resolution(
            call: RemoteToolCall(name: name, arguments: coerce(input)),
            preamble: text.isEmpty ? nil : text
        )
    }

    /// Narrow the model's JSON to the argument types Baton's tools accept.
    /// Anything else (nested objects, arrays) is dropped rather than passed
    /// through half-formed — the tools validate their own inputs regardless.
    public static func coerceArguments(_ input: [String: Any]) -> [String: RemoteArgument] {
        coerce(input)
    }

    private static func coerce(_ input: [String: Any]) -> [String: RemoteArgument] {
        var out: [String: RemoteArgument] = [:]
        for (key, value) in input {
            if let string = value as? String {
                out[key] = .string(string)
            } else if let number = value as? NSNumber {
                // `as? Bool` is useless here: JSONSerialization hands back
                // NSNumber for both, and NSNumber(1) casts to `true`. The
                // underlying CFType is the only honest discriminator — without
                // it, `music_set_volume {"percent": 1}` arrives as `true`.
                #if canImport(Darwin)
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    out[key] = .bool(number.boolValue)
                } else {
                    out[key] = .int(number.intValue)
                }
                #else
                // swift-corelibs-foundation has no CF type IDs, but tags a JSON
                // boolean's NSNumber with the char encoding ("c") — the same
                // distinction, spelled the way this Foundation spells it.
                if number.objCType.pointee == Int8(UInt8(ascii: "c")) {
                    out[key] = .bool(number.boolValue)
                } else {
                    out[key] = .int(number.intValue)
                }
                #endif
            }
        }
        return out
    }

    public static func errorBody(from data: Data) -> String { errorMessage(from: data) }

    private static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return String(data: data.prefix(200), encoding: .utf8) ?? "" }
        return message
    }
}
