import XCTest
@testable import BatonMobile

/// What a settings import decides to test, and how it reads the answers.
///
/// The gating is the half that rots silently: on a fully configured phone — the only kind
/// anyone tests this on by hand — a list that always checks everything is indistinguishable
/// from a correct one. It only diverges on a partial setup, which is exactly the setup
/// somebody has when they are moving to a new phone.
@MainActor
final class ImportedSetupCheckTests: XCTestCase {
    private typealias Check = ImportedSetupCheck
    private typealias Service = ImportedSetupCheck.Service

    // MARK: - Only check what actually arrived

    func testNothingConfiguredMeansNothingIsChecked() {
        XCTAssertEqual(Check.services(for: Check.Configured()), [])
    }

    func testOnlyTheConfiguredServicesAreChecked() {
        let configured = Check.Configured(server: true, friend: false, listenBrainz: true, lastFM: false)
        XCTAssertEqual(Check.services(for: configured), [.server, .listenBrainz])
    }

    func testAFullSetupChecksEverything() {
        let configured = Check.Configured(server: true, friend: true, listenBrainz: true, lastFM: true)
        XCTAssertEqual(Check.services(for: configured), Service.allCases)
    }

    /// A row reading "ListenBrainz: no token yet" on a setup that never had one is noise,
    /// and noise beside a real failure is how the real failure gets missed.
    func testAnUnconfiguredServiceIsOmittedRatherThanListedAsNotSetUp() {
        let configured = Check.Configured(server: true)
        let services = Check.services(for: configured)
        XCTAssertFalse(services.contains(.listenBrainz))
        XCTAssertFalse(services.contains(.lastFM))
        XCTAssertFalse(services.contains(.friend))
    }

    /// Every case of the enum must be reachable from some configuration, or a service has
    /// been added to the list and forgotten in the gate — which reads as "that one always
    /// passes" rather than as "that one is never asked".
    func testEveryServiceIsReachable() {
        let all = Check.services(for: Check.Configured(server: true, friend: true,
                                                       listenBrainz: true, lastFM: true))
        for service in Service.allCases {
            XCTAssertTrue(all.contains(service), "\(service.rawValue) can never be checked")
        }
    }

    // MARK: - Reading a failure

    /// Getting this backwards is the expensive direction: telling somebody their key was
    /// rejected sends them to replace a key that was never the problem, when the real cause
    /// is a Mac's LAN address this phone cannot see. Lives on `AgentClient` because Settings
    /// asks the same question.
    func testAnUnreachableHostIsNotReportedAsARefusedCredential() {
        XCTAssertFalse(AgentClient.looksLikeACredentialProblem(
            "Couldn't reach the gateway at that address. The gateway listens on 8788 by default."))
        XCTAssertFalse(AgentClient.looksLikeACredentialProblem("The request timed out."))
        XCTAssertFalse(AgentClient.looksLikeACredentialProblem("Could not connect to the server."))
    }

    func testARefusedCredentialIsRecognised() {
        XCTAssertTrue(AgentClient.looksLikeACredentialProblem("The gateway rejected the token. Check Gateway token."))
        XCTAssertTrue(AgentClient.looksLikeACredentialProblem("HTTP 401 Unauthorized"))
        XCTAssertTrue(AgentClient.looksLikeACredentialProblem("Your API key was not accepted."))
    }

    // MARK: - The summary the screen reads from

    func testAFreshCheckHasRunNothingAndClaimsNothing() {
        let check = Check()
        XCTAssertFalse(check.hasRun)
        XCTAssertFalse(check.allPassed, "a check that has not run must never report success")
        XCTAssertEqual(check.failures, [])
        XCTAssertEqual(check.status(for: .friend), .unknown)
    }
}
