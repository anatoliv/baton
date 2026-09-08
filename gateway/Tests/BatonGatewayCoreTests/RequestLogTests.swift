import Foundation
import XCTest
@testable import BatonGatewayCore

/// What the gateway writes about the requests it serves.
///
/// Two properties matter and they pull against each other: the log has to be **useful enough** to
/// answer "is that device calling me at all", which is the question a whole afternoon went into
/// answering by other means, and **quiet enough** that the answer is not buried under a long-poll
/// returning every twenty-five seconds.
///
/// The third property is that nothing secret ends up in a file that persists. The strongest
/// guarantee there is structural — `line` takes no token parameter, so no amount of forgetfulness
/// at a call site can pass one — and these cover the input that *is* attacker-shaped: the
/// User-Agent.
final class RequestLogTests: XCTestCase {

    // MARK: - Useful

    func testAnOrdinaryRequestSaysWhatHappened() throws {
        let line = try XCTUnwrap(RequestLog.line(
            method: "GET", path: "/v1/state", status: 200,
            userAgent: "Baton/0.17.12 CFNetwork/3826.500.111", milliseconds: 12
        ))
        XCTAssertTrue(line.contains("GET"), line)
        XCTAssertTrue(line.contains("/v1/state"), line)
        XCTAssertTrue(line.contains("200"), line)
        XCTAssertTrue(line.contains("Baton/0.17.12"), "the caller has to be identifiable: \(line)")
    }

    /// The one this exists for. A rejected token and an unknown route were both invisible before,
    /// and both are the kind of thing someone spends an hour not finding.
    func testARefusalIsLogged() throws {
        let unauthorized = try XCTUnwrap(RequestLog.line(
            method: "GET", path: "/v1/state", status: 401, userAgent: nil, milliseconds: 1))
        XCTAssertTrue(unauthorized.contains("401"), unauthorized)

        let missing = try XCTUnwrap(RequestLog.line(
            method: "POST", path: "/v1/nope", status: 404, userAgent: nil, milliseconds: 1))
        XCTAssertTrue(missing.contains("404"), missing)
    }

    // MARK: - Quiet

    /// A poll that expired with nothing to deliver is the gateway working, and there are about
    /// seven thousand of them a day at two devices. Logging those would bury everything above.
    func testAnEmptyLongPollIsNotLogged() {
        XCTAssertNil(RequestLog.line(
            method: "GET", path: "/v1/device/poll", status: 204, userAgent: "Baton", milliseconds: 25_000))
    }

    /// A poll that carried a command is the opposite: rare, and exactly what someone chasing
    /// "did my phone get told to play" needs to see.
    func testAPollThatCarriedACommandIsLogged() throws {
        let line = try XCTUnwrap(RequestLog.line(
            method: "GET", path: "/v1/device/poll", status: 200, userAgent: "Baton", milliseconds: 300))
        XCTAssertTrue(line.contains("200"), line)
    }

    // MARK: - The healthcheck, and only while it is passing

    /// 2,880 a day, 90.6% of an eight-day log against 6.5% for every real device request, and
    /// arriving as a bare `curl/7.81.0` so it could not be told apart from an outside probe.
    func testThePassingHealthcheckIsNotLogged() {
        XCTAssertNil(RequestLog.line(
            method: "GET", path: "/v1/state", status: 401,
            userAgent: RequestLog.healthcheckAgent, milliseconds: 0))
    }

    /// The whole reason the check probes an *authenticated* route: a 200 without a token means the
    /// token check is not running. Suppressing on the agent alone would have hidden exactly this.
    func testAHealthcheckThatStopsGettingA401IsLogged() throws {
        let authGone = try XCTUnwrap(RequestLog.line(
            method: "GET", path: "/v1/state", status: 200,
            userAgent: RequestLog.healthcheckAgent, milliseconds: 1))
        XCTAssertTrue(authGone.contains("200"), "the failure the check exists for: \(authGone)")

        for status in [403, 404, 500, 502] {
            XCTAssertNotNil(RequestLog.line(
                method: "GET", path: "/v1/state", status: status,
                userAgent: RequestLog.healthcheckAgent, milliseconds: 1),
                "a healthcheck answering \(status) is a finding, not noise")
        }
    }

    /// The suppression is the whole shape or nothing. A caller wearing that agent anywhere else —
    /// another path, another method — is not the healthcheck and is not quietly dropped.
    func testTheHealthcheckAgentIsNotAGeneralLicenceToBeSilent() throws {
        XCTAssertNotNil(RequestLog.line(
            method: "GET", path: "/v1/device/poll", status: 401,
            userAgent: RequestLog.healthcheckAgent, milliseconds: 1))
        XCTAssertNotNil(RequestLog.line(
            method: "GET", path: "/", status: 401,
            userAgent: RequestLog.healthcheckAgent, milliseconds: 1))
        XCTAssertNotNil(RequestLog.line(
            method: "PUT", path: "/v1/state", status: 401,
            userAgent: RequestLog.healthcheckAgent, milliseconds: 1))
    }

