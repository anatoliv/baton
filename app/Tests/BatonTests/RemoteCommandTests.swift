import XCTest
@testable import Baton

/// The chat control surface's pure core: what a message means, what comes back,
/// and — most importantly — who is allowed to say it. Everything here is
/// deterministic and offline; the transports are thin adapters over this.
final class RemoteCommandParserTests: XCTestCase {
    private func call(_ text: String) -> RemoteToolCall? {
        guard case let .tool(call) = RemoteCommandParser.parse(text) else { return nil }
        return call
    }

    // MARK: Transport

    func testTransportVerbsAndAliases() {
        XCTAssertEqual(call("pause")?.name, "music_pause")
        XCTAssertEqual(call("/pause")?.name, "music_pause")
        XCTAssertEqual(call("PAUSE")?.name, "music_pause")
        XCTAssertEqual(call("  next  ")?.name, "music_next")
        XCTAssertEqual(call("skip")?.name, "music_next")
        XCTAssertEqual(call("back")?.name, "music_previous")
    }

    /// Telegram appends `@BotName` to commands in group chats; a bare `/pause`
    /// there arrives as `/pause@BatonBot` and must still resolve.
    func testStripsTelegramBotSuffix() {
        XCTAssertEqual(call("/pause@BatonBot")?.name, "music_pause")
        XCTAssertEqual(call("/play@BatonBot miles davis")?.arguments["query"], .string("miles davis"))
    }

    /// Bare `play` is the button-shaped reading of the word — resume, not a
    /// search for the empty string.
    func testBarePlayResumesRatherThanSearching() {
        XCTAssertEqual(call("play")?.name, "music_resume")
        XCTAssertEqual(call("play kind of blue")?.name, "music_play")
        XCTAssertEqual(call("play kind of blue")?.arguments["query"], .string("kind of blue"))
    }

    func testQueueWithoutArgumentsShowsTheQueue() {
        XCTAssertEqual(call("queue")?.name, "music_get_queue")
        XCTAssertEqual(call("queue radiohead")?.name, "music_queue_add")
    }

    // MARK: Numeric arguments

    func testVolumeAcceptsRangeAndRejectsNonsense() {
        XCTAssertEqual(call("vol 40")?.arguments["percent"], .int(40))
        XCTAssertEqual(call("volume 0")?.arguments["percent"], .int(0))
        XCTAssertEqual(call("vol 100")?.arguments["percent"], .int(100))
        XCTAssertEqual(RemoteCommandParser.parse("vol 101"), .help)
        XCTAssertEqual(RemoteCommandParser.parse("vol -5"), .help)
        XCTAssertEqual(RemoteCommandParser.parse("vol loud"), .help)
    }

    func testRatingBounds() {
        XCTAssertEqual(call("rate 5")?.arguments["rating"], .int(5))
        XCTAssertEqual(call("rate 0")?.arguments["rating"], .int(0))
        XCTAssertEqual(RemoteCommandParser.parse("rate 6"), .help)
    }

    func testDurationFormats() {
        XCTAssertEqual(RemoteCommandParser.parseDuration("90"), 90)
        XCTAssertEqual(RemoteCommandParser.parseDuration("1:30"), 90)
        XCTAssertEqual(RemoteCommandParser.parseDuration("1m30s"), 90)
        XCTAssertEqual(RemoteCommandParser.parseDuration("2m"), 120)
        XCTAssertEqual(RemoteCommandParser.parseDuration("45s"), 45)
        XCTAssertNil(RemoteCommandParser.parseDuration("1:75"))
        XCTAssertNil(RemoteCommandParser.parseDuration("later"))
        XCTAssertNil(RemoteCommandParser.parseDuration(""))
    }

    func testSeekUsesTheCatalogsArgumentName() {
        // The tool's schema calls it `seconds`; a mismatch here would fail at
        // dispatch with an unhelpful error rather than at the type level.
        XCTAssertEqual(call("seek 1:30")?.arguments["seconds"], .int(90))
    }

    // MARK: Modes

