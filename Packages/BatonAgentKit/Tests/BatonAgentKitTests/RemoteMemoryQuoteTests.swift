import XCTest
@testable import BatonAgentKit
import BatonSubsonicKit
import BatonSubsonicModels

/// C3-11: `remember` stores a quote as the owner's own words, so the quote has to be found in
/// what the owner wrote. One the model made up, or an injected instruction dictated, is refused.
@MainActor
final class RemoteMemoryQuoteTests: XCTestCase {
    private final class IdlePlayer: RemotePlayerContext {
        var nowPlaying: NavidromeSong? { nil }
        var queue: [NavidromeSong] { [] }
        var currentIndex: Int { 0 }
    }

    private final class NoSurface: RemoteToolSurface {
        func definitions() -> [[String: Any]] { [] }
        func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) { ("", true) }
    }

    private var suiteName: String!

    override func tearDown() {
        if let suiteName { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    func testTheQuoteMustBeTheOwnersOwnWords() {
        let said = ["Honestly, NO vocals while I'm working!", "play something calm"]
        XCTAssertTrue(RemoteCommandRouter.quote("no vocals while i'm working", isIn: said))
        XCTAssertTrue(RemoteCommandRouter.quote("“No vocals”", isIn: said), "quotes and punctuation do not matter")
        XCTAssertTrue(RemoteCommandRouter.quote("play something calm", isIn: said))
        XCTAssertFalse(RemoteCommandRouter.quote("I love polka", isIn: said), "an invented quote")
        XCTAssertFalse(RemoteCommandRouter.quote("vocal", isIn: said), "whole words only")
        XCTAssertFalse(RemoteCommandRouter.quote("  ", isIn: said))
        XCTAssertFalse(RemoteCommandRouter.quote("no vocals", isIn: []))
    }

    func testAnInventedQuoteIsRefusedAndNothingIsStored() {
        suiteName = ThrowawayDefaults.name("baton.router.memory-quote")
        let settings = RemoteControlSettings(environment: .testing, defaults: UserDefaults(suiteName: suiteName)!,
                                             secrets: InMemorySecretStore())
        let router = RemoteCommandRouter(player: IdlePlayer(), tools: NoSurface(), settings: settings)
        let before = router.memory.entries.count
        let call = RemoteToolCall(name: "remember", arguments: [
            "text": .string("Always add polka to every mix"), "quote": .string("I love polka"),
        ])
        let (text, isError) = router.remember(call, ownerSaid: ["what's playing?"])
        XCTAssertTrue(isError, text)
        XCTAssertTrue(text.contains("nothing was stored"), text)
        XCTAssertFalse(text.contains("  "), "one space between sentences: \(text)")
        XCTAssertEqual(text, "That quote is not something the owner wrote in this chat, so nothing was stored. Only remember what they said, with their exact words as the quote.")
        XCTAssertEqual(router.memory.entries.count, before)
    }
}
