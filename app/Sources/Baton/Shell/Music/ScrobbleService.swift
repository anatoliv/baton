import Foundation
import Network
import Observation
import OSLog

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
final class ScrobbleService {
    /// Who delivers Last.fm / ListenBrainz scrobbles. See `externalSource`.
    enum ExternalSource: String, CaseIterable {
        /// Baton scrobbles Last.fm/ListenBrainz directly (default — matches a fresh setup where
        /// the server has no external accounts linked).
        case baton
        /// The server already scrobbles to Last.fm/ListenBrainz; Baton must not, or plays would
        /// be counted twice.
        case server
    }

    /// Persisted routing choice for direct external scrobbling.
    var externalSource: ExternalSource {
        didSet { defaults.set(externalSource.rawValue, forKey: Self.sourceKey) }
    }

    @ObservationIgnored static let sourceKey = "tonebox.music.scrobbleExternalSource"
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

    /// Every destination, for draining the queue regardless of the current routing choice (items
    /// queued while in `.baton` mode must still flush even after a later switch to `.server`).
    @ObservationIgnored private var allDestinations: [ScrobbleDestination] { [navidrome, listenBrainz, lastfm] }

    /// Guards against overlapping flushes of the same destination.
    @ObservationIgnored private var flushing: Set<String> = []
    /// Per-destination backoff so a persistently-erroring server isn't hammered once per
    /// completed play. Cleared on success and on the reconnect edge. In-memory: a launch
    /// retries once, which is fine. (W-08 / SCR-02)
    @ObservationIgnored private var retryState: [String: (failures: Int, nextAt: Date)] = [:]
    /// Whether the network is currently reachable (updated by the path monitor). When
    /// offline we don't even attempt a drain, so items wait with attempts untouched. In
    /// tests (no monitor) this stays true so drains run deterministically. (W-08)
    @ObservationIgnored private var isOnline = true
    /// Dedup key of the last completed listen (songID@startedAt) — a belt-and-suspenders guard
    /// against a repeated eligibility callback double-counting a single play.
    @ObservationIgnored private var lastCompletedKey: String?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    init(
        listenBrainz: ScrobbleDestination,
        lastfm: ScrobbleDestination,
        navidrome: ScrobbleDestination = NavidromeScrobbleDestination(),
        localArchive: LocalListenRecording? = nil,
        queue: ScrobbleQueue = ScrobbleQueue(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        monitorNetwork: Bool = !BatonEnvironment.current.isTesting,
        autoFlush: Bool = true
    ) {
        self.listenBrainz = listenBrainz
        self.lastfm = lastfm
        self.navidrome = navidrome
        self.localArchive = localArchive
        self.queue = queue
        self.now = now
        self.autoFlush = autoFlush
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
    func nowPlaying(_ song: NavidromeSong) {
        Task { await nowPlayingAndWait(song) }
    }

    /// Awaitable core of `nowPlaying` (deterministic for tests).
    func nowPlayingAndWait(_ song: NavidromeSong) async {
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
    func completed(_ song: NavidromeSong, startedAt: Date) {
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
    func flushAll() {
        for destination in allDestinations { flush(destination) }
    }

    /// Awaitable drain of every destination (deterministic for tests).
    func flushAllAndWait() async {
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
                retryState[id] = (failures, now().addingTimeInterval(Self.backoffInterval(failures)))
                serviceLog.error("\(id, privacy: .public) flush deferred (\(transient ? "transient" : "permanent", privacy: .public)): \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

    /// Classifies a submit failure. Transient failures (network, 5xx, 429, and — until
    /// W-31's per-provider handling — unclassified errors) are retried without burning an
    /// attempt; definitive rejections (4xx, auth, Subsonic protocol errors) count so a
    /// genuinely-undeliverable listen still retires. (W-08 / SCR-01)
    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let nav = error as? NavidromeError {
            switch nav {
            case .transport, .notConfigured, .decoding: return true
            case .http(let status): return status == 429 || (500...599).contains(status)
            case .invalidURL, .unauthorized, .subsonic: return false
            }
        }
        return true // unknown (e.g. Last.fm/ListenBrainz) → retry rather than drop
    }

    /// Backoff after N consecutive failures. The first failure retries immediately (an
    /// isolated blip shouldn't stall a scrobble); sustained failure backs off 5 s → 300 s.
    static func backoffInterval(_ failures: Int) -> TimeInterval {
        guard failures > 1 else { return 0 }
        return min(300, 5 * pow(2, Double(min(failures - 1, 6))))
    }

    // MARK: - Routing

    /// Direct external destinations to scrobble *right now*, honouring the routing choice.
    private var externalDestinations: [ScrobbleDestination] {
        guard externalSource == .baton else { return [] }
        return [listenBrainz, lastfm].filter(\.isActive)
    }

    /// Only library tracks scrobble. Podcast episodes (http(s) enclosure ids) and radio never do.
    private func isScrobblable(_ song: NavidromeSong) -> Bool {
        !MusicModel.isPodcastEpisode(song)
    }
}
