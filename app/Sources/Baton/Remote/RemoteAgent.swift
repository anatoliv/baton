import Foundation

/// Multi-turn tool use for chat control — the difference between a router and
/// something worth talking to.
///
/// `RemoteNaturalLanguage` translates one sentence into one tool call and stops.
/// It never sees a result, so it cannot notice that a search came back empty, or
/// that the chillout in this library is tagged "chill" and not "lazy". It has to
/// be right first time about a library it has never looked at.
///
/// This runs the loop instead: the model calls tools, Baton executes them and
/// feeds the **real results** back, and the model keeps going until it has done
/// something worth reporting. The intelligence isn't a cleverer prompt — it's
/// letting the model look before it answers.
///
/// Bounded on purpose. Someone is watching a chat window, so the loop stops at
/// `maxTurns` model round trips or `deadline` seconds, whichever comes first,
/// and always produces an answer rather than trailing off.
@MainActor
enum RemoteAgent {
    /// Model round trips per request. Measured: a real request spent four of
    /// them looking (genres, liked, then searches) before it was ready to act,
    /// so six left nothing for the acting. Eight leaves room, and the turns are
    /// sub-second against a local model.
    static let maxTurns = 8
    /// Wall-clock ceiling for the whole exchange.
    static let deadline: TimeInterval = 45

    /// Whether the first turn must call a tool before it may speak.
    ///
    /// Added because a real model answered "I searched… I'll play your chill
    /// tracks" having called nothing. It is a knob rather than a constant so the
    /// question "is this still load-bearing now that the follow-through nudge
    /// exists?" is a measurement rather than an argument — flip it, run the
    /// 109-message eval, compare. See `RemoteAgentConversationEval`.
    ///
    /// Measured, both ways, over the full corpus: **104/109 with it, 83/109
    /// without.** Playback fell from 58 messages to 33 and answer-only rose
    /// from 38 to 68 — unforced, the model talks about music instead of
    /// playing it. It stays.
    static var forcesFirstToolCall = true

    /// What the loop produced.
    struct Outcome: Sendable {
        /// What to say. Never empty by the time this returns.
        var text: String
        /// Tool calls that actually ran, in order — the router uses these to
        /// decide on transport buttons, and tests use them to see the reasoning.
        var toolsRun: [String] = []
        /// Set when the model ended by asking the person to choose.
        var choice: RemoteChoicePrompt?
    }

    // MARK: - System prompt

