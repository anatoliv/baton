import Foundation

/// Which of a book's chapters fit one link, and which kind of link carries them
/// (`specs/book-sharing.md`, Phase 1, TBX-1000000132).
///
/// A book goes out in the containers that already exist, with no new format: one chapter as a
/// song link (`/s/`), two to twelve as a mixtape (`/m/`). The caps are the ones the service
/// advertises (`ShareConfig`), so the composer never holds a second copy of a server limit.
/// Pure, so the edges are tested on Linux with the rest of the kit.
public enum ShareBookPlan {
    /// One chapter whose audio is on this device.
    public struct Chapter: Equatable, Sendable {
        /// The chapter's position in the book, 0-based.
        public var index: Int
        public var title: String
        public var durationSeconds: Double
        /// The audio file's size before sealing.
        public var bytes: Int

        public init(index: Int, title: String, durationSeconds: Double, bytes: Int) {
            self.index = index
            self.title = title
            self.durationSeconds = durationSeconds
            self.bytes = bytes
        }

        /// The whole seconds the wire carries: rounded up, and never 0, so a chapter is never
        /// declared shorter than it plays.
        public var wireSeconds: Int { max(1, Int(durationSeconds.rounded(.up))) }
    }

    public enum Container: Equatable, Sendable {
        case song
        case mixtape
    }

    /// Why a selection cannot be one link, in the composer's words.
    public enum Refusal: Error, Equatable, Sendable {
        case nothingSelected
        /// The selection skips a chapter that cannot go from this device, because its audio is not
        /// here or has no known length (its 1-based number), so
        /// "chapters 3 to 6" would not be what the link holds.
        case missingChapter(Int)
        case tooManyChapters(max: Int)
        case tooLong(seconds: Int, maxSeconds: Int)
        case tooLarge(bytes: Int, maxBytes: Int)

        public var message: String {
            switch self {
            case .nothingSelected:
                return "Choose at least one chapter that is on this device."
            case let .missingChapter(number):
                return "Chapter \(number) isn't ready to share on this device. Choose chapters on one side of it, or get the book back first."
            case let .tooManyChapters(max):
                return "One link holds up to \(max) chapters."
            case let .tooLong(seconds, maxSeconds):
                return "These chapters last \(ShareBookPlan.minutes(seconds)); one link holds up to \(ShareBookPlan.minutes(maxSeconds))."
            case let .tooLarge(bytes, maxBytes):
                return "These chapters are \(ShareBookPlan.megabytes(bytes)); one link holds up to \(ShareBookPlan.megabytes(maxBytes))."
            }
        }
    }

    /// The most chapters a mixtape link holds (`ShareMixtapeManifest.validated`).
    public static let maxChapters = 12

    /// The caps a selection is checked against, from the service's advertised config.
    public struct Limits: Equatable, Sendable {
        public var maxDurationSeconds: Int
        public var maxAudioBytes: Int
        /// The service offers mixtapes (`ShareConfig.mixtapes == 1`). Without them only a
        /// single chapter can go.
        public var mixtapes: Bool

        public init(maxDurationSeconds: Int, maxAudioBytes: Int, mixtapes: Bool) {
            self.maxDurationSeconds = maxDurationSeconds
            self.maxAudioBytes = maxAudioBytes
            self.mixtapes = mixtapes
        }

        public init(config: ShareConfig) {
            self.init(maxDurationSeconds: config.maxDurationSeconds, maxAudioBytes: config.maxAudioBytes,
                      mixtapes: config.mixtapes == 1)
        }

        public static let standard = Limits(maxDurationSeconds: ShareLimits.standard.maxDurationSeconds,
                                            maxAudioBytes: ShareLimits.standard.maxAudioBytes, mixtapes: true)
    }

