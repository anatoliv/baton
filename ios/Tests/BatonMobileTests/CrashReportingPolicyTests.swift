import Foundation
import Sentry
import XCTest
@testable import BatonMobile

final class CrashReportingPolicyTests: XCTestCase {
    private let commit = String(repeating: "b", count: 40)

    private var validInfo: [String: Any] {
        [
            "CrashReportingDSN": "public@crash.example.invalid/43",
            "CrashReportingProvider": "crashbox",
            "CrashReportingEnvironment": "production",
            "BatonSourceCommit": commit,
            "CFBundleShortVersionString": "1.1",
            "CFBundleVersion": "123",
        ]
    }

    private func source(_ relativePath: String) throws -> String {
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: ios.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testConfigurationRequiresOneNamedProviderAndExactIdentity() {
        let configuration = CrashReporting.configuration(from: validInfo)
        XCTAssertEqual(configuration?.provider, "crashbox")
        XCTAssertEqual(configuration?.release, "io.tonebox.baton@1.1+123.\(commit)")

        for key in validInfo.keys {
            var candidate = validInfo
            candidate.removeValue(forKey: key)
            XCTAssertNil(CrashReporting.configuration(from: candidate), key)
        }
        var automatic = validInfo
        automatic["CrashReportingProvider"] = "automatic"
        XCTAssertNil(CrashReporting.configuration(from: automatic))

        var hosted = validInfo
        hosted["CrashReportingProvider"] = "hosted-sentry"
        XCTAssertNil(CrashReporting.configuration(from: hosted))
    }

    func testReportingPolicyIsEventOnlyAndNetworkBounded() {
        let configuration = CrashReporting.configuration(from: validInfo)!
        let options = Options()
        CrashReporting.configure(options, configuration: configuration)

        XCTAssertFalse(options.sendDefaultPii)
        XCTAssertFalse(options.sendClientReports)
        XCTAssertFalse(options.enableAutoSessionTracking)
        XCTAssertFalse(options.enableAutoPerformanceTracing)
        XCTAssertFalse(options.enableNetworkTracking)
        XCTAssertFalse(options.enableCaptureFailedRequests)
        XCTAssertFalse(options.attachScreenshot)
        XCTAssertFalse(options.attachViewHierarchy)
        XCTAssertEqual(options.maxCacheItems, UInt(CrashReporting.perLaunchBudget))
        XCTAssertEqual(options.tracesSampleRate?.doubleValue, 0)

        let freshScope = Scope()
        XCTAssertNil(freshScope.serialize()["environment"])
        let configuredScope = options.initialScope(freshScope)
        XCTAssertEqual(
            configuredScope.serialize()["environment"] as? String,
            configuration.environment
        )

        let transport = options.urlSession!.configuration
        XCTAssertFalse(transport.waitsForConnectivity)
        XCTAssertEqual(transport.timeoutIntervalForRequest, CrashReporting.requestTimeout)
        XCTAssertEqual(transport.timeoutIntervalForResource, CrashReporting.resourceTimeout)
    }

    func testFailureFuseAndBudgetAreBounded() {
        enum ExpectedFailure: Error { case unavailable }
        let gate = ReportingAttemptGate()
        var attempts = 0
        XCTAssertEqual(gate.runOnce {
            attempts += 1
            throw ExpectedFailure.unavailable
        }, .failed)
        XCTAssertEqual(gate.runOnce { attempts += 1 }, .failed)
        XCTAssertEqual(attempts, 1)

        let budget = ReportingBudget(limit: 3)
        XCTAssertTrue(budget.admit())
        XCTAssertTrue(budget.admit())
        XCTAssertTrue(budget.admit())
        XCTAssertFalse(budget.admit())
    }

    func testCrashCanaryRequiresAllThreeExplicitGates() {
        XCTAssertTrue(CrashReporting.canTriggerTestCrash(
            optedIn: true,
            configured: true,
            isInternalBuild: true
        ))
        XCTAssertFalse(CrashReporting.canTriggerTestCrash(
            optedIn: false,
            configured: true,
            isInternalBuild: true
        ))
        XCTAssertFalse(CrashReporting.canTriggerTestCrash(
            optedIn: true,
            configured: false,
            isInternalBuild: true
        ))
        XCTAssertFalse(CrashReporting.canTriggerTestCrash(
            optedIn: true,
            configured: true,
            isInternalBuild: false
        ))
    }

    func testRecoveredNativeCrashGetsOneReleaseBoundFingerprint() {
        let release = "io.tonebox.baton@1.1+123.\(commit)"
        let crashTime = Date(timeIntervalSince1970: 1000)
        let pending = CrashReporting.PendingTestCrash(
            release: release,
            timestamp: crashTime
        )

        XCTAssertEqual(
            CrashReporting.recoveredTestCrashFingerprint(
                eventRelease: release,
                eventEnvironment: "production",
                eventTimestamp: crashTime.addingTimeInterval(1),
                pending: pending,
                expectedRelease: release,
                expectedEnvironment: "production",
                hasUnhandledMainThreadMachBadAccess: true
            ),
            ["baton-ios-deliberate-crash", release]
        )

        XCTAssertNil(CrashReporting.recoveredTestCrashFingerprint(
            eventRelease: release,
            eventEnvironment: "production",
            eventTimestamp: crashTime.addingTimeInterval(61),
            pending: pending,
            expectedRelease: release,
            expectedEnvironment: "production",
            hasUnhandledMainThreadMachBadAccess: true
        ))
        XCTAssertNil(CrashReporting.recoveredTestCrashFingerprint(
            eventRelease: release,
            eventEnvironment: "production",
            eventTimestamp: crashTime,
            pending: pending,
            expectedRelease: release,
            expectedEnvironment: "production",
            hasUnhandledMainThreadMachBadAccess: false
        ))
        XCTAssertNil(CrashReporting.recoveredTestCrashFingerprint(
            eventRelease: "io.tonebox.baton@1.1+124.\(commit)",
            eventEnvironment: "production",
            eventTimestamp: crashTime,
            pending: pending,
            expectedRelease: release,
            expectedEnvironment: "production",
            hasUnhandledMainThreadMachBadAccess: true
        ))
    }

    func testPendingNativeCrashIdentityIsBoundedAndPayloadFree() throws {
        let suite = "CrashReportingPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let release = "io.tonebox.baton@1.1+123.\(commit)"
        let crashTime = Date(timeIntervalSince1970: 1000)

        XCTAssertTrue(CrashReporting.persistPendingTestCrash(
            release: release,
            timestamp: crashTime,
            defaults: defaults
        ))
        XCTAssertEqual(
            CrashReporting.pendingTestCrash(defaults: defaults),
            CrashReporting.PendingTestCrash(release: release, timestamp: crashTime)
        )
        let record = try XCTUnwrap(defaults.dictionary(
            forKey: CrashReporting.pendingTestCrashKey
        ))
        XCTAssertEqual(
            Set(record.keys),
            ["release", "timestamp"]
        )
    }

    func testCrashCanaryKeepsOneNativeSymbolicationLineAndSafeOrdering() throws {
        let crashSource = try source("Sources/BatonMobile/CrashCanary/CrashCanary.c")
        XCTAssertTrue(crashSource.contains("__attribute__((noinline, optnone, noreturn))"))
        XCTAssertTrue(crashSource.contains("*invalid_address = 0x42;"))

        let reportingSource = try source("../Shared/CrashReporting.swift")
        XCTAssertTrue(reportingSource.contains(
            "guard isEnabled, isInternalTestFlightBuild, let configuration else {"
        ))
        let marker = try XCTUnwrap(reportingSource.range(
            of: "Baton deliberate crash test starting"
        ))
        let flush = try XCTUnwrap(reportingSource.range(
            of: "SentrySDK.flush(timeout: 2)"
        ))
        let persistence = try XCTUnwrap(reportingSource.range(
            of: "persistPendingTestCrash(",
            range: marker.upperBound ..< reportingSource.endIndex
        ))
        let crash = try XCTUnwrap(reportingSource.range(
            of: "baton_ios_trigger_test_crash()",
            range: marker.upperBound ..< reportingSource.endIndex
        ))
        XCTAssertLessThan(marker.lowerBound, flush.lowerBound)
        XCTAssertLessThan(flush.lowerBound, persistence.lowerBound)
        XCTAssertLessThan(persistence.lowerBound, crash.lowerBound)
        XCTAssertFalse(reportingSource.contains("fatalError("))
    }
}
