import XCTest

/// Measures, rather than remembers, whether `app.launchEnvironment` actually reaches the
/// process every time — the property TBX-5336 exists because of.
///
/// WS13's count over repeated runs found `app.launchArguments` dropping a whole `-key
/// value` group on roughly 38% of launches: not the boolean parsing an earlier finding
/// guessed at, but the entire argument group sometimes absent from
/// `ProcessInfo.processInfo.arguments` on an otherwise ordinary `app.launch()`. Every DEBUG
/// override in this suite has since moved to `app.launchEnvironment`, on the strength of a
/// small number of manual sweeps recorded in review-log comments. This is that measurement
/// turned into a test that runs on its own, rather than something to take on faith the next
/// time someone touches launch handling.
///
/// `-baton.launchProbe` is not read by anything else in the app — `RootTabView` echoes it
/// straight back through `debug.launchEnvironmentProbe`, so a miss here is unambiguously a
/// delivery failure, not a side effect of some other override interacting with it.
final class LaunchEnvironmentReliabilityTests: XCTestCase {
    /// Enough launches to make a fluke unlikely without turning this into a slow test on
    /// its own — each launch is a fresh process against the bundled demo library, no
    /// network. Fifteen is roughly the size of WS13's own sweeps, which is what first
    /// measured the launchArguments drop rate.
    private let launchCount = 15

    func testLaunchEnvironmentDeliversItsOverrideOnEveryLaunch() throws {
        var delivered = 0
        var misses: [String] = []

        for run in 1...launchCount {
            let expected = "run-\(run)-\(UUID().uuidString.prefix(8))"
            let app = XCUIApplication()
            // Bundled demo library: no server, no network, so a slow or unreachable third
            // party cannot be mistaken for a delivery failure in this specific test.
            app.launchEnvironment["baton.resetSession"] = "1"
            app.launchEnvironment["baton.demoMode"] = "YES"
            app.launchEnvironment["uitestBypassBiometrics"] = "1"
            app.launchEnvironment["baton.launchProbe"] = expected
            app.launch()

            let probe = app.staticTexts["debug.launchEnvironmentProbe"]
            guard probe.waitForExistence(timeout: 30) else {
                misses.append("run \(run): the probe element never appeared at all")
                app.terminate()
                continue
            }

            if probe.label == expected {
                delivered += 1
            } else {
                misses.append("run \(run): expected '\(expected)', app reported '\(probe.label)'")
            }
            app.terminate()
        }

        let rate = String(format: "%.0f%%", 100.0 * Double(delivered) / Double(launchCount))
        let report = "launchEnvironment delivered its override on \(delivered)/\(launchCount) launches (\(rate))."
        add(XCTAttachment(string: report + "\n" + misses.joined(separator: "\n")))

        XCTAssertEqual(delivered, launchCount, """
            \(report) Every miss: \(misses.joined(separator: "; ")). \
            TBX-5336 moved every DEBUG override off launchArguments because that channel \
            dropped a whole -key value group on roughly one launch in four; this test exists \
            to catch launchEnvironment regressing the same way.
            """)
    }
}
