import Foundation
import Observation
import OSLog
import BatonSubsonicKit
import BatonSubsonicModels

private let scrobbleLog = Logger(subsystem: "io.tonebox.baton", category: "Scrobbler")

/// Submits listens to **ListenBrainz** (the open, MusicBrainz-backed scrobbling service).
/// Chosen for a personal player because it needs only a **user token** (from your
/// listenbrainz.org profile) — no OAuth dance. Off until a token is set.
///
/// This owns only the ListenBrainz credential + wire format; *when* to scrobble (threshold,
/// dedup, podcast exclusion, offline retry, server-vs-client routing) lives in `ScrobbleService`.
@MainActor
@Observable
public final class MusicScrobbler: ScrobbleDestination {
    /// The ListenBrainz user token (Settings → Music → Scrobbling). Empty ⇒ disabled.
    public var token: String {
        didSet { NavidromeKeychain.setSecret(token, account: Self.tokenKey) } // Keychain
    }

    @ObservationIgnored public static let tokenKey = "tonebox.music.listenBrainzToken"
    @ObservationIgnored private let endpoint = URL(string: "https://api.listenbrainz.org/1/submit-listens")!
    @ObservationIgnored private let session: URLSession

    public var isEnabled: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty }

    public init(session: URLSession = .shared) {
        self.session = session
        token = NavidromeKeychain.secret(account: Self.tokenKey) ?? "" // Keychain, migrate-on-read
    }

    /// The play position (seconds) at which a track counts as "listened" per the standard
    /// scrobble rule — half its length, or 4 minutes, whichever comes first. Pure for testing.
    public static func scrobbleThreshold(duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 30 }
        return min(duration / 2, 240)
    }

    // MARK: - ScrobbleDestination

    public var destinationID: String { "listenbrainz" }
    public var isActive: Bool { isEnabled }
    /// ListenBrainz accepts many listens in one `import` payload; cap the batch conservatively.
    public var maxBatch: Int { 50 }

    /// "Now playing" ping — no timestamp; shows on your ListenBrainz profile while playing.
    public func sendNowPlaying(_ scrobble: Scrobble) async {
        try? await post(listenType: "playing_now", scrobbles: [scrobble])
    }

    /// A batch of completed listens. One track uses `single`; several use `import`. Each listen
    /// carries its own start timestamp so a delayed/offline flush still records the true time.
    public func submit(_ batch: [Scrobble]) async throws {
        guard !batch.isEmpty else { return }
        try await post(listenType: batch.count == 1 ? "single" : "import", scrobbles: batch)
    }

    // MARK: - Wire format

    /// Builds one ListenBrainz `listen` object. `nonisolated static` + pure (no `self`) so the
    /// wire shape is unit-testable off the main actor without a live network destination.
    public nonisolated static func payload(for scrobble: Scrobble, includeTimestamp: Bool) -> [String: Any] {
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

    // MARK: - Is this token real?

    /// What ListenBrainz says about the token currently in the field.
    public enum TokenCheck: Equatable, Sendable {
        case missing
        case valid(user: String)
        /// It answered and said no. A typo in the token lands here, not in `failed`.
        case rejected
        case failed(String)
    }

    /// Ask ListenBrainz whether the token works, rather than assuming it because it is
    /// non-empty. Settings used to show a green "Scrobbling to ListenBrainz" for any string
    /// at all, so a mistyped token looked exactly like a working one and the first sign of
    /// trouble was listens never appearing on a profile nobody thinks to check.
    ///
    /// `validate-token` is the endpoint made for this: one GET, no listen submitted.
    public func checkToken() async -> TokenCheck {
        let token = token.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return .missing }

        var request = URLRequest(url: Self.validateEndpoint)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 401 is the documented refusal, but the service has also answered 200 with
            // `valid: false`, so the body decides whenever it parses.
            if let parsed = Self.readValidation(data) { return parsed }
            if status == 401 || status == 403 { return .rejected }
            return .failed("ListenBrainz answered with HTTP \(status).")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @ObservationIgnored static let validateEndpoint = URL(string: "https://api.listenbrainz.org/1/validate-token")!

    /// The `validate-token` body, read the way the service actually answers it. Pure, so the
    /// shape is testable without a live account. Returns nil when the body says nothing
    /// useful, leaving the HTTP status to decide.
    nonisolated static func readValidation(_ data: Data) -> TokenCheck? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let valid = root["valid"] as? Bool else { return nil }
        guard valid else { return .rejected }
        let user = (root["user_name"] as? String) ?? ""
        return .valid(user: user)
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
