import XCTest
@testable import BatonPlaybackKit

/// Settings used to show a green tick for a credential nobody had ever asked about.
///
/// ListenBrainz was the worst of them: any non-empty string in the token field produced
/// "Scrobbling to ListenBrainz" in green, so a token with a character missing looked exactly
/// like a working account, and the only place the difference appeared was a profile page with
/// no listens on it that nobody thinks to open.
///
/// These cover the part that decides what the answer means. A refused token and a service
/// that isn't there need different things from the person reading the badge — one is a string
/// to copy again, the other is a network to go and look at — so they must not collapse into
/// one grey "not connected".
final class ServiceCredentialCheckTests: XCTestCase {
    // MARK: - ListenBrainz `validate-token`

    /// The documented success body.
    func testAValidTokenReportsTheAccountItBelongsTo() {
        let body = Data(#"{"code":200,"message":"Token valid.","valid":true,"user_name":"anatoli"}"#.utf8)
        XCTAssertEqual(MusicScrobbler.readValidation(body), .valid(user: "anatoli"))
    }

    /// The service has answered 200 with `valid: false` as well as 401, so the body decides
    /// whenever it parses. Reading only the status code would show a green tick for a typo.
    func testATokenTheServiceRejectsIsRefusedEvenInA200() {
        let body = Data(#"{"code":200,"message":"Token invalid.","valid":false}"#.utf8)
        XCTAssertEqual(MusicScrobbler.readValidation(body), .rejected)
    }

    /// A valid token with no user name attached is still valid — the badge just has less to
    /// say. Requiring the name would report a working account as broken.
    func testAValidTokenWithoutAUserNameIsStillValid() {
        let body = Data(#"{"valid":true}"#.utf8)
        XCTAssertEqual(MusicScrobbler.readValidation(body), .valid(user: ""))
    }

    /// Nothing useful in the body means the HTTP status decides, not a guess. Returning
    /// `.rejected` here would tell someone their token was wrong because a proxy served HTML.
    func testAnUnreadableBodyDefersToTheStatusCode() {
        XCTAssertNil(MusicScrobbler.readValidation(Data("<html>502 Bad Gateway</html>".utf8)))
        XCTAssertNil(MusicScrobbler.readValidation(Data(#"{"code":200}"#.utf8)))
        XCTAssertNil(MusicScrobbler.readValidation(Data()))
    }
}
