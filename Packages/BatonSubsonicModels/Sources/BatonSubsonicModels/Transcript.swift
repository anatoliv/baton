import Foundation

/// What was actually said in a track, with timings — the spoken-word counterpart to lyrics.
///
/// Lives here, in the leaf model package, for a boring but load-bearing reason: three modules
/// need this type and none of them may depend on the others. `BatonSpeech` produces it (it
/// calls the recognizer), `BatonPlaybackKit` stores it, `BatonAgentKit` summarizes it. Putting
/// it in `BatonSpeech` would force `BatonPlaybackKit` to depend on a package that isn't built
/// for watchOS, which breaks the parked Watch target the gate keeps honest.
///
/// See `specs/track-transcription.md`.
public struct Transcript: Codable, Equatable, Sendable {
    /// One recognized span of speech. `start`/`end` are seconds into the track, which is what
    /// makes a transcript seekable and what lets the summarizer chunk on real boundaries.
    public struct Segment: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// The playback id this transcribes — enclosure URL for a client-side episode, `streamID`
    /// for a server-side one, Subsonic id for a library track. The same key space
    /// `PodcastProgressStore` uses, so progress and transcript agree on what a track is.
    public var trackID: String
    public var segments: [Segment]
    /// Whether the segments carry real timings. False when the recognizer returned only text,
    /// in which case the transcript still reads but cannot highlight or seek.
    public var synced: Bool
    /// Language the recognizer detected, or was told to use.
    public var language: String?
    /// Which recognizer produced this. Kept so a transcript made by a weaker model is
    /// identifiable later, rather than silently trusted forever.
    public var model: String?
    /// Seconds of audio transcribed, as the recognizer measured it.
    public var duration: Double?
    public var createdAt: Date
    /// Filled in lazily — transcribing and summarizing are separate user actions, and a
    /// transcript is useful on its own.
    public var summary: Summary?

    public init(
        trackID: String,
        segments: [Segment],
        synced: Bool = true,
        language: String? = nil,
        model: String? = nil,
        duration: Double? = nil,
        createdAt: Date = Date(),
        summary: Summary? = nil
    ) {
        self.trackID = trackID
        self.segments = segments
        self.synced = synced
        self.language = language
        self.model = model
        self.duration = duration
        self.createdAt = createdAt
        self.summary = summary
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// The whole transcript as running text — what the summarizer and any search reads.
    public var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Render as timed text so the existing lyrics views can draw it unchanged.
    ///
    /// A transcript and a synced lyric are the same shape, and those views already do the
    /// karaoke highlight and the auto-scroll. Sharing the *renderer* is the point; the two
    /// stay separate everywhere else, because a podcast that failed to transcribe must not
    /// look like a song that simply has no words.
    public var asLyrics: NavidromeLyrics {
        NavidromeLyrics(
            synced: synced,
            lines: segments.map { NavidromeLyrics.Line(start: synced ? $0.start : nil, text: $0.text) }
        )
    }

    /// Segments overlapping `[from, to]` seconds. Half-open at neither end on purpose: a
    /// segment straddling the boundary is part of both windows, since cutting a sentence in
    /// half to satisfy an interval helps nobody reading the result.
    ///
    /// This is what keeps an hour of text out of an agent's context — MCP callers ask for a
    /// window rather than the whole thing.
    public func segments(from: Double, to: Double) -> [Segment] {
        guard to >= from else { return [] }
        return segments.filter { $0.end >= from && $0.start <= to }
    }

    /// Index of the segment being spoken at `time`, for the karaoke highlight.
    ///
    /// Uses the last segment that has *started*, rather than the one whose span contains
    /// `time`, so the highlight holds through the silence between segments instead of
    /// blinking off in every gap.
    public func segmentIndex(at time: Double) -> Int? {
        guard synced, !segments.isEmpty else { return nil }
        var found: Int?
        for (index, segment) in segments.enumerated() {
            if segment.start <= time { found = index } else { break }
        }
        return found
    }
}

// MARK: - Credibility (pure)

/// Whether what came back from the recognizer can honestly be shown as a transcript.
///
/// These live on the model rather than in `BatonSpeech` because two modules need them and
/// neither may depend on the other: `BatonSpeech` applies them when it *parses* a response,
/// and `BatonPlaybackKit` applies them when it *loads* one off disk — so an artifact written
/// by an older, worse pipeline stops being served instead of outliving the fix that would
/// have prevented it.
extension Transcript {
    /// Case- and punctuation-insensitive form of a line, so "Yeah." and "yeah" compare equal.
    public static func normalized(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?\u{2026}\u{2014}- "))
    }

    /// Six, not four, and the difference is not a guess. Measured on "Riders on the Storm":
    /// the track sings "Take him by the hand" four times in a row and means it, while the two
    /// decoding loops in the same response ran to 12 and 128 segments. A threshold of four
    /// would have thrown away a real line to catch nothing extra.
    static let loopRunLength = 6

