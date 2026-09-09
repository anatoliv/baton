import Foundation
import Network
import Observation
import OSLog
import BatonSubsonicKit
import BatonSubsonicModels

private let serviceLog = Logger(subsystem: "io.tonebox.baton", category: "ScrobbleService")

/// The single owner of scrobble *policy*. The playback engine emits two clean signals —
/// `nowPlaying` at the downbeat and `completed` once a track passes the listen threshold — and
/// this service decides who hears them and when:
///
/// - **Podcasts and radio never scrobble.** They flow through the same engine as music, so the
///   guard lives here (a podcast plays with an http(s) enclosure id).
/// - **Play counts + "now playing" always go to the server** (`submission=false` then, at the
///   threshold, `submission=true`) — never at 0 %, so a skipped track isn't miscredited.
/// - **Direct Last.fm / ListenBrainz scrobbling is routed by `externalSource`.** In `.server`
///   mode Baton stays silent and lets the server proxy the play (avoiding double scrobbles); in
///   `.baton` mode Baton scrobbles them itself.
/// - **Completed listens are durable.** Every submission goes through a persisted retry queue,
///   flushed on reconnect, at launch, and after each new play — so an outage or offline session
///   never loses a scrobble.
@MainActor
@Observable
public final class ScrobbleService {
    /// Who delivers Last.fm / ListenBrainz scrobbles. See `externalSource`.
    public enum ExternalSource: String, CaseIterable {
        /// Baton scrobbles Last.fm/ListenBrainz directly (default — matches a fresh setup where
        /// the server has no external accounts linked).
        case baton
        /// The server already scrobbles to Last.fm/ListenBrainz; Baton must not, or plays would
        /// be counted twice.
        case server
    }

    /// Persisted routing choice for direct external scrobbling.
    public var externalSource: ExternalSource {
        didSet { defaults.set(externalSource.rawValue, forKey: Self.sourceKey) }
    }

    @ObservationIgnored public static let sourceKey = "tonebox.music.scrobbleExternalSource"
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private let navidrome: ScrobbleDestination
    @ObservationIgnored private let listenBrainz: ScrobbleDestination
    @ObservationIgnored private let lastfm: ScrobbleDestination
    /// The private, on-device archive (Baton's free local alternative to Last.fm/ListenBrainz).
    /// Recorded to directly — a local write never fails, so it doesn't use the retry queue and is
    /// independent of `externalSource`.
    @ObservationIgnored private let localArchive: LocalListenRecording?
    @ObservationIgnored private let queue: ScrobbleQueue
    @ObservationIgnored private let now: () -> Date
    /// Whether enqueuing a listen immediately kicks off a flush. Off in tests so the queue can
    /// be inspected before draining it deterministically via `flushAllAndWait()`.
    @ObservationIgnored private let autoFlush: Bool

    /// Classifies a song as a podcast episode, which never scrobbles. Defaults to the id-only
    /// test (client-side enclosure URLs); `MusicModel` replaces it with one that also recognises
    /// server-side episodes, whose ids are indistinguishable from library tracks.
    @ObservationIgnored public var isPodcast: (NavidromeSong) -> Bool = { $0.isPodcastEpisode }

    /// Every destination, for draining the queue regardless of the current routing choice (items
    /// queued while in `.baton` mode must still flush even after a later switch to `.server`).
    @ObservationIgnored private var allDestinations: [ScrobbleDestination] { [navidrome, listenBrainz, lastfm] }

