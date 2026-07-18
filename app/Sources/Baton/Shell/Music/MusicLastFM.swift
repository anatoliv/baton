import AppKit
import CryptoKit
import Foundation
import Observation
import OSLog

private let lastfmLog = Logger(subsystem: "io.tonebox.macos", category: "LastFM")

/// Scrobbles to **Last.fm**. Unlike ListenBrainz (a single token), Last.fm needs an app
/// **API key + shared secret** (register a free API account at last.fm/api/account/create)
/// plus a one-time **browser authorization** that yields a session key. All three persist.
/// Requests are signed with the Last.fm md5 `api_sig` scheme.
@MainActor
@Observable
final class MusicLastFM {
    var apiKey: String { didSet { UserDefaults.standard.set(apiKey, forKey: Self.keyKey) } }
    var apiSecret: String { didSet { UserDefaults.standard.set(apiSecret, forKey: Self.secretKey) } }
    private(set) var sessionKey: String { didSet { UserDefaults.standard.set(sessionKey, forKey: Self.sessionKeyKey) } }
    /// The token from a `getToken` request, awaiting the user's browser authorization.
    private(set) var pendingToken: String?

    @ObservationIgnored static let keyKey = "tonebox.music.lastfm.apiKey"
    @ObservationIgnored static let secretKey = "tonebox.music.lastfm.apiSecret"
    @ObservationIgnored static let sessionKeyKey = "tonebox.music.lastfm.sessionKey"
    @ObservationIgnored private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: () -> Date

    var isConnected: Bool { !sessionKey.isEmpty }
    var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !apiSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init(session: URLSession = .shared, now: @escaping () -> Date = { Date() }) {
        self.session = session
        self.now = now
        let d = UserDefaults.standard
        apiKey = d.string(forKey: Self.keyKey) ?? ""
        apiSecret = d.string(forKey: Self.secretKey) ?? ""
        sessionKey = d.string(forKey: Self.sessionKeyKey) ?? ""
    }

    // MARK: - Auth (two-step browser flow)

    /// Step 1: get a request token and open the Last.fm authorization page in the browser.
    func beginAuth() async {
        guard hasCredentials, let json = await call(["method": "auth.getToken"], signed: true),
              let token = json["token"] as? String else { return }
        pendingToken = token
        if let url = URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Step 2 (after the user authorizes in the browser): exchange the token for a session.
    func completeAuth() async {
        guard let token = pendingToken,
              let json = await call(["method": "auth.getSession", "token": token], signed: true),
              let sessionDict = json["session"] as? [String: Any],
              let key = sessionDict["key"] as? String else { return }
        sessionKey = key
        pendingToken = nil
    }

    func disconnect() { sessionKey = ""; pendingToken = nil }

    // MARK: - Scrobbling

    func updateNowPlaying(_ song: NavidromeSong) {
        guard isConnected else { return }
        Task { _ = await call(nowPlayingParams(song), signed: true, post: true) }
    }

    func scrobble(_ song: NavidromeSong) {
        guard isConnected else { return }
        var params = nowPlayingParams(song)
        params["method"] = "track.scrobble"
        params["timestamp"] = String(Int(now().timeIntervalSince1970))
        Task { _ = await call(params, signed: true, post: true) }
    }

    private func nowPlayingParams(_ song: NavidromeSong) -> [String: String] {
        var p = ["method": "track.updateNowPlaying", "artist": song.artist ?? "Unknown Artist", "track": song.title, "sk": sessionKey]
        if let album = song.album, !album.isEmpty { p["album"] = album }
        return p
    }

    // MARK: - Request + signing

    /// The Last.fm `api_sig`: md5 of the params (sorted by name, concatenated as name+value)
    /// with the shared secret appended. Pure for testing.
    static func signature(_ params: [String: String], secret: String) -> String {
        let concat = params.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + secret
        let digest = Insecure.MD5.hash(data: Data(concat.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    private func call(_ extra: [String: String], signed: Bool, post: Bool = false) async -> [String: Any]? {
        var params = extra
        params["api_key"] = apiKey
        if signed { params["api_sig"] = Self.signature(params, secret: apiSecret) }
        params["format"] = "json" // format is excluded from the signature

        var request = URLRequest(url: endpoint)
        let body = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
        if post {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data(using: .utf8)
        } else {
            request.url = URL(string: endpoint.absoluteString + "?" + body)
        }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                lastfmLog.error("Last.fm HTTP \(http.statusCode)")
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            lastfmLog.error("Last.fm request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