    func testShuffleAndRepeatNormalizeSynonyms() {
        XCTAssertEqual(call("shuffle on")?.arguments["enabled"], .bool(true))
        XCTAssertEqual(call("shuffle off")?.arguments["enabled"], .bool(false))
        XCTAssertEqual(RemoteCommandParser.parse("shuffle maybe"), .help)

        XCTAssertEqual(call("repeat one")?.arguments["mode"], .string("one"))
        XCTAssertEqual(call("repeat song")?.arguments["mode"], .string("one"))
        XCTAssertEqual(call("repeat queue")?.arguments["mode"], .string("all"))
        XCTAssertEqual(call("repeat none")?.arguments["mode"], .string("off"))
    }

    /// `sleep off` has to become `minutes: 0` — the tool has no cancel flag.
    func testSleepTimerCancelMapsToZeroMinutes() {
        XCTAssertEqual(call("sleep 30")?.arguments["minutes"], .int(30))
        XCTAssertEqual(call("sleep off")?.arguments["minutes"], .int(0))
        XCTAssertEqual(call("sleep cancel")?.arguments["minutes"], .int(0))
        XCTAssertEqual(RemoteCommandParser.parse("sleep soon"), .help)
    }

    // MARK: Likes

    func testLikeAndUnlikeShareAToolAndDifferByFlag() {
        XCTAssertEqual(call("like")?.name, "music_like")
        XCTAssertNil(call("like")?.arguments["unlike"])
        XCTAssertEqual(call("unlike")?.arguments["unlike"], .bool(true))
        XCTAssertEqual(call("like so what")?.arguments["query"], .string("so what"))
    }

    // MARK: Meta

    func testUnknownTextFallsThroughToNaturalLanguage() {
        XCTAssertEqual(
            RemoteCommandParser.parse("put on something mellow"),
            .natural("put on something mellow")
        )
    }

    /// `ask` is the escape hatch for phrases that collide with a verb.
    func testAskForcesNaturalLanguageEvenForVerbLikePhrases() {
        XCTAssertEqual(RemoteCommandParser.parse("ask play something quiet"), .natural("play something quiet"))
        XCTAssertEqual(RemoteCommandParser.parse("ask"), .help)
    }

    func testLinkAndHelpAndEmpty() {
        XCTAssertEqual(RemoteCommandParser.parse("/link 123456"), .link(code: "123456"))
        XCTAssertEqual(RemoteCommandParser.parse("/link"), .help)
        XCTAssertEqual(RemoteCommandParser.parse("help"), .help)
        XCTAssertEqual(RemoteCommandParser.parse("/start"), .help)
        XCTAssertEqual(RemoteCommandParser.parse("   "), .ignore)
    }
}

// MARK: - Result formatting

final class RemoteResultFormatterTests: XCTestCase {
    func testNowPlayingRendersTrackAndPosition() {
        let json = """
        {"state":"playing","summary":"x","queue_length":12,"queue_index":0,
         "now_playing":{"id":"1","title":"So What","artist":"Miles Davis","duration_seconds":544}}
        """
        let out = RemoteResultFormatter.format(tool: "music_now_playing", result: json)
        XCTAssertTrue(out.contains("So What — Miles Davis"), out)
        XCTAssertTrue(out.contains("9:04"), out)
        XCTAssertTrue(out.contains("Track 1 of 12"), out)
    }

