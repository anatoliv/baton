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
            confirmation). The user's Speech → Delivery settings may override this and route the \
            summary to one or more surfaces (speak now, notification, banner); the returned \
            `delivered` list reflects what actually happened. If the self-hosted TTS server is \
            unreachable, Baton falls back to the built-in macOS voice (unless disabled in \
            Settings). Keep summaries short. \
            When several agents run at once, pass `session` with a short name for THIS agent \
            (e.g. the repo you're working in). Baton speaks it before the summary so the user \
            knows who is talking, and remembers it for the rest of this MCP connection — send \
            it on your first call and later calls inherit it. It is only spoken when the \
            speaker changed since the last summary, so a run of updates from one agent isn't \
            prefixed every time.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The summary to speak. A sentence or two."],
                    "category": ["type": "string", "description": "Task category selecting a voice via the configured map (e.g. 'ops', 'deploy', 'research', 'alert', 'es'). Falls back to 'default'."],
                    "voice": ["type": "string", "description": "Explicit voice, overriding category. Either 'engine:voice' (e.g. 'kokoro:af_bella', 'chatterbox:Emily.wav') or a bare voice id."],
                    "engine": ["type": "string", "description": "'kokoro' (default, fast presets) or 'chatterbox' (premium / cloned voice)."],
                    "mode": ["type": "string", "description": "'notify' (default), 'banner', or 'auto'."],
                    "session": ["type": "string", "description": "Short name for the calling agent/session (e.g. 'global-services'). Spoken before the summary when the speaker changes; sticky for this MCP connection. Max 40 chars."],
                    "prepare": ["type": "string", "description": "Clean the text for the ear before speaking: 'terminal' (strip ANSI and shell prompts, keep the last command's output), 'browser' (drop web boilerplate), or 'generic'. Every option also removes anything shaped like a credential, shortens hashes and URLs, and announces code blocks rather than pronouncing them. Use 'terminal' when the text is command output."],
                ],
                "required": ["text"],
            ],
        ]
    }

    // MARK: - Handler

    static func run(
        _ args: [String: Any],
        _ music: MusicModel,
        sessionID: String? = nil
    ) async throws -> String {
        let text = try requireString(args, "text")
        guard text.count <= SpeechConfig.maxSummaryChars else {
            throw BatonMCPToolError(message: "Summary is too long (\(text.count) chars; max \(SpeechConfig.maxSummaryChars)). Keep it to a sentence or two.")
        }
        // Declare-then-resolve: an explicit `session` updates this connection's
        // label, otherwise we reuse whatever it declared earlier. Note the length
        // check above ran on `text` alone — the spoken prefix is Baton's addition
        // and must not count against the agent's summary budget.
        music.speechLabels.declare(optionalString(args, "session"), forSession: sessionID)
        let sessionLabel = music.speechLabels.label(forSession: sessionID)
        let category = optionalString(args, "category")
        let explicitVoice = optionalString(args, "voice")
        let engineOverride = optionalString(args, "engine")
            .flatMap { SpeechConfig.Engine(rawValue: $0.lowercased()) }
        let requestedMode = (optionalString(args, "mode") ?? "notify").lowercased()
        guard ["auto", "banner", "notify"].contains(requestedMode) else {
            throw BatonMCPToolError(message: "Unknown mode \"\(requestedMode)\" — use 'notify', 'banner', or 'auto'.")
        }
        // The user's Settings → Speech → Delivery decides the concrete surfaces. When they defer
        // to the agent, the requested `mode` is honored (with the SEC-12 auto-play gate on an
        // agent's `auto`, so a leaked token can't blast audio); otherwise their own surfaces
        // compose — speak-now and/or notification and/or banner.
        let plan = SpeechConfig.deliveryPlan(
            announceImmediately: SpeechConfig.announceImmediately,
            allowAgentAutoPlay: SpeechConfig.allowAutoPlay,
            notification: SpeechConfig.alertWithNotification,
            banner: SpeechConfig.alertWithBanner,
            requestedMode: requestedMode
        )

        let voice = SpeechConfig.resolve(
            category: category, explicitVoice: explicitVoice, engineOverride: engineOverride
        )

        // Try the self-hosted server; if it's unreachable and fallback is on, speak the text
        // with the built-in macOS voice so a summary is never silently dropped.
        // What actually gets synthesized: the summary, led by the session name when
        // a different agent spoke last.
        // Optional cleaning, for callers handing over text scraped off a screen rather than an
        // authored summary — the `baton-say` CLI, chiefly. Reuses the read-aloud pipeline rather
        // than growing a second redactor: a shell script cannot be trusted to strip a token, and
        // two implementations of that would drift.
        let prepared: String
        if let profileName = optionalString(args, "prepare") {
            guard let profile = SpeakableText.SourceProfile(rawValue: profileName.lowercased()) else {
                throw BatonMCPToolError(message: "Unknown prepare \"\(profileName)\" — use 'terminal', 'browser', or 'generic'.")
            }
            let chunks = SpeakableText.prepare(text, profile: profile)
            guard !chunks.isEmpty else {
                throw BatonMCPToolError(message: "Nothing speakable was left after cleaning that text.")
            }
            prepared = chunks.joined(separator: " ")
        } else {
            prepared = text
        }
        let spokenText = music.speechLabels.announce(text: prepared, label: sessionLabel)
        let utterance: SpeechPlaybackEngine.Utterance
        var engineUsed = voice.engine.rawValue
        do {
            let audio = try await SpeechService.synthesize(text: spokenText, voice: voice)
            utterance = .file(try writeTemp(audio))
        } catch let error as SpeechService.SynthError {
            guard SpeechConfig.fallbackEnabled else { throw BatonMCPToolError(message: error.message) }
            utterance = .native(spokenText)
            engineUsed = "system (fallback)"
            speechLog.notice("TTS host unreachable — using system voice fallback")
        } catch {
            throw BatonMCPToolError(message: error.localizedDescription)
        }

        // Record every spoken summary so any past one can be replayed later, keeping the resolved
        // voice ("engine:voice", or nil when the system-voice fallback was used) so Replay reproduces
        // the same sound.
        let usedFallback = engineUsed.hasPrefix("system")
        // `prepared`, never the raw `text`. When a caller asks for cleaning, the raw text is
        // screen scrapings that may carry a credential — and this store persists to disk. A
        // redactor that protects the speaker but writes the secret to UserDefaults protects
        // nothing. Found by driving the real app; no unit test covered the history write here.
        music.nowPlayingSummaryID = music.speechHistory.record(
            text: prepared,
            voice: usedFallback ? nil : "\(voice.engine.rawValue):\(voice.voice)",
            engine: usedFallback ? "system" : voice.engine.rawValue,
            category: category,
            sessionLabel: sessionLabel
        )

        // Execute every surface the plan calls for — they compose, so a summary can be spoken
        // now AND leave a notification, or wait as both a banner and a notification.
        var delivered: [String] = []
        var bannerShown = false
        if plan.speakNow {
            music.speech.play(utterance, text: spokenText)
            delivered.append("speaking")
        }
        if plan.banner {
            music.speech.presentBanner(text: spokenText, utterance: utterance)
            bannerShown = true
            delivered.append("banner_shown")
        }
        var fallback: String?
        if plan.notify {
            // If notifications are denied/undelivered, fall back to an in-app banner and say so —
            // never report "notified" for a summary the user will never see.
            switch await SpeechNotifier.post(text: text, utterance: utterance) {
            case .delivered:
                delivered.append("notified")
            case .denied:
                fallback = "notifications-denied"
                if !bannerShown {
                    music.speech.presentBanner(text: text, utterance: utterance)
                    bannerShown = true
                    delivered.append("banner_shown")
                }
            }
        }
        return status(delivered: delivered, engine: engineUsed, voice: voice, text: text, fallback: fallback)
    }

    // MARK: - Helpers

    /// Directory holding staged speech clips.
    static var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("baton-speech", isDirectory: true)
    }

    /// Delete staged clips older than a day. Call at launch so orphaned WAVs (a summary that
    /// was never played/dismissed) don't accumulate. Played clips are deleted immediately by
    /// the playback engine.
    static func sweepStaleTempFiles(olderThan seconds: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: tempDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > seconds {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Write synthesized audio to a temp file so a later confirmation (banner tap / notification
    /// Play action) can play it instantly without re-synthesizing.
    ///
    /// Internal rather than private because read-aloud stages its chunks the same way, and a
    /// second staging directory would need a second launch-time sweep to keep it from filling
    /// up. One directory, one `sweepStaleTempFiles`.
    static func writeTemp(_ data: Data) throws -> URL {
        let dir = tempDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
        do { try data.write(to: url) } catch {
            throw BatonMCPToolError(message: "Couldn't stage speech audio: \(error.localizedDescription)")
        }
        return url
    }

    private static func status(delivered: [String], engine: String, voice: SpeechConfig.Voice, text: String, fallback: String? = nil) -> String {
        var payload: [String: Any] = [
            // `status` is the primary surface (first action taken); `delivered` is the full set,
            // since a summary can reach the user through more than one surface at once.
            "status": delivered.first ?? "queued",
            "delivered": delivered,
            "engine": engine,
            "voice": voice.voice,
            "chars": text.count,
        ]
        if let fallback { payload["fallback"] = fallback }
        return BatonMCPToolCatalog.jsonText(payload)
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
