import Foundation
import Testing
@testable import Baton

// MARK: - Test doubles

/// Records what it was asked to scrobble; can be made inactive or fail its first N submits.
@MainActor
private final class MockDestination: ScrobbleDestination {
    let destinationID: String
    var active: Bool
    let maxBatch: Int
    var failFirst: Int
    /// When true, `submit` throws a *permanent* rejection (burns a queue attempt); otherwise
    /// a *transient* failure (retried without burning an attempt — ).
    let permanentFailure: Bool

    private(set) var nowPlayingCalls: [Scrobble] = []
    private(set) var submitted: [Scrobble] = []
    private(set) var submitCallCount = 0

    init(_ id: String, active: Bool = true, maxBatch: Int = 50, failFirst: Int = 0, permanentFailure: Bool = false) {
        destinationID = id
        self.active = active
        self.maxBatch = maxBatch
        self.failFirst = failFirst
        self.permanentFailure = permanentFailure
    }

    var isActive: Bool { active }
    func sendNowPlaying(_ scrobble: Scrobble) async { nowPlayingCalls.append(scrobble) }
    func submit(_ batch: [Scrobble]) async throws {
        submitCallCount += 1
        if submitCallCount <= failFirst {
            throw permanentFailure
                ? NavidromeError.subsonic(code: 0, message: "mock")
                : NavidromeError.transport("mock")
        }
        submitted.append(contentsOf: batch)
    }
}

@MainActor
private func librarySong(_ id: String = "song1", duration: Int? = 200) -> NavidromeSong {
    NavidromeSong(id: id, title: "Title \(id)", artist: "Artist", album: "Album",
                  albumID: nil, duration: duration, coverArtID: nil)
}

@MainActor
private func podcastEpisode() -> NavidromeSong {
    NavidromeSong(id: "https://example.com/ep1.mp3", title: "Episode", artist: "Show",
                  album: nil, albumID: nil, duration: 3600, coverArtID: nil)
}

@MainActor
private func makeService(
    lb: MockDestination, fm: MockDestination, nav: MockDestination,
    source: ScrobbleService.ExternalSource = .baton
) -> (ScrobbleService, ScrobbleQueue) {
    let defaults = UserDefaults(suiteName: "scrobble-test-\(UUID().uuidString)")!
    let queue = ScrobbleQueue(defaults: defaults)
    let service = ScrobbleService(
        listenBrainz: lb, lastfm: fm, navidrome: nav, queue: queue, defaults: defaults,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }, monitorNetwork: false, autoFlush: false
    )
    service.externalSource = source
    return (service, queue)
}

// MARK: - ScrobbleService

