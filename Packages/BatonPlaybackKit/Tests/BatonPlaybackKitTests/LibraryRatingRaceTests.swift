import XCTest
import BatonSubsonicKit
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Two quick rating changes where the first fails after the second has landed: the failure
/// put back the rating from before both.
@MainActor
final class LibraryRatingRaceTests: XCTestCase {
    override func tearDown() {
        SlowFailingRatingProtocol.reset()
        super.tearDown()
    }

    func testAnEarlierRatingThatFailsLateDoesNotUndoALaterOne() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowFailingRatingProtocol.self]
        let session = URLSession(configuration: config)
        let credentials = NavidromeCredentials(baseURL: URL(string: "https://music.example")!, username: "joe",
                                               secret: "sesame", authMode: .tokenSalt)
        let store = MusicLibraryStore(clientProvider: { NavidromeClient(credentials: credentials, session: session) })
        let song = NavidromeSong(id: "s1", title: "Song", artist: "A")

        let first = Task { await store.setRating(song, rating: 4) }   // the server fails this one, slowly
        while SlowFailingRatingProtocol.started == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await store.setRating(song, rating: 5)
        XCTAssertEqual(store.rating(song), 5, "precondition: the second rating landed")
        await first.value
        XCTAssertEqual(store.rating(song), 5, "the first rating's late failure undid the second")
    }
}

/// Two quick like toggles that both fail (offline): the UI must end as the server is, not
/// liked. The newest write's revert restored its own baseline, which was the first toggle's
/// optimistic state.
@MainActor
final class LibraryLikeFailureTests: XCTestCase {
    private func store() -> MusicLibraryStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlwaysFailingProtocol.self]
        let session = URLSession(configuration: config)
        let credentials = NavidromeCredentials(baseURL: URL(string: "https://music.example")!, username: "joe",
                                               secret: "sesame", authMode: .tokenSalt)
        return MusicLibraryStore(clientProvider: { NavidromeClient(credentials: credentials, session: session) })
    }

    func testTwoFailedLikeTogglesLeaveTheSongAsTheServerHasIt() async {
        let store = store()
        let song = NavidromeSong(id: "s1", title: "Song", artist: "A")
        AlwaysFailingProtocol.count = 0
        AlwaysFailingProtocol.delays = [0.3, 0.05]   // the first toggle fails last
        async let first: Void = store.toggleLike(song)
        async let second: Void = store.toggleLike(song)
        _ = await (first, second)
        XCTAssertFalse(store.isLiked(song), "the UI shows liked while the server never was")
    }

    func testTheOtherOrderToo() async {
        let store = store()
        let song = NavidromeSong(id: "s2", title: "Song", artist: "A")
        AlwaysFailingProtocol.count = 0
        AlwaysFailingProtocol.delays = [0.05, 0.3]   // the first toggle fails first
        async let first: Void = store.toggleLike(song)
        async let second: Void = store.toggleLike(song)
        _ = await (first, second)
        XCTAssertFalse(store.isLiked(song), "the UI shows liked while the server never was")
    }
}

/// A like that succeeds slowly, then an unlike that fails at once: the server holds the like,
/// and the heart must show it (fresh-context verification of the review fix).
@MainActor
final class LibraryLikeMixedAnswerTests: XCTestCase {
    func testAnOlderSuccessAfterANewerFailureShowsWhatTheServerHolds() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowStarFastUnstarFailProtocol.self]
        let session = URLSession(configuration: config)
        let credentials = NavidromeCredentials(baseURL: URL(string: "https://music.example")!, username: "joe",
                                               secret: "sesame", authMode: .tokenSalt)
        let store = MusicLibraryStore(clientProvider: { NavidromeClient(credentials: credentials, session: session) })
        let song = NavidromeSong(id: "s3", title: "Song", artist: "A")
        async let like: Void = store.toggleLike(song)      // star: succeeds after 0.3 s
        async let unlike: Void = store.toggleLike(song)    // unstar: fails at once
        _ = await (like, unlike)
        XCTAssertTrue(store.isLiked(song), "the server starred the song and the heart shows it unliked")
    }
}

/// `star` succeeds after 0.3 s; `unstar` fails at once.
final class SlowStarFastUnstarFailProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path.hasSuffix("unstar.view") {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let body = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                     cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// Fails every request, the n-th after `delays[n]` seconds.
final class AlwaysFailingProtocol: URLProtocol {
    nonisolated(unsafe) static var delays: [Double] = []
    nonisolated(unsafe) static var count = 0
    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let n = Self.count
        Self.count += 1
        let delay = n < Self.delays.count ? Self.delays[n] : 0
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }
    override func stopLoading() {}
}

/// `setRating` with rating=4 fails after a delay; anything else succeeds at once.
final class SlowFailingRatingProtocol: URLProtocol {
    nonisolated(unsafe) static var started = 0
    static func reset() { started = 0 }
    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let slowFailure = url.query?.contains("rating=4") ?? false
        if slowFailure { Self.started += 1 }
        let respond = { [weak self] in
            guard let self else { return }
            if slowFailure {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let body = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if slowFailure { DispatchQueue.global().asyncAfter(deadline: .now() + 0.4, execute: respond) } else { respond() }
    }
    override func stopLoading() {}
}
