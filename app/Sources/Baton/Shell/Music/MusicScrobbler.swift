import Foundation
import Observation
import OSLog

private let scrobbleLog = Logger(subsystem: "io.tonebox.baton", category: "Scrobbler")

/// Submits listens to **ListenBrainz** (the open, MusicBrainz-backed scrobbling service).
/// Chosen for a personal player because it needs only a **user token** (from your
/// listenbrainz.org profile) — no OAuth dance. Off until a token is set.
///
/// This owns only the ListenBrainz credential + wire format; *when* to scrobble (threshold,
/// dedup, podcast exclusion, offline retry, server-vs-client routing) lives in `ScrobbleService`.
@MainActor
@Observable
final class MusicScrobbler: ScrobbleDestination {
    /// The ListenBrainz user token (Settings → Music → Scrobbling). Empty ⇒ disabled.
    var token: String {
        didSet { NavidromeKeychain.setSecret(token, account: Self.tokenKey) } // Keychain (W-13)
    }

    @ObservationIgnored static let tokenKey = "tonebox.music.listenBrainzToken"
    @ObservationIgnored private let endpoint = URL(string: "https://api.listenbrainz.org/1/submit-listens")!
    @ObservationIgnored private let session: URLSession

    var isEnabled: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty }

    init(session: URLSession = .shared) {
        self.session = session
        token = NavidromeKeychain.secret(account: Self.tokenKey) ?? "" // Keychain, migrate-on-read (W-13)
    }

    /// The play position (seconds) at which a track counts as "listened" per the standard
    /// scrobble rule — half its length, or 4 minutes, whichever comes first. Pure for testing.
    static func scrobbleThreshold(duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 30 }
        return min(duration / 2, 240)
    }

    // MARK: - ScrobbleDestination

    var destinationID: String { "listenbrainz" }
    var isActive: Bool { isEnabled }
    /// ListenBrainz accepts many listens in one `import` payload; cap the batch conservatively.
    var maxBatch: Int { 50 }

    /// "Now playing" ping — no timestamp; shows on your ListenBrainz profile while playing.
    func sendNowPlaying(_ scrobble: Scrobble) async {
        try? await post(listenType: "playing_now", scrobbles: [scrobble])
    }

    /// A batch of completed listens. One track uses `single`; several use `import`. Each listen
    /// carries its own start timestamp so a delayed/offline flush still records the true time.
    func submit(_ batch: [Scrobble]) async throws {
        guard !batch.isEmpty else { return }
        try await post(listenType: batch.count == 1 ? "single" : "import", scrobbles: batch)
    }

    // MARK: - Wire format

    /// Builds one ListenBrainz `listen` object. `nonisolated static` + pure (no `self`) so the
    /// wire shape is unit-testable off the main actor without a live network destination. (W-49)
    nonisolated static func payload(for scrobble: Scrobble, includeTimestamp: Bool) -> [String: Any] {
        var metadata: [String: Any] = [
            "artist_name": scrobble.artist,
            "track_name": scrobble.track,
        ]
        if let album = scrobble.album { metadata["release_name"] = album }
        var additional: [String: Any] = ["submission_client": "Baton"]
        if let seconds = scrobble.durationSeconds { additional["duration_ms"] = seconds * 1000 }
        metadata["additional_info"] = additional

        var listen: [String: Any] = ["track_metadata": metadata]
        // `playing_now` must NOT carry a listened_at; completed listens must.
        if includeTimestamp { listen["listened_at"] = scrobble.startedAt }
        return listen
    }

    private func post(listenType: String, scrobbles: [Scrobble]) async throws {
        let token = token.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        let includeTimestamp = listenType != "playing_now"
        let body: [String: Any] = [
            "listen_type": listenType,
            "payload": scrobbles.map { Self.payload(for: $0, includeTimestamp: includeTimestamp) },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw ScrobbleError.service("ListenBrainz: could not encode payload")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            scrobbleLog.error("ListenBrainz \(listenType, privacy: .public) HTTP \(http.statusCode)")
            throw ScrobbleError.http(http.statusCode)
        }
    }
}
