import Foundation

// "Previously…" as both apps offer it (M8.4 on the Mac, TBX-10963 on the iPhone). `Recap` holds
// the prompt and the cleaning; this is the rest of what the two apps must agree on: the words a
// recap is made from when the app has no prepared book, where the listener is, when a recap is
// offered, the one router call that writes it, and the voice it is said in. Each app keeps only
// its own screen and its own way of speaking.

extension Recap {
    /// A chapter as an app holds it: its words (the clipping's text, or the text sent to the home
    /// server) and the length of its audio once it has some.
    public struct ChapterText: Sendable, Equatable {
        public var index: Int
        public var title: String
        public var text: String
        public var durationSeconds: Double?

        public init(index: Int, title: String, text: String, durationSeconds: Double? = nil) {
            self.index = index
            self.title = title
            self.text = text
            self.durationSeconds = durationSeconds
        }
    }

    /// How many sentences make a passage when the paragraphs are not known.
    public static let sentencesPerPassage = 4

    /// A book's words as the companions read them, from chapter texts alone: sentences grouped
    /// into short paragraphs. Nil when no chapter has any words.
    public static func book(documentID: String, title: String, author: String?,
                            chapters: [ChapterText]) -> PreparedBook? {
        let prepared = chapters.sorted { $0.index < $1.index }.map {
            PreparedChapter(index: $0.index, title: $0.title, segments: segments($0.text))
        }
        guard prepared.contains(where: { !$0.segments.isEmpty }) else { return nil }
        return PreparedBook(documentID: documentID, title: title, author: author, language: nil,
                            voices: VoicePlan(narrator: ""), chapters: prepared)
    }

    /// Sentences as narration segments, a few to a paragraph.
    public static func segments(_ text: String) -> [SpeechSegment] {
        SentenceSplitter.sentences(text).enumerated().map { index, sentence in
            SpeechSegment(text: sentence, kind: .narration, pauseBeforeMs: 0, paragraph: index / sentencesPerPassage)
        }
    }

    /// Where the listener is from the synced position: the chapter and the share of its audio
    /// played (`chapterDuration`), else the end of a finished book, else its start. The share is
    /// rounded down to whole sentences (`BookPosition(chapter:fractionHeard:in:)`), which is the
    /// spoiler bound: nothing past it reaches the model.
    public static func position(in book: PreparedBook, synced: (chapterIndex: Int, seconds: Double)?,
                                chapterDuration: Double?, finished: Bool) -> BookPosition {
        if let synced {
            let duration = chapterDuration ?? 0
            let fraction = duration > 0 ? synced.seconds / duration : 0
            return BookPosition(chapter: synced.chapterIndex, fractionHeard: fraction, in: book)
        }
        if finished, let last = book.chapters.last {
            return BookPosition(chapter: last.index, segment: last.segments.count)
        }
        return BookPosition(chapter: 0, segment: 0)
    }

    /// Whether Play offers a recap: an unfinished book with a synced position, last played more
    /// than a day ago, with enough heard before that position to recap.
    public static func shouldOffer(book: PreparedBook, synced: (chapterIndex: Int, seconds: Double)?,
                                   chapterDuration: Double?, finished: Bool,
                                   lastPlayed: Date?, now: Date = Date()) -> Bool {
        guard !finished, synced != nil else { return false }
        let position = position(in: book, synced: synced, chapterDuration: chapterDuration, finished: finished)
        return shouldOffer(lastPlayed: lastPlayed, now: now, heard: HeardText(book, upTo: position))
    }

    /// The recap, written by the first source the router may use that answers, cleaned for the
    /// ear; nil when none did, so the book simply plays. A cloud source is used only with
    /// `consent` for chapters.
    public static func write(book: PreparedBook, position: BookPosition, sources: [ModelSource],
                             consent: ModelConsent = ModelConsent(),
                             executor: @escaping ModelRouter.Executor) async -> (text: String, source: String)? {
        let router = ModelRouter(sources: sources, consent: consent)
        guard !router.plan(for: .recap).usable.isEmpty else { return nil }
        return await make(book: book, position: position, complete: { @Sendable system, user in
            try await router.complete(.recap, system: system, user: user, executor: executor)
        })
    }

    /// "It has been a while since you heard The Machine Stops. Hear a short recap…"
    public static func offerText(title: String) -> String {
        "It has been a while since you heard \(title). Hear a short recap of what you have heard, then carry on?"
    }

    // MARK: - Saying it

    /// The voice a recap is said in: never the narrator's, so the recap is not mistaken for the
    /// book. The recap is written in English (`system`), so the voice is an English Kokoro voice:
    /// the other sex from the narrator, in the narrator's accent, which is the clearest change of
    /// voice a listener can hear. A narrator that is not a Kokoro voice gets Heart.
    public static func voice(otherThan narrator: String) -> String {
        let id = (narrator.split(separator: ":").last.map(String.init) ?? narrator).lowercased()
        let isKokoro = narrator.lowercased().hasPrefix("kokoro:") || !narrator.contains(":")
        let chars = Array(id)
        guard isKokoro, chars.count > 2, chars[2] == "_" else {
            return narrator.lowercased() == "kokoro:af_heart" ? "kokoro:am_michael" : "kokoro:af_heart"
        }
        let british = chars[0] == "b"
        let female = chars[1] == "f"
        switch (british, female) {
        case (true, true): return "kokoro:bm_george"
        case (true, false): return "kokoro:bf_emma"
        case (false, true): return "kokoro:am_michael"
        case (false, false): return "kokoro:af_heart"
        }
    }

    /// The recap cut at its last sentence end within `characters`, for a speech route with a
    /// length limit (the home server's preview takes 600). Unchanged when it already fits.
    public static func fitting(_ text: String, characters: Int) -> String {
        guard text.count > characters else { return text }
        let cut = String(text.prefix(characters))
        if let end = cut.range(of: #"[.!?](?=[^.!?]*$)"#, options: .regularExpression),
           cut.distance(from: cut.startIndex, to: end.lowerBound) > characters / 3 {
            return String(cut[...end.lowerBound])
        }
        let words = cut.split(separator: " ").dropLast().joined(separator: " ")
        return words + "."
    }
}