@MainActor
@Suite("ScrobbleService policy")
struct ScrobbleServiceTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("podcasts are never scrobbled — no now-playing, no submission, nothing queued")
    func podcastsExcluded() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm"), nav = MockDestination("navidrome", maxBatch: 1)
        let (service, queue) = makeService(lb: lb, fm: fm, nav: nav)

        await service.nowPlayingAndWait(podcastEpisode())
        service.completed(podcastEpisode(), startedAt: start)
        await service.flushAllAndWait()

        #expect(nav.nowPlayingCalls.isEmpty && lb.nowPlayingCalls.isEmpty && fm.nowPlayingCalls.isEmpty)
        #expect(nav.submitted.isEmpty && lb.submitted.isEmpty && fm.submitted.isEmpty)
        #expect(queue.pending.isEmpty)
    }

    @Test("in Baton mode a completed listen reaches all three destinations")
    func fansOutInBatonMode() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm"), nav = MockDestination("navidrome", maxBatch: 1)
        let (service, _) = makeService(lb: lb, fm: fm, nav: nav, source: .baton)

        service.completed(librarySong(), startedAt: start)
        await service.flushAllAndWait()

        #expect(nav.submitted.count == 1)
        #expect(lb.submitted.count == 1)
        #expect(fm.submitted.count == 1)
    }

    @Test("in Server mode Baton scrobbles play counts only — server proxies Last.fm/ListenBrainz")
    func serverModeSkipsExternal() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm"), nav = MockDestination("navidrome", maxBatch: 1)
        let (service, _) = makeService(lb: lb, fm: fm, nav: nav, source: .server)

        service.nowPlaying(librarySong())          // via Task
        await service.nowPlayingAndWait(librarySong())
        service.completed(librarySong(), startedAt: start)
        await service.flushAllAndWait()

        #expect(nav.submitted.count == 1)           // server still gets the play
        #expect(lb.submitted.isEmpty && fm.submitted.isEmpty)
        #expect(lb.nowPlayingCalls.isEmpty && fm.nowPlayingCalls.isEmpty)
        #expect(nav.nowPlayingCalls.isEmpty == false)
    }

    @Test("the same play (same start time) is never counted twice")
    func dedupSameStart() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm"), nav = MockDestination("navidrome", maxBatch: 1)
        let (service, _) = makeService(lb: lb, fm: fm, nav: nav)

        service.completed(librarySong(), startedAt: start)
        service.completed(librarySong(), startedAt: start)   // duplicate eligibility callback
        await service.flushAllAndWait()

        #expect(nav.submitted.count == 1)
    }

    @Test("a genuine replay (new start time) counts again")
    func replayCountsAgain() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm"), nav = MockDestination("navidrome", maxBatch: 1)
        let (service, _) = makeService(lb: lb, fm: fm, nav: nav)

        service.completed(librarySong(), startedAt: start)
        service.completed(librarySong(), startedAt: start.addingTimeInterval(300))
        await service.flushAllAndWait()

        #expect(nav.submitted.count == 2)
    }

    @Test("the scrobble timestamp is the track's start time, not the submit time")
    func timestampIsTrackStart() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm"), nav = MockDestination("navidrome", maxBatch: 1)
        let (service, _) = makeService(lb: lb, fm: fm, nav: nav)

        service.completed(librarySong(), startedAt: start)
        await service.flushAllAndWait()

        #expect(lb.submitted.first?.startedAt == Int(start.timeIntervalSince1970))
    }

    @Test("an unconfigured external destination is never enqueued")
    func inactiveDestinationSkipped() async {
        let lb = MockDestination("listenbrainz", active: false)
        let fm = MockDestination("lastfm"), nav = MockDestination("navidrome", maxBatch: 1)
        let (service, queue) = makeService(lb: lb, fm: fm, nav: nav)

        service.completed(librarySong(), startedAt: start)
        await service.flushAllAndWait()

        #expect(lb.submitted.isEmpty)
        #expect(nav.submitted.count == 1 && fm.submitted.count == 1)
        #expect(queue.pendingDestinations.contains("listenbrainz") == false)
    }

    @Test("a transient failure is retried on the next flush, not lost, without burning an attempt")
    func failedSubmissionRetries() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm")
        let nav = MockDestination("navidrome", maxBatch: 1, failFirst: 1)   // first submit throws (transient)
        let (service, queue) = makeService(lb: lb, fm: fm, nav: nav)

        service.completed(librarySong(), startedAt: start)
        await service.flushAllAndWait()
        #expect(nav.submitted.isEmpty)                                       // held back
        #expect(queue.take(destination: "navidrome", limit: 10).count == 1) // still queued
        // : a transient failure must NOT count against maxAttempts.
        #expect(queue.take(destination: "navidrome", limit: 10).first?.attempts == 0)

        await service.flushAllAndWait()
        #expect(nav.submitted.count == 1)                                    // delivered on retry
        #expect(queue.pendingDestinations.contains("navidrome") == false)
    }

    @Test("a permanent rejection burns an attempt")
    func permanentRejectionBurnsAttempt() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm")
        let nav = MockDestination("navidrome", maxBatch: 1, failFirst: 1, permanentFailure: true)
        let (service, queue) = makeService(lb: lb, fm: fm, nav: nav)
        service.completed(librarySong(), startedAt: start)
        await service.flushAllAndWait()
        #expect(queue.take(destination: "navidrome", limit: 10).first?.attempts == 1)
    }

    @Test("an offline stretch never burns attempts or drops the head scrobble")
    func offlineDoesNotDropScrobbles() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm")
        let nav = MockDestination("navidrome", maxBatch: 1, failFirst: 1000) // always transient-fails
        let (service, queue) = makeService(lb: lb, fm: fm, nav: nav)
        service.completed(librarySong("s1"), startedAt: start)
        for _ in 0 ..< (ScrobbleQueue.maxAttempts + 5) { await service.flushAllAndWait() }
        let head = queue.take(destination: "navidrome", limit: 10).first
        #expect(head != nil)
        #expect(head?.attempts == 0)
    }
}

