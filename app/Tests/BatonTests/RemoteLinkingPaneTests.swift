import BatonAgentKit
import XCTest
@testable import Baton

/// Settings → Remote after five wrong `/link` codes (C-3 follow-up). Linking is
/// then shut and the settings hold a burned code, so the pane must not offer it as the code to
/// send; it says linking is paused until a new code is made.
@MainActor
final class RemoteLinkingPaneTests: XCTestCase {
    private func makeSettings() -> RemoteControlSettings {
        RemoteControlSettings(
            environment: .testing,
            defaults: UserDefaults(suiteName: ThrowawayDefaults.name("baton.remote.linking-pane"))!,
            secrets: InMemorySecretStore()
        )
    }

    func testAfterFiveWrongCodesThePaneOffersNoCodeAndSaysLinkingIsPaused() {
        let settings = makeSettings()
        XCTAssertEqual(BatonRemotePane.usableLinkCode(settings), settings.linkCode, "a fresh code is offered")

        for _ in 0 ..< 5 { _ = settings.matchesLinkCode("not-the-code") }
        XCTAssertTrue(settings.isLinkingLocked)

        XCTAssertNil(BatonRemotePane.usableLinkCode(settings), "the pane offered a burned code: \(settings.linkCode)")
        let instructions = BatonRemotePane.linkingInstructions(settings)
        XCTAssertFalse(instructions.contains(settings.linkCode), "the instructions name a code that cannot link")
        XCTAssertTrue(instructions.contains("Make a new code"))
    }

    func testANewCodeReopensLinkingAndIsOffered() {
        let settings = makeSettings()
        for _ in 0 ..< 5 { _ = settings.matchesLinkCode("not-the-code") }
        settings.regenerateLinkCode()

        XCTAssertEqual(BatonRemotePane.usableLinkCode(settings), settings.linkCode)
        XCTAssertTrue(BatonRemotePane.linkingInstructions(settings).contains("/link \(settings.linkCode)"))
    }
}