    /// The link these chapters would make, or why they cannot be one.
    public static func check(_ chapters: [Chapter], limits: Limits = .standard) -> Result<Container, Refusal> {
        guard !chapters.isEmpty else { return .failure(.nothingSelected) }
        for (a, b) in zip(chapters, chapters.dropFirst()) where b.index != a.index + 1 {
            return .failure(.missingChapter(a.index + 2))
        }
        let most = limits.mixtapes ? maxChapters : 1
        guard chapters.count <= most else { return .failure(.tooManyChapters(max: most)) }
        let seconds = chapters.reduce(0) { $0 + $1.wireSeconds }
        guard seconds <= limits.maxDurationSeconds else {
            return .failure(.tooLong(seconds: seconds, maxSeconds: limits.maxDurationSeconds))
        }
        let sealed = chapters.reduce(0) { $0 + ShareCrypto.sealedLength(plaintextLength: $1.bytes) }
        guard sealed <= limits.maxAudioBytes else { return .failure(.tooLarge(bytes: sealed, maxBytes: limits.maxAudioBytes)) }
        return .success(chapters.count == 1 ? .song : .mixtape)
    }

    /// The composer's first selection, as positions in `chapters`: the whole book when it fits,
    /// otherwise the longest run from the first chapter that does. Nil when not even the first
    /// chapter fits one link.
    public static func defaultRange(_ chapters: [Chapter], limits: Limits = .standard) -> ClosedRange<Int>? {
        guard !chapters.isEmpty else { return nil }
        var best: ClosedRange<Int>?
        for end in chapters.indices {
            guard case .success = check(Array(chapters[0 ... end]), limits: limits) else { break }
            best = 0 ... end
        }
        return best
    }

    /// The link's title: the book's, and which chapters when it is not all of them
    /// ("Middlemarch, chapters 3 to 6"). Cut to the wire's title limit on a character boundary.
    public static func title(book: String, selected: [Chapter], chapterCount: Int) -> String {
        let name = truncated(book, to: ShareLimits.maxTitleLength).isEmpty ? "A book" : book
        var suffix = ""
        if let first = selected.first, let last = selected.last, selected.count < chapterCount {
            suffix = first.index == last.index
                ? ", chapter \(first.index + 1)"
                : ", chapters \(first.index + 1) to \(last.index + 1)"
        }
        let room = ShareLimits.maxTitleLength - suffix.unicodeScalars.count
        return truncated(name, to: room) + suffix
    }

    /// The title a single chapter carries on a song link: the chapter's own, or the book's for a
    /// one-chapter book or a chapter with no title.
    public static func chapterTitle(_ chapter: Chapter, book: String, chapterCount: Int) -> String {
        let own = truncated(chapter.title, to: ShareLimits.maxTitleLength)
        if chapterCount == 1 || own.isEmpty { return title(book: book, selected: [chapter], chapterCount: chapterCount) }
        return own
    }

    /// The artist and album lines every chapter carries: the author and the book, cut to fit.
    public static func credits(book: String, author: String?) -> (artist: String, album: String) {
        (truncated(author ?? "", to: ShareLimits.maxTitleLength), truncated(book, to: ShareLimits.maxTitleLength))
    }

    /// A line the wire accepts (`ShareText.clean`): NFC, control characters (a tab, a line break
    /// in a chapter heading) as spaces, trimmed, and cut to `limit` scalars with an ellipsis.
    static func truncated(_ text: String, to limit: Int) -> String {
        let folded = String(String.UnicodeScalarView(text.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar in
            scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value) ? " " : scalar
        }))
        let clean = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.unicodeScalars.count > limit else { return clean }
        var out = ""
        var used = 0
        for character in clean {
            let size = character.unicodeScalars.count
            guard used + size <= max(0, limit - 1) else { break }
            out.append(character)
            used += size
        }
        return out + "…"
    }

    static func minutes(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 1 { return "\(seconds) s" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) minutes"
    }

    static func megabytes(_ bytes: Int) -> String {
        let mib = Double(bytes) / 1_048_576
        return mib < 10 ? String(format: "%.1f MB", mib) : "\(Int(mib.rounded())) MB"
    }
}