    /// Written for an agent that can look things up, unlike the router prompt it
    /// replaces — every line here assumes a second turn is available.
    static let systemPrompt = """
    You are Baton, the owner's music player, talking to them in a chat app. You \
    can call tools, see what they return, and call more before you answer. Use \
    that: look things up rather than guessing.

    You are also someone to talk to about music. Answer what is asked, have an \
    opinion when one is wanted, and only reach for the player when the person \
    actually wants to hear something.

    FIRST, decide which of these it is:
    - A QUESTION about the player or the library — "what's playing", "who sings \
    this", "how long is this", "what's in the queue", "do I have any Coltrane", \
    "what genres do I have", "show me my liked songs", "find/search …". Look it \
    up, then ANSWER IT. Do not play, queue, skip, or stop anything. Starting \
    music because someone asked a question is the single worst thing you can do \
    here — they were listening to something, or to nothing, on purpose.
    - TALK — "what do you think of this", "tell me about this artist", "is this \
    any good", "I'm in a weird mood", "hey". Reply like a friend who knows their \
    collection. Two lines. Your first move is always a tool call, so look \
    something up that makes the reply better — what's playing, what they like — \
    then talk. Don't touch playback.
    - A REQUEST TO HEAR SOMETHING — "put on", "play", "I want", "give me", or a \
    bare mood. Then do it, and end with the music actually started.

    How the library actually works:
    - Searching matches text in titles, artists, and albums — nothing else. A \
    mood is rarely a title, so "lazy music" finds nothing while the same music \
    sits there tagged "chill", "lounge" or "ambient".
    - So when a search for a mood comes back empty, do NOT report failure. Look: \
    music_list_genres shows the words this library really uses, music_liked \
    shows what its owner loves, music_browse_albums and music_random show what \
    is in here at all. Then search again with words you have seen work.
    - A search for a NAMED thing that comes back empty is a real answer: they \
    don't have it. Say so plainly, and don't play something else instead.
    - Never invent ids. Use ids you have seen in a tool result this turn, or \
    pass `query` and let the tool resolve it.

    Playing, and the words that matter:
    - music_play starts now and REPLACES the queue — only for "play", "put on".
    - "find X", "search X", "show me X", "do I have X" are QUESTIONS even when X \
    is an artist or a genre. List what you found. Do not play it.
    - music_queue_add appends and disturbs nothing — for "add", "queue", "stick \
    on the end", "queue up more like this". If they said queue, never replace.
    - music_play_next inserts after the current track — "play X next".
    - music_start_radio is an endless stream from what is playing — "keep this \
    going", "start a radio". Naming an artist is music_play, not radio.
    - music_build_mix assembles a set of a target length; use it when they ask \
    for an amount of music ("an hour of", "a 40 minute mix").
    - Ground recommendations in this library and this listener — play counts, \
    ratings and liked songs are in the tool results. "Your most-played" beats a \
    guess about what is popular in general.

    When you find more than one answer, use ask_choice — this is the tool that \
    makes you good company rather than a slot machine:
    - Two artists sharing a name, two unrelated clusters of music, a six-hour \
    mix beside a forty-minute set: OFFER THEM. Do not pick for them.
    - If you are about to write "I found two…", "there are a couple of…", or \
    "I'll play the first one" — stop. That sentence IS an ask_choice. Saying you \
    found two things and then choosing yourself is the worst of both.
    - Give each option the fact that decides it: how many tracks, how long, play \
    counts, why you'd pick it. A bare list of names is not a question anyone can \
    answer.
    - Don't ask when there is one obvious answer, when the request was already \
    specific, or when they said they don't mind ("just", "whatever", "surprise \
    me") — then act.
    - Ask at most once per request, and never twice in a row.

    Some tool results carry a `baton_note`. That is Baton handing you a fact it \
    knows and you cannot see — a play count worth mentioning, two artists with \
    the same name. Act on it in the same reply, once, and never repeat it later.

    Use `remember` only when the owner states something durable about \
    themselves or their library that the server cannot tell you — "no vocals \
    while I work", "the gothic playlists are my partner's", "call the Classic \
    Trance ones my trance". Store their words. Never store a guess about their \
    mood or character, and never store what a tool could look up.

    Never describe an action instead of taking it. If your answer says you \
    played, queued or built something, the tool call that does it must be in \
    that same reply. Until you have called a tool, nothing has happened.

    How to write:
    - Two short lines at most. This is a phone screen, not a report.
    - Sound like a person who knows the collection, not a search engine. Say why \
    you picked something when the reason is interesting.
    - Say what you did and why it isn't literally what was asked, when it isn't: \
    "nothing called 'lazy' — your chillout is tagged chill, playing that".
    - Never mention tool names, ids, or JSON. They mean nothing to anyone.
    - No preamble, no restating the question, no offering to help further.
    """

    // MARK: - Loop

    /// Injection seam for tests: run a tool, get its text back plus whether it
    /// failed. Production passes the real MCP catalog.
    typealias ToolRunner = @MainActor (RemoteToolCall) async -> (text: String, isError: Bool)
    /// Injection seam for tests: one model round trip.
    typealias Turn = @MainActor ([RemoteAgentMessage], RemoteToolSchemas) async throws -> RemoteAgentStep