    /// Guards against overlapping flushes of the same destination.
    @ObservationIgnored private var flushing: Set<String> = []
    /// Per-destination backoff so a persistently-erroring server isn't hammered once per
    /// completed play. Cleared on success and on the reconnect edge. In-memory: a launch
    /// retries once, which is fine.
    @ObservationIgnored private var retryState: [String: (failures: Int, nextAt: Date)] = [:]
    /// Whether the network is currently reachable (updated by the path monitor). When
    /// offline we don't even attempt a drain, so items wait with attempts untouched. In
    /// tests (no monitor) this stays true so drains run deterministically.
    @ObservationIgnored private var isOnline = true
    /// Dedup key of the last completed listen (songID@startedAt) — a belt-and-suspenders guard
    /// against a repeated eligibility callback double-counting a single play.
    @ObservationIgnored private var lastCompletedKey: String?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    /// One pending re-drain per destination, so a backoff actually ends.
    ///
    /// Without this, `nextAt` only gated a drain someone else triggered: a new play, a
    /// relaunch, or a connectivity edge. With the network up the whole time and the
    /// *service* down, none of the three arrives, and a queue sits full while the app looks
    /// perfectly healthy. The tasks live in a box of their own so the box's `deinit`
    /// cancels them — a `@MainActor` class cannot touch its own state from `deinit`.
    @ObservationIgnored private let retryTasks = ScheduledRetries()
    /// How the scheduled re-drain waits. Injectable so a test can drive the wait to zero
    /// and assert the drain re-fires on its own, with no new enqueue and no path change.
    @ObservationIgnored private let waitBeforeRetry: @Sendable (TimeInterval) async -> Void

    public init(
        listenBrainz: ScrobbleDestination,
        lastfm: ScrobbleDestination,
        navidrome: ScrobbleDestination = NavidromeScrobbleDestination(),
        localArchive: LocalListenRecording? = nil,
        queue: ScrobbleQueue = ScrobbleQueue(),
        defaults: UserDefaults = BatonStorage.defaults,
        now: @escaping () -> Date = { Date() },
        monitorNetwork: Bool = !BatonEnvironment.current.isTesting,
        autoFlush: Bool = true,
        waitBeforeRetry: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.listenBrainz = listenBrainz
        self.lastfm = lastfm
        self.navidrome = navidrome
        self.localArchive = localArchive
        self.queue = queue
        self.now = now
        self.autoFlush = autoFlush
        self.waitBeforeRetry = waitBeforeRetry
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.sourceKey)
        externalSource = stored.flatMap(ExternalSource.init(rawValue:)) ?? .baton