// MARK: - Whole-book links (`/b/`, Phase 2)

extension ShareBookPlan {
    /// What a whole-book link would hold, once every check has passed.
    public struct WholeBook: Equatable, Sendable {
        public var chapters: Int
        public var seconds: Int
        /// The chapters' audio once sealed. Read-along text and the manifest come on top.
        public var sealedAudioBytes: Int

        /// "30 chapters · 10 h 0 m · 206 MB. A book link holds up to 200 chapters and 256 MB."
        public func line(limits: ShareBookLimits) -> String {
            let count = chapters == 1 ? "1 chapter" : "\(chapters) chapters"
            return "\(count) · \(ShareBookPlan.minutes(seconds)) · \(ShareBookPlan.megabytes(sealedAudioBytes)). "
                + "A book link holds up to \(limits.maxChapters) chapters and \(ShareBookPlan.megabytes(limits.maxBookBytes))."
        }
    }

    /// A chapter's name in a whole-book link: its own, cut to the wire's limit, or "Chapter 3".
    public static func wholeBookChapterTitle(_ chapter: Chapter) -> String {
        let own = truncated(chapter.title, to: ShareLimits.maxTitleLength)
        return own.isEmpty ? "Chapter \(chapter.index + 1)" : own
    }

    /// The book's name as the link carries it, cut to fit, or "A book" for a book with none.
    public static func bookTitle(_ book: String) -> String {
        let name = truncated(book, to: ShareLimits.maxTitleLength)
        return name.isEmpty ? "A book" : name
    }

    /// Why a whole book cannot be one `/b/` link, in the composer's words. Chapter numbers are
    /// 1-based, as the book shows them.
    public enum WholeBookRefusal: Error, Equatable, Sendable {
        case empty
        case missingChapters([Int])
        case tooManyChapters(max: Int)
        case chapterTooLong(Int, maxSeconds: Int)
        case tooLong(seconds: Int, maxSeconds: Int)
        case chapterTooLarge(Int, maxBytes: Int)
        case tooLarge(bytes: Int, maxBytes: Int)

        public var message: String {
            switch self {
            case .empty:
                return "No chapter of this book is on this device yet."
            case let .missingChapters(numbers):
                let named = ShareBookPlan.list(numbers)
                let verb = numbers.count == 1 ? "isn't" : "aren't"
                return "\(named) \(verb) on this device. A whole-book link needs every chapter here: get \(numbers.count == 1 ? "it" : "them") back first, or send a run of chapters instead."
            case let .tooManyChapters(max):
                return "A book link holds up to \(max) chapters."
            case let .chapterTooLong(number, maxSeconds):
                return "Chapter \(number) is longer than \(ShareBookPlan.minutes(maxSeconds)), the most one chapter can be."
            case let .tooLong(seconds, maxSeconds):
                return "This book lasts \(ShareBookPlan.minutes(seconds)); a book link holds up to \(ShareBookPlan.minutes(maxSeconds))."
            case let .chapterTooLarge(number, maxBytes):
                return "Chapter \(number) is larger than \(ShareBookPlan.megabytes(maxBytes)), the most one chapter can be."
            case let .tooLarge(bytes, maxBytes):
                return "This book is \(ShareBookPlan.megabytes(bytes)); a book link holds up to \(ShareBookPlan.megabytes(maxBytes))."
            }
        }
    }

