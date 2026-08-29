import XCTest
@testable import BatonAgentKit
import BatonSubsonicKit
import BatonSubsonicModels

/// The agent loop's contract: it must SEE tool results and be able to act on
/// them. Every test here drives it with a scripted model, so the behaviour under
/// test is Baton's control flow rather than any model's judgement.
@MainActor
final class RemoteAgentLoopTests: XCTestCase {
    private func config() -> RemoteControlSettings.NaturalLanguageConfig {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.apiKey = "sk-test"
        config.isAgentEnabled = true
        return config
    }

    private func call(_ name: String, _ arguments: [String: RemoteArgument] = [:]) -> RemoteAgentStep.PendingCall {
        .init(id: "call_\(name)", call: RemoteToolCall(name: name, arguments: arguments))
    }

    /// The whole point. A one-shot router reports "nothing matched" and stops;
    /// this must be able to look at the empty result and try something else.
    func testAnEmptySearchIsFedBackSoTheModelCanTryAgain() async throws {
        var seenByModel: [String] = []
        var turnIndex = 0

        let outcome = try await RemoteAgent.run(
            message: "find lazy music and play",
            history: [],
            playerContext: nil,
            config: config(),
            tools: RemoteToolSchemas(json: []),
            runTool: { call in
                switch call.name {
                case "music_search":
                    guard case let .string(query)? = call.arguments["query"] else { return ("{}", false) }
                    return query == "lazy"
                        ? (#"{"songs":[],"albums":[],"artists":[]}"#, false)
                        : (#"{"songs":[{"id":"s1","title":"Deep Rooftop Chillout"}]}"#, false)
                case "music_play":
                    return (#"{"playing":{"title":"Deep Rooftop Chillout"},"queued":5}"#, false)
                default:
                    return ("{}", false)
                }
            },
            turn: { messages, _ in
                // Record what the model can see, to prove results come back.
                seenByModel = messages.compactMap { message in
                    message.role == "tool_results" ? message.results.map(\.text).joined() : nil
                }
                turnIndex += 1
                switch turnIndex {
                case 1: return RemoteAgentStep(calls: [self.call("music_search", ["query": .string("lazy")])])
                case 2: return RemoteAgentStep(calls: [self.call("music_search", ["query": .string("chill")])])
                case 3: return RemoteAgentStep(calls: [self.call("music_play", ["query": .string("chill")])])
                default: return RemoteAgentStep(text: "Nothing called lazy — playing your chillout.")
                }
            }
        )

        XCTAssertEqual(outcome.toolsRun, ["music_search", "music_search", "music_play"])
        XCTAssertEqual(outcome.text, "Nothing called lazy — playing your chillout.")
        XCTAssertTrue(
            seenByModel.contains { $0.contains(#""songs":[]"#) },
            "the model must actually see the empty result: \(seenByModel)"
        )
    }

    /// A turn with no tool call is the model saying it's finished — the exit the
    /// old single-shot router had no way to express. It stands as soon as
    /// something has actually been done; see
    /// `testPromisingAnActionWithoutTakingItBuysOneMoreTurn` for the case where
    /// nothing has.
    func testATextOnlyTurnEndsTheLoopOnceSomethingHasBeenDone() async throws {
        var turns = 0
        let outcome = try await RemoteAgent.run(
            message: "what's playing",
            history: [],
            playerContext: nil,
            config: config(),
            tools: RemoteToolSchemas(json: []),
            runTool: { _ in (#"{"now_playing":{"title":"Absolutely"}}"#, false) },
            turn: { _, _ in
                turns += 1
                return turns == 1
                    ? RemoteAgentStep(calls: [self.call("music_now_playing")])
                    : RemoteAgentStep(text: "Absolutely — DIDO.")
            }
        )
        // Three, not two, and deliberately: looking is not *doing*, so the
        // follow-through rule spends its one nudge here before letting the
        // answer stand. That costs a round trip on questions that never needed
        // an action — the price of never again promising playback and
        // delivering silence, which is the failure that reads as success.
        XCTAssertEqual(turns, 3)
        XCTAssertEqual(outcome.toolsRun, ["music_now_playing"], "it must not be pushed into playing")
        XCTAssertEqual(outcome.text, "Absolutely — DIDO.")
    }

    /// A failing tool is not a dead end — the error text goes back as a result
    /// so the model can correct itself, exactly like a human would.
    func testToolFailuresAreReportedBackRatherThanThrown() async throws {
        var sawError = false
        var turnIndex = 0
        let outcome = try await RemoteAgent.run(
            message: "play something",
            history: [],
            playerContext: nil,
            config: config(),
            tools: RemoteToolSchemas(json: []),
            runTool: { _ in ("No songs matched \"nonsense\".", true) },
            turn: { messages, _ in
                turnIndex += 1
                sawError = sawError || messages.contains { $0.results.contains { $0.isError } }
                return turnIndex == 1
                    ? RemoteAgentStep(calls: [self.call("music_play", ["query": .string("nonsense")])])
                    : RemoteAgentStep(text: "Couldn't find that one.")
            }
        )
        XCTAssertTrue(sawError, "the failure must reach the model as a tool result")
        XCTAssertEqual(outcome.text, "Couldn't find that one.")
    }

    /// A model that keeps calling tools forever must still produce an answer,
    /// and must stop costing requests.
    func testTheLoopIsBounded() async throws {
        var turns = 0
        let outcome = try await RemoteAgent.run(
            message: "go forever",
            history: [],
            playerContext: nil,
            config: config(),
            tools: RemoteToolSchemas(json: []),
            runTool: { _ in ("{}", false) },
            turn: { _, tools in
                turns += 1
                // The wrap-up turn is the one offered no tools; answer it.
                return tools.isEmpty
                    ? RemoteAgentStep(text: "Here's what I found.")
                    : RemoteAgentStep(calls: [self.call("music_search", ["query": .string("x")])])
            }
        )
        XCTAssertLessThanOrEqual(turns, RemoteAgent.maxTurns + 1, "budget exceeded: \(turns)")
        XCTAssertEqual(outcome.text, "Here's what I found.")
        XCTAssertFalse(outcome.text.isEmpty, "must never trail off silently")
    }

    /// The first turn forces a tool call, so the model cannot answer a request
    /// about the library without having looked at it. Measured need: a real
    /// model replied "I searched… I'll play your chill tracks" having called
    /// nothing — a claim to the user and silence from the speakers.
    ///
    /// It must apply on turn one *with* prior conversation history, which is the
    /// case a naive "have I seen an assistant message" check gets wrong.
    func testTheFirstTurnForcesATool_evenWithPriorHistory() throws {
        var config = self.config()
        config.provider = .openAICompatible

        let history = [
            RemoteAgentMessage(role: "user", text: "hello"),
            RemoteAgentMessage(role: "assistant", text: "Ready."),
        ]
        let firstTurn = history + [RemoteAgentMessage(role: "user", text: "play something lazy")]
        let request = try RemoteAgent.buildRequest(
            firstTurn, tools: RemoteAgent.toolSchemas(definitions: TestToolFixtures.definitions), config: config,
            playerContext: nil, forceTool: firstTurn.last?.role == "user"
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["tool_choice"] as? String, "required")

        // Turn two ends with results, not the user — by then it must be free to
        // stop and speak, which is the whole difference from the old router.
        let secondTurn = firstTurn + [
            RemoteAgentMessage(role: "assistant", text: "", calls: [call("music_search")]),
            RemoteAgentMessage(role: "tool_results", results: [.init(id: "call_music_search", text: "{}")]),
        ]
        let later = try RemoteAgent.buildRequest(
            secondTurn, tools: RemoteAgent.toolSchemas(definitions: TestToolFixtures.definitions), config: config,
            playerContext: nil, forceTool: secondTurn.last?.role == "user"
        )
        let laterBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(later.httpBody)) as? [String: Any])
        XCTAssertNil(laterBody["tool_choice"], "the model must be able to stop and answer")
    }

    /// Caught live and the most valuable thing this work found: the model
    /// answered "I'll play your most-listened chill tracks" having called
    /// nothing that plays. Silence from the speakers, success on the screen.
    ///
    /// A turn that only talks, before anything has been *done*, buys one more
    /// turn with the looking tools removed.
    func testPromisingAnActionWithoutTakingItBuysOneMoreTurn() async throws {
        var offered: [Int] = []
        var turnIndex = 0

        let outcome = try await RemoteAgent.run(
            message: "find lazy music and play",
            history: [],
            playerContext: nil,
            config: config(),
            tools: RemoteAgent.toolSchemas(definitions: TestToolFixtures.definitions),
            runTool: { _ in (#"{"songs":[],"albums":[],"artists":[]}"#, false) },
            turn: { _, tools in
                turnIndex += 1
                offered.append(tools.json.count)
                switch turnIndex {
                case 1: return RemoteAgentStep(calls: [self.call("music_search", ["query": .string("lazy")])])
                // The lie: a promise, with nothing behind it.
                case 2: return RemoteAgentStep(text: "I'll play your chill tracks.")
                // Given another turn, it does the thing.
                default: return RemoteAgentStep(
                    text: "Playing your chill tracks.",
                    calls: [self.call("music_play", ["query": .string("chill")])]
                )
                }
            }
        )

        XCTAssertTrue(outcome.toolsRun.contains("music_play"), "the promise must be kept: \(outcome.toolsRun)")
        // The follow-up turn keeps the FULL toolset. Restricting it to acting
        // tools was measured, across 109 real messages, to turn "what's
        // playing?" and "do I have any Coltrane" into playback — 72 of them
        // ended in music. The judgement belongs in the notice, not the tool list.
        XCTAssertEqual(offered[1], offered[2], "the follow-up must not be acting-only")
        XCTAssertTrue(
            RemoteAgent.followThroughNotice.lowercased().contains("answered a question"),
            "the notice must permit answering, or a question becomes playback"
        )
    }

    /// …but only one extra turn. A model that keeps promising must not be able
    /// to spend the whole budget doing it.
    func testTheFollowThroughNudgeIsSpentOnlyOnce() async throws {
        var turns = 0
        let outcome = try await RemoteAgent.run(
            message: "play something",
            history: [],
            playerContext: nil,
            config: config(),
            tools: RemoteAgent.toolSchemas(definitions: TestToolFixtures.definitions),
            runTool: { _ in ("{}", false) },
            turn: { _, _ in
                turns += 1
                return turns == 1
                    ? RemoteAgentStep(calls: [self.call("music_search")])
                    : RemoteAgentStep(text: "I'll get right on that.")
            }
        )
        XCTAssertEqual(turns, 3, "one search, one promise, one second chance — then it stands")
        XCTAssertEqual(outcome.text, "I'll get right on that.")
    }

    /// An informational request needs no action, and the notice says so. It must
    /// not be pushed into playing something nobody asked for.
    func testAnInformationalAnswerIsAllowedToStand() async throws {
        var turns = 0
        let outcome = try await RemoteAgent.run(
            message: "what genres do I have?",
            history: [],
            playerContext: nil,
            config: config(),
            tools: RemoteAgent.toolSchemas(definitions: TestToolFixtures.definitions),
            runTool: { _ in (#"{"genres":[{"name":"Trance","song_count":107}]}"#, false) },
            turn: { _, _ in
                turns += 1
                return turns == 1
                    ? RemoteAgentStep(calls: [self.call("music_list_genres")])
                    : RemoteAgentStep(text: "Mostly Trance — 107 tracks.")
            }
        )
        XCTAssertEqual(outcome.text, "Mostly Trance — 107 tracks.")
        XCTAssertFalse(outcome.toolsRun.contains("music_play"), "must not play at someone")
    }

    /// A weak model under load writes a tool call as text instead of emitting
    /// one. The call is lost either way; showing the person the wreckage is the
    /// part Baton controls.
    func testLeakedMachineryIsCutFromWhatTheUserSees() {
        let leaked = """
        I see you're already listening to DIDO. Let me play something quieter.
        <tool_call>
        {"name": "music_play", "arguments": {"query": "ambient"}}
        """
        let cleaned = RemoteAgent.sanitize(leaked)
        XCTAssertEqual(cleaned, "I see you're already listening to DIDO. Let me play something quieter.")
        XCTAssertFalse(cleaned.contains("{"))

        // Cutting from the first marker keeps the sentence; it never trims the
        // middle of a legitimate reply.
        XCTAssertEqual(
            RemoteAgent.sanitize("Playing your chill tracks."), "Playing your chill tracks.")
        // And a reply that is nothing but machinery still has to say something.
        XCTAssertEqual(RemoteAgent.sanitize("<tool_call>{\"name\":\"x\"}"), "Done.")
    }

    /// A huge tool result would otherwise be echoed on every subsequent turn.
    func testToolResultsAreClampedBeforeTheyReachTheTranscript() {
        let huge = String(repeating: "x", count: 20_000)
        let clamped = RemoteAgent.clampToolResult(huge, limit: 100)
        XCTAssertLessThan(clamped.count, 200)
        XCTAssertTrue(clamped.contains("truncated"), "truncation must be visible to the model")
    }

    // MARK: Asking

    func testAskChoiceEndsTheLoopAndCarriesTheOptions() async throws {
        let outcome = try await RemoteAgent.run(
            message: "play dido",
            history: [],
            playerContext: nil,
            config: config(),
            tools: RemoteToolSchemas(json: []),
            runTool: { _ in XCTFail("ask_choice must not be dispatched to the catalog"); return ("", false) },
            turn: { _, _ in
                RemoteAgentStep(text: "Two different Didos in here.", calls: [self.call(
                    RemoteChoicePrompt.toolName,
                    [
                        "question": .string("Which one?"),
                        "label_1": .string("Trance DIDO"), "command_1": .string("play DIDO absolutely"),
                        "detail_1": .string("34 plays, 5★"),
                        "label_2": .string("Singer Dido"), "command_2": .string("play white flag"),
                        "recommended": .int(1),
                    ]
                )])
            }
        )

        let prompt = try XCTUnwrap(outcome.choice)
        XCTAssertEqual(prompt.options.count, 2)
        XCTAssertEqual(prompt.recommendedChoice.label, "Trance DIDO")
        XCTAssertTrue(prompt.rendered().contains("34 plays"), "the deciding fact must be shown")
        XCTAssertEqual(outcome.text, "Two different Didos in here.")
    }

    /// One option is not a question. Rather than showing a broken prompt, the
    /// complaint goes back as a tool result and the model gets to act instead.
    func testAMalformedChoiceIsSentBackForRepairRatherThanShown() async throws {
        var turnIndex = 0
        let outcome = try await RemoteAgent.run(
            message: "play something",
            history: [],
            playerContext: nil,
            config: config(),
            tools: RemoteToolSchemas(json: []),
            runTool: { _ in ("{}", false) },
            turn: { messages, _ in
                turnIndex += 1
                if turnIndex == 1 {
                    return RemoteAgentStep(calls: [self.call(
                        RemoteChoicePrompt.toolName,
                        ["question": .string("Which?"), "label_1": .string("Only one"), "command_1": .string("play x")]
                    )])
                }
                XCTAssertTrue(
                    messages.contains { $0.results.contains { $0.text.contains("2–4 options") } },
                    "the model should be told what was wrong"
                )
                return RemoteAgentStep(text: "Playing your most-played instead.")
            }
        )
        XCTAssertNil(outcome.choice)
        XCTAssertEqual(outcome.text, "Playing your most-played instead.")
    }
}

// MARK: - Transcript shapes

/// Both dialects have to be spoken exactly, because a malformed transcript is
/// rejected by the provider rather than degraded — the whole conversation dies.
final class RemoteAgentTranscriptTests: XCTestCase {
    private let call = RemoteAgentStep.PendingCall(
        id: "toolu_1",
        call: RemoteToolCall(name: "music_search", arguments: ["query": .string("chill")])
    )

    func testAnthropicAssistantTurnCarriesToolUseBlocks() throws {
        let message = RemoteAgentMessage(role: "assistant", text: "Looking.", calls: [call])
        let content = try XCTUnwrap(message.anthropic["content"] as? [[String: Any]])
        XCTAssertEqual(message.anthropic["role"] as? String, "assistant")
        XCTAssertEqual(content.first?["type"] as? String, "text")
        let use = try XCTUnwrap(content.last)
        XCTAssertEqual(use["type"] as? String, "tool_use")
        XCTAssertEqual(use["id"] as? String, "toolu_1")
        XCTAssertEqual(use["name"] as? String, "music_search")
        XCTAssertEqual((use["input"] as? [String: Any])?["query"] as? String, "chill")
    }

    /// Anthropic carries tool results in a *user* message; the id must match the
    /// call, or the API rejects the turn outright.
    func testAnthropicToolResultsRideInAUserMessageAndKeepTheirIDs() throws {
        let message = RemoteAgentMessage(
            role: "tool_results",
            results: [.init(id: "toolu_1", text: "{}", isError: true)]
        )
        XCTAssertEqual(message.anthropic["role"] as? String, "user")
        let block = try XCTUnwrap((message.anthropic["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(block["type"] as? String, "tool_result")
        XCTAssertEqual(block["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(block["is_error"] as? Bool, true)
    }

    /// The other dialect spells all of it differently, including arguments as a
    /// JSON *string* rather than an object.
    func testOpenAIAssistantTurnEncodesArgumentsAsAString() throws {
        let message = RemoteAgentMessage(role: "assistant", text: "Looking.", calls: [call])
        let rendered = try XCTUnwrap(message.openAI.first)
        let toolCall = try XCTUnwrap((rendered["tool_calls"] as? [[String: Any]])?.first)
        let function = try XCTUnwrap(toolCall["function"] as? [String: Any])
        let arguments = try XCTUnwrap(function["arguments"] as? String)
        XCTAssertTrue(arguments.contains("\"query\""), arguments)
        XCTAssertEqual(toolCall["id"] as? String, "toolu_1")
    }

    func testOpenAIGivesEveryToolResultItsOwnMessage() {
        let message = RemoteAgentMessage(role: "tool_results", results: [
            .init(id: "a", text: "{}"), .init(id: "b", text: "{}"),
        ])
        XCTAssertEqual(message.openAI.count, 2)
        XCTAssertEqual(message.openAI.first?["role"] as? String, "tool")
        XCTAssertEqual(message.openAI.first?["tool_call_id"] as? String, "a")
    }

    /// Both parsers must return every call in a turn, not just the first —
    /// dropping one strands its id and the next request is rejected.
    func testBothDialectsParseMultipleToolCalls() throws {
        let anthropic = Data("""
        {"content":[{"type":"text","text":"Looking."},
        {"type":"tool_use","id":"a","name":"music_search","input":{"query":"chill"}},
        {"type":"tool_use","id":"b","name":"music_liked","input":{}}]}
        """.utf8)
        let step = try RemoteAgentStep.parse(anthropic, provider: .anthropic)
        XCTAssertEqual(step.calls.map(\.call.name), ["music_search", "music_liked"])
        XCTAssertEqual(step.text, "Looking.")

        let openAI = Data("""
        {"choices":[{"message":{"content":"Looking.","tool_calls":[
        {"id":"a","type":"function","function":{"name":"music_search","arguments":"{\\"query\\":\\"chill\\"}"}},
        {"id":"b","type":"function","function":{"name":"music_liked","arguments":"{}"}}]}}]}
        """.utf8)
        let other = try RemoteAgentStep.parse(openAI, provider: .openAICompatible)
        XCTAssertEqual(other.calls.map(\.call.name), ["music_search", "music_liked"])
        XCTAssertEqual(other.calls.first?.call.arguments["query"], .string("chill"))
    }

    /// A real response, captured verbatim from a LiteLLM proxy answering the
    /// second turn of "find lazy music and play" — the turn that had just been
    /// shown an empty search result. Hand-written fixtures agree with the parser
    /// by construction; this one was produced by a provider that had never
    /// heard of it, including the fields Baton doesn't read
    /// (`provider_specific_fields`) and its own tool-call id format.
    func testTheParserHandlesAVerbatimProviderResponse() throws {
        let captured = Data("""
        {"choices":[{"finish_reason":"tool_calls","index":0,"message":{
        "content":"Nothing called \\"lazy music\\" — but your library uses \\"chill\\" for that vibe. Playing your chill tracks.",
        "role":"assistant","provider_specific_fields":{},
        "tool_calls":[{"id":"chatcmpl-tool-aa42276a1d678663","type":"function",
        "function":{"arguments":"{\\"query\\": \\"chill\\"}","name":"music_play"}}]}}]}
        """.utf8)

        let step = try RemoteAgentStep.parse(captured, provider: .openAICompatible)
        XCTAssertEqual(step.calls.count, 1)
        XCTAssertEqual(step.calls.first?.call.name, "music_play")
        XCTAssertEqual(step.calls.first?.call.arguments["query"], .string("chill"))
        XCTAssertEqual(step.calls.first?.id, "chatcmpl-tool-aa42276a1d678663")
        XCTAssertTrue(step.text?.contains("chill") == true, step.text ?? "nil")
    }

    /// Deliberation that overruns the token budget looks like "it had nothing to
    /// say", which would be reported as an unroutable sentence.
    func testTruncationIsDistinguishedFromHavingNothingToSay() {
        let data = Data(#"{"content":[],"stop_reason":"max_tokens"}"#.utf8)
        XCTAssertThrowsError(try RemoteAgentStep.parse(data, provider: .anthropic)) { error in
            guard case RemoteNaturalLanguage.Failure.truncated = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }
}

// MARK: - Reading an answer

final class RemoteChoiceResolutionTests: XCTestCase {
    private let prompt = RemoteChoicePrompt(
        question: "Which one?",
        options: [
            RemoteChoice(label: "Chillout", command: "play chill"),
            RemoteChoice(label: "Ambient", command: "play ambient"),
        ],
        recommended: 0
    )

    /// People answer a question four different ways, and a button is a fifth.
    func testEveryNaturalWayOfAnsweringResolves() {
        for answer in ["2", "pick 2", "second", "the second", "2.", "Ambient", "ambient"] {
            XCTAssertEqual(
                RemotePendingChoices.resolve(answer, in: prompt)?.command, "play ambient",
                "“\(answer)” should have picked the ambient one"
            )
        }
        XCTAssertEqual(RemotePendingChoices.resolve("1", in: prompt)?.command, "play chill")
        XCTAssertEqual(RemotePendingChoices.resolve("first", in: prompt)?.command, "play chill")
    }

    /// "yeah" is consent, not confusion — take the recommendation rather than
    /// asking the same question again.
    func testAgreementTakesTheRecommendation() {
        for answer in ["yes", "yeah", "sure", "whatever", "you pick", "surprise me"] {
            XCTAssertEqual(
                RemotePendingChoices.resolve(answer, in: prompt)?.command, "play chill", answer
            )
        }
    }

    /// Anything that isn't an answer must fall through to the normal command
    /// path — a new request is not a vote.
    func testUnrelatedMessagesDoNotCountAsAnAnswer() {
        for answer in ["pause", "play radiohead", "3", "what's playing"] {
            XCTAssertNil(RemotePendingChoices.resolve(answer, in: prompt), answer)
        }
    }

    /// With "Chill" and "Chillout" both offered, a partial word is a coin flip.
    /// Falling through beats guessing.
    func testAnAmbiguousLabelIsNotGuessed() {
        let ambiguous = RemoteChoicePrompt(
            question: "Which?",
            options: [
                RemoteChoice(label: "Chill", command: "play chill"),
                RemoteChoice(label: "Chillout", command: "play chillout"),
            ]
        )
        XCTAssertNil(RemotePendingChoices.resolve("chill", in: ambiguous))
        // The numbers still work, which is why they're always printed.
        XCTAssertEqual(RemotePendingChoices.resolve("2", in: ambiguous)?.command, "play chillout")
    }

    /// Caught against a real model: asked for the command to run, it answered
    /// with the *tool name* and put the artist in the label. An option that does
    /// nothing when tapped is worse than not offering it.
    func testACommandWrittenAsAToolNameIsRepaired() {
        let prompt = RemoteChoicePrompt(arguments: [
            "question": .string("Which Dido?"),
            "label_1": .string("DIDO"), "command_1": .string("music_play"),
            "label_2": .string("Dido"), "command_2": .string("music_play white flag"),
        ])
        // The label is the only description of the option there is, so it's what
        // a bare tool name has to borrow.
        XCTAssertEqual(prompt?.options.first?.command, "play DIDO")
        XCTAssertEqual(prompt?.options.last?.command, "play white flag")

        // Every repaired command must actually resolve to a tool, or the button
        // is decoration.
        for option in prompt?.options ?? [] {
            guard case .tool = RemoteCommandParser.parse(option.command) else {
                return XCTFail("“\(option.command)” doesn't run anything")
            }
        }
    }

    /// A real command must survive untouched — repair is a backstop, not a
    /// rewrite of everything that comes through.
    func testWellFormedCommandsAreLeftAlone() {
        XCTAssertEqual(RemoteChoicePrompt.repair("play chill", label: "Chillout"), "play chill")
        XCTAssertEqual(RemoteChoicePrompt.repair("mix ambient 45", label: "Ambient"), "mix ambient 45")
        XCTAssertEqual(RemoteChoicePrompt.repair("playlist trance", label: "Trance"), "playlist trance")
    }

    /// The model sends options flattened; a prompt with fewer than two real
    /// options isn't a question.
    func testPromptRejectsTooFewOptions() {
        XCTAssertNil(RemoteChoicePrompt(arguments: [
            "question": .string("Which?"),
            "label_1": .string("Only"), "command_1": .string("play x"),
        ]))
        XCTAssertNil(RemoteChoicePrompt(arguments: [
            "label_1": .string("A"), "command_1": .string("play a"),
            "label_2": .string("B"), "command_2": .string("play b"),
        ]))
    }

    /// An out-of-range or missing `recommended` must still leave something safe
    /// to auto-pick, because silence will eventually run it.
    func testRecommendationAlwaysResolvesToARealOption() {
        let arguments: [String: RemoteArgument] = [
            "question": .string("Which?"),
            "label_1": .string("A"), "command_1": .string("play a"),
            "label_2": .string("B"), "command_2": .string("play b"),
            "recommended": .int(9),
        ]
        let prompt = RemoteChoicePrompt(arguments: arguments)
        XCTAssertEqual(prompt?.recommendedChoice.command, "play a")
    }
}