    static func run(
        message: String,
        history: [RemoteConversationLog.Turn],
        playerContext: String?,
        config: RemoteControlSettings.NaturalLanguageConfig,
        tools: RemoteToolSchemas,
        runTool: ToolRunner,
        turn: Turn? = nil,
        now: @Sendable () -> Date = Date.init
    ) async throws -> Outcome {
        guard config.isConfigured else { throw RemoteNaturalLanguage.Failure.notConfigured }

        // The message being answered is appended last, so it is still last only
        // on the first turn — from turn two on, the transcript ends with tool
        // results. (Checking for *any* assistant message would be wrong: prior
        // conversation history is full of them.)
        let takeTurn: Turn = turn ?? { messages, schemas in
            let isFirstTurn = forcesFirstToolCall && messages.last?.role == "user"
            return try await requestTurn(
                messages, tools: schemas, config: config,
                playerContext: playerContext, forceTool: isFirstTurn
            )
        }

        let started = now()
        var messages = history.map { RemoteAgentMessage(role: $0.role, text: $0.text) }
        messages.append(RemoteAgentMessage(role: "user", text: message))

        var toolsRun: [String] = []
        var lastText = ""
        /// Spent once per exchange — see the `step.calls.isEmpty` branch.
        var nudgedToAct = false
        var actionOnlyNextTurn = false

        for turnIndex in 0 ..< maxTurns {
            let outOfTime = now().timeIntervalSince(started) > deadline
            let isLastTurn = outOfTime || turnIndex == maxTurns - 1

            // Measured, live: given six turns it spent all of them looking —
            // genres, liked songs, four searches — and signed off with "I'll
            // play your chill tracks" having played nothing. Exploring is not
            // free; it has to be told when the budget is gone. The tools stay
            // available on this turn precisely so it can still act.
            if isLastTurn {
                messages.append(RemoteAgentMessage(role: "user", text: Self.lastTurnNotice))
            }
            // Telling it to stop looking was not enough — measured live, it
            // spent its last turn on one more search. So the looking tools are
            // taken away instead of asked about: what remains can act or speak,
            // and nothing else.
            let offered = (isLastTurn || actionOnlyNextTurn) ? Self.actionOnly(tools) : tools
            actionOnlyNextTurn = false
            let step = try await takeTurn(messages, offered)

            if let text = step.text, !text.isEmpty { lastText = text }

            guard !step.calls.isEmpty else {
                // Text with no call normally means "I'm finished" — the exit the
                // old router could never take. But measured live, it also signed
                // off with "I'll play your most-listened chill tracks" having
                // called nothing that plays: a promise the speakers don't keep,
                // and it reads as success to anyone not in earshot.
                //
                // So when nothing has actually been *done* yet, it gets exactly
                // one turn to do it, with only acting tools on the table. Once.
                // A request that genuinely needed no action just answers again,
                // which the notice explicitly allows.
                let didSomething = toolsRun.contains { !Self.discoveryTools.contains($0) }
                if !didSomething, !nudgedToAct, !isLastTurn {
                    nudgedToAct = true
                    // The full toolset stays. Two things were tried and measured
                    // over 109 real messages, and both were worse:
                    //
                    //   · offering only acting tools — 72 of 109 ended in
                    //     playback, including "what's playing?" and "do I have
                    //     any Coltrane";
                    //   · offering only acting tools *when the reply mentions
                    //     playback* — which sounds precise and is not, because
                    //     the correct answer to "what's playing?" is the
                    //     sentence "Playing DIDO — Absolutely". The keyword is
                    //     in the right answer as often as the wrong one.
                    //
                    // So the notice below carries the judgement, and the model
                    // keeps the freedom to answer. The residual cost is a rare
                    // "I'll play X" with nothing played; the alternative was
                    // starting music at people who asked a question.
                    messages.append(step.assistantMessage)
                    messages.append(RemoteAgentMessage(role: "user", text: Self.followThroughNotice))
                    continue
                }
                return Outcome(text: Self.sanitize(lastText), toolsRun: toolsRun)
            }

            // A choice ends the exchange — the next thing that happens is up to
            // the person, so anything the model queued behind it is discarded.
            if let ask = step.calls.first(where: { $0.call.name == RemoteChoicePrompt.toolName }) {
                guard let prompt = RemoteChoicePrompt(arguments: ask.call.arguments) else {
                    // Malformed choice: don't strand the person with nothing.
                    messages.append(step.assistantMessage)
                    messages.append(RemoteAgentMessage(
                        role: "tool_results",
                        results: [.init(id: ask.id, text: "ask_choice needs a question and 2–4 options, each with a label and a command. Fix and retry, or just act.")]
                    ))
                    continue
                }
                return Outcome(
                    text: lastText.isEmpty ? prompt.question : Self.sanitize(lastText),
                    toolsRun: toolsRun,
                    choice: prompt
                )
            }

            messages.append(step.assistantMessage)
            // Anything said alongside a tool call is narration of a step in
            // progress ("Looking at your genres…"). Letting it survive means a
            // silent final turn — or a wrap-up that fails, which is a `try?` —
            // speaks the narration as if it were the outcome. Only a turn that
            // *ended* the exchange gets to be the answer.
            lastText = ""
            var results: [RemoteAgentMessage.ToolResult] = []
            for pending in step.calls {
                let (text, isError) = await runTool(pending.call)
                toolsRun.append(pending.call.name)
                results.append(.init(id: pending.id, text: RemoteAgentResults.shape(text), isError: isError))
            }
            messages.append(RemoteAgentMessage(role: "tool_results", results: results))

            // The budget is spent and it acted rather than spoke — which is the
            // right way round. Ask for the sentence, with no tools left to call.
            if isLastTurn {
                if lastText.isEmpty {
                    let wrapUp = try? await takeTurn(messages, RemoteToolSchemas(json: []))
                    if let text = wrapUp?.text, !text.isEmpty { lastText = text }
                }
                break
            }
        }

        return Outcome(
            text: lastText.isEmpty ? "I looked, but couldn't finish that one." : Self.sanitize(lastText),
            toolsRun: toolsRun
        )
    }