        if monitorNetwork {
            // Retry queued scrobbles the moment connectivity returns.
            pathMonitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied
                Task { @MainActor in
                    guard let self else { return }
                    self.isOnline = satisfied
                    guard satisfied else { return }
                    self.retryState.removeAll() // connectivity returned — retry immediately
                    self.flushAll()
                }
            }
            pathMonitor.start(queue: DispatchQueue(label: "io.tonebox.scrobble.path"))
        }
        // Deliver anything left over from a previous session.
        flushAll()
    }

    // MARK: - Signals from the player

    /// A track just started playing — ping "now playing". Ignored for podcasts/radio.
    public func nowPlaying(_ song: NavidromeSong) {
        Task { await nowPlayingAndWait(song) }
    }

    /// Awaitable core of `nowPlaying` (deterministic for tests).
    public func nowPlayingAndWait(_ song: NavidromeSong) async {
        guard isScrobblable(song) else { return }
        let scrobble = Scrobble(song: song, startedAt: now())
        await navidrome.sendNowPlaying(scrobble)
        for destination in externalDestinations {
            await destination.sendNowPlaying(scrobble)
        }
    }

    /// A track passed the listen threshold — record a completed listen. `startedAt` is when the
    /// track began (the canonical scrobble timestamp), carried from the downbeat. Ignored for
    /// podcasts/radio, and deduped so a single play is never counted twice.
    public func completed(_ song: NavidromeSong, startedAt: Date) {
        guard isScrobblable(song) else { return }
        let key = "\(song.id)@\(Int(startedAt.timeIntervalSince1970))"
        guard key != lastCompletedKey else { return }
        lastCompletedKey = key

        // Private, on-device log first — always, whatever the external routing is.
        localArchive?.record(song, playedAt: startedAt)

        let scrobble = Scrobble(song: song, startedAt: startedAt)
        enqueue(scrobble, to: navidrome)
        for destination in externalDestinations {
            enqueue(scrobble, to: destination)
        }
    }

    // MARK: - Queue + flush

    /// Force-drain every destination (called on reconnect, at launch, and after each new play).
    /// How many completed listens are still waiting to reach an external service.
    ///
    /// Read-only, for the settings screens: "scrobbling is set up" and "your plays are
    /// actually arriving" are different claims, and a queue that only ever grows is the
    /// symptom the user needs to be able to see.
    public var pendingCount: Int { queue.pending.count }

    /// Drops every queued listen without delivering it — session teardown only.
    ///
    /// Not a "cancel" for users: the queue is durable precisely so a tube journey doesn't
    /// lose plays. The one case where dropping is correct is a session ending, because the
    /// listens belong to the account leaving, not the one arriving.
    public func purgeQueue() { queue.clear() }

    public func flushAll() {
        for destination in allDestinations { flush(destination) }
    }

    /// Awaitable drain of every destination (deterministic for tests).
    public func flushAllAndWait() async {
        for destination in allDestinations { await drain(destination) }
    }

    private func enqueue(_ scrobble: Scrobble, to destination: ScrobbleDestination) {
        guard destination.isActive else { return }
        queue.enqueue(scrobble, destination: destination.destinationID)
        if autoFlush { flush(destination) }
    }

    private func flush(_ destination: ScrobbleDestination) {
        Task { await drain(destination) }
    }

    /// Deliver queued items for one destination, oldest first, in `maxBatch`-sized chunks, until
    /// the queue empties or the server pushes back (a thrown submit keeps the batch queued with a
    /// bumped attempt count and stops the drain until the next trigger). Re-entrancy is guarded so
    /// overlapping triggers don't double-submit the same batch.
    private func drain(_ destination: ScrobbleDestination) async {
        let id = destination.destinationID
        guard isOnline, destination.isActive, !flushing.contains(id),
              queue.pendingDestinations.contains(id) else { return }
        if let s = retryState[id], now() < s.nextAt { return } // backing off
        flushing.insert(id)
        defer { flushing.remove(id) }
        while true {
            let batch = queue.take(destination: id, limit: destination.maxBatch)
            guard !batch.isEmpty else { break }
            do {
                try await destination.submit(batch.map(\.scrobble))
                queue.resolve(batch)
                retryState[id] = nil // success clears backoff
            } catch {
                // A transient failure (offline/timeout/5xx/429) must NOT count against
                // maxAttempts — otherwise an offline evening permanently drops scrobbles.
                let transient = Self.isTransient(error)
                queue.fail(batch, countsAsAttempt: !transient)
                let failures = (retryState[id]?.failures ?? 0) + 1
                let wait = Self.backoffInterval(failures)
                retryState[id] = (failures, now().addingTimeInterval(wait))
                serviceLog.error("\(id, privacy: .public) flush deferred (\(transient ? "transient" : "permanent", privacy: .public)): \(error.localizedDescription, privacy: .public)")
                scheduleRetry(destination, after: wait)
                break
            }
        }
    }

    /// Come back once the backoff has run out, so a destination that is simply down
    /// recovers on its own. Cancelled and replaced if the same destination defers again,
    /// cancelled wholesale when the service goes away, and a no-op while offline: the
    /// reconnect edge already drains, and a drain with no network only burns a wake-up.
    private func scheduleRetry(_ destination: ScrobbleDestination, after wait: TimeInterval) {
        guard wait > 0 else { return } // the first failure retries on the next trigger anyway
        let id = destination.destinationID
        let task = Task { @MainActor [weak self, waitBeforeRetry] in
            await waitBeforeRetry(wait)
            guard !Task.isCancelled, let self, self.isOnline else { return }
            // The wait we asked for has elapsed, so the gate in `drain` has been paid.
            // Keep the failure count: the next backoff must still be longer than this one.
            if let state = self.retryState[id] { self.retryState[id] = (state.failures, self.now()) }
            await self.drain(destination)
        }
        retryTasks.replace(id, with: task)
    }

    /// Classifies a submit failure. Transient failures (network, 5xx, 429, and errors no
    /// provider arm recognises) are retried without burning an attempt; definitive
    /// rejections (4xx, auth, Subsonic protocol errors) count so a genuinely-undeliverable
    /// listen still retires.
    ///
    /// The `ScrobbleError` arm is the one that was missing. Last.fm and ListenBrainz both
    /// raise it, and everything they raised was filed as transient — including the 401 and
    /// the Last.fm 4/9/26 that mean "re-authenticate", which no amount of retrying fixes.
    /// A revoked session then filled the queue to `maxEntries` and dropped the oldest real
    /// listens off the front while nothing ever retired. Only the codes that plainly mean
    /// credentials are permanent here; an unrecognised code is still retried, because
    /// getting the list wrong in the other direction throws listens away.
    public static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let nav = error as? NavidromeError {
            switch nav {
            // A locked Keychain is the definition of transient: it unlocks, and the listen is
            // then perfectly deliverable. Burning an attempt on it would retire real listens
            // for the duration of a screen lock.
            case .transport, .notConfigured, .decoding, .credentialsUnreadable: return true
            case .http(let status): return status == 429 || (500...599).contains(status)
            case .invalidURL, .unauthorized, .subsonic: return false
            }
        }
        if let scrobble = error as? ScrobbleError {
            switch scrobble {
            case .http(let status): return !(status == 401 || status == 403)
            case .service(let message): return !MusicLastFM.isCredentialRejection(message)
            }
        }
        return true // unknown provider error → retry rather than drop
    }

    /// Backoff after N consecutive failures. The first failure retries immediately (an
    /// isolated blip shouldn't stall a scrobble); sustained failure backs off 5 s → 300 s.
    public static func backoffInterval(_ failures: Int) -> TimeInterval {
        guard failures > 1 else { return 0 }
        return min(300, 5 * pow(2, Double(min(failures - 1, 6))))
    }

    // MARK: - Routing

    /// Direct external destinations to scrobble *right now*, honouring the routing choice.
    private var externalDestinations: [ScrobbleDestination] {
        guard externalSource == .baton else { return [] }
        return [listenBrainz, lastfm].filter(\.isActive)
    }

    /// Only library tracks scrobble. Podcast episodes, radio and local files never do.
    ///
    /// **The comment said this before the code did.** It excluded podcasts only, so anything
    /// else that is not a library track went to Last.fm and ListenBrainz as though it were one.
    /// That went unnoticed while the only such content was the bundled demo library; clippings
    /// made it reachable in ordinary use, and a scrobble of "Google Chrome 09.15" by
    /// the artist "Google Chrome" is not something a listening history can be asked to carry.
    ///
    /// Asking `MediaKind` is also the honest test: the id already says what a thing is, and
    /// enumerating the exclusions one at a time is how the next kind gets missed too.
    /// **And the code has to ask `isPodcast`, not just declare it.** The hook above was
    /// injected by the Mac and read by nothing, so a server-side episode — whose id is an
    /// opaque Subsonic id, indistinguishable from a library track — was submitted to Last.fm
    /// and ListenBrainz as music, permanently. The id-only test is necessary and not
    /// sufficient; the host's registry is the only thing that knows the rest.
    private func isScrobblable(_ song: NavidromeSong) -> Bool {
        Self.isScrobblableForTesting(song) && !isPodcast(song)
    }

    /// The id-only half of the rule, reachable without building a service. Exposed because
    /// the rule is about *what may leave this machine*, and that deserves a test that does
    /// not depend on standing up scrobble destinations. It cannot see a server-side podcast
    /// episode; `isScrobblable` asks `isPodcast` for that.
    public static func isScrobblableForTesting(_ song: NavidromeSong) -> Bool {
        MediaKind(id: song.id) == .libraryTrack
    }
}

/// Holds the pending re-drain task per destination. A plain, non-isolated class so its
/// `deinit` can cancel them: a `@MainActor` type's `deinit` is nonisolated and cannot reach
/// its own main-actor state, so a dictionary of tasks stored directly on `ScrobbleService`
/// would have no honest place to be cancelled from.
private final class ScheduledRetries: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    func replace(_ id: String, with task: Task<Void, Never>) {
        lock.lock()
        let previous = tasks.updateValue(task, forKey: id)
        lock.unlock()
        previous?.cancel()
    }

    func cancelAll() {
        lock.lock()
        let pending = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        pending.forEach { $0.cancel() }
    }

    deinit { cancelAll() }
}
