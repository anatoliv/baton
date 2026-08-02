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
