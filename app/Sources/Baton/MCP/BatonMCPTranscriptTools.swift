import Foundation

/// Transcripts and summaries over MCP — `music_transcript` and `music_summarize_track`.
///
/// These are what let an agent answer "what did they say about X" about something you were
/// listening to, rather than only about its metadata.
///
/// **Both are windowed.** An hour of speech is roughly ten thousand words, and a tool that
/// returned all of it would spend most of a context on one episode. `music_transcript`
/// therefore takes `from`/`to` seconds and caps what it returns; the summary, which is short
/// by construction, is the thing to read first.
///
/// See `specs/track-transcription.md`.
@MainActor
enum BatonMCPTranscriptTools {
    /// Segment ceiling for one call. Enough to read a few minutes closely; far short of
    /// letting an episode crowd out everything else an agent knows.
    static let maxSegments = 120

    // MARK: - Definitions

    static func definitions() -> [[String: Any]] {
        [
            [
                "name": "music_transcript",
                "description": """
                Read what was actually said in a spoken track — a podcast episode, talk, or \
                interview — with a timestamp on every line. Defaults to what's playing now; \
                pass `song_id` for a specific track. The transcript is produced once by a \
                self-hosted recognizer and then cached, so repeat calls are free.

                An hour of speech is far too much to read in one go, so this returns a \
                WINDOW: pass `from_seconds` and `to_seconds` to read a stretch (at most \
                \(maxSegments) lines come back). To find the right stretch first, call \
                `music_summarize_track` — its sections are timestamped, so they tell you \
                where to look.

                If the track has never been transcribed, this reports that rather than \
                starting one: transcribing is a GPU pass over the whole file and belongs to \
                the person, not the agent. It also reports when the transcription host is \
                simply unreachable, which is not the same as the track having no speech.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "song_id": ["type": "string", "description": "Track id. Omit for the current track."],
                        "from_seconds": ["type": "number", "description": "Start of the window, in seconds. Default 0."],
                        "to_seconds": ["type": "number", "description": "End of the window, in seconds. Omit for the end of the track."],
                    ],
                    "required": [] as [String],
                ],
            ],
            [
                "name": "music_summarize_track",
                "description": """
                Summarize a spoken track that has already been transcribed: one overview plus \
                timestamped sections that act as chapter marks. Read this BEFORE \
                `music_transcript` — the sections say where in the episode a topic lives, so \
                you can then read only that window instead of the whole hour.

                Defaults to what's playing; pass `song_id` for a specific track. A summary is \
                written once and cached with the transcript. Pass `create: true` to write one \
                if it doesn't exist yet — that sends the transcript to whichever model the \
                natural-language settings point at, so it is refused unless that model is on \
                the user's own network.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "song_id": ["type": "string", "description": "Track id. Omit for the current track."],
                        "create": [
                            "type": "boolean",
                            "description": "Write the summary if there isn't one yet. Default false — it costs several model calls.",
                        ],
                    ],
                    "required": [] as [String],
                ],
            ],
        ]
    }

    // MARK: - music_transcript

    static func transcript(_ args: [String: Any], _ music: MusicModel) throws -> String {
        let song = try resolveSong(args, music)
        let coordinator = TranscriptionCoordinator.shared

        guard let transcript = coordinator.transcript(for: song.id) else {
            // Distinguish "not transcribed" from "the host is down" — an agent that conflates
            // them will tell the user their episode has no speech in it.
            if let failure = coordinator.failure(for: song.id) {
                return jsonText([
                    "song_id": song.id,
                    "title": song.title,
                    "transcribed": false,
                    "reason": failure.isUnavailable ? "unavailable" : "failed",
                    "detail": failure.message,
                ])
            }
            return jsonText([
                "song_id": song.id,
                "title": song.title,
                "transcribed": false,
                "reason": "not_transcribed",
                "detail": "No transcript yet. The person can make one from the Transcript panel in the player.",
            ])
        }

        let from = optionalDouble(args, "from_seconds") ?? 0
        let to = optionalDouble(args, "to_seconds") ?? (transcript.segments.last?.end ?? 0)
        let window = transcript.segments(from: from, to: to)
        let clipped = Array(window.prefix(maxSegments))

        var out: [String: Any] = [
            "song_id": song.id,
            "title": song.title,
            "transcribed": true,
            "synced": transcript.synced,
            "segment_count": transcript.segments.count,
            "window_from_seconds": from,
            "window_to_seconds": to,
            "returned_segments": clipped.count,
            "lines": clipped.map { segment in
                [
                    "start_seconds": segment.start,
                    "timestamp": TranscriptSummarizer.timestamp(segment.start),
                    "text": segment.text,
                ] as [String: Any]
            },
        ]
        if let language = transcript.language { out["language"] = language }
        if let model = transcript.model { out["model"] = model }
        if clipped.count < window.count {
            // Say so rather than truncating silently: a window that quietly stops is how an
            // agent concludes a topic was never mentioned again.
            out["truncated"] = true
            out["truncated_note"] = "Window held \(window.count) lines; \(maxSegments) returned. "
                + "Narrow from_seconds/to_seconds to read the rest."
        }
        if let summary = transcript.summary, !summary.isEmpty {
            out["has_summary"] = true
            out["overview"] = summary.overview
        }
        return jsonText(out)
    }

    // MARK: - music_summarize_track

    static func summarize(
        _ args: [String: Any],
        _ music: MusicModel,
        naturalLanguage: RemoteControlSettings.NaturalLanguageConfig?
    ) async throws -> String {
        let song = try resolveSong(args, music)
        let coordinator = TranscriptionCoordinator.shared

        guard let transcript = coordinator.transcript(for: song.id) else {
            return jsonText([
                "song_id": song.id,
                "title": song.title,
                "summarized": false,
                "reason": "not_transcribed",
                "detail": "This track has no transcript yet, so there's nothing to summarize.",
            ])
        }

        var summary = transcript.summary
        if summary == nil || summary?.isEmpty == true {
            guard (args["create"] as? Bool) == true else {
                return jsonText([
                    "song_id": song.id,
                    "title": song.title,
                    "summarized": false,
                    "reason": "no_summary",
                    "detail": "There's no summary yet. Call again with create: true to write one.",
                ])
            }
            guard let naturalLanguage else {
                return jsonText([
                    "song_id": song.id,
                    "summarized": false,
                    "reason": "no_model",
                    "detail": "No summarizing model is configured in Settings → Remote.",
                ])
            }
            summary = await coordinator.summarize(trackID: song.id, config: naturalLanguage)
            guard let written = summary else {
                let failure = coordinator.failure(for: song.id)
                return jsonText([
                    "song_id": song.id,
                    "summarized": false,
                    "reason": failure?.isUnavailable == true ? "unavailable" : "failed",
                    "detail": failure?.message ?? "Summarizing failed.",
                ])
            }
            summary = written
        }

        guard let summary else {
            return jsonText(["song_id": song.id, "summarized": false, "reason": "no_summary"])
        }
        return jsonText([
            "song_id": song.id,
            "title": song.title,
            "summarized": true,
            "overview": summary.overview,
            "sections": summary.sections.map { section in
                [
                    "start_seconds": section.start,
                    "timestamp": TranscriptSummarizer.timestamp(section.start),
                    "title": section.title,
                    "summary": section.text,
                ] as [String: Any]
            },
        ])
    }

    // MARK: - Helpers

    private static func resolveSong(_ args: [String: Any], _ music: MusicModel) throws -> NavidromeSong {
        if let id = args["song_id"] as? String, !id.isEmpty {
            if let queued = music.music.queue.first(where: { $0.id == id }) { return queued }
            // Not in the queue — a transcript is keyed by id alone, so a stub carries enough
            // to look one up without a server round trip for something already on disk.
            return NavidromeSong(id: id, title: id, artist: nil, album: nil, duration: nil)
        }
        guard let current = music.music.nowPlaying else {
            throw BatonMCPToolError(message: "Nothing is playing, so there's no track to read. Pass 'song_id'.")
        }
        return current
    }

    private static func optionalDouble(_ args: [String: Any], _ key: String) -> Double? {
        if let d = args[key] as? Double { return d }
        if let n = args[key] as? NSNumber { return n.doubleValue }
        if let s = args[key] as? String { return Double(s) }
        return nil
    }

    private static func jsonText(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