    /// The tools that only read. On the final turn these come off the table, so
    /// "no more looking" is a fact about what it can call rather than a request
    /// it can decline.
    static let discoveryTools: Set<String> = [
        "music_search", "music_list_genres", "music_browse_albums", "music_similar_songs",
        "music_liked", "music_random", "music_artist_info", "music_list_playlists",
        "music_get_playlist", "music_get_queue", "music_now_playing",
    ]

    static func actionOnly(_ tools: RemoteToolSchemas) -> RemoteToolSchemas {
        RemoteToolSchemas(json: tools.json.filter { schema in
            guard let name = schema["name"] as? String else { return false }
            return !discoveryTools.contains(name)
        })
    }

    /// Sent when the model talked without doing anything. Measured: an earlier
    /// version said "act now" and offered only acting tools, and the model
    /// dutifully started music in reply to "what's playing?", "how long is this
    /// track", and "do I have any Coltrane" — 72 of 109 ordinary messages ended
    /// in playback. The judgement it needs is not "act or not" but "did I just
    /// describe something I have not done", so that is what it is asked.
    static let followThroughNotice = """
    (Baton: you have not called anything that changes what is playing. If your \
    last reply said you would play, queue, or build something, call that tool \
    NOW — otherwise you promised something that will not happen. If your reply \
    answered a question, that is finished: say it again, unchanged, with no tool \
    call. Do not start music to answer a question.)
    """

    /// Sent when the turn budget is gone. Here the tools really are taken away,
    /// because "stop looking" was ignored when it was merely asked for.
    static let lastTurnNotice = """
    (Baton: this is your last turn — no more looking. If what was asked needs an \
    action, call the tool that does it now, in this reply, and say one short line \
    about it. If it only needs an answer, just answer.)
    """

