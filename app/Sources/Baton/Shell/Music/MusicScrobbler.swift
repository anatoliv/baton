import Foundation
import Observation
import OSLog

private let scrobbleLog = Logger(subsystem: "io.tonebox.macos", category: "Scrobbler")

/// Submits listens to **ListenBrainz** (the open, MusicBrainz-backed scrobbling service).
/// Chosen over Last.fm for a personal player because it needs only a **user token** (from
/// your listenbrainz.org profile) — no OAuth dance. Off until a token is set. This is in
/// addition to the server-side scrobble Tonebox already sends Navidrome.
@MainActor
@Observable
final class MusicScrobbler {
    /// The ListenBrainz user token (Settings → Music → Scrobbling). Empty ⇒ disabled.
    var token: String {
        didSet { UserDefaults.standard.set(token, forKey: Self.tokenKey) }
    }

    @ObservationIgnored static let tokenKey = "tonebox.music.listenBrainzToken"
    @ObservationIgnored private let endpoint = URL(string: "https://api.listenbrainz.org/1/submit-listens")!
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: () -> Date

    var isEnabled: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty }

    init(session: URLSession = .shared, now: @escaping () -> Date = { Date() }) {
        self.session = session
        self.now = now
        token = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
    }

    /// "Now playing" ping — no timestamp; shows on your ListenBrainz profile while playing.
    func updateNowPlaying(_ song: NavidromeSong) {
        submit(song, listenType: "playing_now", listenedAt: nil)
    }

    /// A completed listen — call once a track has been played past the scrobble threshold
    /// (half its length, or 4 minutes, whichever comes first — the standard rule).
    func submitListen(_ song: NavidromeSong) {
        submit(song, listenType: "single", listenedAt: Int(now().timeIntervalSince1970))
    }

    /// The play position (seconds) at which a track counts as "listened" per the standard
    /// scrobble rule. Pure for testing.
    static func scrobbleThreshold(duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 30 }
        return min(duration / 2, 240)
    }

    private func submit(_ song: NavidromeSong, listenType: String, listenedAt: Int?) {
        let token = token.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        var metadata: [String: Any] = [
            "artist_name": song.artist ?? "Unknown Artist",
            "track_name": song.title,
        ]
        if let album = song.album, !album.isEmpty { metadata["release_name"] = album }
        var listen: [String: Any] = ["track_metadata": metadata]
        if let listenedAt { listen["listened_at"] = listenedAt }
        let body: [String: Any] = ["listen_type": listenType, "payload": [listen]]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        Task {
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                    scrobbleLog.error("ListenBrainz \(listenType, privacy: .public) HTTP \(http.statusCode)")
                }
            } catch {
                scrobbleLog.error("ListenBrainz submit failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
