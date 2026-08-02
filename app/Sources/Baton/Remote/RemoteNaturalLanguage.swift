import Foundation

/// The tool catalog, boxed to cross an actor boundary. JSON-as-`[[String: Any]]`
/// isn't `Sendable`, but this value is built once from the MCP catalog and never
/// mutated afterwards, so the unchecked conformance is a statement about that
/// immutability rather than a suppression.
struct RemoteToolSchemas: @unchecked Sendable {
    let json: [[String: Any]]

    var isEmpty: Bool { json.isEmpty }
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
enum RemoteNaturalLanguage {
    /// Tools withheld from model routing. `audio_*` are cross-process focus
    /// primitives that aren't user-facing actions, `speak_summary` is for agents
    /// with something to narrate, and `music_delete_playlist` is the one
    /// destructive tool in the catalog — too much to hand to a sentence that was
    /// merely *probably* about deleting something. Type the command for that.
    static let withheldTools: Set<String> = [
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
    - "more like this" / "keep this going" is music_start_radio.
    - When the message names an artist, album, or song, pass it through as the \
    query verbatim rather than rewriting it.
    - If the message is a question about what is playing, use music_now_playing.
    """

    struct Resolution: Sendable {
        var call: RemoteToolCall
        /// The model's own words, when it said something alongside the call.
        var preamble: String?
    }

    enum Failure: LocalizedError {
        case notConfigured
        case http(status: Int, body: String)
        case refused(String)
        case noToolCall(String)
        case truncated
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Natural language isn't set up. Turn it on in Baton → Settings → Remote."
            case let .http(status, body):
                "The model provider returned \(status). \(body)"
            case let .refused(reason):
                "The model declined that request. \(reason)"
            case let .noToolCall(text):
                text.isEmpty ? "I couldn't turn that into a playback command." : text
            case .truncated:
                "The model ran out of room before it picked a command. Try a shorter request."
            case let .malformed(detail):
                "Unexpected response from the model provider: \(detail)"
            }
        }
    }

    // MARK: - Entry point

    /// Ask the model which tool to run. Throws rather than guessing: a failure
    /// here should tell the user why, not silently do something unintended.
    static func resolve(
        _ message: String,
        config: RemoteControlSettings.NaturalLanguageConfig,
        tools: RemoteToolSchemas,
        session: URLSession = .shared
    ) async throws -> Resolution {
        guard config.isConfigured else { throw Failure.notConfigured }

        let request = try buildRequest(message, config: config, tools: tools)
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(status: http.statusCode, body: errorMessage(from: data))
        }
        return try parse(data)
    }

    // MARK: - Request

    static func buildRequest(
        _ message: String,
        config: RemoteControlSettings.NaturalLanguageConfig,
        tools: RemoteToolSchemas
    ) throws -> URLRequest {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/v1/messages") else {
            throw Failure.malformed("bad base URL \(config.baseURL)")
        }

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 8192,
            "system": systemPrompt,
            // Force a tool call: the model's job here is routing, not chatting.
            "tool_choice": ["type": "any"],
            // Routing is a shallow task; low effort keeps a chat reply snappy.
            // (Thinking is left at the model's default rather than disabled —
            // disabling it is what makes some models emit a tool call as plain
            // text instead of a structured one.)
            "output_config": ["effort": "low"],
            "tools": tools.json,
            "messages": [["role": "user", "content": message]],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Re-shape the MCP catalog into the Messages API's tool format. MCP spells
    /// the schema key `inputSchema`; the Messages API spells it `input_schema`.
    static func toolSchemas(from definitions: [[String: Any]]) -> RemoteToolSchemas {
        RemoteToolSchemas(json: definitions.compactMap { def in
            guard let name = def["name"] as? String,
                  !withheldTools.contains(name),
                  let description = def["description"] as? String,
                  let schema = def["inputSchema"] as? [String: Any]
            else { return nil }
            return ["name": name, "description": description, "input_schema": schema]
        })
    }

    // MARK: - Response

    static func parse(_ data: Data) throws -> Resolution {
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
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    out[key] = .bool(number.boolValue)
                } else {
                    out[key] = .int(number.intValue)
                }
            }
        }
        return out
    }

    private static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return String(data: data.prefix(200), encoding: .utf8) ?? "" }
        return message
    }
}
