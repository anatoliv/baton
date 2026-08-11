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
                ServerStatus.isAuthFailure(NavidromeError.subsonic(code: code, message: "nope")),
                "Subsonic \(code) is an auth failure, not an unreachable server"
            )
        }
    }

    func testUnauthorizedIsARefusedSignIn() {
        XCTAssertTrue(ServerStatus.isAuthFailure(NavidromeError.unauthorized))
        XCTAssertTrue(ServerStatus.isAuthFailure(NavidromeError.http(status: 401)))
        XCTAssertTrue(ServerStatus.isAuthFailure(NavidromeError.http(status: 403)))
    }

    /// A server that is down, or a certificate that isn't trusted, is not a password
    /// problem — telling someone their sign-in was refused would be actively misleading.
    func testTransportAndServerFaultsAreNotSignInProblems() {
        XCTAssertFalse(ServerStatus.isAuthFailure(NavidromeError.transport("connection lost")))
        XCTAssertFalse(ServerStatus.isAuthFailure(NavidromeError.http(status: 500)))
        XCTAssertFalse(ServerStatus.isAuthFailure(NavidromeError.subsonic(code: 70, message: "not found")))
        XCTAssertFalse(ServerStatus.isAuthFailure(URLError(.cannotFindHost)))
    }

    // MARK: - Saying what actually went wrong

    func testCommonNetworkFailuresAreExplainedInPlainWords() {
        XCTAssertEqual(ServerStatus.describe(URLError(.notConnectedToInternet)),
                       "This iPhone has no internet connection.")
        XCTAssertEqual(ServerStatus.describe(URLError(.timedOut)),
                       "The server didn't answer in time.")
        XCTAssertEqual(ServerStatus.describe(URLError(.cannotFindHost)),
                       "Nothing is answering at that address.")
    }

    func testATLSFailureSaysItIsTheCertificate() {
        XCTAssertTrue(ServerStatus.describe(URLError(.secureConnectionFailed)).contains("certificate"))
    }

    func testAnHTTPFaultReportsItsStatus() {
        XCTAssertTrue(ServerStatus.describe(NavidromeError.http(status: 502)).contains("502"))
    }

    /// Unknown failures must still say *something* rather than an empty badge.
    func testAnUnrecognisedErrorStillProducesText() {
        XCTAssertFalse(ServerStatus.describe(URLError(.unknown)).isEmpty)
    }

    // MARK: - What each state shows

    func testOnlyAVerifiedConnectionIsGreen() {
        XCTAssertEqual(ServerStatus.State.connected(openSubsonic: true).tint, .green)
        for state: ServerStatus.State in [.unknown, .checking, .rejected, .unreachable("x"), .offline] {
            XCTAssertNotEqual(state.tint, .green, "\(state.label) must not read as connected")
        }
    }

    /// Offline mode is a choice, not a fault — downloads still play, so a red warning
    /// would be telling someone something is broken when they turned it on themselves.
    func testOfflineModeIsNotReportedAsAFailure() {
        let offline = ServerStatus.State.offline
        XCTAssertEqual(offline.tint, .blue)
        XCTAssertNotEqual(offline.label, ServerStatus.State.unreachable("x").label)
        XCTAssertTrue(offline.detail?.contains("downloads") == true)
    }

    func testTheFailureStatesExplainThemselves() {
        XCTAssertNotNil(ServerStatus.State.rejected.detail)
        XCTAssertEqual(ServerStatus.State.unreachable("Nothing is answering.").detail,
                       "Nothing is answering.")
    }

    /// A fresh instance must not claim anything before it has checked.
    func testItStartsWithoutClaimingAConnection() {
        XCTAssertEqual(ServerStatus().state, .unknown)
    }
}