    /// Strip machinery the model leaked into what it said.
    ///
    /// A small model under load sometimes writes a tool call as *text* instead
    /// of emitting a structured one — `<tool_call>{"name": "music_play"…` in
    /// the middle of a sentence. It rose from one case to three across the
    /// 109-message eval as the context grew, so it is a load symptom and will
    /// come back on any busy turn. The call itself is lost either way; what
    /// Baton controls is whether the person is shown the wreckage.
    ///
    /// Conservative on purpose: it cuts from the first machinery marker and
    /// keeps everything before it, so a reply that merely *mentions* a tool
    /// still reads fine and nothing legitimate is trimmed from the middle.
    static func sanitize(_ text: String) -> String {
        var cleaned = text
        for marker in ["<tool_call>", "<|tool_call|>", "<function_call>", "```json"] {
            if let range = cleaned.range(of: marker) {
                cleaned = String(cleaned[cleaned.startIndex ..< range.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // If the leak began at the very start, there is no sentence to keep.
        return cleaned.isEmpty ? "Done." : cleaned
    }

    /// Kept as the plain-text fallback and for tests; JSON results go through
    /// `RemoteAgentResults.shape`, which drops whole items instead of cutting
    /// the string. See that file for why character truncation was wrong.
    static func clampToolResult(_ text: String, limit: Int = 6000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…(truncated; narrow the query if you need the rest)"
    }

    // MARK: - One round trip

    static func requestTurn(
        _ messages: [RemoteAgentMessage],
        tools: RemoteToolSchemas,
        config: RemoteControlSettings.NaturalLanguageConfig,
        playerContext: String?,
        forceTool: Bool = false,
        session: URLSession = .shared
    ) async throws -> RemoteAgentStep {
        let request = try buildRequest(
            messages, tools: tools, config: config,
            playerContext: playerContext, forceTool: forceTool)

        // A model on your own network is one Wi-Fi hiccup away from an error the
        // reader can only interpret as "Baton is broken" — and three of 109 eval
        // messages died this way. One retry costs a second and covers it; a
        // genuine outage still surfaces, just a beat later.
        var data = Data()
        var response: URLResponse?
        for attempt in 0 ... 1 {
            do {
                (data, response) = try await session.data(for: request)
                break
            } catch let error as URLError {
                guard attempt == 0, Self.isWorthRetrying(error) else {
                    throw RemoteNaturalLanguage.transportFailure(
                        error, host: request.url?.host ?? config.baseURL)
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        guard let response else {
            throw RemoteNaturalLanguage.Failure.malformed("no HTTP response")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteNaturalLanguage.Failure.malformed("no HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw RemoteNaturalLanguage.Failure.http(
                status: http.statusCode, body: RemoteNaturalLanguage.errorBody(from: data))
        }
        return try RemoteAgentStep.parse(data, provider: config.provider)
    }

    /// Transient by nature: a dropped connection or a timeout. An auth failure
    /// or a bad hostname will fail identically twice, so it isn't retried.
    static func isWorthRetrying(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed:
            true
        default:
            false
        }
    }

    static func buildRequest(
        _ messages: [RemoteAgentMessage],
        tools: RemoteToolSchemas,
        config: RemoteControlSettings.NaturalLanguageConfig,
        playerContext: String?,
        forceTool: Bool = false
    ) throws -> URLRequest {
        let system = playerContext.map { systemPrompt + "\n\n" + $0 } ?? systemPrompt

        var request = URLRequest(url: try RemoteNaturalLanguage.endpoint(for: config))
        request.httpMethod = "POST"
        // Generous next to the router's 30 s: this turn may be the model reading
        // a genre list and deciding, not a reflex.
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any]
        switch config.provider {
        case .anthropic:
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            body = [
                "model": config.model,
                "max_tokens": 8192,
                // Cached, not sent fresh: the prompt and the tool list are
                // identical on every turn of every message, and an exchange
                // runs up to eight turns. Marking the last system block caches
                // the tools with it, since tools render ahead of system.
                "system": [[
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"],
                ]],
                "messages": messages.map { $0.anthropic },
            ]
            if !tools.isEmpty {
                body["tools"] = tools.json
                // Forced on the FIRST turn only. Measured against a real model:
                // asked to find lazy music, it replied "I searched… I'll play
                // your chill tracks" having called nothing at all — a claim to
                // the user and silence from the speakers. Requiring one call
                // before it may speak makes "look before you answer" structural
                // rather than a request. After that it's free to stop and talk,
                // which is what the router could never do.
                if forceTool { body["tool_choice"] = ["type": "any"] }
            }

        case .openAICompatible:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": config.model,
                "messages": [["role": "system", "content": system]]
                    + messages.flatMap { $0.openAI },
            ]
            if !tools.isEmpty {
                if forceTool { body["tool_choice"] = "required" } // see the note above
                body["tools"] = tools.json.map { schema -> [String: Any] in
                    ["type": "function", "function": [
                        "name": schema["name"] ?? "",
                        "description": schema["description"] ?? "",
                        "parameters": schema["input_schema"] ?? [:],
                    ]]
                }
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The catalog the agent may drive: the chat-safe schemas plus `ask_choice`,
    /// which exists only here — an MCP client has its own user to talk to.
    static func toolSchemas() -> RemoteToolSchemas {
        let base = RemoteNaturalLanguage.toolSchemas(from: BatonMCPToolCatalog.definitions())
        // First, not last. Buried at the end of thirty-six tools it was never
        // reached for — measured against a real model, which wrote "I found two
        // artists named Dido" and then picked one itself.
        return RemoteToolSchemas(json: [RemoteChoicePrompt.schema, rememberSchema] + base.json)
    }

    /// Remote-only, like `ask_choice`: an MCP client has its own place to put
    /// notes. `quote` is required by the schema, which is what makes an
    /// invented memory hard rather than merely discouraged.
    static var rememberSchema: [String: Any] {
        [
            "name": "remember",
            "description": """
            Store something the owner has just told you about themselves or \
            their library that the server could never answer — a standing \
            preference, a correction, a name they use for something. Only when \
            they actually said it, and only when it will still be true next \
            week. Never for a mood, a guess, or anything a tool can look up.
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "One line, in your words, of what to remember. e.g. 'No vocals while working'.",
                    ],
                    "quote": [
                        "type": "string",
                        "description": "What the owner actually said, verbatim. Required — a memory with no source is not allowed.",
                    ],
                    "kind": [
                        "type": "string",
                        "description": "preference, fact, vocabulary, or dislike.",
                    ],
                ],
                "required": ["text", "quote"],
            ],
        ]
    }
}

// MARK: - Transcript

/// One message in the agent transcript, in whichever shape the turn needs:
/// plain text, an assistant turn that made tool calls, or the results of those
/// calls. Kept dialect-neutral and rendered per provider, so the loop itself
/// never learns which API it is talking to.
struct RemoteAgentMessage: Sendable {
    struct ToolResult: Sendable {
        var id: String
        var text: String
        var isError: Bool = false
    }

    /// "user", "assistant", or "tool_results".
    var role: String
    var text: String = ""
    var calls: [RemoteAgentStep.PendingCall] = []
    var results: [ToolResult] = []

    var anthropic: [String: Any] {
        switch role {
        case "tool_results":
            return ["role": "user", "content": results.map { result -> [String: Any] in
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": result.id,
                    "content": result.text,
                ]
                if result.isError { block["is_error"] = true }
                return block
            }]
        case "assistant" where !calls.isEmpty:
            var content: [[String: Any]] = []
            if !text.isEmpty { content.append(["type": "text", "text": text]) }
            for call in calls {
                content.append([
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.call.name,
                    "input": call.call.jsonArguments,
                ])
            }
            return ["role": "assistant", "content": content]
        default:
            return ["role": role, "content": text]
        }
    }

    /// One message here can be several there: this dialect gives every tool
    /// result its own `role: "tool"` message.
    var openAI: [[String: Any]] {
        switch role {
        case "tool_results":
            return results.map { ["role": "tool", "tool_call_id": $0.id, "content": $0.text] }
        case "assistant" where !calls.isEmpty:
            return [[
                "role": "assistant",
                "content": text,
                "tool_calls": calls.map { call -> [String: Any] in
                    let arguments = (try? JSONSerialization.data(withJSONObject: call.call.jsonArguments))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.call.name, "arguments": arguments],
                    ]
                },
            ]]
        default:
            return [["role": role, "content": text]]
        }
    }
}

/// One model turn: whatever it said, plus whatever it wants run. Unlike the
/// router's single `Resolution`, this keeps **all** the calls and their ids —
/// results have to come back matched to the call that asked for them.
struct RemoteAgentStep: Sendable {
    struct PendingCall: Sendable {
        var id: String
        var call: RemoteToolCall
    }

    var text: String?
    var calls: [PendingCall] = []

    var assistantMessage: RemoteAgentMessage {
        RemoteAgentMessage(role: "assistant", text: text ?? "", calls: calls)
    }

    static func parse(
        _ data: Data,
        provider: RemoteControlSettings.LLMProvider
    ) throws -> RemoteAgentStep {
        switch provider {
        case .anthropic: try parseAnthropic(data)
        case .openAICompatible: try parseOpenAI(data)
        }
    }

    private static func parseAnthropic(_ data: Data) throws -> RemoteAgentStep {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteNaturalLanguage.Failure.malformed("response was not a JSON object")
        }
        if root["stop_reason"] as? String == "refusal" {
            let detail = (root["stop_details"] as? [String: Any])?["explanation"] as? String
            throw RemoteNaturalLanguage.Failure.refused(detail ?? "")
        }
        guard let content = root["content"] as? [[String: Any]] else {
            throw RemoteNaturalLanguage.Failure.malformed("response had no content array")
        }

        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let calls = content.compactMap { block -> PendingCall? in
            guard block["type"] as? String == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String
            else { return nil }
            let input = block["input"] as? [String: Any] ?? [:]
            return PendingCall(
                id: id,
                call: RemoteToolCall(name: name, arguments: RemoteNaturalLanguage.coerceArguments(input))
            )
        }

        // Truncation mid-deliberation reads as "it had nothing to say", which is
        // a misleading answer to what is really a budget problem.
        if calls.isEmpty, text.isEmpty, root["stop_reason"] as? String == "max_tokens" {
            throw RemoteNaturalLanguage.Failure.truncated
        }
        return RemoteAgentStep(text: text.isEmpty ? nil : text, calls: calls)
    }

    private static func parseOpenAI(_ data: Data) throws -> RemoteAgentStep {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteNaturalLanguage.Failure.malformed("response was not a JSON object")
        }
        guard let choice = (root["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw RemoteNaturalLanguage.Failure.malformed("response had no choices")
        }

        let text = (message["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { raw -> PendingCall? in
            guard let id = raw["id"] as? String,
                  let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String
            else { return nil }
            var arguments: [String: Any] = [:]
            // This dialect sends arguments as a JSON *string*, not an object.
            if let encoded = function["arguments"] as? String, !encoded.isEmpty,
               let decoded = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] {
                arguments = decoded
            }
            return PendingCall(
                id: id,
                call: RemoteToolCall(name: name, arguments: RemoteNaturalLanguage.coerceArguments(arguments))
            )
        }

        if calls.isEmpty, text.isEmpty, choice["finish_reason"] as? String == "length" {
            throw RemoteNaturalLanguage.Failure.truncated
        }
        return RemoteAgentStep(text: text.isEmpty ? nil : text, calls: calls)
    }
}
