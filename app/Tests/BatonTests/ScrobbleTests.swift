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

/// A clock the test moves by hand, so a backoff can expire without any real waiting.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
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

/// A server-side podcast episode: an opaque Subsonic id, indistinguishable from a library
/// track until the host's episode registry is asked.
@MainActor
private func serverPodcastEpisode(_ id: String = "ep-4821") -> NavidromeSong {
    NavidromeSong(id: id, title: "Episode 12", artist: "Show", album: nil,
                  albumID: nil, duration: 3600, coverArtID: nil)
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

    /// The exclusion above only ever proved the id rule: a client-side episode carries an
    /// `https://` id, which `MediaKind` already refuses. A **server-side** episode carries an
    /// opaque Subsonic id, so the only thing that can tell it apart is the host's registry —
    /// which is what `isPodcast` is for, and what the service never asked. The Mac injected
    /// that hook and the code read it nowhere, so every server-side episode played past the
    /// threshold went to Last.fm and ListenBrainz as music, permanently.
    @Test("a server-side podcast episode is never scrobbled, opaque id and all")
    func serverSidePodcastExcluded() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm"), nav = MockDestination("navidrome", maxBatch: 1)
        let (service, queue) = makeService(lb: lb, fm: fm, nav: nav)
        let episode = serverPodcastEpisode()
        // What the composition root does: consult the episode registry as well as the id.
        service.isPodcast = { $0.id == episode.id }

        await service.nowPlayingAndWait(episode)
        service.completed(episode, startedAt: start)
        await service.flushAllAndWait()

        #expect(nav.nowPlayingCalls.isEmpty && lb.nowPlayingCalls.isEmpty && fm.nowPlayingCalls.isEmpty)
        #expect(nav.submitted.isEmpty && lb.submitted.isEmpty && fm.submitted.isEmpty)
        #expect(queue.pending.isEmpty)
    }

    /// The guard is a podcast guard, not an off switch: a library track alongside it still
    /// scrobbles, or the fix would be indistinguishable from breaking scrobbling.
    @Test("a library track still scrobbles while the podcast hook is installed")
    func libraryTrackUnaffectedByThePodcastHook() async {
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm"), nav = MockDestination("navidrome", maxBatch: 1)
        let (service, _) = makeService(lb: lb, fm: fm, nav: nav)
        let episode = serverPodcastEpisode()
        service.isPodcast = { $0.id == episode.id }

        service.completed(librarySong(), startedAt: start)
        await service.flushAllAndWait()

        #expect(nav.submitted.count == 1 && lb.submitted.count == 1 && fm.submitted.count == 1)
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

    /// A backoff used to be a gate and nothing else: `nextAt` blocked a drain that someone
    /// else triggered, and the only triggers were a new play, a relaunch, or a connectivity
    /// edge. With the network up the whole time and the service down, none of the three
    /// arrives — so a queue that backed off once stayed backed off, looking healthy.
    ///
    /// The wait is injected and the clock is moved by hand, so this asserts the re-drain
    /// happens on its own rather than that a sleep is long enough.
    @Test("a deferred drain comes back on its own, with no new enqueue and no path change")
    func deferredDrainRefiresItself() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let lb = MockDestination("listenbrainz"), fm = MockDestination("lastfm")
        // Two transient failures: the first backs off by zero, the second schedules a wait.
        let nav = MockDestination("navidrome", maxBatch: 1, failFirst: 2)
        let defaults = UserDefaults(suiteName: "scrobble-retry-\(UUID().uuidString)")!
        let service = ScrobbleService(
            listenBrainz: lb, lastfm: fm, navidrome: nav,
            queue: ScrobbleQueue(defaults: defaults), defaults: defaults,
            now: { clock.now }, monitorNetwork: false, autoFlush: false,
            waitBeforeRetry: { seconds in clock.advance(by: seconds) }
        )

        service.completed(librarySong(), startedAt: start)
        await service.flushAllAndWait()   // failure 1: backoff 0, nothing scheduled
        await service.flushAllAndWait()   // failure 2: backoff 10 s, one retry scheduled
        #expect(nav.submitted.isEmpty)

        // Nothing else happens: no new play, no reconnect, no manual flush.
        for _ in 0 ..< 200 where nav.submitted.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(nav.submitted.count == 1, "the scheduled retry has to deliver the queued listen")
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