    func testStoppedPlayerReadsAsNothingPlaying() {
        let out = RemoteResultFormatter.format(tool: "music_now_playing", result: #"{"state":"stopped"}"#)
        XCTAssertEqual(out, "Nothing playing.")
    }

    /// Most transport tools already answer with a human sentence; those must
    /// pass through untouched rather than being parsed and rebuilt.
    func testPlainSentenceResultsPassThrough() {
        let sentence = "Music volume set to 70."
        XCTAssertEqual(RemoteResultFormatter.format(tool: "music_set_volume", result: sentence), sentence)
    }

    /// A short list is worth printing in full.
    func testAShortPlaylistListIsPrintedInFull() {
        let json = #"{"playlists":[{"name":"Evening","song_count":24},{"name":"Focus","song_count":80}]}"#
        let out = RemoteResultFormatter.format(tool: "music_list_playlists", result: json)
        XCTAssertTrue(out.contains("• Evening (24)"), out)
        XCTAssertTrue(out.contains("• Focus (80)"), out)
        XCTAssertFalse(out.contains("too many"), out)
    }

    /// A long one is not: 25 rows of near-identical names plus "…and 296 more"
    /// is a wall of text you cannot act on. The count and how to open one are
    /// the useful facts.
    func testALongPlaylistListAnswersWithTheCountAndHowToOpenOne() {
        let items = (1...321).map { #"{"name":"02 - Classic Trance (Pt \#($0))","song_count":60}"# }
        let json = #"{"playlists":["# + items.joined(separator: ",") + "]}"
        let out = RemoteResultFormatter.format(tool: "music_list_playlists", result: json)

        XCTAssertTrue(out.contains("321 playlists"), out)
        XCTAssertTrue(out.contains("playlist <name>"), "must say how to open one")
        XCTAssertTrue(out.contains("trance"), "partial-name matching is the actionable part")
        // A handful of examples, not a wall.
        XCTAssertLessThan(out.count, 600, "long lists must not dump rows")
        XCTAssertTrue(out.contains("…and 316 more"), out)
    }

    func testSearchGroupsByKind() {
        let json = """
        {"songs":[{"title":"So What","artist":"Miles Davis","duration_seconds":544}],
         "albums":[{"name":"Kind of Blue","artist":"Miles Davis"}],
         "artists":[{"name":"Miles Davis"}]}
        """
        let out = RemoteResultFormatter.format(tool: "music_search", result: json)
        XCTAssertTrue(out.contains("*Songs*"), out)
        XCTAssertTrue(out.contains("*Albums*"), out)
        XCTAssertTrue(out.contains("Kind of Blue — Miles Davis"), out)
    }

    func testEmptySearchIsStatedPlainly() {
        let out = RemoteResultFormatter.format(tool: "music_search", result: #"{"songs":[],"albums":[],"artists":[]}"#)
        XCTAssertEqual(out, "Nothing matched.")
    }
}

/// Chat platforms refuse oversized messages outright, so an unclamped long
/// reply is a lost reply — the failure mode is silence, the worst one.
final class RemoteReplyClampTests: XCTestCase {
    func testShortTextPassesThrough() {
        XCTAssertEqual(RemoteReply.clamped("hello", to: 100), "hello")
    }

    func testLongTextIsCutOnALineBoundary() {
        let text = (1...300).map { "Track number \($0) — Some Artist" }.joined(separator: "\n")
        let out = RemoteReply.clamped(text, to: 2000)
        XCTAssertLessThanOrEqual(out.count, 2000)
        XCTAssertTrue(out.hasSuffix("…"), "truncation must be visible, not silent")
        // The last visible line is a whole row, not half a title.
        let lastLine = out.dropLast(2).split(separator: "\n").last ?? ""
        XCTAssertTrue(lastLine.hasSuffix("Some Artist"), String(lastLine))
    }
}

// MARK: - Natural language

@MainActor
final class RemoteNaturalLanguageTests: XCTestCase {
    func testToolSchemasRenameTheSchemaKeyAndWithholdRiskyTools() {
        let schemas = RemoteNaturalLanguage.toolSchemas(from: BatonMCPToolCatalog.definitions())
        XCTAssertFalse(schemas.isEmpty)

        for schema in schemas.json {
            XCTAssertNotNil(schema["input_schema"], "Messages API spells it input_schema")
            XCTAssertNil(schema["inputSchema"], "the MCP spelling must not leak through")
        }

        let names = Set(schemas.json.compactMap { $0["name"] as? String })
        // The one destructive tool, and the agent-coordination primitives, are
        // deliberately not reachable from a sentence.
        XCTAssertFalse(names.contains("music_delete_playlist"))
        XCTAssertFalse(names.contains("audio_suspend"))
        XCTAssertFalse(names.contains("audio_resume"))
        XCTAssertFalse(names.contains("speak_summary"))
        XCTAssertTrue(names.contains("music_play"))
        XCTAssertTrue(names.contains("music_build_mix"))
    }

    /// The evaluation caught the model fabricating song_ids. Chat replies never
    /// show ids, so an id parameter on this surface is an invitation to invent —
    /// the schemas offered to the chat model must not carry them.
    func testIdParametersAreStrippedFromChatSchemas() {
        let schemas = RemoteNaturalLanguage.toolSchemas(from: BatonMCPToolCatalog.definitions())
        for schema in schemas.json {
            let props = (schema["input_schema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            let name = schema["name"] as? String ?? "?"
            XCTAssertNil(props["song_ids"], "\(name) still offers song_ids")
            XCTAssertNil(props["playlist_id"], "\(name) still offers playlist_id")
        }
    }

    /// The player state rides at the end of the system prompt in both dialects.
    func testPlayerContextLandsInTheSystemPromptOfBothDialects() throws {
        let context = "Player state: \u{201C}So What\u{201D} by Miles Davis — track 3 of 12 in the queue."

        var anthropic = RemoteControlSettings.NaturalLanguageConfig()
        anthropic.isEnabled = true; anthropic.apiKey = "k"
        let a = try RemoteNaturalLanguage.buildRequest(
            "x", config: anthropic, tools: RemoteToolSchemas(json: []), playerContext: context)
        let aBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(a.httpBody)) as? [String: Any])
        XCTAssertTrue((aBody["system"] as? String)?.hasSuffix(context) == true)

        var openAI = RemoteControlSettings.NaturalLanguageConfig()
        openAI.isEnabled = true; openAI.apiKey = "k"; openAI.provider = .openAICompatible
        openAI.baseURL = "https://api.openai.com/v1"
        let o = try RemoteNaturalLanguage.buildRequest(
            "x", config: openAI, tools: RemoteToolSchemas(json: []), playerContext: context)
        let oBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(o.httpBody)) as? [String: Any])
        let system = (oBody["messages"] as? [[String: Any]])?.first?["content"] as? String
        XCTAssertTrue(system?.hasSuffix(context) == true)
    }

    func testParsesAToolCall() throws {
        let body = """
        {"content":[{"type":"tool_use","id":"t1","name":"music_play","input":{"query":"miles davis"}}],
         "stop_reason":"tool_use"}
        """
        let resolution = try RemoteNaturalLanguage.parse(Data(body.utf8))
        XCTAssertEqual(resolution.call.name, "music_play")
        XCTAssertEqual(resolution.call.arguments["query"], .string("miles davis"))
        XCTAssertNil(resolution.preamble)
    }

    /// JSONSerialization hands back NSNumber for both booleans and integers, and
    /// `NSNumber(1) as? Bool` is `true` — so a naive cast turns
    /// `{"percent": 1}` into `{"percent": true}` and the volume tool rejects it.
    func testIntegerArgumentsAreNotMisreadAsBooleans() throws {
        let body = """
        {"content":[{"type":"tool_use","id":"t1","name":"music_set_volume","input":{"percent":1}}]}
        """
        let resolution = try RemoteNaturalLanguage.parse(Data(body.utf8))
        XCTAssertEqual(resolution.call.arguments["percent"], .int(1))
    }

    func testBooleanArgumentsSurviveAsBooleans() throws {
        let body = """
        {"content":[{"type":"tool_use","id":"t1","name":"music_set_shuffle","input":{"enabled":true}}]}
        """
        let resolution = try RemoteNaturalLanguage.parse(Data(body.utf8))
        XCTAssertEqual(resolution.call.arguments["enabled"], .bool(true))
    }

    func testCapturesTextAlongsideTheToolCall() throws {
        let body = """
        {"content":[{"type":"text","text":"Sure — putting on something quiet."},
                    {"type":"tool_use","id":"t1","name":"music_play","input":{"query":"ambient"}}]}
        """
        let resolution = try RemoteNaturalLanguage.parse(Data(body.utf8))
        XCTAssertEqual(resolution.preamble, "Sure — putting on something quiet.")
    }

    /// A refusal is an HTTP 200 with empty content — reading `content[0]`
    /// without checking `stop_reason` first is how that becomes a crash.
    func testRefusalIsSurfacedRatherThanTreatedAsEmpty() {
        let body = #"{"content":[],"stop_reason":"refusal","stop_details":{"explanation":"nope"}}"#
        XCTAssertThrowsError(try RemoteNaturalLanguage.parse(Data(body.utf8))) { error in
            guard case RemoteNaturalLanguage.Failure.refused = error else {
                return XCTFail("expected .refused, got \(error)")
            }
        }
    }

    /// Thinking counts against `max_tokens`, so a long deliberation can end the
    /// response before the tool call is emitted. That must not be reported as
    /// "I couldn't turn that into a command" — the sentence was fine, the budget
    /// wasn't, and those need different answers.
    func testTruncatedResponseIsDistinguishedFromAnUnroutableSentence() {
        let body = #"{"content":[],"stop_reason":"max_tokens"}"#
        XCTAssertThrowsError(try RemoteNaturalLanguage.parse(Data(body.utf8))) { error in
            guard case RemoteNaturalLanguage.Failure.truncated = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }

    func testResponseWithNoToolCallThrows() {
        let body = #"{"content":[{"type":"text","text":"I'm not sure what to play."}],"stop_reason":"end_turn"}"#
        XCTAssertThrowsError(try RemoteNaturalLanguage.parse(Data(body.utf8))) { error in
            guard case RemoteNaturalLanguage.Failure.noToolCall = error else {
                return XCTFail("expected .noToolCall, got \(error)")
            }
        }
    }

    func testRequestOmitsParametersTheModelWouldReject() throws {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.apiKey = "sk-ant-test"

        let request = try RemoteNaturalLanguage.buildRequest("play something", config: config, tools: RemoteToolSchemas(json: []))
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        // Sampling parameters are rejected outright by current models.
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])
        // Routing is the whole job, so a tool call is required, not optional.
        XCTAssertEqual((body["tool_choice"] as? [String: Any])?["type"] as? String, "any")
    }