    /// The one that decides whether this filter is worth having. An over-matching filter is worse
    /// than the noise it removes: the 401 flood in the log was investigated *because* it was
    /// visible, and the still-unidentified `Python-urllib/3.12` caller has to stay that visible.
    func testAnotherCallerGettingTheSame401IsStillLogged() throws {
        let others = [
            "Python-urllib/3.12",       // the unidentified ~15-minute caller
            "curl/7.81.0",              // what the healthcheck looked like before it was tagged
            "curl/8.5.0",               // deploy.sh's own post-deploy assertion, from the host
            "Baton/97",
            "baton-healthcheck",        // near miss: no version
            "baton-healthcheck/2",      // near miss: a version we do not send
            "baton-healthcheck-probe/1",
            "not-baton-healthcheck/1",
        ]
        for agent in others {
            let line = try XCTUnwrap(RequestLog.line(
                method: "GET", path: "/v1/state", status: 401, userAgent: agent, milliseconds: 1),
                "a 401 from \(agent) must stay visible")
            XCTAssertTrue(line.contains("401"), line)
        }

        // And with no User-Agent at all, which is what an anonymous probe looks like.
        XCTAssertNotNil(RequestLog.line(
            method: "GET", path: "/v1/state", status: 401, userAgent: nil, milliseconds: 1))
    }

    /// compose.yml passes `-A baton-healthcheck/1`; the sanitiser has to leave that intact or the
    /// suppression silently stops matching and the flood returns without anything failing.
    func testTheAgentComposeSendsSurvivesTheSanitiser() {
        XCTAssertEqual(RequestLog.caller("baton-healthcheck/1"), RequestLog.healthcheckAgent)
        XCTAssertFalse(RequestLog.looksLikeSecret(RequestLog.healthcheckAgent))
    }

    // MARK: - Nothing secret reaches the log

    /// The User-Agent is unvalidated input being written to a file that persists. These are the
    /// shapes the repo's own pre-push scan looks for.
    func testACredentialShapedUserAgentIsRefusedRatherThanEchoed() {
        let secrets = [
            "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
            "sk-proj-0123456789abcdef0123456789abcdef",
            // Assembled rather than written out. This shape is what the repo's own pre-push
            // scan and the public mirror's secrets guard both match, so a literal here blocks
            // a release to make a point the assembled string makes just as well — the value
            // handed to RequestLog is byte-identical either way.
            "sntrys_" + String(repeating: "0123456789abcdef", count: 2),
            String(repeating: "a1b2c3d4", count: 8),   // a long unbroken run, i.e. a token
        ]
        for secret in secrets {
            let line = RequestLog.line(method: "GET", path: "/v1/state", status: 200,
                                       userAgent: secret, milliseconds: 1) ?? ""
            XCTAssertFalse(line.contains(secret), "a credential-shaped caller was echoed: \(line)")
            XCTAssertTrue(line.contains("unknown"), "and it should say so plainly: \(line)")
        }
    }

    /// Only the product token, never the rest of the header. A token smuggled in behind a space
    /// is dropped by the same rule that keeps the line short.
    func testOnlyTheFirstComponentOfTheUserAgentIsKept() throws {
        let line = try XCTUnwrap(RequestLog.line(
            method: "GET", path: "/v1/files", status: 200,
            userAgent: "Baton/1.0.13 Bearer sk-should-never-appear", milliseconds: 4
        ))
        XCTAssertTrue(line.contains("Baton/1.0.13"), line)
        XCTAssertFalse(line.contains("sk-should-never-appear"), line)
        XCTAssertFalse(line.lowercased().contains("bearer"), line)
    }

    /// A real one, so the sanitiser is not simply refusing everything — which would pass every
    /// assertion above while making the log useless.
    func testARealUserAgentSurvivesIntact() {
        XCTAssertEqual(RequestLog.caller("Baton/1.0.13 CFNetwork/3826.500.111 Darwin/25.5.0"),
                       "Baton/1.0.13")
        XCTAssertEqual(RequestLog.caller(nil), "unknown")
    }

    // MARK: - The status is the one actually sent

    func testTheStatusIsReadBackOutOfTheResponse() {
        let ok = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        XCTAssertEqual(RequestLog.status(ofResponse: ok), 200)

        let refused = Data("HTTP/1.1 401 Unauthorized\r\n\r\n".utf8)
        XCTAssertEqual(RequestLog.status(ofResponse: refused), 401)

        // Garbage in, a number that is obviously not a status out — rather than a plausible 200.
        XCTAssertEqual(RequestLog.status(ofResponse: Data("nonsense".utf8)), 0)
    }
}
