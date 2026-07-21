import Foundation

/// A single place scrobbles are delivered — the Navidrome/Subsonic server, ListenBrainz, or
/// Last.fm. `ScrobbleService` fans plays out to every active destination through this one
/// interface, so adding a target (or a test double) never touches the triggering logic.
@MainActor
protocol ScrobbleDestination: AnyObject {
    /// Stable key stored in the retry queue — never localise or rename it, or queued items
    /// from an older build would be orphaned.
    var destinationID: String { get }
    /// Whether this destination is configured and switched on right now.
    var isActive: Bool { get }
    /// Largest number of completed listens accepted in one `submit` call. Subsonic has no
    /// batch endpoint (1); Last.fm and ListenBrainz accept up to 50.
    var maxBatch: Int { get }

    /// Best-effort "now playing" ping. Never throws — a lost now-playing is ephemeral and not
    /// worth queueing.
    func sendNowPlaying(_ scrobble: Scrobble) async
    /// Deliver a batch of completed listens. **Throws on any failure** so the caller keeps the
    /// batch in the retry queue; returns normally only when the server accepted them.
    func submit(_ batch: [Scrobble]) async throws
}

/// Errors a destination raises so a failed batch is retried rather than silently dropped.
enum ScrobbleError: Error {
    case http(Int)
    case service(String)
}

/// Delivers scrobbles to the Navidrome/Subsonic server via `scrobble.view`. A `submission=false`
/// ping feeds the server's "Now Playing"; `submission=true` credits the play count (and, if the
/// user linked Last.fm/ListenBrainz *on the server*, is proxied there too). Subsonic has no batch
/// endpoint, so a batch is delivered one id at a time and fails as a whole if any id fails.
@MainActor
final class NavidromeScrobbleDestination: ScrobbleDestination {
    var destinationID: String { "navidrome" }
    /// The server is the play source, so treat it as active whenever it's configured; transient
    /// unreachability (e.g. offline playback of a download) surfaces as a thrown submit and the
    /// listen waits in the queue.
    var isActive: Bool { NavidromeConfig.isConfigured }
    var maxBatch: Int { 1 }

    func sendNowPlaying(_ scrobble: Scrobble) async {
        guard !BatonEnvironment.current.isTesting, NavidromeConfig.isConfigured else { return }
        try? await NavidromeConfig.makeClient().scrobble(id: scrobble.songID, submission: false)
    }

    func submit(_ batch: [Scrobble]) async throws {
        guard !BatonEnvironment.current.isTesting else { return }
        let client = try NavidromeConfig.makeClient()
        for scrobble in batch {
            // Pass the track's real start time (ms) so a delayed/offline flush is credited at the
            // listen time, not the flush time. (W-31 / SCR-03)
            try await client.scrobble(id: scrobble.songID, submission: true, time: scrobble.startedAt * 1000)
        }
    }
}
