import BatonSubsonicModels
import XCTest
@testable import BatonMobile

/// The connection badge.
///
/// A green light is believed, so the only thing worse than not having one is having one
/// that is wrong. These tests are mostly about the failure states: a refused password and
/// a server that isn't there need *different* things from the person reading the badge,
/// and Subsonic makes them easy to confuse — it reports bad credentials as a protocol
/// error inside a 200 response, not as an HTTP 401. Classify that wrong and every wrong
/// password reads as "can't reach server", sending people to debug a network that is fine.
@MainActor
final class ServerStatusTests: XCTestCase {
    // MARK: - Telling a refused sign-in from an absent server

    func testSubsonicCredentialErrorsAreRefusedSignIns() {
        for code in [40, 41, 44, 50] {
            XCTAssertTrue(
                ServiceStatus.isAuthFailure(NavidromeError.subsonic(code: code, message: "nope")),
                "Subsonic \(code) is an auth failure, not an unreachable server"
            )
        }
    }

    func testUnauthorizedIsARefusedSignIn() {
        XCTAssertTrue(ServiceStatus.isAuthFailure(NavidromeError.unauthorized))
        XCTAssertTrue(ServiceStatus.isAuthFailure(NavidromeError.http(status: 401)))
        XCTAssertTrue(ServiceStatus.isAuthFailure(NavidromeError.http(status: 403)))
    }

    /// A server that is down, or a certificate that isn't trusted, is not a password
    /// problem — telling someone their sign-in was refused would be actively misleading.
    func testTransportAndServerFaultsAreNotSignInProblems() {
        XCTAssertFalse(ServiceStatus.isAuthFailure(NavidromeError.transport("connection lost")))
        XCTAssertFalse(ServiceStatus.isAuthFailure(NavidromeError.http(status: 500)))
        XCTAssertFalse(ServiceStatus.isAuthFailure(NavidromeError.subsonic(code: 70, message: "not found")))
        XCTAssertFalse(ServiceStatus.isAuthFailure(URLError(.cannotFindHost)))
    }

    // MARK: - Saying what actually went wrong

    func testCommonNetworkFailuresAreExplainedInPlainWords() {
        XCTAssertEqual(ServiceStatus.describe(URLError(.notConnectedToInternet)),
                       "There's no internet connection.")
        XCTAssertEqual(ServiceStatus.describe(URLError(.timedOut)),
                       "It didn't answer in time.")
        XCTAssertEqual(ServiceStatus.describe(URLError(.cannotFindHost)),
                       "Nothing is answering at that address.")
    }

    func testATLSFailureSaysItIsTheCertificate() {
        XCTAssertTrue(ServiceStatus.describe(URLError(.secureConnectionFailed)).contains("certificate"))
    }

    func testAnHTTPFaultReportsItsStatus() {
        XCTAssertTrue(ServiceStatus.describe(NavidromeError.http(status: 502)).contains("502"))
    }

    /// Unknown failures must still say *something* rather than an empty badge.
    func testAnUnrecognisedErrorStillProducesText() {
        XCTAssertFalse(ServiceStatus.describe(URLError(.unknown)).isEmpty)
    }

    // MARK: - What each state shows

    func testOnlyAVerifiedConnectionIsGreen() {
        XCTAssertEqual(ServiceStatus.ok(detail: "OpenSubsonic extensions available").tint, .green)
        for state: ServiceStatus in [.unknown, .checking, .notConfigured("No server yet"), .refused("x"), .unreachable("x"), .offline] {
            XCTAssertNotEqual(state.tint, .green, "\(state.label) must not read as connected")
        }
    }

    /// Offline mode is a choice, not a fault — downloads still play, so a red warning
    /// would be telling someone something is broken when they turned it on themselves.
    func testOfflineModeIsNotReportedAsAFailure() {
        let offline = ServiceStatus.offline
        XCTAssertEqual(offline.tint, .blue)
        XCTAssertNotEqual(offline.label, ServiceStatus.unreachable("x").label)
        XCTAssertTrue(offline.detail?.contains("downloads") == true)
    }

    func testTheFailureStatesExplainThemselves() {
        XCTAssertNotNil(ServiceStatus.refused(ServiceStatus.refusedDetail).detail)
        XCTAssertEqual(ServiceStatus.unreachable("Nothing is answering.").detail,
                       "Nothing is answering.")
    }

    /// A fresh instance must not claim anything before it has checked.
    func testItStartsWithoutClaimingAConnection() {
        XCTAssertEqual(ServerStatus().state, .unknown)
    }
}
