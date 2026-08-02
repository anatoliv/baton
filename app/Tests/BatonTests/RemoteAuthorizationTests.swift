import XCTest
@testable import Baton

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
        let router = RemoteCommandRouter(
            music: MusicModel(environment: .testing),
            focus: BatonAudioFocusRegistry(),
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
        router.resolveNaturalLanguage = { message, _, tools in
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

    func testNaturalLanguageFailureIsReportedNotSwallowed() async {
        let (router, settings) = makeRouter()
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-ant-test"
        router.resolveNaturalLanguage = { _, _, _ in
            throw RemoteNaturalLanguage.Failure.refused("no")
        }

        let reply = await router.handle(inbound("do something odd"))
        XCTAssertTrue(reply?.text.contains("declined") == true, reply?.text ?? "nil")
    }
}
