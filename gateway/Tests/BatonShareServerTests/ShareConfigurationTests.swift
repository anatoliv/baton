import BatonMCPProtocol
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

    func testMixtapesAreOffUnlessTheEnvironmentTurnsThemOn() throws {
        XCTAssertFalse(try ShareConfiguration.fromEnvironment([:]).mixtapesEnabled)
        for on in ["1", "true", "TRUE"] {
            XCTAssertTrue(try ShareConfiguration.fromEnvironment(["BATON_SHARE_MIXTAPES": on]).mixtapesEnabled, on)
        }
        for off in ["0", "false", ""] {
            XCTAssertFalse(try ShareConfiguration.fromEnvironment(["BATON_SHARE_MIXTAPES": off]).mixtapesEnabled, off)
        }
        XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(["BATON_SHARE_MIXTAPES": "yes please"]))
    }

    func testTheConfigRouteAdvertisesMixtapesOnlyWhenEnabled() throws {
        for enabled in [false, true] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("share-config-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var config = try ShareConfiguration.fromEnvironment(["BATON_SHARE_DATA": directory.path,
                                                                 "BATON_SHARE_MIXTAPES": enabled ? "1" : "0"])
            config.publicBase = URL(string: "https://batonmusic.app")!
            let service = try ShareService(config: config)
            let response = service.handle(HTTPRequestMessage(method: "GET", path: "/v1/share/config", query: [:], headers: [:], body: Data()))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            XCTAssertEqual(body["mixtapes"] as? Int, enabled ? 1 : nil)
        }
    }
}