    // MARK: OpenAI-compatible dialect

    private func openAIConfig(base: String = "https://api.openai.com/v1") -> RemoteControlSettings.NaturalLanguageConfig {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.provider = .openAICompatible
        config.apiKey = "sk-test"
        config.model = "gpt-4o-mini"
        config.baseURL = base
        return config
    }

    /// Every part of the wire format differs from Anthropic's: the path, the auth
    /// header, where the system prompt goes, how tools are wrapped, and how a
    /// tool call is forced.
    func testOpenAIRequestUsesTheChatCompletionsWireFormat() throws {
        let tools = RemoteNaturalLanguage.toolSchemas(from: BatonMCPToolCatalog.definitions())
        let request = try RemoteNaturalLanguage.buildRequest("skip this", config: openAIConfig(), tools: tools)

        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"), "that's the Anthropic header")
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["tool_choice"] as? String, "required")
        // Anthropic-only knobs must not leak into a dialect that 400s on them.
        XCTAssertNil(body["system"])
        XCTAssertNil(body["output_config"])
        XCTAssertNil(body["max_tokens"], "this dialect renamed it on newer models; omitting avoids the 400")

        // The system prompt rides as a message here, not a top-level field.
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, "skip this")

        // Tools nest under `function`, and the schema key is `parameters`.
        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["type"] as? String, "function")
        let function = try XCTUnwrap(tool["function"] as? [String: Any])
        XCTAssertNotNil(function["name"])
        XCTAssertNotNil(function["parameters"])
        XCTAssertNil(function["input_schema"], "that's the Anthropic spelling")
    }

    /// `arguments` arrives as a JSON *string*, not an object — decoding it as an
    /// object would silently drop every argument.
    func testOpenAIToolCallArgumentsAreDecodedFromTheirJSONString() throws {
        let body = """
        {"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"c1","type":"function","function":{
            "name":"music_play","arguments":"{\\"query\\":\\"kind of blue\\",\\"limit\\":5}"}}]}}]}
        """
        let resolution = try RemoteNaturalLanguage.parse(Data(body.utf8), provider: .openAICompatible)
        XCTAssertEqual(resolution.call.name, "music_play")
        XCTAssertEqual(resolution.call.arguments["query"], .string("kind of blue"))
        XCTAssertEqual(resolution.call.arguments["limit"], .int(5))
    }

    func testOpenAITruncationAndMissingCallAreDistinguished() {
        let truncated = #"{"choices":[{"finish_reason":"length","message":{"content":""}}]}"#
        XCTAssertThrowsError(try RemoteNaturalLanguage.parse(Data(truncated.utf8), provider: .openAICompatible)) {
            guard case RemoteNaturalLanguage.Failure.truncated = $0 else {
                return XCTFail("expected .truncated, got \($0)")
            }
        }
        let chatty = #"{"choices":[{"finish_reason":"stop","message":{"content":"I'm not sure."}}]}"#
        XCTAssertThrowsError(try RemoteNaturalLanguage.parse(Data(chatty.utf8), provider: .openAICompatible)) {
            guard case RemoteNaturalLanguage.Failure.noToolCall = $0 else {
                return XCTFail("expected .noToolCall, got \($0)")
            }
        }
    }

    /// People paste whichever URL their provider's docs showed them. Both forms
    /// have to land on the same endpoint, or the failure is a bare 404.
    func testEndpointNormalizationAcceptsRootOrFullURL() throws {
        for base in ["https://api.openai.com/v1", "https://api.openai.com/v1/chat/completions", "https://api.openai.com"] {
            XCTAssertEqual(
                try RemoteNaturalLanguage.endpoint(for: openAIConfig(base: base)).absoluteString,
                "https://api.openai.com/v1/chat/completions",
                "base \(base)"
            )
        }
        for base in ["https://api.anthropic.com", "https://api.anthropic.com/", "https://api.anthropic.com/v1/messages"] {
            var config = RemoteControlSettings.NaturalLanguageConfig()
            config.baseURL = base
            XCTAssertEqual(
                try RemoteNaturalLanguage.endpoint(for: config).absoluteString,
                "https://api.anthropic.com/v1/messages",
                "base \(base)"
            )
        }
    }

    /// A self-hosted OpenAI-compatible server (vLLM, Ollama, LM Studio) is the
    /// point of this dialect — it must survive a plain-http LAN address.
    func testSelfHostedEndpointsAreSupported() throws {
        let config = openAIConfig(base: "http://ai-01.local:8000/v1")
        XCTAssertNil(RemoteNaturalLanguage.complaint(about: config))
        XCTAssertEqual(
            try RemoteNaturalLanguage.endpoint(for: config).absoluteString,
            "http://ai-01.local:8000/v1/chat/completions"
        )
    }

    func testProviderMismatchIsNamedWithTheFix() throws {
        var anthropicWithOpenAIURL = RemoteControlSettings.NaturalLanguageConfig()
        anthropicWithOpenAIURL.apiKey = "k"
        anthropicWithOpenAIURL.baseURL = "https://api.openai.com/v1/chat/completions"
        let a = try XCTUnwrap(RemoteNaturalLanguage.complaint(about: anthropicWithOpenAIURL))
        XCTAssertTrue(a.contains("OpenAI-compatible"), a)

        var openAIWithAnthropicURL = openAIConfig(base: "https://api.anthropic.com")
        openAIWithAnthropicURL.provider = .openAICompatible
        let b = try XCTUnwrap(RemoteNaturalLanguage.complaint(about: openAIWithAnthropicURL))
        XCTAssertTrue(b.contains("Anthropic"), b)
    }

    /// macOS reports a blocked *local network* as "the Internet connection
    /// appears to be offline" — a claim the user can see through, since the chat
    /// message that triggered it arrived over the internet seconds earlier.
    func testALocalHostBlockedByMacOSNamesThePrivacySetting() {
        let failure = RemoteNaturalLanguage.transportFailure(
            URLError(.notConnectedToInternet), host: "192.168.3.8"
        )
        guard case let .localNetworkBlocked(host) = failure else {
            return XCTFail("expected .localNetworkBlocked, got \(failure)")
        }
        XCTAssertEqual(host, "192.168.3.8")
        XCTAssertTrue(failure.errorDescription?.contains("Local Network") == true)
    }

    /// The same error against a public host really does mean offline, and must
    /// not be dressed up as a privacy setting.
    func testAPublicHostKeepsTheOfflineReading() {
        let failure = RemoteNaturalLanguage.transportFailure(
            URLError(.notConnectedToInternet), host: "api.anthropic.com"
        )
        if case .localNetworkBlocked = failure {
            XCTFail("a public host is not a local-network problem")
        }
    }

    func testAnUnansweredHostIsReportedAsSuch() {
        let failure = RemoteNaturalLanguage.transportFailure(
            URLError(.cannotConnectToHost), host: "ai-01.local"
        )
        guard case .unreachable = failure else {
            return XCTFail("expected .unreachable, got \(failure)")
        }
    }

    func testPrivateHostDetection() {
        for host in ["192.168.3.8", "10.0.0.5", "172.16.4.1", "172.31.255.1", "localhost", "ai-01.local", "127.0.0.1"] {
            XCTAssertTrue(RemoteNaturalLanguage.isPrivate(host), host)
        }
        for host in ["api.openai.com", "api.anthropic.com", "172.32.0.1", "8.8.8.8"] {
            XCTAssertFalse(RemoteNaturalLanguage.isPrivate(host), host)
        }
    }

    /// A provider's own wording can be accurate and still useless. LiteLLM
    /// answers a key it can't recognize with `400 "No connected db."`, which
    /// reads like a server outage rather than a wrong key.
    func testOpaqueProviderErrorsGetAnActionableHint() {
        let liteLLM = RemoteNaturalLanguage.hint(status: 400, body: #"{"error":{"message":"No connected db.","type":"no_db_connection"}}"#)
        XCTAssertTrue(liteLLM.contains("key"), liteLLM)

        XCTAssertTrue(RemoteNaturalLanguage.hint(status: 401, body: "invalid x-api-key").contains("API key"))
        XCTAssertTrue(RemoteNaturalLanguage.hint(status: 404, body: "not found").contains("base URL"))
        XCTAssertEqual(RemoteNaturalLanguage.hint(status: 500, body: "overloaded"), "", "no guess when there's nothing to guess")
    }

    // MARK: Settings validation

    private func config(base: String, key: String = "sk-ant-test") -> RemoteControlSettings.NaturalLanguageConfig {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.apiKey = key
        config.baseURL = base
        return config
    }

    func testMissingPiecesAreNamedIndividually() {
        XCTAssertNotNil(RemoteNaturalLanguage.complaint(about: config(base: "")))
        XCTAssertNotNil(RemoteNaturalLanguage.complaint(about: config(base: "api.anthropic.com")))
        XCTAssertNotNil(RemoteNaturalLanguage.complaint(about: config(base: "https://api.anthropic.com", key: "")))
    }

    func testAValidConfigurationDrawsNoComplaint() {
        XCTAssertNil(RemoteNaturalLanguage.complaint(about: config(base: "https://api.anthropic.com")))
        XCTAssertNil(RemoteNaturalLanguage.complaint(about: config(base: "https://api.anthropic.com/")))
    }

    func testTrailingSlashInBaseURLDoesNotDoubleUp() throws {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.apiKey = "k"
        config.baseURL = "https://gateway.example.com/"
        let request = try RemoteNaturalLanguage.buildRequest("x", config: config, tools: RemoteToolSchemas(json: []))
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example.com/v1/messages")
    }
}

// MARK: - Discord text handling

final class DiscordTextTests: XCTestCase {
    /// Replies are authored in Telegram's flavour; Discord reads a single
    /// asterisk as italic, so pairs are promoted to `**`.
    func testEmphasisIsPromotedForDiscord() {
        XCTAssertEqual(DiscordBridge.emphasize("*Songs*\nfoo"), "**Songs**\nfoo")
    }

    /// A lone asterisk (a track called `*` or a stray one) must not turn the
    /// remainder of the message bold.
    func testUnbalancedEmphasisIsLeftAlone() {
        XCTAssertEqual(DiscordBridge.emphasize("2 * 3 is six"), "2 * 3 is six")
    }

    func testLeadingMentionIsStripped() {
        XCTAssertEqual(DiscordBridge.stripLeadingMention("<@12345> pause"), "pause")
        XCTAssertEqual(DiscordBridge.stripLeadingMention("<@!12345>  play jazz"), "play jazz")
        XCTAssertEqual(DiscordBridge.stripLeadingMention("pause"), "pause")
    }
}
