import AppKit
import CryptoKit
import Foundation
import Observation
import OSLog

private let lastfmLog = Logger(subsystem: "io.tonebox.baton", category: "LastFM")

/// Scrobbles to **Last.fm**. Unlike ListenBrainz (a single token), Last.fm needs an app
/// **API key + shared secret** (register a free API account at last.fm/api/account/create)
/// plus a one-time **browser authorization** that yields a session key. All three persist.
/// Requests are signed with the Last.fm md5 `api_sig` scheme.
///
/// This owns only the Last.fm credentials + wire format; scheduling (threshold, dedup, podcast
/// exclusion, offline retry, batching) is `ScrobbleService`'s job.
@MainActor
@Observable
final class MusicLastFM: ScrobbleDestination {
    var apiKey: String { didSet { UserDefaults.standard.set(apiKey, forKey: Self.keyKey) } } // public identifier
    var apiSecret: String { didSet { NavidromeKeychain.setSecret(apiSecret, account: Self.secretKey) } } // Keychain
    private(set) var sessionKey: String { didSet { NavidromeKeychain.setSecret(sessionKey, account: Self.sessionKeyKey) } } // Keychain
    /// The token from a `getToken` request, awaiting the user's browser authorization.
    private(set) var pendingToken: String?

    @ObservationIgnored static let keyKey = "tonebox.music.lastfm.apiKey"
    @ObservationIgnored static let secretKey = "tonebox.music.lastfm.apiSecret"
    @ObservationIgnored static let sessionKeyKey = "tonebox.music.lastfm.sessionKey"
    @ObservationIgnored private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    @ObservationIgnored private let session: URLSession

    var isConnected: Bool { !sessionKey.isEmpty }
    var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !apiSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init(session: URLSession = .shared) {
        self.session = session
        let d = UserDefaults.standard
        apiKey = d.string(forKey: Self.keyKey) ?? ""
        // Secret + session key from the Keychain (migrate-on-read handles existing installs).
        apiSecret = NavidromeKeychain.secret(account: Self.secretKey) ?? ""
        sessionKey = NavidromeKeychain.secret(account: Self.sessionKeyKey) ?? ""
    }

    // MARK: - Auth (two-step browser flow)

    /// Step 1: get a request token and open the Last.fm authorization page in the browser.
    func beginAuth() async {
        guard hasCredentials, let json = try? await call(["method": "auth.getToken"]),
              let token = json["token"] as? String else { return }
        pendingToken = token
        if let url = URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Step 2 (after the user authorizes in the browser): exchange the token for a session.
    func completeAuth() async {
        guard let token = pendingToken,
              let json = try? await call(["method": "auth.getSession", "token": token]),
              let sessionDict = json["session"] as? [String: Any],
              let key = sessionDict["key"] as? String else { return }
        sessionKey = key
        pendingToken = nil
    }

    func disconnect() { sessionKey = ""; pendingToken = nil }

    // MARK: - ScrobbleDestination

    var destinationID: String { "lastfm" }
    var isActive: Bool { isConnected }
    /// Last.fm's `track.scrobble` accepts up to 50 scrobbles per request via array notation.
    var maxBatch: Int { 50 }

    func sendNowPlaying(_ scrobble: Scrobble) async {
        guard isConnected else { return }
        var params: [String: String] = ["method": "track.updateNowPlaying", "sk": sessionKey]
        params["artist"] = scrobble.artist
        params["track"] = scrobble.track
        if let album = scrobble.album { params["album"] = album }
        if let seconds = scrobble.durationSeconds { params["duration"] = String(seconds) }
        _ = try? await call(params, post: true)
    }

    func submit(_ batch: [Scrobble]) async throws {
        guard isConnected, !batch.isEmpty else { return }
        var params: [String: String] = ["method": "track.scrobble", "sk": sessionKey]
        // Array notation: artist[i]/track[i]/timestamp[i]/… — the timestamp is each track's start.
        for (i, scrobble) in batch.enumerated() {
            params["artist[\(i)]"] = scrobble.artist
            params["track[\(i)]"] = scrobble.track
            params["timestamp[\(i)]"] = String(scrobble.startedAt)
            if let album = scrobble.album { params["album[\(i)]"] = album }
            if let seconds = scrobble.durationSeconds { params["duration[\(i)]"] = String(seconds) }
        }
        _ = try await call(params, post: true)
    }

    // MARK: - Request + signing

    /// The Last.fm `api_sig`: md5 of the params (sorted by name, concatenated as name+value)
    /// with the shared secret appended. Pure for testing.
    static func signature(_ params: [String: String], secret: String) -> String {
        let concat = params.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + secret
        let digest = Insecure.MD5.hash(data: Data(concat.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// Sign, send, and validate a Last.fm call. Throws on transport failure, a non-2xx status,
    /// or a Last.fm application error code so completed-listen submissions can be retried.
    @discardableResult
    private func call(_ extra: [String: String], post: Bool = false) async throws -> [String: Any] {
        var params = extra
        params["api_key"] = apiKey
        params["api_sig"] = Self.signature(params, secret: apiSecret)
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

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            lastfmLog.error("Last.fm HTTP \(http.statusCode)")
            throw ScrobbleError.http(http.statusCode)
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let code = json["error"] as? Int {
            let message = json["message"] as? String ?? "error \(code)"
            lastfmLog.error("Last.fm error \(code, privacy: .public): \(message, privacy: .public)")
            throw ScrobbleError.service("Last.fm \(code): \(message)")
        }
        return json
    }
}
