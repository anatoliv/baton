import AppKit
import XCTest
@testable import Baton

/// After the in-place Sparkle update to 0.20.4, pbs still listed only Speak and
/// Summarize with Baton for /Applications/Baton.app. "Make an Audiobook with Baton" appeared
/// only after a manual `pbs -update`. Baton now asks for that refresh itself, once per launch.
///
/// `applicationDidFinishLaunching` returns early under XCTest, so the call site is checked in
/// the source, the same way `LaunchOrderTests` and `AppCompositionRootTests` check theirs, and
/// the once-only rule is checked on a delegate whose refresh is replaced by a counter. A real
/// refresh in the test host would register the test build as a Services provider.
@MainActor
final class ServicesRefreshTests: XCTestCase {
    func testTheRegistryIsRefreshedOncePerProcess() {
        let delegate = BatonAppDelegate()
        var calls = 0
        delegate.updateDynamicServices = { calls += 1 }

        delegate.refreshServicesRegistry()
        XCTAssertEqual(calls, 1, "the first call must refresh the Services registry")
        delegate.refreshServicesRegistry()
        XCTAssertEqual(calls, 1, "a second call in the same process must not refresh again")
    }

    private func launchBody() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Baton/BatonApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching("),
                                  "BatonAppDelegate no longer has applicationDidFinishLaunching; update this test")
        let end = try XCTUnwrap(source.range(of: "func applicationWillTerminate(", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
    }

    func testLaunchRefreshesServicesOnceAfterRegisteringTheProvider() throws {
        let lines = try launchBody()
        let refreshes = lines.indices.filter { lines[$0] == "refreshServicesRegistry()" }
        XCTAssertEqual(refreshes.count, 1, "applicationDidFinishLaunching must call refreshServicesRegistry() exactly once")
        let provider = try XCTUnwrap(lines.firstIndex(of: "NSApp.servicesProvider = ScreenTextReader.shared"))
        let testingGuard = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("guard !BatonEnvironment.current.isTesting") })
        if let refresh = refreshes.first {
            XCTAssertGreaterThan(refresh, provider, "refresh after the provider is registered, so pbs reaches this process")
            XCTAssertGreaterThan(refresh, testingGuard, "never refresh from the test host")
        }
    }

    func testTheRealRefreshIsNSUpdateDynamicServicesOffTheMainThread() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Baton/BatonApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let compact = source.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(compact.contains(
            "var updateDynamicServices: () -> Void = { DispatchQueue.global(qos: .utility).async { NSUpdateDynamicServices() } }"
        ), "the default refresh must call NSUpdateDynamicServices() on a background queue")
    }
}
