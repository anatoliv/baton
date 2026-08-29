import Foundation
import OSLog

public let speechLog = Logger(subsystem: "io.tonebox.baton", category: "Speech")

/// Synthesizes speech by calling an OpenAI-compatible `/v1/audio/speech` endpoint — Kokoro
/// for fast preset voices, Chatterbox for cloned/premium voices — and returns WAV `Data`.
///
/// This is the first JSON-body POST in the codebase (the Navidrome client is GET-only); it
/// mirrors that client's transport idiom: build a `URLRequest`, `URLSession.data(for:)`,
/// validate the `HTTPURLResponse`, and surface typed errors.
public enum SpeechService {
    public struct SynthError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }

        public init(message: String) { self.message = message }
    }

    /// Turn a transport failure into a message that says what to *do* about it.
    ///
    /// **The case worth naming is `-1009` to a private address**. macOS returns
    /// `NSURLErrorNotConnectedToInternet` when an app has been refused the **Local Network**
    /// privacy grant, which reads as "there is no network" while every other request the app
    /// makes keeps working, because those go to the internet. On 2026-08-29 that produced a
    /// Mac where `curl` reached the same host from a shell in 15 ms and 235 of
    /// Baton's own requests succeeded, while every LAN request failed and each summary quietly
    /// fell back to the built-in voice. It was chased as a network fault, a sleeping host, and
    /// a VPN before the grant was suspected.
    ///
    /// The generic wording is what made that expensive: "couldn't reach the host" is equally
    /// true of a host that is asleep, and the two want completely different responses. A
    /// symptom the app can recognise should be named by the app.
    public static func transportMessage(_ error: Error, engine: String, base: String) -> String {
        let generic = "Couldn't reach the \(engine) TTS service at \(base): \(error.localizedDescription)"
        guard (error as? URLError)?.code == .notConnectedToInternet,
              let host = URLComponents(string: base)?.host, isPrivateAddress(host)
        else { return generic }

        return "macOS is blocking Baton from reaching \(host), which is on your local network. "
            + "This is the Local Network privacy setting, not a problem with the server: other "
            + "requests keep working because they go out to the internet. Open System Settings → "
            + "Privacy & Security → Local Network and switch Baton on. If it is already on, "
            + "switch it off and on again, which is often needed after the app updates."
    }

    /// Whether a host is a literal address in one of the private IPv4 ranges, or a `.local`
    /// name. Deliberately literal-only: a hostname that *resolves* to a private address would
    /// need a lookup, and this runs on an error path where a second network call is the last
    /// thing wanted. A missed case falls back to the generic message, which is merely less
    /// helpful rather than wrong.
    public static func isPrivateAddress(_ host: String) -> Bool {
        if host.hasSuffix(".local") || host == "localhost" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0 ... 255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16 ... 31): return true
        case (127, _): return true
        default: return false
        }
    }

    public static func synthesize(text: String, voice: SpeechConfig.Voice, session: URLSession = .shared) async throws -> Data {
        let base = SpeechConfig.baseURL(for: voice.engine).trimmingCharacters(in: .whitespaces)
        guard var comps = URLComponents(string: base), comps.host != nil else {
            throw SynthError(message: "Invalid \(voice.engine.rawValue) TTS host \"\(base)\". Set it in Settings → Speech.")
        }
        // A URL with a host requires an absolute path (leading "/"); preserve any base path
        // prefix and append the endpoint.
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path + "/v1/audio/speech"
        guard let url = comps.url else {
            throw SynthError(message: "Couldn't build a TTS URL from \"\(base)\".")
        }

        // Both servers speak the OpenAI TTS schema and require `model` + `voice`.
        let body: [String: Any] = [
            "model": voice.engine == .chatterbox ? "chatterbox" : "kokoro",
            "voice": voice.voice,
            "input": text,
            "response_format": "wav",
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Baton (macOS; speak_summary)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sendWithRetry(request, session: session)
        } catch {
            throw SynthError(message: transportMessage(error, engine: voice.engine.rawValue, base: base))
        }
        guard let http = response as? HTTPURLResponse else {
            throw SynthError(message: "Unexpected response from the TTS service.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw SynthError(message: "TTS service returned HTTP \(http.statusCode). \(detail)")
        }
        guard !data.isEmpty else { throw SynthError(message: "TTS returned no audio.") }
        speechLog.info("synthesized \(data.count) bytes via \(voice.engine.rawValue, privacy: .public)/\(voice.voice, privacy: .public)")
        return data
    }

    /// One quick retry on any transport failure — the self-hosted TTS host may be waking up
    /// (a cold GPU box), or the connection may simply have gone stale.
    ///
    /// **Any `URLError`, not a list of three.** It used to retry only `.cannotConnectToHost`,
    /// `.networkConnectionLost` and `.timedOut`, and a case outside that list is exactly what
    /// broke long readings: the Kokoro host closes idle keep-alive connections, a reading leaves
    /// the connection idle for as long as playback takes, and the next request dies instantly on
    /// a dead socket. Measured on 2026-08-28 — two requests back to back succeed, one after 47
    /// seconds of idle fails in 0.00s, and an immediate retry succeeds in 0.24s.
    ///
    /// Retrying a POST is normally unsafe, because the server may have acted on the first one.
    /// It is safe *here* specifically: synthesis has no side effects, so the worst a duplicate
    /// costs is a second of GPU time. That reasoning does not transfer to other POSTs in this
    /// app, which is why the retry lives in this function rather than in a shared helper.
    private static func sendWithRetry(_ request: URLRequest, session: URLSession = .shared) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            speechLog.notice("TTS request failed (\(error.code.rawValue, privacy: .public)) — retrying once")
            try? await Task.sleep(nanoseconds: 500_000_000)
            return try await session.data(for: request)
        }
    }

    /// Fetch the available voice ids from an engine's `GET /v1/audio/voices`. Handles both
    /// response shapes seen in the wild: Kokoro returns `{"voices":[{"id":…}]}`, Chatterbox
    /// returns `{"voices":["Emily.wav", …]}`. Returns the ids/names, sorted.
    public static func listVoices(engine: SpeechConfig.Engine, session: URLSession = .shared) async throws -> [String] {
        let base = SpeechConfig.baseURL(for: engine).trimmingCharacters(in: .whitespaces)
        guard var comps = URLComponents(string: base), comps.host != nil else {
            throw SynthError(message: "Invalid \(engine.rawValue) TTS host \"\(base)\".")
        }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path + "/v1/audio/voices"
        guard let url = comps.url else { throw SynthError(message: "Couldn't build a voices URL from \"\(base)\".") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SynthError(message: transportMessage(error, engine: engine.rawValue, base: base))
        }
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw SynthError(message: "Voices request failed for \(engine.rawValue).")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["voices"] as? [Any] else {
            throw SynthError(message: "Unexpected voices response from \(engine.rawValue).")
        }
        let ids: [String] = raw.compactMap { element in
            if let s = element as? String { return s }
            if let d = element as? [String: Any] { return (d["id"] as? String) ?? (d["name"] as? String) }
            return nil
        }
        return ids.sorted()
    }
}
