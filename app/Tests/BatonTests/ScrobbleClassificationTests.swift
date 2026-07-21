import Foundation
import Testing
@testable import Baton

/// : the transient-vs-permanent split that keeps an offline session from destroying
/// the scrobbles the durable queue exists to protect.
@MainActor
@Suite("Scrobble failure classification")
struct ScrobbleClassificationTests {
    @Test("network / 5xx / 429 / not-configured are transient")
    func transient() {
        #expect(ScrobbleService.isTransient(URLError(.notConnectedToInternet)))
        #expect(ScrobbleService.isTransient(NavidromeError.transport("x")))
        #expect(ScrobbleService.isTransient(NavidromeError.http(status: 503)))
        #expect(ScrobbleService.isTransient(NavidromeError.http(status: 429)))
        #expect(ScrobbleService.isTransient(NavidromeError.notConfigured))
    }

    @Test("4xx / auth / Subsonic protocol errors are definitive rejections")
    func permanent() {
        #expect(!ScrobbleService.isTransient(NavidromeError.http(status: 404)))
        #expect(!ScrobbleService.isTransient(NavidromeError.unauthorized))
        #expect(!ScrobbleService.isTransient(NavidromeError.subsonic(code: 70, message: "not found")))
    }

    @Test("first failure retries immediately, then backs off exponentially")
    func backoff() {
        #expect(ScrobbleService.backoffInterval(1) == 0)
        #expect(ScrobbleService.backoffInterval(2) == 10)
        #expect(ScrobbleService.backoffInterval(3) == 20)
        #expect(ScrobbleService.backoffInterval(100) == 300)
    }

    @Test("transient fails leave attempts untouched; permanent fails burn and eventually retire")
    func queueFailFlag() {
        let defaults = UserDefaults(suiteName: "scrobble-cls-\(UUID().uuidString)")!
        let queue = ScrobbleQueue(defaults: defaults)
        let s = Scrobble(
            song: NavidromeSong(id: "x", title: "x", artist: "A", album: nil, albumID: nil, duration: 100, coverArtID: nil),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        queue.enqueue(s, destination: "navidrome")
        let batch = queue.take(destination: "navidrome", limit: 10)

        for _ in 0 ..< 30 { queue.fail(batch, countsAsAttempt: false) }
        #expect(queue.pending.count == 1)
        #expect(queue.pending.first?.attempts == 0)

        for _ in 0 ..< ScrobbleQueue.maxAttempts { queue.fail(batch, countsAsAttempt: true) }
        #expect(queue.pending.isEmpty)
    }
}