    /// A long repeated line is more likely a real refrain than a decoding loop.
    static let repeatedLineLimit = 40

    /// Lines a recognizer emits over music or silence because its training data was full of
    /// subtitle files. Measured: the instrumental intro of "Riders on the Storm" came back as
    /// "Transcribed by ESO, translated by —", which the track never said.
    static let recognizerBoilerplate = [
        "transcribed by", "subtitles by", "subtitled by", "amara.org",
        "thanks for watching", "subscribe to",
    ]

    static func isBoilerplate(_ text: String) -> Bool {
        let line = normalized(text)
        return recognizerBoilerplate.contains { line.contains($0) }
    }

    /// Drop what the recognizer invented rather than heard, keeping everything else.
    ///
    /// This is the half that lets a *song* transcribe at all. Voice-activity detection was
    /// the previous answer to hallucination, and over music it is far too blunt: on "Riders
    /// on the Storm" it left 1.7 seconds of a 434-second track and mangled the one line it
    /// kept ("Do this as we're born" for "Into this house we're born"). With it off the same
    /// track returns the lyric correctly, plus two runs of the word "Yeah" — 12 segments over
    /// the instrumental break and 128 over the outro — which is what this removes. What
    /// survives is 27 segments of real words covering a quarter of the track.
    ///
    /// Removing the invention beats never generating it, because the two are not equivalent:
    /// VAD also removes the singing.
    public static func strippingHallucinations(_ segments: [Segment]) -> [Segment] {
        var kept: [Segment] = []
        var index = 0
        while index < segments.count {
            let line = normalized(segments[index].text)
            var runEnd = index
            while runEnd + 1 < segments.count, normalized(segments[runEnd + 1].text) == line {
                runEnd += 1
            }
            let isLoop = (runEnd - index + 1) >= loopRunLength && line.count <= repeatedLineLimit
            if !isLoop {
                kept.append(contentsOf: segments[index ... runEnd].filter { !isBoilerplate($0.text) })
            }
            index = runEnd + 1
        }
        return kept
    }

    /// Whether what came back is too little of the track to be a transcript of it.
    ///
    /// A tenth of the running time is far below anything spoken-word: talk covers most of its
    /// duration, and even an interview full of pauses stays well above this. Only applied to
    /// tracks over a minute, so a short clip is never judged on a ratio.
    public static func isTooSparse(_ segments: [Segment], duration: Double?) -> Bool {
        guard let duration, duration > 60 else { return false }
        let covered = segments.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        return covered / duration < 0.10
    }

    /// Whether a transcript is the recognizer looping rather than reporting speech.
    ///
    /// Backstop to `strippingHallucinations`, which only catches *consecutive* repeats. A
    /// response that alternates between two invented lines is still not a transcript.
    /// Deliberately conservative: real speech repeats too ("Yeah." "Yeah." "Right."), so this
    /// only fires when nearly every segment is identical AND the repeated line is short.
    public static func isDegenerate(_ segments: [Segment]) -> Bool {
        guard segments.count >= 10 else { return false }
        let lines = segments.map { normalized($0.text) }
        var counts: [String: Int] = [:]
        for line in lines { counts[line, default: 0] += 1 }
        guard let (commonest, count) = counts.max(by: { $0.value < $1.value }) else { return false }
        let share = Double(count) / Double(lines.count)
        return share >= 0.8 && commonest.count <= repeatedLineLimit
    }

    /// True when today's rules would refuse to produce this transcript at all.
    ///
    /// Read at *load* time, not just at parse time. A transcript already on disk was written
    /// by whatever pipeline existed that day, and the one that prompted this — a single
    /// 1.7-second fragment of a seven-minute song — went on being served to the pane and to
    /// agents over MCP long after the code that made it was replaced.
    public var looksLikeNothingWasSaid: Bool {
        segments.isEmpty
            || Transcript.isTooSparse(segments, duration: duration)
            || Transcript.isDegenerate(segments)
    }
}

/// A summary of a transcript: one overview plus timestamped sections.
///
/// The sections are not scaffolding left over from chunking — they are the chapter marks,
/// and they are the more useful half. An overview tells you whether to listen; a section
/// list tells you *where*, and each one seeks.
public struct Summary: Codable, Equatable, Sendable {
    public struct Section: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var title: String
        public var text: String

        public init(start: Double, end: Double, title: String, text: String) {
            self.start = start
            self.end = end
            self.title = title
            self.text = text
        }
    }

    public var overview: String
    public var sections: [Section]
    /// Which model wrote this, for the same reason `Transcript.model` is kept.
    public var model: String?
    public var createdAt: Date

    public init(overview: String, sections: [Section], model: String? = nil, createdAt: Date = Date()) {
        self.overview = overview
        self.sections = sections
        self.model = model
        self.createdAt = createdAt
    }

    public var isEmpty: Bool { overview.isEmpty && sections.isEmpty }
}
