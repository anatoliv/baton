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
}
