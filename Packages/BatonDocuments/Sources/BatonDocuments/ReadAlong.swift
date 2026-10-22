import Foundation

/// Where each chunk of a chapter sits in its audio (`specs/document-clippings.md`, *Expansions* 6,
/// read-along).
///
/// The renderer joins a chapter from one clip per `SpeechSegment`, so it knows exactly where each
/// one starts and ends; it writes that down beside the chapter as `chapter-N.timing.json`. A chunk
/// is a sentence, or a few short ones, which is fine-grained enough to follow by eye. The text is
/// the segment's own (before the pronunciation lexicon), which is what a reader expects to see.
///
/// Small on purpose: a 40-minute chapter is a few hundred entries. Books rendered before this
/// existed have no timing, and a read-along view shows their text without a highlight.
public struct ReadAlongTiming: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct Segment: Codable, Sendable, Equatable {
        public var text: String
        /// The paragraph within the chapter, as `SpeechSegment.paragraph` (the heading is -1).
        public var paragraph: Int
        /// Seconds into the chapter's audio where this chunk's speech begins (after its pause).
        public var start: Double
        /// Seconds into the chapter's audio where it ends.
        public var end: Double

        public init(text: String, paragraph: Int, start: Double, end: Double) {
            self.text = text
            self.paragraph = paragraph
            self.start = start
            self.end = end
        }
    }

    public var version: Int
    public var segments: [Segment]

    public init(segments: [Segment]) {
        self.version = Self.currentVersion
        self.segments = segments
    }

    /// `chapter-3.m4a` → `chapter-3.timing.json`; nil for a name that is not a chapter file.
    public static func fileName(forChapterFile file: String) -> String? {
        guard file.range(of: #"^chapter-\d{1,4}\.m4a$"#, options: .regularExpression) != nil else { return nil }
        return String(file.dropLast(".m4a".count)) + ".timing.json"
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode, or nil for anything unreadable or newer than this build knows. Timing is a nicety:
    /// a file it cannot read means "no highlight", never an error in front of the listener.
    public static func decode(_ data: Data) -> ReadAlongTiming? {
        guard let timing = try? JSONDecoder().decode(ReadAlongTiming.self, from: data),
              timing.version <= currentVersion else { return nil }
        return timing
    }
}

/// A chapter as a read-along view shows it: sentences in paragraphs, with times when the chapter
/// has them. Answers the two questions the view asks: which sentence is being heard at `t`, and
/// where to seek for a sentence that was tapped. The same on the Mac and the iPhone.
public struct ReadAlong: Sendable, Equatable {
    public struct Sentence: Sendable, Equatable, Identifiable {
        public var id: Int
        public var text: String
        public var paragraph: Int
        public var start: Double?
        public var end: Double?
    }

    public let sentences: [Sentence]

    /// Whether the sentences carry times: false for a chapter made before timing was kept.
    public var isTimed: Bool { !sentences.isEmpty && sentences.allSatisfy { $0.start != nil } }

    /// From the timing the renderer wrote.
    public init(timing: ReadAlongTiming) {
        sentences = timing.segments.enumerated().map { index, segment in
            Sentence(id: index, text: segment.text, paragraph: segment.paragraph,
                     start: segment.start, end: max(segment.start, segment.end))
        }
    }

    /// From the chapter's words alone, with no times: a chapter made before timing was kept.
    /// The text of such a chapter has lost its paragraphs, so sentences are grouped a few to a
    /// paragraph to stay readable.
    public init(untimedText text: String, sentencesPerParagraph: Int = 4) {
        let per = max(1, sentencesPerParagraph)
        sentences = SentenceSplitter.sentences(text).enumerated().map { index, sentence in
            Sentence(id: index, text: sentence, paragraph: index / per, start: nil, end: nil)
        }
    }

    /// The timing when there is one that fits the chapter, else the text without times.
    public init(timing: ReadAlongTiming?, fallbackText: String?) {
        if let timing, !timing.segments.isEmpty {
            self.init(timing: timing)
        } else {
            self.init(untimedText: fallbackText ?? "")
        }
    }

    /// The sentence being heard at `time` seconds: the last one to have started. In the pause
    /// before a sentence, the one before stays lit, which is what a reader's eye expects. Before
    /// the first starts, the first; past the end, the last. Nil without timing.
    public func sentenceIndex(at time: Double) -> Int? {
        guard isTimed, let first = sentences.first?.start else { return nil }
        // A sentence counts as started a few milliseconds early: a tap seeks to its start, and
        // the player keeps time in 1/600 s, so it lands up to 1 ms before it and lit the
        // sentence before until the audio started again, a third of a second or more
        // Five milliseconds is far below anything a listener hears.
        let time = time + Self.startTolerance
        if time < first { return 0 }
        // Binary search for the last sentence whose start <= time.
        var low = 0
        var high = sentences.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if (sentences[mid].start ?? 0) <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// How early a sentence counts as started, for the player's 1/600 s clock (`sentenceIndex`).
    public static let startTolerance = 0.005

    /// Where to seek for sentence `index`: where its speech starts. Nil without timing or for an
    /// index out of range.
    public func seekTarget(for index: Int) -> Double? {
        guard isTimed, sentences.indices.contains(index) else { return nil }
        return sentences[index].start
    }

    /// The sentences in paragraphs, in order: a new paragraph wherever the paragraph number
    /// changes. Each group is (paragraph number, its sentences).
    public var paragraphs: [(paragraph: Int, sentences: [Sentence])] {
        var groups: [(paragraph: Int, sentences: [Sentence])] = []
        for sentence in sentences {
            if let last = groups.last, last.paragraph == sentence.paragraph {
                groups[groups.count - 1].sentences.append(sentence)
            } else {
                groups.append((sentence.paragraph, [sentence]))
            }
        }
        return groups
    }

    public static func == (lhs: ReadAlong, rhs: ReadAlong) -> Bool { lhs.sentences == rhs.sentences }
}

/// The timing of chapters this device holds, keyed by the chapter audio's SHA-256: the timing
/// belongs to exactly that audio, whichever renderer made it, and a chapter in Clippings carries
/// its digest. One small JSON file each, in a folder of the books directory.
public struct ReadAlongStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store beside the books (`Books/read-along`), the same place on the Mac and the iPhone.
    public static func inBooks(_ booksDirectory: URL) -> ReadAlongStore {
        ReadAlongStore(directory: booksDirectory.appendingPathComponent("read-along", isDirectory: true))
    }

    public func url(forAudio sha256: String) -> URL? {
        let digest = sha256.lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        return directory.appendingPathComponent("\(digest).json")
    }

    public func save(_ timing: ReadAlongTiming, forAudio sha256: String) throws {
        guard let url = url(forAudio: sha256) else { throw BookStoreError.badID }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try timing.encoded().write(to: url, options: .atomic)
    }

    public func load(forAudio sha256: String?) -> ReadAlongTiming? {
        guard let sha256, let url = url(forAudio: sha256), let data = try? Data(contentsOf: url) else { return nil }
        return ReadAlongTiming.decode(data)
    }

    public func remove(forAudio sha256: String) {
        guard let url = url(forAudio: sha256) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
