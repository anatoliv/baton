import XCTest
@testable import Baton
@testable import BatonAgentKit

/// The security boundary for chat control. A bot token is *not* a credential:
/// anyone who finds the bot can message it, so every inbound message is checked
/// against an allowlist that starts empty and authorizes nobody.
@MainActor
final class RemoteAuthorizationTests: XCTestCase {
    private func makeRouter() -> (RemoteCommandRouter, RemoteControlSettings) {
        // `.testing` routes defaults and secrets to isolated in-memory stores,
        // so nothing here touches the login Keychain or real preferences.
        let settings = RemoteControlSettings(
            environment: .testing,
            defaults: UserDefaults(suiteName: "baton.remote.tests.\(UUID().uuidString)")!,
            secrets: InMemorySecretStore()
        )
        let music = MusicModel(environment: .testing)
        let focus = BatonAudioFocusRegistry()
        let router = RemoteCommandRouter(
            player: music.music,
            tools: MCPToolSurface(music: music, focus: focus),
            settings: settings
        )
        return (router, settings)
    }

    private func inbound(_ text: String, sender: String = "42", channel: String = "c1") -> RemoteInbound {
        RemoteInbound(
            platform: .telegram, senderID: sender, senderName: "tester",
            channelID: channel, text: text
        )
    }

    // MARK: Fail closed

    func testUnknownSenderCannotControlPlayback() async {
        let (router, _) = makeRouter()
        let reply = await router.handle(inbound("pause"))
        let text = try? XCTUnwrap(reply?.text)
        XCTAssertTrue(text?.contains("isn't authorized") == true, text ?? "nil")
    }

    /// The empty allowlist is the default state after install — it must deny,
    /// not wave everyone through.
    func testEmptyAllowlistAuthorizesNobody() async {
        let (router, settings) = makeRouter()
        XCTAssertTrue(settings.telegram.allowedSenders.isEmpty)
        let reply = await router.handle(inbound("next"))
        XCTAssertTrue(reply?.text.contains("isn't authorized") == true)
    }

