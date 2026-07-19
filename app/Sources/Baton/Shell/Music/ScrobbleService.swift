import Foundation
import Network
import Observation
import OSLog

private let serviceLog = Logger(subsystem: "io.tonebox.macos", category: "ScrobbleService")

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
        monitorNetwork: Bool = !BatonRuntime.isTest,
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
                guard path.status == .satisfied else { return }
                Task { @MainActor in self?.flushAll() }
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
        guard destination.isActive, !flushing.contains(id),
              queue.pendingDestinations.contains(id) else { return }
        flushing.insert(id)
        defer { flushing.remove(id) }
        while true {
            let batch = queue.take(destination: id, limit: destination.maxBatch)
            guard !batch.isEmpty else { break }
            do {
                try await destination.submit(batch.map(\.scrobble))
                queue.resolve(batch)
            } catch {
                queue.fail(batch)
                serviceLog.error("\(id, privacy: .public) flush deferred: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
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
