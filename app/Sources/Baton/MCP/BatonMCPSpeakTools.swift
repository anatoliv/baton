import Foundation

/// Agent-native spoken task summaries — the `speak_summary` MCP tool. An agent finishes a
/// task and calls this with a short summary; Baton synthesizes it (Kokoro preset voices by
/// default, Chatterbox for a cloned/premium voice) and delivers it per `mode`: a macOS
/// notification with a Play button, an in-app banner with Play, or immediate playback — so a
/// spoken alert plays on your confirmation, in a voice chosen per task category.
///
/// Networking lives in `SpeechService`, playback + banner state in `SpeechPlaybackEngine`
/// (hung off `MusicModel` as `music.speech`), notifications in `SpeechNotifier`.
@MainActor
enum BatonMCPSpeakTools {
    // MARK: - Tool definition

    static func definition() -> [String: Any] {
        [
            "name": "speak_summary",
            "description": """
            Speak a short task-completion summary aloud through Baton. Put the summary in \
            `text`. Pick a voice by task `category` (mapped to a configured voice — e.g. \
            'ops', 'deploy', 'research', 'alert', or 'es' for Spanish; unknown categories \
            fall back to 'default'), or pass an explicit `voice`. `engine` selects Kokoro \
            (fast preset voices, default) or Chatterbox (premium / cloned voice). `mode` \
            controls delivery: 'notify' (default — a macOS notification with a Play button), \
            'banner' (an in-app banner with Play), or 'auto' (speak immediately, no \
            confirmation). If the self-hosted TTS server is unreachable, Baton falls back to \
            the built-in macOS voice (unless disabled in Settings). Keep summaries short.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The summary to speak. A sentence or two."],
                    "category": ["type": "string", "description": "Task category selecting a voice via the configured map (e.g. 'ops', 'deploy', 'research', 'alert', 'es'). Falls back to 'default'."],
                    "voice": ["type": "string", "description": "Explicit voice, overriding category. Either 'engine:voice' (e.g. 'kokoro:af_bella', 'chatterbox:Emily.wav') or a bare voice id."],
                    "engine": ["type": "string", "description": "'kokoro' (default, fast presets) or 'chatterbox' (premium / cloned voice)."],
                    "mode": ["type": "string", "description": "'notify' (default), 'banner', or 'auto'."],
                ],
                "required": ["text"],
            ],
        ]
    }

    // MARK: - Handler

    static func run(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let text = try requireString(args, "text")
        let category = optionalString(args, "category")
        let explicitVoice = optionalString(args, "voice")
        let engineOverride = optionalString(args, "engine")
            .flatMap { SpeechConfig.Engine(rawValue: $0.lowercased()) }
        let mode = (optionalString(args, "mode") ?? "notify").lowercased()

        guard ["auto", "banner", "notify"].contains(mode) else {
            throw BatonMCPToolError(message: "Unknown mode \"\(mode)\" — use 'notify', 'banner', or 'auto'.")
        }

        let voice = SpeechConfig.resolve(
            category: category, explicitVoice: explicitVoice, engineOverride: engineOverride
        )

        // Try the self-hosted server; if it's unreachable and fallback is on, speak the text
        // with the built-in macOS voice so a summary is never silently dropped.
        let utterance: SpeechPlaybackEngine.Utterance
        var engineUsed = voice.engine.rawValue
        do {
            let audio = try await SpeechService.synthesize(text: text, voice: voice)
            utterance = .file(try writeTemp(audio))
        } catch let error as SpeechService.SynthError {
            guard SpeechConfig.fallbackEnabled else { throw BatonMCPToolError(message: error.message) }
            utterance = .native(text)
            engineUsed = "system (fallback)"
            speechLog.notice("TTS host unreachable — using system voice fallback")
        } catch {
            throw BatonMCPToolError(message: error.localizedDescription)
        }

        switch mode {
        case "auto":
            music.speech.play(utterance)
            return status("speaking", mode: mode, engine: engineUsed, voice: voice, text: text)
        case "banner":
            music.speech.presentBanner(text: text, utterance: utterance)
            return status("banner_shown", mode: mode, engine: engineUsed, voice: voice, text: text)
        default: // "notify"
            await SpeechNotifier.post(text: text, utterance: utterance)
            return status("notified", mode: mode, engine: engineUsed, voice: voice, text: text)
        }
    }

    // MARK: - Helpers

    /// Write synthesized audio to a temp file so a later confirmation (banner tap / notification
    /// Play action) can play it instantly without re-synthesizing.
    private static func writeTemp(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-speech", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
        do { try data.write(to: url) } catch {
            throw BatonMCPToolError(message: "Couldn't stage speech audio: \(error.localizedDescription)")
        }
        return url
    }

    private static func status(_ status: String, mode: String, engine: String, voice: SpeechConfig.Voice, text: String) -> String {
        BatonMCPToolCatalog.jsonText([
            "status": status,
            "mode": mode,
            "engine": engine,
            "voice": voice.voice,
            "chars": text.count,
        ])
    }

    private static func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw BatonMCPToolError(message: "Missing required argument '\(key)'.")
        }
        return value
    }

    private static func optionalString(_ args: [String: Any], _ key: String) -> String? {
        guard let value = args[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}
