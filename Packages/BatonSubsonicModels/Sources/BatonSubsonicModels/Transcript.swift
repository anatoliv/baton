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
