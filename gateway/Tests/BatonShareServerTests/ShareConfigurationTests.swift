import Foundation
import XCTest
@testable import BatonShareServer

final class ShareConfigurationTests: XCTestCase {
    func testContainerBindingIsUnchangedByDefault() throws {
        XCTAssertFalse(try ShareConfiguration.fromEnvironment([:]).loopbackOnly)
    }

    func testLocalProbeExplicitlyBindsLoopback() throws {
        XCTAssertTrue(try ShareConfiguration.fromEnvironment(["BATON_SHARE_BIND": "127.0.0.1"]).loopbackOnly)
    }

    func testInvalidBindingIsRefusedRatherThanExposed() {
        XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(["BATON_SHARE_BIND": "localhost"]))
        XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(["BATON_SHARE_BIND": ""]))
    }
}
