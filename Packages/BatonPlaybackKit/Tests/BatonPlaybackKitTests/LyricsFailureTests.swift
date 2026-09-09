import BatonSubsonicModels
import XCTest
@testable import BatonPlaybackKit

/// What the lyrics panel is told when there are no lyrics to show.
///
/// Every failure on this path used to end as the same sentence: "No lyrics for this track".
/// A refused sign in, a rate limit from LRCLIB (which answers 429), a 500 and a song nobody
/// has written words for were one answer, logged at `debug` if at all. Two of those are
/// things the person can act on, and one of them is not a statement about the song (S-F27).
final class LyricsFailureTests: XCTestCase {
    override func tearDown() {
        LyricsStub.reset()
        super.tearDown()
    }

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsStub.self]
        return URLSession(configuration: configuration)
    }

    // MARK: The two stubbed statuses the card names

    /// LRCLIB rate limiting is the failure most likely to be seen for real: the lookup runs
    /// on every track change, and once the service starts answering 429 it does so for a
    /// while. "No lyrics for this track", forty times in a row, for tracks that all have them.
    func testARateLimitedLookupSaysSoRatherThanClaimingThereAreNoLyrics() async {
        LyricsStub.status = 429
        let lookup = await LRCLIBLyrics.lookup(title: "Bohemian Rhapsody", artist: "Queen",
                                               album: nil, durationSeconds: 354,
                                               session: stubbedSession())
        XCTAssertEqual(lookup, .failed(.rateLimited))
        XCTAssertEqual(lookup.failureMessage,
                       "The lyrics service is rate limiting requests. Try again in a minute.")
    }

    func testARefusedLookupSaysSoRatherThanClaimingThereAreNoLyrics() async {
        LyricsStub.status = 401
        let lookup = await LRCLIBLyrics.lookup(title: "Bohemian Rhapsody", artist: "Queen",
                                               album: nil, durationSeconds: 354,
                                               session: stubbedSession())
        XCTAssertEqual(lookup, .failed(.refused))
        XCTAssertNotNil(lookup.failureMessage)
        XCTAssertNotEqual(lookup.failureMessage, LyricsFailure.rateLimited.message,
                          "the two must not collapse into one message")
    }

    /// The distinction the whole change rests on: a service that answered and has nothing is
    /// not a failure, and must keep the plain empty state. `/api/get` 404s constantly.
    func testATrackWithNoRecordIsStillJustNoLyrics() async {
        LyricsStub.status = 404
        let lookup = await LRCLIBLyrics.lookup(title: "Bohemian Rhapsody", artist: "Queen",
                                               album: nil, durationSeconds: 354,
                                               session: stubbedSession())
        XCTAssertEqual(lookup, LyricsLookup.none)
        XCTAssertNil(lookup.failureMessage, "the panel shows its ordinary empty state here")
    }

    /// A lookup that works is unchanged by any of this.
    func testAFoundSheetIsStillReturned() async {
        LyricsStub.status = 200
        LyricsStub.body = Data(#"{"plainLyrics":"is this the real life","syncedLyrics":null}"#.utf8)
        let lookup = await LRCLIBLyrics.lookup(title: "Bohemian Rhapsody", artist: "Queen",
                                               album: nil, durationSeconds: 354,
                                               session: stubbedSession())
        XCTAssertEqual(lookup.lyrics?.lines.map(\.text), ["is this the real life"])
        XCTAssertNil(lookup.failureMessage)
    }

    /// Offline is the case that stays in the log: it is not about this track, it fixes
    /// itself, and a sentence about it in a lyrics sheet is noise.
    func testATransportFailureKeepsTheOrdinaryEmptyState() async {
        LyricsStub.error = URLError(.notConnectedToInternet)
        let lookup = await LRCLIBLyrics.lookup(title: "Bohemian Rhapsody", artist: "Queen",
                                               album: nil, durationSeconds: 354,
                                               session: stubbedSession())
        XCTAssertEqual(lookup, .failed(.unavailable))
        XCTAssertNil(lookup.failureMessage)
    }

    // MARK: The status map, stated once

    func testStatusesMapToTheKindTheyMean() {
        XCTAssertEqual(LRCLIBLyrics.kind(ofStatus: 200), .ok)
        XCTAssertEqual(LRCLIBLyrics.kind(ofStatus: 404), .missing)
        XCTAssertEqual(LRCLIBLyrics.kind(ofStatus: 401), .failed(.refused))
        XCTAssertEqual(LRCLIBLyrics.kind(ofStatus: 403), .failed(.refused))
        XCTAssertEqual(LRCLIBLyrics.kind(ofStatus: 429), .failed(.rateLimited))
        XCTAssertEqual(LRCLIBLyrics.kind(ofStatus: 500), .failed(.unavailable))
    }

    /// The server hop, which is the other half of the path and the one that can actually be
    /// refused: Subsonic reports a wrong password as a protocol error inside a 200.
    func testAServerErrorBecomesTheKindThePanelCanExplain() {
        XCTAssertEqual(MusicLibraryStore.lyricsFailure(for: NavidromeError.unauthorized), .refused)
        XCTAssertEqual(MusicLibraryStore.lyricsFailure(for: NavidromeError.subsonic(code: 40, message: "wrong")),
                       .refused)
        XCTAssertEqual(MusicLibraryStore.lyricsFailure(for: NavidromeError.http(status: 401)), .refused)
        XCTAssertEqual(MusicLibraryStore.lyricsFailure(for: NavidromeError.http(status: 429)), .rateLimited)
        XCTAssertEqual(MusicLibraryStore.lyricsFailure(for: NavidromeError.transport("offline")), .unavailable)
        // Never configured is a different sentence, and every other screen already says it.
        // Telling someone their sign in was refused when they never signed in sends them to
        // check a password that does not exist.
        XCTAssertEqual(MusicLibraryStore.lyricsFailure(for: NavidromeError.notConfigured), .unavailable)
    }

    /// A failed server hop must not bury a working fallback, and when both come back empty
    /// the more actionable reason is the one that survives.
    func testLyricsWinOverAFailureAndTheActionableFailureWinsOverTheRest() {
        let sheet = NavidromeLyrics(synced: false, lines: [.init(text: "words")])
        XCTAssertEqual(LyricsLookup.combining(.failed(.refused), .found(sheet)), .found(sheet))
        XCTAssertEqual(LyricsLookup.combining(.found(sheet), .failed(.rateLimited)), .found(sheet))
        XCTAssertEqual(LyricsLookup.combining(.failed(.unavailable), .failed(.refused)), .failed(.refused))
        XCTAssertEqual(LyricsLookup.combining(.failed(.rateLimited), .failed(.unavailable)),
                       .failed(.rateLimited))
        XCTAssertEqual(LyricsLookup.combining(LyricsLookup.none, LyricsLookup.none), LyricsLookup.none)
    }

    /// House style, and the one thing about these strings a test can hold: no em or en dash,
    /// and short enough to sit where "No lyrics for this track" sits today.
    func testTheVisibleReasonsAreOnePlainLine() throws {
        for failure in [LyricsFailure.refused, .rateLimited] {
            let message = try XCTUnwrap(failure.message)
            XCTAssertFalse(message.contains("\u{2014}"), "em dash in: \(message)")
            XCTAssertFalse(message.contains("\u{2013}"), "en dash in: \(message)")
            XCTAssertFalse(message.contains("\n"))
            XCTAssertLessThan(message.count, 90, "too long for the panel: \(message)")
            XCTAssertNotNil(failure.title)
        }
        XCTAssertNil(LyricsFailure.unavailable.message, "this one stays in the log")
    }
}

/// Answers every LRCLIB request with one stubbed status.
private final class LyricsStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data("{}".utf8)
    nonisolated(unsafe) static var error: (any Error)?

    static func reset() {
        status = 200
        body = Data("{}".utf8)
        error = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "lrclib.net"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
