import BatonSubsonicKit
import XCTest
@testable import BatonMobile

/// Covers cached before C3-2's fix kept the signed URL on disk: the artwork
/// cache is cleared once, and only once.
final class ArtworkCacheOneTimeClearTests: XCTestCase {
    func testTheCacheIsClearedOnceAndThenLeftAlone() throws {
        let suite = ThrowawayDefaults.name("artwork-clear")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0)
        let request = URLRequest(url: URL(string: "https://music.example/rest/getCoverArt?id=1")!)
        func store() {
            let response = HTTPURLResponse(url: URL(string: "https://music.example/rest/getCoverArt?id=1&u=me&t=tok&s=salt")!,
                                           statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            cache.storeCachedResponse(CachedURLResponse(response: response, data: Data([1, 2, 3])), for: request)
        }

        store()
        XCTAssertNotNil(cache.cachedResponse(for: request), "precondition: an old entry")
        XCTAssertTrue(ArtworkCacheOneTimeClear.run(defaults: defaults, cache: cache))
        XCTAssertNil(cache.cachedResponse(for: request), "the old entry, signed URL and all, is gone")

        store()
        XCTAssertFalse(ArtworkCacheOneTimeClear.run(defaults: defaults, cache: cache))
        XCTAssertNotNil(cache.cachedResponse(for: request), "a later launch keeps what it fetched since")
    }
}
