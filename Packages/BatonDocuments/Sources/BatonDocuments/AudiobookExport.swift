import Foundation

/// A finished book as one audiobook file with chapter marks (M8.8): what the M4B's chapters
/// are, written once for both makers. The gateway feeds `ffmetadata` to ffmpeg; the Mac's
/// AVFoundation export takes `marks` as its chapter list.
public enum AudiobookExport {
    public struct Mark: Sendable, Equatable {
        public var title: String
        public var start: Double
        public var end: Double

        public init(title: String, start: Double, end: Double) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    /// Chapter marks from the rendered chapters' measured lengths, or nil while any chapter is
    /// not ready: an audiobook with a hole in it is not offered.
    public static func marks(_ job: BookJob) -> [Mark]? {
        var marks: [Mark] = []
        var at = 0.0
        for (chapter, state) in zip(job.book.chapters, job.chapters) {
            guard case let .ready(_, _, seconds, _) = state else { return nil }
            marks.append(Mark(title: chapter.title, start: at, end: at + seconds))
            at += seconds
        }
        return marks.isEmpty ? nil : marks
    }

    /// The same marks placed on each chapter's length as it is joined, not as it was rendered
    /// An AAC chapter carries its encoder priming and end padding, so its packets
    /// run a little longer than its words; stream-copied end to end, chapter k begins at the sum
    /// of the earlier chapters' packet durations. Placed on the rendered lengths the marks fall
    /// progressively early. Unchanged when the counts differ, which is the caller's mistake.
    public static func placed(_ marks: [Mark], muxedLengths: [Double]) -> [Mark] {
        guard marks.count == muxedLengths.count else { return marks }
        var at = 0.0
        return zip(marks, muxedLengths).map { mark, length in
            defer { at += length }
            return Mark(title: mark.title, start: at, end: at + length)
        }
    }

    /// The chapter files in order, or nil while any is not ready.
    public static func chapterFiles(_ job: BookJob) -> [String]? {
        var files: [String] = []
        for state in job.chapters {
            guard case let .ready(file, _, _, _) = state else { return nil }
            files.append(file)
        }
        return files.isEmpty ? nil : files
    }

    /// ffmpeg's metadata file: the book's tags and one `[CHAPTER]` per mark, in milliseconds.
    public static func ffmetadata(book: PreparedBook, marks: [Mark]) -> String {
        var out = ";FFMETADATA1\n"
        out += "title=\(escape(book.title))\nalbum=\(escape(book.title))\ngenre=Audiobook\n"
        if let author = book.author { out += "artist=\(escape(author))\nalbum_artist=\(escape(author))\n" }
        for mark in marks {
            out += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int((mark.start * 1000).rounded()))\n"
            out += "END=\(Int((mark.end * 1000).rounded()))\ntitle=\(escape(mark.title))\n"
        }
        return out
    }

    /// ffmetadata escapes `=`, `;`, `#`, `\` and line ends with a backslash. Scalar by scalar,
    /// because "\r\n" is one Character; a NUL, which ends ffmpeg's line read, is dropped.
    static func escape(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for c in value.unicodeScalars where c != "\u{0}" {
            if "=;#\\\r\n".unicodeScalars.contains(c) { out.append("\\") }
            out.append(c)
        }
        return String(out)
    }

    /// "The Machine Stops - E. M. Forster.m4b", safe as a file name anywhere.
    public static func fileName(_ book: PreparedBook) -> String {
        let base = [book.title, book.author].compactMap { $0 }.joined(separator: " - ")
        let cleaned = base.unicodeScalars.map { CharacterSet(charactersIn: "/\\:*?\"<>|").contains($0) || $0.value < 0x20 ? "_" : String($0) }.joined()
        return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) + ".m4b"
    }
}
