import Foundation

/// Voice the dialogue for a book already made, in Change Voice… on both apps.
///
/// A book keeps its words only as the segments it was made from, not the document it was
/// imported from, and that is enough. `DocumentSpeech.prepare` splits each paragraph into chunks
/// with the quotation marks kept, so joining a paragraph's segments gives back the text that was
/// spoken, and preparing that text again gives the same segments. So:
///
/// - **Turning a cast on** proposes and attributes over `spokenDocument`, exactly as the import
///   sheet does over the imported file, and `reprepared` makes the book with it: the book the
///   import would have made with that cast.
/// - **Editing a cast** (rename, merge, revoice, remove, mark the narrator) changes who speaks
///   the lines already attributed (`recast`): no model, and no line moves to someone else.
/// - **Turning it off** is the narrator-only book prepared from the same words.
/// - **Changing the narrator** keeps the cast, as `inVoice` does.
extension PreparedBook {
    /// The book's words as a document: each chapter's paragraphs joined from its segments, in
    /// order, at the paragraph numbers they had (a paragraph that made no segment stays empty).
    /// The document id is the book's, so a book made from it is the same book in the library.
    public var spokenDocument: ImportedDocument {
        let rebuilt = chapters.map { chapter -> DocumentChapter in
            var paragraphs: [String] = []
            for segment in chapter.segments where segment.paragraph >= 0 {
                while paragraphs.count <= segment.paragraph { paragraphs.append("") }
                let text = paragraphs[segment.paragraph]
                paragraphs[segment.paragraph] = text.isEmpty ? segment.text : text + " " + segment.text
            }
            return DocumentChapter(index: chapter.index, title: chapter.title, paragraphs: paragraphs)
        }
        return ImportedDocument(sourceSHA256: documentID, sourceKind: .text, title: title, author: author,
                                language: language, chapters: rebuilt)
    }

    /// This book made again from its own words with `plan`, and with `casting` when given (the
    /// lines `fill` places included). Without a cast it is the narrator-only book. The headings
    /// are the ones it was made with (a chapter's numbering is not in its segments), and its
    /// pronunciations and audio settings stay.
    public func reprepared(plan: VoicePlan, casting: DialogueCast.Casting? = nil,
                           fill: DialogueCast.Fill? = nil) -> PreparedBook {
        let document = spokenDocument
        var narratorOnly = plan
        narratorOnly.characters = [:]
        var book = casting.map { DialogueCast.prepare(document, plan: plan, casting: $0, fill: fill, audio: audio) }
            ?? DocumentSpeech.prepare(document, voices: narratorOnly, audio: audio)
        for c in book.chapters.indices {
            guard let original = chapters.first(where: { $0.index == book.chapters[c].index }),
                  let heading = original.segments.first(where: { $0.kind == .heading }),
                  let at = book.chapters[c].segments.firstIndex(where: { $0.kind == .heading }) else { continue }
            book.chapters[c].segments[at] = heading
        }
        book.lexicon = lexicon
        return book
    }

    /// The narrator-only book from the same words: Voice the dialogue turned off.
    public func withoutCast() -> PreparedBook {
        let castLeft = !voices.characters.isEmpty || chapters.contains { $0.segments.contains { $0.speaker != nil } }
        guard castLeft else { return self }
        return reprepared(plan: voices)
    }

    /// The cast as Change Voice edits it: everyone who speaks a line in a voice of their own,
    /// most lines first, with a line of theirs to hear.
    public var casting: DialogueCast.Casting? {
        guard hasCast else { return nil }
        var lines: [String: Int] = [:]
        var samples: [String: String] = [:]
        var order: [String] = []
        for segment in chapters.flatMap(\.segments) {
            guard let who = segment.speaker, voices.characters[who] != nil else { continue }
            if lines[who] == nil { order.append(who) }
            lines[who, default: 0] += 1
            // Their longest line that is still short enough to hear in a moment.
            if samples[who] == nil || (segment.text.count <= 220 && segment.text.count > samples[who]!.count) {
                samples[who] = segment.text
            }
        }
        let speakers = order.sorted { (lines[$0] ?? 0) != (lines[$1] ?? 0) ? (lines[$0] ?? 0) > (lines[$1] ?? 0) : $0 < $1 }
            .map { name -> DialogueCast.Casting.Speaker in
                let gender = VoiceCatalogue.describe(voices.characters[name] ?? "").gender
                let character = DialogueCast.Character(name: name, gender: gender == "female" ? "f" : (gender == "male" ? "m" : "x"))
                return .init(id: name, character: character, voice: voices.characters[name], isNarrator: false,
                             lines: lines[name] ?? 0, sample: samples[name].map(DialogueCast.stripMarks))
            }
        return DialogueCast.Casting(speakers: speakers, source: "this book's cast")
    }

    /// The book with its cast edited (`casting` from `self.casting`, changed in the editor): each
    /// line keeps the speaker it had, under their new name; a speaker merged into another speaks
    /// as them; one removed, marked the narrator, or left without a voice goes back to the
    /// narrator. Nothing is attributed again, so no line moves to someone else.
    public func recast(_ casting: DialogueCast.Casting) -> PreparedBook {
        var to: [String: (name: String, voice: String?)] = [:]
        for speaker in casting.speakers {
            let voice = speaker.isNarrator ? nil : speaker.voice
            to[speaker.id] = (speaker.name, voice)
            // Someone merged into this speaker: their old name is now one of its phrases.
            for alias in speaker.character.aliases {
                for old in voices.characters.keys where old.lowercased() == alias && to[old] == nil && casting.speaker(old) == nil {
                    to[old] = (speaker.name, voice)
                }
            }
        }
        var book = self
        var characters: [String: String] = [:]
        for c in book.chapters.indices {
            for s in book.chapters[c].segments.indices {
                guard let old = book.chapters[c].segments[s].speaker else { continue }
                if let target = to[old], let voice = target.voice {
                    book.chapters[c].segments[s].speaker = target.name
                    characters[target.name] = voice
                } else {
                    book.chapters[c].segments[s].speaker = nil
                }
            }
        }
        book.voices.characters = characters
        // Nobody left with a voice of their own: the narrator-only book, chunk for chunk.
        return characters.isEmpty ? reprepared(plan: book.voices) : book
    }
}
