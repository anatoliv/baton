import Foundation

/// `ImportedDocument` → `PreparedBook`: redact, normalize for the ear, split into dialogue and
/// narration, chunk, and place the pauses.
///
/// The pauses are what make an hour of narration sound read rather than recited: a sentence
/// boundary inside a paragraph gets almost nothing (the voice's own cadence carries it), a change
/// of speaker a little, a paragraph more, and the chapter heading is followed by a breath.
public enum DocumentSpeech {
    public struct Pauses: Sendable, Equatable {
        public var betweenChunks = 120
        public var speakerChange = 250
        public var paragraph = 650
        public var afterHeading = 900

        public init() {}
    }

    /// Attribution for a cast: given the chapter index and the quote's index within that
    /// chapter (0-based, in reading order), the speaking character, or `nil` for the narrator.
    public typealias Attribution = @Sendable (_ chapter: Int, _ quote: Int) -> String?

    /// Sentences are packed into requests up to this many characters (`SentenceSplitter.chunks`).
    public static let packTarget = 280

    public static func prepare(_ document: ImportedDocument, voices: VoicePlan,
                               audio: AudioSettings = AudioSettings(),
                               pauses: Pauses = Pauses(),
                               attribution: Attribution? = nil) -> PreparedBook {
        let doc = SecretRedactor.redact(document)
        let chapters = doc.chapters.map { chapter -> PreparedChapter in
            var segments: [SpeechSegment] = []
            let heading = normalize(chapter.spokenHeading)
            if !heading.isEmpty {
                segments.append(SpeechSegment(text: heading, kind: .heading, pauseBeforeMs: 0, paragraph: -1))
            }
            var quoteIndex = 0
            var openQuote = false
            for (p, paragraph) in chapter.paragraphs.enumerated() {
                let spans = dialogueSpans(normalize(paragraph), continuingQuote: &openQuote)
                // Attach speakers, then merge neighbours that share one, so with no cast a
                // whole paragraph flows as prose and "“Who is it?” she called." stays one chunk.
                var runs: [(text: String, kind: SpeechSegment.Kind, speaker: String?)] = []
                for span in spans {
                    var speaker: String?
                    if span.isQuote {
                        speaker = attribution?(chapter.index, quoteIndex)
                        quoteIndex += 1
                    }
                    let kind: SpeechSegment.Kind = span.isQuote ? .quote : .narration
                    if let last = runs.last, last.speaker == speaker {
                        runs[runs.count - 1].text += " " + span.text
                        if last.kind != kind { runs[runs.count - 1].kind = .narration }
                    } else {
                        runs.append((span.text, kind, speaker))
                    }
                }
                for (r, run) in runs.enumerated() {
                    for (c, chunk) in SentenceSplitter.chunks(run.text, target: packTarget).enumerated() {
                        let pause: Int
                        if r == 0 && c == 0 {
                            pause = segments.last?.kind == .heading ? pauses.afterHeading : (segments.isEmpty ? 0 : pauses.paragraph)
                        } else if c == 0 {
                            pause = pauses.speakerChange
                        } else {
                            pause = pauses.betweenChunks
                        }
                        segments.append(SpeechSegment(text: chunk, kind: run.kind, speaker: run.speaker,
                                                      pauseBeforeMs: pause, paragraph: p))
                    }
                }
            }
            return PreparedChapter(index: chapter.index, title: chapter.title, segments: segments)
        }
        return PreparedBook(documentID: doc.sourceSHA256, title: doc.title, author: doc.author,
                            language: doc.language, voices: voices, audio: audio,
                            chapters: chapters.filter { $0.segments.contains { $0.kind != .heading } })
    }

    // MARK: - Normalization

    /// Text a TTS engine reads well. Narrow on purpose: this is the author's prose, and the
    /// spec forbids rewriting it. Only marks that are typography rather than words change.
    public static func normalize(_ text: String) -> String {
        var out = text
        // Footnote markers: "[12]", "word*", "word†". Read aloud they are noise mid-sentence.
        out = out.replacingOccurrences(of: #"\[\d{1,3}\]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<=\p{L})[*†‡]+"#, with: "", options: .regularExpression)
        // ASCII dashes standing in for an em dash.
        out = out.replacingOccurrences(of: #"\s*--\s*"#, with: " \(Typography.emDash) ", options: .regularExpression)
        // An em dash glued to words reads as a hyphenated word to some engines; give it room.
        out = out.replacingOccurrences(of: #"(?<=\S)\u2014(?=\S)"#, with: " \(Typography.emDash) ", options: .regularExpression)
        out = out.replacingOccurrences(of: "...", with: "\u{2026}")
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Dialogue

    struct Span: Equatable {
        var text: String
        var isQuote: Bool
    }

    /// Split a paragraph at curly double quotes into narration and quoted spans. A quote left
    /// open at the end of a paragraph continues into the next one (the convention for a speech
    /// that runs over paragraphs), which `continuingQuote` carries. Straight quotes are not
    /// dialogue markers here: they cannot say which end they are, and a wrong guess turns the
    /// rest of the chapter inside out. A book set with straight quotes simply gets no cast.
    static func dialogueSpans(_ paragraph: String, continuingQuote: inout Bool) -> [Span] {
        var spans: [Span] = []
        var current = ""
        let carried = continuingQuote
        var inQuote = continuingQuote
        var chars = Substring(paragraph)
        if inQuote, chars.first == "\u{201C}" {   // the reopening mark of a continued speech
            current.append(chars.removeFirst())
        }
        func flush() {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { spans.append(Span(text: t, isQuote: inQuote)) }
            current = ""
        }
        for ch in chars {
            if ch == "\u{201C}", !inQuote {
                flush()
                inQuote = true
                current.append(ch)
            } else if ch == "\u{201D}", inQuote {
                current.append(ch)
                flush()
                inQuote = false
            } else {
                current.append(ch)
            }
        }
        flush()
        continuingQuote = inQuote
        if !carried, spans.count == 1, spans[0].isQuote, !inQuote, isCaption(spans[0].text) { spans[0].isQuote = false }
        return spans
    }

    /// A paragraph that is one quotation with nothing to end it, such as a picture's caption
    /// ("He came down to see the place", under an illustration in Gutenberg's *Pride and
    /// Prejudice*), a title or a sign, is not anyone speaking. The HTML importer leaves captions
    /// out by their markup; a Markdown or plain-text copy of the same book has lost that markup,
    /// so the caption reached the cast as a line. Speech set as a paragraph of its
    /// own ends in punctuation inside the closing mark ("Bingley.", "But it is,", "Oh!"); on the
    /// held-out texts every such paragraph without it was a caption.
    static func isCaption(_ quote: String) -> Bool {
        guard quote.hasPrefix("\u{201C}"), quote.hasSuffix("\u{201D}") else { return false }
        let inner = quote.dropFirst().dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "\u{2019}\u{201D})] "))
        guard let last = inner.last else { return false }
        return !".,!?;:\u{2014}\u{2013}\u{2026}-".contains(last)
    }
}
