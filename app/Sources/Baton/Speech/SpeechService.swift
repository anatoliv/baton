import Foundation
import OSLog

let speechLog = Logger(subsystem: "io.tonebox.macos", category: "Speech")

/// Synthesizes speech by calling an OpenAI-compatible `/v1/audio/speech` endpoint — Kokoro
/// for fast preset voices, Chatterbox for cloned/premium voices — and returns WAV `Data`.
///
/// This is the first JSON-body POST in the codebase (the Navidrome client is GET-only); it
/// mirrors that client's transport idiom: build a `URLRequest`, `URLSession.data(for:)`,
/// validate the `HTTPURLResponse`, and surface typed errors.
enum SpeechService {
    struct SynthError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func synthesize(text: String, voice: SpeechConfig.Voice) async throws -> Data {
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
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SynthError(message: "Couldn't reach the \(voice.engine.rawValue) TTS service at \(base): \(error.localizedDescription)")
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

    /// Fetch the available voice ids from an engine's `GET /v1/audio/voices`. Handles both
    /// response shapes seen in the wild: Kokoro returns `{"voices":[{"id":…}]}`, Chatterbox
    /// returns `{"voices":["Emily.wav", …]}`. Returns the ids/names, sorted.
    static func listVoices(engine: SpeechConfig.Engine) async throws -> [String] {
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
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SynthError(message: "Couldn't reach \(engine.rawValue) at \(base): \(error.localizedDescription)")
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
