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
