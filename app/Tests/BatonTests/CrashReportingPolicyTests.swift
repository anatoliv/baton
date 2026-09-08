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

    func testInitializationFailureIsContainedAndNotRetried() {
        enum ExpectedFailure: Error { case unavailable }
        let gate = ReportingAttemptGate()
        var attempts = 0
        XCTAssertEqual(gate.runOnce {
            attempts += 1
            throw ExpectedFailure.unavailable
        }, .failed)
        XCTAssertEqual(gate.runOnce { attempts += 1 }, .failed)
        XCTAssertEqual(attempts, 1)
    }

    func testSlowInitializationDoesNotNeedTheCallingThread() {
        let gate = ReportingAttemptGate()
        let background = DispatchQueue(label: "crash-reporting-policy-test", qos: .utility)
        let entered = expectation(description: "initializer entered")
        let finished = expectation(description: "initializer finished")
        let release = DispatchSemaphore(value: 0)

        background.async {
            _ = gate.runOnce {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 1)
            }
            finished.fulfill()
        }
        wait(for: [entered], timeout: 0.5)
        XCTAssertEqual(gate.current(), .failed)
        release.signal()
        wait(for: [finished], timeout: 0.5)
        XCTAssertEqual(gate.current(), .started)
    }

    func testBudgetHasAHardCeiling() {
        let budget = ReportingBudget(limit: 20)
        XCTAssertEqual((0..<100).filter { _ in budget.admit() }.count, 20)
    }
}
