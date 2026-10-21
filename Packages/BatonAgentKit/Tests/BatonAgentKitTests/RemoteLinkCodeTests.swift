import BatonSubsonicKit
import XCTest
@testable import BatonAgentKit

/// The `/link` code is six digits and anyone who can message the bot can submit one. Without a
/// budget, a stranger could walk the million codes and take control of the speakers, so wrong
/// guesses are counted against the current code and, past a small limit, the code is burned and
/// linking waits for the owner to ask for a new one.
@MainActor
final class RemoteLinkCodeTests: XCTestCase {
    private func makeSettings() -> RemoteControlSettings {
        let (_, defaults) = ThrowawayDefaults.suite("linkcode")
        return RemoteControlSettings(environment: .testing, defaults: defaults,
                                     secrets: InMemorySecretStore())
    }

    private func wrongCode(for settings: RemoteControlSettings) -> String {
        settings.linkCode == "000000" ? "000001" : "000000"
    }

    func testTooManyWrongCodesBurnTheCode() {
        let settings = makeSettings()
        let original = settings.linkCode
        for _ in 0..<RemoteControlSettings.maxFailedLinkAttempts {
            XCTAssertFalse(settings.matchesLinkCode(wrongCode(for: settings)))
        }
        XCTAssertNotEqual(settings.linkCode, original, "the guessed-at code must be retired")
        XCTAssertFalse(settings.matchesLinkCode(original), "the old code still links")
        XCTAssertFalse(settings.matchesLinkCode(settings.linkCode),
                       "the guess budget refilled on its own; a stranger can keep guessing")
    }

    func testANewCodeFromTheOwnerLinksAgain() {
        let settings = makeSettings()
        for _ in 0..<RemoteControlSettings.maxFailedLinkAttempts {
            _ = settings.matchesLinkCode(wrongCode(for: settings))
        }
        settings.regenerateLinkCode()
        XCTAssertTrue(settings.matchesLinkCode(settings.linkCode))
    }

    func testACorrectCodeWithinTheLimitStillLinks() {
        let settings = makeSettings()
        for _ in 0..<(RemoteControlSettings.maxFailedLinkAttempts - 1) {
            XCTAssertFalse(settings.matchesLinkCode(wrongCode(for: settings)))
        }
        XCTAssertTrue(settings.matchesLinkCode(settings.linkCode))
    }
}
