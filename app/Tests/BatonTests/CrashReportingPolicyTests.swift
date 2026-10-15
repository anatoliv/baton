import Foundation
import Sentry
import XCTest
@testable import Baton

final class CrashReportingPolicyTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)

    private var validInfo: [String: Any] {
        [
            "CrashReportingDSN": "public@crash.example.invalid/42",
            "CrashReportingProvider": "crashbox",
            "CrashReportingEnvironment": "production",
            "BatonSourceCommit": commit,
            "CFBundleShortVersionString": "0.17.12",
            "CFBundleVersion": "97",
        ]
    }

    func testCompleteConfigurationCarriesImmutableRelease() {
        let configuration = CrashReporting.configuration(from: validInfo)
        XCTAssertEqual(configuration?.provider, "crashbox")
        XCTAssertEqual(configuration?.environment, "production")
        XCTAssertEqual(configuration?.release, "io.tonebox.baton@0.17.12+97.\(commit)")
    }

    func testPartialMalformedAndMutableConfigurationsStayOff() {
        let required = [
            "CrashReportingDSN", "CrashReportingProvider", "CrashReportingEnvironment",
            "BatonSourceCommit", "CFBundleShortVersionString", "CFBundleVersion",
        ]
        for key in required {
            var candidate = validInfo
            candidate.removeValue(forKey: key)
            XCTAssertNil(CrashReporting.configuration(from: candidate), key)
        }

        for malformed in [
            "http://public@crash.example.invalid/42",
            "public:secret@crash.example.invalid/42",
            "crash.example.invalid/42",
            "public@crash.example.invalid/",
            "public@crash.example.invalid/42?token=secret",
            "public@crash.example.invalid/42#fragment",
        ] {
            var candidate = validInfo
            candidate["CrashReportingDSN"] = malformed
            XCTAssertNil(CrashReporting.configuration(from: candidate), malformed)
        }

        var automatic = validInfo
        automatic["CrashReportingProvider"] = "automatic"
        XCTAssertNil(CrashReporting.configuration(from: automatic))

        var mutable = validInfo
        mutable["BatonSourceCommit"] = "main"
        XCTAssertNil(CrashReporting.configuration(from: mutable))
    }

    func testEveryProviderOtherThanCrashboxFailsClosed() {
        var info = validInfo
        for provider in ["hosted-sentry", "sentry", "automatic", "fallback"] {
            info["CrashReportingProvider"] = provider
            XCTAssertNil(CrashReporting.configuration(from: info), provider)
        }
    }

    func testEventOnlyPolicyIsBounded() {
        let configuration = CrashReporting.configuration(from: validInfo)!
        let options = Options()
        CrashReporting.configure(options, configuration: configuration)

        XCTAssertEqual(options.dsn, configuration.dsn)
        XCTAssertEqual(options.releaseName, configuration.release)
        XCTAssertEqual(options.environment, "production")
        XCTAssertFalse(options.sendDefaultPii)
        XCTAssertEqual(options.shutdownTimeInterval, 0)
        XCTAssertEqual(options.maxCacheItems, UInt(CrashReporting.perLaunchBudget))
        XCTAssertEqual(options.maxBreadcrumbs, 0)
        XCTAssertFalse(options.sendClientReports)
        XCTAssertFalse(options.enableAutoSessionTracking)
        XCTAssertFalse(options.enableWatchdogTerminationTracking)
        XCTAssertFalse(options.enableAppHangTracking)
        XCTAssertFalse(options.enableAutoPerformanceTracing)
        XCTAssertFalse(options.enableNetworkTracking)
        XCTAssertFalse(options.enableNetworkBreadcrumbs)
        XCTAssertFalse(options.enableCaptureFailedRequests)
        XCTAssertFalse(options.enableFileIOTracing)
        XCTAssertFalse(options.enableCoreDataTracing)
        XCTAssertFalse(options.enableTimeToFullDisplayTracing)
        XCTAssertFalse(options.enableAutoBreadcrumbTracking)
        XCTAssertEqual(options.tracesSampleRate?.doubleValue, 0)

        let profile = SentryProfileOptions()
        options.configureProfiling?(profile)
        XCTAssertEqual(profile.lifecycle, .manual)
        XCTAssertEqual(profile.sessionSampleRate, 0)
        XCTAssertFalse(profile.profileAppStarts)

        let transport = options.urlSession!.configuration
        XCTAssertFalse(transport.waitsForConnectivity)
        XCTAssertEqual(transport.timeoutIntervalForRequest, CrashReporting.requestTimeout)
        XCTAssertEqual(transport.timeoutIntervalForResource, CrashReporting.resourceTimeout)
        XCTAssertNil(transport.urlCache)
        XCTAssertNil(transport.httpCookieStorage)
        XCTAssertNil(transport.urlCredentialStorage)
    }

    // MARK: - Whether the reporter came up
    //
    // `SentrySDK.start` cannot throw, so a test that hands the gate a throwing
    // closure proves a contract production cannot reach. These drive the
    // production decision (`CrashReporting.startReporter`) inside the production
    // gate with the SDK's real `Options` and DSN parser. Only the SDK's global
    // start and its `isEnabled` are stood in, so nothing installs a crash handler
    // in the test process and nothing can reach the network.

    private var shipped: CrashReporting.Configuration {
        CrashReporting.configuration(from: validInfo)!
    }

    /// Runs the real gate around the real decision, as `startSDKOnce` does.
    private func attempt(
        _ gate: ReportingAttemptGate,
        _ configuration: CrashReporting.Configuration,
        starts: inout [Options],
        setupRan: Bool,
        enabled: Bool
    ) -> ReportingAttemptGate.Outcome {
        var started: [Options] = []
        let outcome = gate.runOnce {
            try CrashReporting.startReporter(
                configuration,
                start: { started.append($0) },
                waitForSetup: { setupRan },
                isEnabled: { enabled }
            )
        }
        starts += started
        return outcome
    }

    private func settingsStatus(_ gate: ReportingAttemptGate) -> CrashReporting.Status {
        CrashReporting.status(enabled: true, configured: true, outcome: gate.current())
    }

    func testAReporterThatComesUpIsOnAndGetsTheShippedOptions() throws {
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, shipped, starts: &starts, setupRan: true, enabled: true), .started)
        XCTAssertEqual(settingsStatus(gate), .on)
        XCTAssertEqual(starts.count, 1)
        let options = try XCTUnwrap(starts.first)
        XCTAssertNotNil(options.parsedDsn, "the SDK's own parser accepts the shipped DSN shape")
        XCTAssertEqual(options.parsedDsn?.url.host, "crash.example.invalid")
        XCTAssertEqual(options.releaseName, shipped.release)
        XCTAssertEqual(options.environment, shipped.environment)
        XCTAssertFalse(options.enableAutoSessionTracking)
        XCTAssertEqual(options.urlSession?.configuration.timeoutIntervalForResource, CrashReporting.resourceTimeout)
    }

    func testADSNTheSDKRefusesIsUnavailableAndNeverStarted() {
        // No public key: the SDK's DSN parser refuses it. Built directly, since
        // `configuration(from:)` already refuses this shape before the SDK sees it.
        let refused = CrashReporting.Configuration(
            dsn: "https://crash.example.invalid/42",
            provider: shipped.provider,
            release: shipped.release,
            environment: shipped.environment
        )
        var startCalls = 0
        XCTAssertThrowsError(try CrashReporting.startReporter(
            refused,
            start: { _ in startCalls += 1 },
            waitForSetup: { true },
            isEnabled: { true }
        )) {
            XCTAssertEqual($0 as? CrashReporting.StartFailure, .configurationRejected)
        }
        XCTAssertEqual(startCalls, 0)

        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, refused, starts: &starts, setupRan: true, enabled: true), .failed)
        XCTAssertTrue(starts.isEmpty)
        XCTAssertEqual(settingsStatus(gate), .unavailable)
    }

    func testAReporterThatDoesNotEnableIsUnavailableAndDoesNotRetry() {
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, shipped, starts: &starts, setupRan: true, enabled: false), .failed)
        XCTAssertEqual(settingsStatus(gate), .unavailable)
        XCTAssertEqual(
            attempt(gate, shipped, starts: &starts, setupRan: true, enabled: true), .failed,
            "a failed start must not retry on its own"
        )
        XCTAssertEqual(starts.count, 1)
        gate.resetAfterExplicitDisable()
        XCTAssertEqual(
            attempt(gate, shipped, starts: &starts, setupRan: true, enabled: true), .started,
            "turning it off and on again is the retry Settings offers"
        )
        XCTAssertEqual(starts.count, 2)
    }

    func testASetupThatNeverRunsIsUnavailable() {
        XCTAssertThrowsError(try CrashReporting.startReporter(
            shipped, start: { _ in }, waitForSetup: { false }, isEnabled: { true }
        )) {
            XCTAssertEqual($0 as? CrashReporting.StartFailure, .setupTimedOut)
        }
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, shipped, starts: &starts, setupRan: false, enabled: true), .failed)
        XCTAssertEqual(settingsStatus(gate), .unavailable)
    }

    func testAStartInProgressReadsOnAndBlocksASecondClient() {
        let gate = ReportingAttemptGate()
        var seenDuringStart: ReportingAttemptGate.Outcome?
        var secondCaller: ReportingAttemptGate.Outcome?
        _ = gate.runOnce {
            try CrashReporting.startReporter(
                shipped,
                start: { _ in },
                waitForSetup: {
                    seenDuringStart = gate.current()
                    secondCaller = gate.runOnce { XCTFail("a concurrent caller must not start a second client") }
                    return true
                },
                isEnabled: { true }
            )
        }
        XCTAssertEqual(seenDuringStart, .starting)
        XCTAssertEqual(secondCaller, .starting)
        XCTAssertEqual(
            CrashReporting.status(enabled: true, configured: true, outcome: .starting), .on,
            "Settings opened mid-start must not flash the unavailable text"
        )
        XCTAssertFalse(CrashReporting.isSettled(enabled: true, configured: true, outcome: .starting))
        XCTAssertFalse(CrashReporting.isSettled(enabled: true, configured: true, outcome: .idle),
                       "a toggle's start still queued is not settled")
        XCTAssertTrue(CrashReporting.isSettled(enabled: true, configured: true, outcome: .failed))
        XCTAssertTrue(CrashReporting.isSettled(enabled: false, configured: true, outcome: .idle))
        XCTAssertTrue(CrashReporting.isSettled(enabled: true, configured: false, outcome: .idle))
    }

    func testStatusNamesEveryStateSettingsShows() {
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: false, outcome: .failed), .notConfigured)
        XCTAssertEqual(CrashReporting.status(enabled: false, configured: true, outcome: .failed), .off)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: .started), .on)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: .failed), .unavailable)
        XCTAssertFalse(CrashReporting.unavailableMessage.contains("—"))
        XCTAssertFalse(CrashReporting.unavailableMessage.contains("–"))
    }

    /// A locked value the main-queue tests share with a background thread.
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// The production wait, run as production runs it (off the main thread),
    /// against a stand-in that sets up the way the SDK does: `dispatch_async`
    /// on the main queue from the calling thread.
    func testTheMainQueueWaitSeesSetupQueuedBeforeIt() {
        let enabled = Locked(false)
        let failure = Locked<CrashReporting.StartFailure?>(nil)
        let configuration = shipped
        let done = expectation(description: "start finished")
        DispatchQueue.global().async {
            do {
                try CrashReporting.startReporter(
                    configuration,
                    start: { _ in DispatchQueue.main.async { enabled.set(true) } },
                    waitForSetup: { CrashReporting.mainQueueCaughtUp(within: 5) },
                    isEnabled: { enabled.get() }
                )
            } catch {
                failure.set(error as? CrashReporting.StartFailure)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertNil(failure.get())
        XCTAssertTrue(enabled.get())
    }

    func testTheMainQueueWaitGivesUpWhenTheMainThreadIsStuck() {
        let finished = DispatchSemaphore(value: 0)
        let caughtUp = Locked<Bool?>(nil)
        DispatchQueue.global().async {
            caughtUp.set(CrashReporting.mainQueueCaughtUp(within: 0.2))
            finished.signal()
        }
        // Hold the main thread, as a hung launch would, until the wait gives up.
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(caughtUp.get(), false)
    }

    func testBudgetHasAHardCeiling() {
        let budget = ReportingBudget(limit: 20)
        XCTAssertEqual((0..<100).filter { _ in budget.admit() }.count, 20)
    }
}
