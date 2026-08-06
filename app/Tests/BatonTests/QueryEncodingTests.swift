import XCTest
import BatonSubsonicKit
@testable import Baton

/// `URLComponents` percent-encodes `&` and `=` inside query values but leaves `;` and
/// `+` alone — both are legal in a query component per RFC 3986. Servers disagree:
/// Navidrome is Go, and `url.ParseQuery` rejects a bare `;` with "invalid semicolon
/// separator in query"; `+` decodes as a space. A song title containing either breaks
/// the request or silently searches for something else.
final class QueryEncodingTests: XCTestCase {
    private func url(query value: String) throws -> String {
        let creds = NavidromeCredentials(
            baseURL: URL(string: "https://example.test")!,
            username: "u",
            secret: "p",
            authMode: .tokenSalt
        )
        let client = NavidromeClient(credentials: creds)
        return try client.makeURL("search3.view", query: [
            URLQueryItem(name: "query", value: value),
        ]).absoluteString
    }

    func testSemicolonIsEncoded() throws {
        let s = try url(query: "rock; roll")
        XCTAssertTrue(s.contains("%3B"), "semicolon must be encoded: \(s)")
        XCTAssertFalse(s.contains("roll") && s.contains("; "), "raw semicolon leaked: \(s)")
    }

    /// The exact string that produced "invalid semicolon separator in query" in the
    /// field — an HTML-escaped ampersand, whose trailing `;` broke Go's parser.
    func testHTMLEscapedAmpersandDoesNotBreakTheQuery() throws {
        let s = try url(query: "Melodic Techno &amp; Deep Progressive")
        XCTAssertFalse(s.contains(";"), "no raw semicolon may reach the server: \(s)")
        XCTAssertTrue(s.contains("%26"), "the ampersand itself should still be encoded: \(s)")
    }

    func testPlusIsEncodedSoItIsNotDecodedAsSpace() throws {
        let s = try url(query: "a+b")
        XCTAssertTrue(s.contains("%2B"), "plus must be encoded or it arrives as a space: \(s)")
    }

    func testAmpersandStillEncodedAndDoesNotSplitParameters() throws {
        let s = try url(query: "Simon & Garfunkel")
        XCTAssertTrue(s.contains("%26"))
        XCTAssertFalse(s.contains("&query=Simon & "), "value must not split the query string: \(s)")
    }

    func testNonASCIISurvivesEncoding() throws {
        let s = try url(query: "øneheart")
        XCTAssertTrue(s.contains("%C3%B8"), "UTF-8 percent-encoding expected: \(s)")
    }

    func testOrdinaryQueryIsUnaffected() throws {
        let s = try url(query: "jazz")
        XCTAssertTrue(s.contains("query=jazz"))
        XCTAssertFalse(s.contains("%3B"))
        XCTAssertFalse(s.contains("%2B"))
    }
}

/// `NavidromeClient.foldedForSearch` — the fix for the `øneheart` miss.
///
/// Navidrome indexes a normalised `full_text` column: the title `best of øneheart` is
/// stored as `oneheart`. Sending the literal `øneheart` matched nothing, and the failure
/// was silent — search simply returned zero rows. Confirmed against the live database:
/// `full_text` reads " ambient best mix of oneheart unknown yt".
final class SearchFoldingTests: XCTestCase {
    func testStrokedODoesNotSurviveAsItself() {
        // The reported bug. `ø` is a distinct letter, not `o` plus a combining stroke, so
        // .diacriticInsensitive alone does not fold it — it needs the explicit map.
        XCTAssertEqual(NavidromeClient.foldedForSearch("øneheart"), "oneheart")
    }

    func testComposedDiacriticsFold() {
        XCTAssertEqual(NavidromeClient.foldedForSearch("Tiësto"), "Tiesto")
        XCTAssertEqual(NavidromeClient.foldedForSearch("Amélie"), "Amelie")
        XCTAssertEqual(NavidromeClient.foldedForSearch("Björk"), "Bjork")
        XCTAssertEqual(NavidromeClient.foldedForSearch("Motörhead"), "Motorhead")
    }

