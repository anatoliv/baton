import XCTest
@testable import BatonAgentKit
import BatonSubsonicKit
import BatonSubsonicModels

/// The one-call router hands the model a narrowed catalog. Whatever name comes
/// back still reaches the tool surface, so the narrowing has to be enforced
/// where the call is dispatched.
@MainActor
final class RemoteCommandRouterOfferedToolTests: XCTestCase {
    private final class IdlePlayer: RemotePlayerContext {
        var nowPlaying: NavidromeSong? { nil }
        var queue: [NavidromeSong] { [] }
        var currentIndex: Int { 0 }
    }

    private final class SpySurface: RemoteToolSurface {
        var ran: [String] = []
        func definitions() -> [[String: Any]] {
            TestToolFixtures.definitions + [
                ["name": "music_delete_playlist", "description": "Delete a playlist.",
                 "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]]]],
            ]
        }
        func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) {
            ran.append(name)
            return (#"{"now_playing":null}"#, false)
        }
    }

    private var suiteName: String!

    override func tearDown() {
        if let suiteName { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func makeRouter(_ surface: SpySurface) -> RemoteCommandRouter {
        suiteName = ThrowawayDefaults.name("baton.router.offered")
        let settings = RemoteControlSettings(
            environment: .testing,
            defaults: UserDefaults(suiteName: suiteName)!,
            secrets: InMemorySecretStore()
        )
        settings.authorize(sender: "42", on: .telegram)
        settings.naturalLanguage.isEnabled = true
        settings.naturalLanguage.apiKey = "sk-test"
        return RemoteCommandRouter(player: IdlePlayer(), tools: surface, settings: settings)
    }

    private func inbound(_ text: String) -> RemoteInbound {
        RemoteInbound(platform: .telegram, senderID: "42", senderName: "tester", channelID: "c1", text: text)
    }

    func testAWithheldToolNamedByTheModelIsNotRun() async {
        let surface = SpySurface()
        let router = makeRouter(surface)
        var offered: [String] = []
        router.resolveNaturalLanguage = { _, _, tools, _, _ in
            offered = tools.json.compactMap { $0["name"] as? String }
            return .init(call: RemoteToolCall(name: "music_delete_playlist",
                                              arguments: ["name": .string("Favourites")]),
                         preamble: nil)
        }

        let reply = await router.handle(inbound("tidy up my favourites please"))
        XCTAssertFalse(offered.contains("music_delete_playlist"), "precondition: the tool is withheld")
        XCTAssertEqual(surface.ran, [], "a tool that was not offered must never reach the surface")
        XCTAssertEqual(reply?.isFailure, true, reply?.text ?? "nil")
    }

    func testAnOfferedToolStillRuns() async {
        let surface = SpySurface()
        let router = makeRouter(surface)
        router.resolveNaturalLanguage = { _, _, _, _, _ in
            .init(call: RemoteToolCall(name: "music_now_playing"), preamble: nil)
        }

        _ = await router.handle(inbound("what is this song"))
        XCTAssertEqual(surface.ran, ["music_now_playing"])
    }
}