// MARK: - ScrobbleQueue

@MainActor
@Suite("ScrobbleQueue durability")
struct ScrobbleQueueTests {
    private func scrobble(_ id: String) -> Scrobble {
        Scrobble(song: NavidromeSong(id: id, title: id, artist: "A", album: nil, albumID: nil, duration: 100, coverArtID: nil),
                 startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("take returns oldest-first per destination; resolve removes exactly those")
    func fifoResolve() {
        let queue = ScrobbleQueue(defaults: UserDefaults(suiteName: "q-\(UUID())")!)
        queue.enqueue(scrobble("a"), destination: "lastfm")
        queue.enqueue(scrobble("b"), destination: "listenbrainz")
        queue.enqueue(scrobble("c"), destination: "lastfm")

        let lastfm = queue.take(destination: "lastfm", limit: 10)
        #expect(lastfm.map(\.scrobble.songID) == ["a", "c"])

        queue.resolve([lastfm[0]])
        #expect(queue.take(destination: "lastfm", limit: 10).map(\.scrobble.songID) == ["c"])
        #expect(queue.pendingDestinations == ["lastfm", "listenbrainz"])
    }

    @Test("a failed item is retried in place until maxAttempts, then retired")
    func retiresAfterMaxAttempts() {
        let queue = ScrobbleQueue(defaults: UserDefaults(suiteName: "q-\(UUID())")!)
        queue.enqueue(scrobble("a"), destination: "lastfm")

        for _ in 0 ..< (ScrobbleQueue.maxAttempts - 1) {
            let batch = queue.take(destination: "lastfm", limit: 1)
            #expect(batch.count == 1)
            queue.fail(batch)
        }
        // One attempt left before retirement.
        let last = queue.take(destination: "lastfm", limit: 1)
        #expect(last.first?.attempts == ScrobbleQueue.maxAttempts - 1)
        queue.fail(last)
        #expect(queue.pending.isEmpty)   // retired
    }

    @Test("queued scrobbles survive a fresh queue backed by the same store")
    func persistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: "q-\(UUID())")!
        let first = ScrobbleQueue(defaults: defaults)
        first.enqueue(scrobble("a"), destination: "lastfm")

        let reloaded = ScrobbleQueue(defaults: defaults)
        #expect(reloaded.take(destination: "lastfm", limit: 10).map(\.scrobble.songID) == ["a"])
    }

    @Test("the backlog is bounded — oldest entries drop past the cap")
    func boundedGrowth() {
        let queue = ScrobbleQueue(defaults: UserDefaults(suiteName: "q-\(UUID())")!)
        for i in 0 ..< (ScrobbleQueue.maxEntries + 10) {
            queue.enqueue(scrobble("s\(i)"), destination: "lastfm")
        }
        #expect(queue.pending.count == ScrobbleQueue.maxEntries)
        // The very first entries were dropped; the newest survive.
        #expect(queue.pending.last?.scrobble.songID == "s\(ScrobbleQueue.maxEntries + 9)")
    }
}

// MARK: - Threshold rule

@MainActor
@Suite("Scrobble threshold rule")
struct ScrobbleThresholdTests {
    @Test("half the duration, capped at 4 minutes; short/zero durations floor at 30s")
    func rule() {
        #expect(MusicScrobbler.scrobbleThreshold(duration: 100) == 50)    // half
        #expect(MusicScrobbler.scrobbleThreshold(duration: 600) == 240)   // 4-min cap
        #expect(MusicScrobbler.scrobbleThreshold(duration: 0) == 30)      // guard
    }
}