    func testAuthorizedSenderIsLetThrough() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        let reply = await router.handle(inbound("help"))
        XCTAssertEqual(reply?.text, RemoteCommandRouter.helpText)
    }

    /// Authorizing on one platform must not authorize the same id on the other —
    /// Telegram and Discord ids are unrelated namespaces.
    func testAuthorizationDoesNotCrossPlatforms() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)

        let onDiscord = RemoteInbound(
            platform: .discord, senderID: "42", senderName: "tester",
            channelID: "c1", text: "help"
        )
        let reply = await router.handle(onDiscord)
        XCTAssertTrue(reply?.text.contains("isn't authorized") == true)
    }

    func testChannelRestrictionNarrowsAnAuthorizedSender() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        var config = settings.telegram
        config.allowedChannels = ["allowed-channel"]
        settings.telegram = config

        let denied = await router.handle(inbound("help", channel: "other-channel"))
        XCTAssertTrue(denied?.text.contains("isn't authorized") == true)

        let allowed = await router.handle(inbound("help", channel: "allowed-channel"))
        XCTAssertEqual(allowed?.text, RemoteCommandRouter.helpText)
    }

    // MARK: Linking

    func testCorrectLinkCodeAuthorizesTheSender() async {
        let (router, settings) = makeRouter()
        let code = settings.linkCode

        let reply = await router.handle(inbound("/link \(code)"))
        XCTAssertTrue(reply?.text.contains("Linked") == true, reply?.text ?? "nil")
        XCTAssertTrue(settings.telegram.allowedSenders.contains("42"))
    }

    func testWrongLinkCodeChangesNothing() async {
        let (router, settings) = makeRouter()
        let reply = await router.handle(inbound("/link 000000-not-a-code"))
        XCTAssertTrue(reply?.text.contains("isn't right") == true, reply?.text ?? "nil")
        XCTAssertTrue(settings.telegram.allowedSenders.isEmpty)
    }

    /// The code is single-use: it's typed into a chat, so it ends up in a message
    /// history that may be backed up, forwarded, or read over someone's shoulder.
    func testLinkCodeIsSpentOnUse() async {
        let (router, settings) = makeRouter()
        let code = settings.linkCode
        _ = await router.handle(inbound("/link \(code)"))
        XCTAssertNotEqual(settings.linkCode, code)

        // A second person replaying the same code gets nothing.
        let replay = await router.handle(inbound("/link \(code)", sender: "99"))
        XCTAssertTrue(replay?.text.contains("isn't right") == true)
        XCTAssertFalse(settings.telegram.allowedSenders.contains("99"))
    }

    func testUnknownSenderCannotDoAnythingExceptLink() async {
        let (router, settings) = makeRouter()
        // Every one of these is a real command for an authorized user.
        for text in ["pause", "vol 100", "play something", "stop", "help"] {
            let reply = await router.handle(inbound(text))
            XCTAssertTrue(
                reply?.text.contains("isn't authorized") == true,
                "\(text) leaked through the allowlist"
            )
        }
        XCTAssertTrue(settings.telegram.allowedSenders.isEmpty)
    }

    func testRevokeRemovesAccess() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.revoke(sender: "42", on: .telegram)
        let reply = await router.handle(inbound("help"))
        XCTAssertTrue(reply?.text.contains("isn't authorized") == true)
    }

    // MARK: Natural language gating

    /// With no model configured, unrecognized text must say so rather than
    /// silently doing nothing — and must not attempt a network call.
    func testUnrecognizedTextExplainsItselfWhenNaturalLanguageIsOff() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        let reply = await router.handle(inbound("put on something mellow"))
        let text = reply?.text ?? ""
        XCTAssertTrue(text.contains("help"), text)
        XCTAssertTrue(text.contains("natural language"), text)
    }

    func testNaturalLanguageResolutionIsDispatchedThroughTheToolCatalog() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-ant-test"

        var seen: String?
        router.resolveNaturalLanguage = { message, _, tools, _, _ in
            seen = message
            XCTAssertFalse(tools.isEmpty, "the model must be given Baton's tools")
            // `music_now_playing` needs no server, so this exercises the whole
            // resolve → dispatch → format path without a network round trip.
            return .init(call: RemoteToolCall(name: "music_now_playing"), preamble: "On it.")
        }

        let reply = await router.handle(inbound("what's playing right now"))
        XCTAssertEqual(seen, "what's playing right now")
        XCTAssertTrue(reply?.text.hasPrefix("On it.") == true, reply?.text ?? "nil")
    }

    /// "add this artist to the queue" was unanswerable because the model could
    /// not see the player. The router sits next to the player, so the state
    /// must travel with every natural-language request.
    func testPlayerStateTravelsWithTheRequest() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-test"

        var seenContext: String?
        router.resolveNaturalLanguage = { _, _, _, _, context in
            seenContext = context
            return .init(call: RemoteToolCall(name: "music_now_playing"), preamble: nil)
        }
        _ = await router.handle(inbound("add this artist to the queue please"))
        let context = seenContext ?? ""
        XCTAssertTrue(context.hasPrefix("Player state:"), context)
    }

    /// With nothing playing the context must say so — an absent line would
    /// leave the model guessing, and a stale line would be worse.
    func testIdlePlayerStateIsStatedNotOmitted() {
        let (router, _) = makeRouter()
        XCTAssertEqual(router.playerContext(), "Player state: nothing is playing right now.")
    }

    // MARK: Conversation memory

    /// The gap that made "select one of them" search for those literal words:
    /// each message arrived with no idea what came before it.
    func testFollowUpsCarryThePreviousExchangeAsContext() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-test"

        var seenHistory: [RemoteConversationLog.Turn] = []
        router.resolveNaturalLanguage = { _, _, _, history, _ in
            seenHistory = history
            return .init(call: RemoteToolCall(name: "music_now_playing"), preamble: nil)
        }

        _ = await router.handle(inbound("show me tracks for dido"))
        _ = await router.handle(inbound("select one of them"))

        // The first request had nothing to go on; the second must carry both
        // sides of the first exchange, oldest first.
        XCTAssertEqual(seenHistory.count, 2, "expected the prior user + assistant turns")
        XCTAssertEqual(seenHistory.first?.role, "user")
        XCTAssertEqual(seenHistory.first?.text, "show me tracks for dido")
        XCTAssertEqual(seenHistory.last?.role, "assistant")
    }

    /// Typed commands are remembered too — a follow-up to "play dido" deserves
    /// the same context as a follow-up to a spoken request.
    func testTypedCommandsAlsoBecomeContext() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        _ = await router.handle(inbound("np"))
        let history = router.conversation.history(for: "telegram:c1")
        XCTAssertEqual(history.first?.text, "np")
    }

    // MARK: Second reading

    /// "play the second one" is a reference, not a song title — but `play` is a
    /// command verb, so the parser claims it and searches literally. When that
    /// search finds nothing, the model gets a turn with the conversation in hand.
    func testAFailedLiteralSearchGetsASecondReadingFromTheModel() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-test"

        var asked: String?
        router.resolveNaturalLanguage = { text, _, _, _, _ in
            asked = text
            return .init(call: RemoteToolCall(name: "music_now_playing"), preamble: nil)
        }

        // No server in tests, so the search fails — which is the trigger.
        let reply = await router.handle(inbound("play the second one"))
        XCTAssertEqual(asked, "play the second one", "the model should get the original words")
        XCTAssertFalse(reply?.text.contains("No songs matched") == true, reply?.text ?? "nil")
    }

    /// The hole that swallowed "find lazy music and play": a search that matches
    /// nothing is not a tool *error*, so the reply came back clean and the second
    /// reading — the one that would have noticed "and play" — never happened.
    func testASearchThatMatchedNothingCountsAsAFailureSoItGetsASecondReading() {
        let call = RemoteToolCall(
            name: "music_search", arguments: ["query": .string("lazy music and play")])
        let reply = RemoteCommandRouter.reply(
            for: call, result: #"{"songs":[],"albums":[],"artists":[]}"#, isError: false)

        XCTAssertTrue(reply.isFailure, "an empty search must be eligible for a second reading")
        XCTAssertTrue(reply.text.contains("lazy music and play"), reply.text)
    }

    func testASearchWithHitsIsNotRetried() {
        let call = RemoteToolCall(name: "music_search", arguments: ["query": .string("dido")])
        let reply = RemoteCommandRouter.reply(
            for: call,
            result: #"{"songs":[],"albums":[],"artists":[{"id":"1","name":"Dido"}]}"#,
            isError: false
        )
        XCTAssertFalse(reply.isFailure, "an artist match is an answer, not a miss")
    }

    /// The retry costs a request, so it's only for tools where the *words* can
    /// fail while the intent is sound — not for, say, a bad volume number.
    func testNonQueryFailuresAreNotRetried() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-test"

        var asked = false
        router.resolveNaturalLanguage = { _, _, _, _, _ in
            asked = true
            return .init(call: RemoteToolCall(name: "music_now_playing"), preamble: nil)
        }
        _ = await router.handle(inbound("seek 1:30")) // no track loaded → fails
        XCTAssertFalse(asked, "a seek failure is not a misread sentence")
    }

    /// With no model configured the literal answer has to stand — silently
    /// swallowing it would leave the user with nothing at all.
    func testWithoutAModelTheLiteralFailureIsStillReported() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        let reply = await router.handle(inbound("play the second one"))
        XCTAssertTrue(reply?.isFailure == true, reply?.text ?? "nil")
    }

    /// 0.13.0 shipped a crash that killed the app on the *first* agent-mode
    /// message, and every test passed: each one replaced `resolveAgent` with a
    /// stub, so the real closure — the only thing that runs in production — was
    /// never once executed. Invoking it hopped off the main actor and then
    /// called main-actor-isolated code, tripping `swift_task_checkIsolated`
    /// inside `BatonMCPToolCatalog.definitions()` before any network call.
    ///
    /// So this test runs the shipped closure. It needs no model and no server:
    /// the crash happened while building the tool list, which is evaluated
    /// before the config is even looked at. Reaching a thrown error at all is
    /// the assertion; without the isolation annotation this traps and takes the
    /// whole test process with it.
    func testTheRealAgentClosureRunsOnTheMainActor() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        // Deliberately NOT configured, so nothing leaves the machine.
        settings.naturalLanguage.isEnabled = false

        do {
            _ = try await router.resolveAgent("play something lazy", [], nil, "telegram:c1")
            XCTFail("expected .notConfigured from an unconfigured model")
        } catch {
            XCTAssertTrue(
                error is RemoteNaturalLanguage.Failure,
                "reached the loop and failed properly rather than trapping: \(error)"
            )
        }
    }

    // MARK: A verb that matched, an argument that didn't

    /// The shipped bug, at the router: "rate 4 this track and list similar by
    /// the same artist" printed the command list. The parser claimed `rate`,
    /// couldn't read the rest as an integer, and answered `.help` — terminal,
    /// so the model never saw a sentence that plainly meant two things.
    func testACompoundCommandReachesTheModelInsteadOfTheManual() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-test"
        settings.naturalLanguage.isAgentEnabled = true

        var asked: String?
        router.resolveAgent = { message, _, _, _ in
            asked = message
            return RemoteAgent.Outcome(text: "Rated 4. Here's more by DIDO.", toolsRun: ["music_rate"])
        }

        let reply = await router.handle(inbound("rate 4 this track and list similar by the same artist"))
        XCTAssertEqual(asked, "rate 4 this track and list similar by the same artist",
                       "the model needs the whole sentence, both halves of it")
        XCTAssertFalse(reply?.text.contains("Playback —") == true, "must not be the command list")
    }

    /// With no model to ask, say what the verb wanted — not the whole manual.
    func testWithoutAModelTheAnswerIsTheOneThingTheVerbNeeded() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)

        let reply = await router.handle(inbound("rate 4 this track and list similar"))
        XCTAssertTrue(reply?.text.contains("0 to 5") == true, reply?.text ?? "nil")
        XCTAssertFalse(reply?.text.contains("Playback —") == true, "not the whole command list")
    }

    // MARK: Asking, answering, and not answering

    /// A router configured for agent mode, whose agent always asks the same
    /// question. The options run `np`/`pause` — real commands that need no
    /// server, so the whole path is exercised offline.
    private func makeAskingRouter(
        recommended: Int = 0
    ) -> (RemoteCommandRouter, RemoteControlSettings) {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-test"
        settings.naturalLanguage.isAgentEnabled = true
        router.resolveAgent = { _, _, _, _ in
            RemoteAgent.Outcome(
                text: "Two different Didos in here.",
                choice: RemoteChoicePrompt(
                    question: "Which one?",
                    options: [
                        RemoteChoice(label: "Trance DIDO", command: "np", detail: "34 plays"),
                        RemoteChoice(label: "Singer Dido", command: "pause"),
                    ],
                    recommended: recommended
                )
            )
        }
        return (router, settings)
    }

    func testAQuestionComesBackWithItsOptionsAsButtons() async {
        let (router, _) = makeAskingRouter()
        let reply = await router.handle(inbound("play dido"))

        XCTAssertEqual(reply?.choices.map(\.label), ["Trance DIDO", "Singer Dido"])
        // The numbers are printed too — buttons don't survive every client.
        XCTAssertTrue(reply?.text.contains("*1.* Trance DIDO") == true, reply?.text ?? "nil")
        XCTAssertTrue(reply?.text.contains("34 plays") == true, "the deciding fact must show")
        XCTAssertTrue(reply?.text.contains("Two different Didos") == true, "keep the finding")
    }

    /// A bare "2" is not a command, and would have been read as plain English
    /// before. With a question outstanding it's an answer.
    func testATypedNumberAnswersTheQuestion() async {
        let (router, _) = makeAskingRouter()
        _ = await router.handle(inbound("play dido"))

        let answer = await router.handle(inbound("2"))
        // Option 2 is `pause`, which reports the player state.
        XCTAssertFalse(answer?.text.contains("Which one?") == true, "must not re-ask")
        XCTAssertNil(router.pending.prompt(for: "telegram:c1"), "the question is spent")
    }

    /// The user's requirement: silence is an answer. Nobody replies, so the
    /// recommended option runs by itself and says that it did.
    func testSilenceRunsTheRecommendedOptionAndSaysSo() async {
        let (router, _) = makeAskingRouter(recommended: 1)
        router.autoPickDelay = 0.05

        var delivered: [RemoteReply] = []
        router.deliver = { reply, _, _ in delivered.append(reply) }

        _ = await router.handle(inbound("play dido"))
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(delivered.count, 1, "exactly one unprompted message")
        let text = delivered.first?.text ?? ""
        XCTAssertTrue(text.contains("Singer Dido"), "must name what it picked: \(text)")
        XCTAssertTrue(text.hasPrefix("No answer"), text)
        XCTAssertNil(router.pending.prompt(for: "telegram:c1"))
    }

    /// Moving on to something else must disarm the timer. Music starting by
    /// itself a minute after you asked for something different is the failure
    /// mode that would make people switch the whole feature off.
    func testAnUnrelatedMessageCancelsThePendingAutoPick() async {
        let (router, _) = makeAskingRouter()
        router.autoPickDelay = 0.05

        var delivered: [RemoteReply] = []
        router.deliver = { reply, _, _ in delivered.append(reply) }

        _ = await router.handle(inbound("play dido"))
        _ = await router.handle(inbound("pause")) // a new request, not an answer
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(delivered.isEmpty, "the abandoned question must not fire")
        XCTAssertNil(router.pending.prompt(for: "telegram:c1"))
    }

    /// In a group chat, anyone can send messages Baton ignores. Ignoring them
    /// has to include not quietly cancelling the owner's pending question.
    func testAStrangerCannotCancelSomeoneElsesPendingChoice() async {
        let (router, _) = makeAskingRouter(recommended: 1)
        router.autoPickDelay = 0.2

        var delivered: [RemoteReply] = []
        router.deliver = { reply, _, _ in delivered.append(reply) }

        _ = await router.handle(inbound("play dido"))
        _ = await router.handle(inbound("hello", sender: "stranger"))
        XCTAssertNotNil(router.pending.prompt(for: "telegram:c1"), "still waiting on the owner")

        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(delivered.count, 1, "the owner's auto-pick must still fire")
    }

    /// The auto-pick acts on someone's behalf, so it must obey the same
    /// allowlist as everything else — an unauthorized chat can't arm one.
    func testAnUnauthorizedChatNeverArmsAnAutoPick() async {
        let (router, settings) = makeAskingRouter()
        settings.revoke(sender: "42", on: .telegram)
        router.autoPickDelay = 0.05

        var delivered: [RemoteReply] = []
        router.deliver = { reply, _, _ in delivered.append(reply) }

        _ = await router.handle(inbound("play dido"))
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertNil(router.pending.prompt(for: "telegram:c1"))
    }

    /// Agent mode is opt-in. With it off, the single-shot router still runs —
    /// and never sends library contents anywhere.
    func testAgentModeIsOffUnlessSwitchedOn() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-test"
        XCTAssertFalse(settings.naturalLanguage.isAgentEnabled, "must default off")

        var usedAgent = false
        var usedSingleShot = false
        router.resolveAgent = { _, _, _, _ in
            usedAgent = true
            return RemoteAgent.Outcome(text: "agent")
        }
        router.resolveNaturalLanguage = { _, _, _, _, _ in
            usedSingleShot = true
            return .init(call: RemoteToolCall(name: "music_now_playing"), preamble: nil)
        }

        _ = await router.handle(inbound("put on something mellow"))
        XCTAssertFalse(usedAgent)
        XCTAssertTrue(usedSingleShot)
    }

    func testForgetDropsTheThread() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        _ = await router.handle(inbound("np"))
        XCTAssertFalse(router.conversation.history(for: "telegram:c1").isEmpty)

        let reply = await router.handle(inbound("forget"))
        XCTAssertTrue(reply?.text.contains("Forgotten") == true, reply?.text ?? "nil")
        // The `forget` exchange itself is the only thing left.
        let remaining = router.conversation.history(for: "telegram:c1")
        XCTAssertEqual(remaining.filter { $0.text == "np" }.count, 0)
    }

    /// Context is per-chat: one conversation must not leak into another.
    func testThreadsAreScopedToTheirChat() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        _ = await router.handle(inbound("np", channel: "kitchen"))
        XCTAssertTrue(router.conversation.history(for: "telegram:study").isEmpty)
        XCTAssertFalse(router.conversation.history(for: "telegram:kitchen").isEmpty)
    }

    func testNaturalLanguageFailureIsReportedNotSwallowed() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-ant-test"
        router.resolveNaturalLanguage = { _, _, _, _, _ in
            throw RemoteNaturalLanguage.Failure.refused("no")
        }

        let reply = await router.handle(inbound("do something odd"))
        XCTAssertTrue(reply?.text.contains("declined") == true, reply?.text ?? "nil")
    }

    // MARK: The desktop surface

    /// The app's own window is authorized without an allowlist entry.
    ///
    /// This is the one place the fail-closed rule is deliberately not applied, so it needs a
    /// test that says why rather than a comment. The allowlist exists because a bot token is
    /// not a credential — anyone who can message the bot could otherwise drive the speakers.
    /// Nobody is "finding" the Music Friend window: they are already sitting at the Mac that
    /// is playing the music and can press the buttons directly.
    func testTheDesktopWindowIsAuthorizedWithoutAnAllowlist() async {
        let (router, settings) = makeRouter()
        // Explicitly empty — the state that denies every chat platform.
        XCTAssertTrue(settings.config(for: .telegram).allowedSenders.isEmpty)

        let reply = await router.handle(RemoteInbound(
            platform: .desktop, senderID: "desktop", senderName: "You",
            channelID: "desktop", text: "pause"
        ))
        let text = reply?.text ?? ""
        XCTAssertFalse(text.contains("isn't authorized"),
                       "the desktop window was refused by the chat allowlist: \(text)")
    }

    /// Authorizing the desktop must not authorize anyone else.
    ///
    /// The bypass is a single `platform == .desktop` check, and the failure mode worth
    /// guarding is that it widens: a stranger on Telegram must still be refused with the
    /// desktop path in place.
    func testAuthorizingTheDesktopDoesNotAuthorizeTelegram() async {
        let (router, _) = makeRouter()
        _ = await router.handle(RemoteInbound(
            platform: .desktop, senderID: "desktop", senderName: "You",
            channelID: "desktop", text: "pause"
        ))
        let reply = await router.handle(inbound("pause", sender: "stranger"))
        XCTAssertTrue(reply?.text.contains("isn't authorized") == true,
                      "an unknown Telegram sender was let in: \(reply?.text ?? "nil")")
    }

    /// Desktop exchanges are logged as `.mac`, not as a fourth surface.
    ///
    /// One product, one tally. A separate surface would split the Mac's feedback between the
    /// bridges and the window and make both look quieter than they are.
    func testDesktopExchangesAreRecordedAgainstTheMacSurface() {
        XCTAssertEqual(RemoteCommandRouter.surface(for: RemoteInbound(
            platform: .desktop, senderID: "desktop", senderName: "You",
            channelID: "desktop", text: "hello"
        )), .mac)
    }

    /// An unprompted desktop reply reaches the transcript instead of vanishing.
    ///
    /// The router speaks on its own when a pending choice auto-picks, and the desktop has no
    /// channel to push down — so the first version dropped it, which meant music could start
    /// on the Mac with nothing in the window to say why. The sink is what a transcript
    /// subscribes to; this proves the wiring, not the timer.
    func testAnUnpromptedDesktopReplyReachesTheSink() async {
        let music = MusicModel(environment: .testing)
        let focus = BatonAudioFocusRegistry()
        let service = RemoteControlService(
            player: music.music,
            tools: MCPToolSurface(music: music, focus: focus),
            settings: RemoteControlSettings(
                environment: .testing,
                defaults: UserDefaults(suiteName: "baton.sink.tests.\(UUID().uuidString)")!,
                secrets: InMemorySecretStore()
            )
        )
        var delivered: [String] = []
        service.desktopSink = { delivered.append($0.text) }

        await service.deliverForTesting(RemoteReply(text: "started the quiet one"), on: .desktop)
        XCTAssertEqual(delivered, ["started the quiet one"],
                       "an unprompted desktop reply was dropped instead of reaching the window")
    }
}