    /// Whether the whole book can be one `/b/` link within the caps the service advertises.
    /// `chapters` are those on this device; `chapterCount` is every chapter the book has, so a
    /// chapter that is not here is named rather than silently left out.
    public static func checkWholeBook(_ chapters: [Chapter], chapterCount: Int,
                                      limits: ShareBookLimits) -> Result<WholeBook, WholeBookRefusal> {
        guard !chapters.isEmpty, chapterCount > 0 else { return .failure(.empty) }
        let here = Set(chapters.map(\.index))
        let missing = (0 ..< chapterCount).filter { !here.contains($0) }.map { $0 + 1 }
        guard missing.isEmpty else { return .failure(.missingChapters(missing)) }
        guard chapters.count <= limits.maxChapters else { return .failure(.tooManyChapters(max: limits.maxChapters)) }
        var seconds = 0, bytes = 0
        for chapter in chapters.sorted(by: { $0.index < $1.index }) {
            guard chapter.wireSeconds <= limits.maxChapterSeconds else {
                return .failure(.chapterTooLong(chapter.index + 1, maxSeconds: limits.maxChapterSeconds))
            }
            let sealed = ShareCrypto.sealedLength(plaintextLength: chapter.bytes)
            guard sealed <= limits.maxChapterBytes else {
                return .failure(.chapterTooLarge(chapter.index + 1, maxBytes: limits.maxChapterBytes))
            }
            seconds += chapter.wireSeconds
            bytes += sealed
        }
        guard seconds <= limits.maxBookSeconds else { return .failure(.tooLong(seconds: seconds, maxSeconds: limits.maxBookSeconds)) }
        guard bytes <= limits.maxBookBytes else { return .failure(.tooLarge(bytes: bytes, maxBytes: limits.maxBookBytes)) }
        return .success(WholeBook(chapters: chapters.count, seconds: seconds, sealedAudioBytes: bytes))
    }

    /// Whether the composer opens on the whole-book link: the service offers it, every chapter
    /// is here, and the whole book does not fit one Phase 1 link (more than 12 chapters, or over
    /// the advertised duration or size). A run that fits keeps Phase 1, and a book with a chapter
    /// missing starts on the chapters it can send.
    public static func prefersWholeBook(_ chapters: [Chapter], chapterCount: Int, limits: Limits,
                                        bookLimits: ShareBookLimits?) -> Bool {
        guard let bookLimits, case .success = checkWholeBook(chapters, chapterCount: chapterCount, limits: bookLimits)
        else { return false }
        if case .success = check(chapters.sorted { $0.index < $1.index }, limits: limits) { return false }
        return true
    }

    /// A chapter's read-along sentences as the book format carries them, or nil when there are
    /// none. Every segment is made one the format accepts rather than refusing the chapter: text
    /// cut to the segment limit, a paragraph below the heading's -1 raised to it, an end before
    /// its start moved to the start, and a segment with no usable start or no words left out.
    public static func readAlongText(_ segments: [ShareBookText.Segment]) -> ShareBookText? {
        var out = [ShareBookText.Segment]()
        for segment in segments {
            guard out.count < ShareBookText.maxSegments else { break }
            guard segment.start.isFinite, segment.start >= 0,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var text = segment.text
            if text.unicodeScalars.count > ShareBookText.maxSegmentLength {
                text = String(String.UnicodeScalarView(text.unicodeScalars.prefix(ShareBookText.maxSegmentLength)))
            }
            let end = segment.end.isFinite ? max(segment.start, segment.end) : segment.start
            out.append(.init(text: text, paragraph: max(-1, segment.paragraph), start: segment.start, end: end))
        }
        return out.isEmpty ? nil : ShareBookText(segments: out)
    }

    /// "Chapter 3", "Chapters 3 and 7", "Chapters 2, 5, 8, 9, 11 and 4 more".
    static func list(_ numbers: [Int]) -> String {
        guard let first = numbers.first else { return "" }
        if numbers.count == 1 { return "Chapter \(first)" }
        let shown = numbers.prefix(5).map(String.init)
        if numbers.count > 5 { return "Chapters \(shown.joined(separator: ", ")) and \(numbers.count - 5) more" }
        return "Chapters \(shown.dropLast().joined(separator: ", ")) and \(shown.last!)"
    }
}
