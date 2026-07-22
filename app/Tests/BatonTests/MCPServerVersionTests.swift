import XCTest
@testable import Baton
@testable import BatonMCPProtocol

/// The version Baton reports to agents — `initialize`'s `serverInfo.version` and `app.version`
/// in the `mcp.json` discovery file — must track the shipping app, not a literal.
///
/// It was hardcoded to "0.1.0" and stayed there through seven releases, so every MCP client was
/// told Baton was 0.1.0 while 0.6.x shipped. These tests fail if it's ever pinned again.
final class MCPServerVersionTests: XCTestCase {
    /// Whatever the host bundle reports is what agents must see.
    func testServerVersionMatchesTheHostBundle() {
        let bundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let bundle {
            XCTAssertEqual(BatonMCPConstants.serverVersion, bundle)
        } else {
            XCTAssertEqual(BatonMCPConstants.serverVersion, BatonMCPConstants.unknownVersion)
        }
    }

    /// The specific regression: the old hardcoded value must not be what we report, unless the
    /// app genuinely is 0.1.0 again.
    func testServerVersionIsNotThePinnedLiteral() {
        let bundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard bundle != "0.1.0" else { return } // would be legitimate
        XCTAssertNotEqual(BatonMCPConstants.serverVersion, "0.1.0",
                          "serverVersion looks pinned again — it must read the host bundle")
    }

    /// Sanity: it's a usable, non-empty version string rather than a placeholder or empty value.
    func testServerVersionIsWellFormed() {
        let v = BatonMCPConstants.serverVersion
        XCTAssertFalse(v.isEmpty)
        XCTAssertNil(v.rangeOfCharacter(from: .whitespacesAndNewlines))
        XCTAssertTrue(v.allSatisfy { $0.isNumber || $0 == "." },
                      "expected a dotted numeric version, got \(v)")
    }
}
