#if canImport(AVFoundation)
import XCTest
@testable import BatonAgentKit

/// Discord's gateway closes with 4004 for a bad token and 4010-4014 for settings that never
/// change on retry (4014 is the Message Content intent left off in the portal). Reconnecting on
/// those spends the 1,000 identifies a day Discord allows before it resets the bot token.
final class DiscordCloseCodeTests: XCTestCase {
    func testFatalCloseCodesStopTheBridge() {
        guard case .authFailed? = DiscordBridge.fatalCloseError(closeCode: 4004) else {
            return XCTFail("4004 is a rejected token")
        }
        for code in 4010...4014 {
            XCTAssertNotNil(DiscordBridge.fatalCloseError(closeCode: code), "\(code) is fatal")
        }
    }

    func testRecoverableCloseCodesReconnect() {
        for code in [1000, 1001, 1006, 4000, 4007, 4008, 4009] {
            XCTAssertNil(DiscordBridge.fatalCloseError(closeCode: code), "\(code) is recoverable")
        }
    }
}
#endif