    func testLigaturesAndOtherDistinctLettersExpand() {
        XCTAssertEqual(NavidromeClient.foldedForSearch("æther"), "aether")
        XCTAssertEqual(NavidromeClient.foldedForSearch("Straße"), "Strasse")
        XCTAssertEqual(NavidromeClient.foldedForSearch("Þorn"), "THorn")
    }

    func testPlainASCIIIsUntouched() {
        XCTAssertEqual(NavidromeClient.foldedForSearch("jazz"), "jazz")
        XCTAssertEqual(NavidromeClient.foldedForSearch("Deep Focus Music"), "Deep Focus Music")
    }

    func testCaseIsPreservedSoTheServerDecidesSensitivity() {
        XCTAssertEqual(NavidromeClient.foldedForSearch("ØNEHEART"), "ONEHEART")
    }

    func testFoldingIsIdempotent() {
        let once = NavidromeClient.foldedForSearch("øneheart Tiësto")
        XCTAssertEqual(NavidromeClient.foldedForSearch(once), once)
    }
}

/// Stream-URL provenance.
///
/// A play recorded downstream says only "this track was played". A track that appears in
/// two playlists is then indistinguishable between them, so any judgement about whether a
/// *playlist* works has to be inferred from membership. Annotating the stream request with
/// its queue source makes that observable instead.
@MainActor
final class StreamProvenanceTests: XCTestCase {
    private let base = URL(string: "https://example.test/rest/stream.view?id=abc&format=mp3")!

    private func source(_ kind: StreamingPlaybackController.QueueSource.Kind,
                        id: String? = nil) -> StreamingPlaybackController.QueueSource {
        .init(label: "L", kind: kind, id: id)
    }

    func testPlaylistProvenanceCarriesKindAndID() {
        let url = StreamingPlaybackController.annotate(base, with: source(.playlist, id: "pl42"))
        XCTAssertTrue(url.absoluteString.contains("playedFrom=playlist:pl42")
                      || url.absoluteString.contains("playedFrom=playlist%3Apl42"),
                      url.absoluteString)
    }

    func testSourceWithoutAnIDStillRecordsItsKind() {
        let url = StreamingPlaybackController.annotate(base, with: source(.search))
        XCTAssertTrue(url.absoluteString.contains("playedFrom=search"), url.absoluteString)
    }

    func testNoSourceLeavesTheURLUntouched() {
        XCTAssertEqual(StreamingPlaybackController.annotate(base, with: nil), base)
    }

    func testExistingParametersSurvive() {
        // The auth and format params must reach the server intact — dropping `format=mp3`
        // would break playback of every Opus file in a YouTube-sourced library.
        let url = StreamingPlaybackController.annotate(base, with: source(.album, id: "a1"))
        XCTAssertTrue(url.absoluteString.contains("id=abc"))
        XCTAssertTrue(url.absoluteString.contains("format=mp3"))
    }

    func testAnnotationIsSafeForEveryQueueKind() {
        for kind in [StreamingPlaybackController.QueueSource.Kind.playlist, .album, .artist,
                     .radio, .search, .liked, .song] {
            let url = StreamingPlaybackController.annotate(base, with: source(kind, id: "x"))
            XCTAssertTrue(url.absoluteString.contains("playedFrom="), "\(kind)")
        }
    }

    func testAnEmptyIDDoesNotProduceATrailingSeparator() {
        let url = StreamingPlaybackController.annotate(base, with: source(.playlist, id: ""))
        XCTAssertFalse(url.absoluteString.contains("playlist:"), url.absoluteString)
        XCTAssertFalse(url.absoluteString.contains("playlist%3A"), url.absoluteString)
    }
}
