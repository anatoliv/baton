import XCTest
@testable import BatonMobile

/// What a cover-art request did, and what it is allowed to remember about it.
///
/// `ArtworkCache` had no tests in either app target. The three things it got wrong were all
/// invisible from outside: it discarded the HTTP response, so a refused credential and a
/// dropped connection were the same nil; the palette loader cached the neutral fallback
/// after any failure, so one blip left a backdrop grey for the session; and the byte cache
/// was keyed on the full signed URL, whose salt changes per request, so it stored the same
/// cover many times and served none of them back. (TBX-5349 / S-F19)
@MainActor
final class ArtworkLoadOutcomeTests: XCTestCase {
    private var savedSession: URLSession!
    private var savedCache: URLCache!
    /// A fresh instance per test, not `ArtworkCache.shared`: the singleton carries decoded
    /// covers and the refusal debounce from whichever test ran before, and a suite that
    /// depends on its own order is not a suite.
    private var subject: ArtworkCache!

    override func setUp() {
        super.setUp()
        savedSession = ArtworkCache.session
        savedCache = ArtworkCache.byteCache
        StubArtworkProtocol.reset()
        ArtworkCache.session = ArtworkCache.makeSession(protocolClasses: [StubArtworkProtocol.self])
        // Memory only: the real one writes into the app's Caches directory, and a test has no
        // business leaving covers there.
        ArtworkCache.byteCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0)
        subject = ArtworkCache()
    }

    override func tearDown() {
        ArtworkCache.session = savedSession
        ArtworkCache.byteCache = savedCache
        subject = nil
        StubArtworkProtocol.reset()
        super.tearDown()
    }

    /// A cover URL with Subsonic token auth on it, unique per test so the decoded-image cache
    /// (a process-wide `NSCache`) cannot answer for a previous case.
    private func coverURL(id: String = UUID().uuidString, salt: String = "aaaa1111") -> URL {
        URL(string: "https://music.example/rest/getCoverArt.view"
            + "?id=\(id)&size=600&v=1.16.1&c=Baton&u=demo&t=deadbeefdeadbeefdeadbeefdeadbeef&s=\(salt)")!
    }

    // MARK: - The status is read

    func testTheStatusSeparatesARefusedCredentialFromEverythingElse() {
        XCTAssertEqual(ArtworkCache.classify(status: 200), .loaded)
        XCTAssertEqual(ArtworkCache.classify(status: 204), .loaded)
        XCTAssertEqual(ArtworkCache.classify(status: 401), .refused(status: 401))
        XCTAssertEqual(ArtworkCache.classify(status: 403), .refused(status: 403))
        XCTAssertEqual(ArtworkCache.classify(status: 404), .serverError(status: 404))
        XCTAssertEqual(ArtworkCache.classify(status: 500), .serverError(status: 500))
    }

    /// The case that made the old code wrong rather than merely quiet.
    ///
    /// The stub answers 401 with a **decodable image body**, which is what a reverse proxy
    /// serving a branded "access denied" picture does. Ignoring the status, as the old loader
    /// did, means that picture decodes, is returned as the album cover, and is cached for the
    /// session under the cover's key.
    func testAStubbed401ReportsARefusedCredentialAndCachesNothing() async {
        StubArtworkProtocol.status = 401
        StubArtworkProtocol.body = Self.onePixelPNG()
        var announcements = 0
        subject.onCredentialRefused = { announcements += 1 }

        let url = coverURL()
        let (image, outcome) = await subject.load(url, side: 120)

        XCTAssertEqual(outcome, .refused(status: 401))
        XCTAssertNil(image, "a refused request must not hand back the body it was refused with")
        XCTAssertNil(subject.cached(url, side: 120),
                     "nothing about a refused load is remembered")
        XCTAssertEqual(subject.lastRefusal, .refused(status: 401))
        XCTAssertEqual(announcements, 1, "the app is told once, so it can check the credential")
    }

    /// A 404 is the server's problem, not the account's, and must not send anyone to re-type
    /// a password that is correct.
    func testAMissingCoverIsAServerErrorAndAnnouncesNothing() async {
        StubArtworkProtocol.status = 404
        StubArtworkProtocol.body = Data("not found".utf8)
        var announcements = 0
        subject.onCredentialRefused = { announcements += 1 }

        let (image, outcome) = await subject.load(coverURL(), side: 120)

        XCTAssertEqual(outcome, .serverError(status: 404))
        XCTAssertNil(image)
        XCTAssertEqual(announcements, 0)
    }

    /// A grid refuses sixty covers at once and they are all the same news.
    func testOnlyTheFirstRefusalInTheWindowReachesTheApp() {
        let cache = subject!
        let start = Date()
        XCTAssertTrue(cache.noteRefusal(status: 401, now: start))
        XCTAssertFalse(cache.noteRefusal(status: 401, now: start.addingTimeInterval(1)))
        XCTAssertFalse(cache.noteRefusal(status: 401, now: start.addingTimeInterval(29)))
        XCTAssertTrue(cache.noteRefusal(status: 401,
                                        now: start.addingTimeInterval(ArtworkCache.refusalNoticeInterval + 1)),
                      "a refusal after the window is fresh news and must be said again")
    }

    // MARK: - The cache key

    /// The credential identifies the caller; `id` and `size` identify the picture.
    func testTheCacheKeyDropsTheCredentialAndKeepsTheCover() {
        let key = ArtworkCache.cacheKeyURL(for: coverURL(id: "al-1"))
        let query = URLComponents(url: key, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = Set(query.map(\.name))

        XCTAssertTrue(names.isDisjoint(with: ["u", "t", "s", "p", "apiKey"]),
                      "no credential may reach the cache key, which is written to disk in cleartext")
        XCTAssertEqual(query.first { $0.name == "id" }?.value, "al-1")
        XCTAssertEqual(query.first { $0.name == "size" }?.value, "600")
        XCTAssertFalse(key.absoluteString.contains("deadbeef"))
    }

    /// The measurement this exists for: in the owner's real cache, 645 cover-art entries
    /// carried 645 distinct salts for 456 distinct covers, so the disk tier could never serve
    /// a repeat. Two requests for one cover from two client instances must share a key.
    func testTwoSaltsForTheSameCoverShareOneKey() {
        XCTAssertEqual(ArtworkCache.cacheKeyURL(for: coverURL(id: "al-2", salt: "1111")),
                       ArtworkCache.cacheKeyURL(for: coverURL(id: "al-2", salt: "2222")))
        XCTAssertNotEqual(ArtworkCache.cacheKeyURL(for: coverURL(id: "al-2")),
                          ArtworkCache.cacheKeyURL(for: coverURL(id: "al-3")))
    }

    /// And the same thing end to end: a second request for the same cover under a fresh salt
    /// is served from the byte cache instead of going back to the server.
    func testASecondRequestUnderAFreshSaltIsServedFromTheCache() async {
        StubArtworkProtocol.status = 200
        StubArtworkProtocol.body = Self.onePixelPNG()

        let first = await ArtworkCache.fetchBytes(for: coverURL(id: "al-9", salt: "1111"))
        XCTAssertEqual(first.1, .loaded)
        XCTAssertEqual(StubArtworkProtocol.requestCount, 1)

        let second = await ArtworkCache.fetchBytes(for: coverURL(id: "al-9", salt: "9999"))
        XCTAssertEqual(second.1, .loaded)
        XCTAssertEqual(second.0, first.0)
        XCTAssertEqual(StubArtworkProtocol.requestCount, 1,
                       "the salt changed, the cover did not: this must not be a second download")
    }

    /// A stored cover is not kept forever. Album art does change, and a hand-rolled cache
    /// gets no `Cache-Control` handling for free.
    func testAStoredCoverGoesStale() async {
        StubArtworkProtocol.status = 200
        StubArtworkProtocol.body = Self.onePixelPNG()
        let url = coverURL(id: "al-10")
        let stored = Date()
        _ = await ArtworkCache.fetchBytes(for: url, now: stored)
        XCTAssertEqual(StubArtworkProtocol.requestCount, 1)

        let later = stored.addingTimeInterval(ArtworkCache.byteCacheMaxAge + 60)
        _ = await ArtworkCache.fetchBytes(for: url, now: later)
        XCTAssertEqual(StubArtworkProtocol.requestCount, 2)
    }

    /// The privacy half, asserted where it can be seen: what the byte cache holds is keyed
    /// without the username or the token.
    func testTheStoredEntryHoldsNoCredential() async {
        StubArtworkProtocol.status = 200
        StubArtworkProtocol.body = Self.onePixelPNG()
        let url = coverURL(id: "al-11")
        _ = await ArtworkCache.fetchBytes(for: url)

        let credentialed = ArtworkCache.byteCache.cachedResponse(for: URLRequest(url: url))
        XCTAssertNil(credentialed, "the signed URL must not be a key in the store")
        let stripped = ArtworkCache.byteCache
            .cachedResponse(for: URLRequest(url: ArtworkCache.cacheKeyURL(for: url)))
        XCTAssertNotNil(stripped, "the cover must be there under the key that repeats")
    }

    /// A 1x1 PNG, so a stubbed body actually decodes. Without this the 401 test would pass on
    /// the old code for the wrong reason: an undecodable body also yields nil.
    static func onePixelPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    }
}

/// Answers every request with a status and a body the test picks.
final class StubArtworkProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _status = 200
    nonisolated(unsafe) private static var _body = Data()

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    static var status: Int {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }

    static var body: Data {
        get { lock.lock(); defer { lock.unlock() }; return _body }
        set { lock.lock(); _body = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock(); _requestCount = 0; _status = 200; _body = Data(); lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requestCount += 1
        let status = Self._status
        let body = Self._body
        Self.lock.unlock()

        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
