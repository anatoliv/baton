import Foundation

/// Voice the dialogue as both apps ask for it: the switch and its state, writing a
/// cast list with a model, and placing the lines the rules leave once the person has checked it.
/// The Mac's import sheet and Change Voice…, and the iPhone's, run this same flow; each brings
/// its own models (`ModelRouter` and its executor), the voices it can offer, and its own words
/// for why no model could help.
public enum DialogueCastFlow {
    /// Where Voice the dialogue stands for one book.
    public struct Choice: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            case idle
            case writing
            case ready(DialogueCast.Casting)
            case unavailable(String)
        }

        public enum Placing: Equatable, Sendable {
            /// Not asked: the cast has not been checked.
            case idle
            case placing(done: Int, of: Int)
            /// The model's answers (none when no model answered or the person skipped), and the
            /// line that says what happened.
            case placed(DialogueCast.Fill, line: String)
        }

        /// Off unless asked.
        public var isOn: Bool
        public var phase: Phase
        /// The voices the speakers can choose from (the renderer's list when the cast was written).
        public var voices: [String]
        /// The person has checked the cast and pressed Use This Cast. Nothing a model wrote is
        /// used before that.
        public var reviewed: Bool
        public var placing: Placing

        public init(isOn: Bool = false, phase: Phase = .idle, voices: [String] = [], reviewed: Bool = false,
                    placing: Placing = .idle) {
            self.isOn = isOn
            self.phase = phase
            self.voices = voices
            self.reviewed = reviewed
            self.placing = placing
        }

        /// The cast that goes into the book: on, written, and checked.
        public var castingToUse: DialogueCast.Casting? {
            guard isOn, reviewed, case let .ready(casting) = phase else { return nil }
            return casting
        }

        /// The model's speakers for the lines the rules left, with the cast they were asked with.
        public var fillToUse: DialogueCast.Fill? {
            guard castingToUse != nil, case let .placed(fill, _) = placing else { return nil }
            return fill
        }

        /// Make Audiobook waits while the cast is being written, has not been checked, or its
        /// remaining lines are being placed.
        public var holdsTheBook: Bool {
            guard isOn else { return false }
            switch phase {
            case .writing: return true
            case .ready:
                if case .placing = placing { return true }
                return !reviewed
            case .idle, .unavailable: return false
            }
        }
    }

    /// Voice the dialogue in Change Voice…: what a book already made becomes. A book
    /// with no cast can be given one (proposed over its own words and checked, as at import); a
    /// book with one can have it edited (rename, merge, revoice, remove, nothing attributed
    /// again) or turned off. Changing the narrator keeps the cast.
    public struct Change: Equatable, Sendable {
        /// The book as it is.
        public let original: PreparedBook
        /// The switch, and for a book with no cast, the cast being proposed and checked.
        public var choice: Choice
        /// For a book with a cast: that cast, as edited.
        public var edited: DialogueCast.Casting?

        public init(_ book: PreparedBook) {
            original = book
            edited = book.casting
            choice = Choice(isOn: book.hasCast)
            if let edited {
                choice.phase = .ready(edited)
                choice.reviewed = true
            }
        }

        /// The book had a cast when Change Voice opened: editing it needs no model.
        public var hadCast: Bool { original.hasCast }

        /// What the cast part of the change does, apart from the narrator.
        public var changesCast: Bool {
            if hadCast { return !choice.isOn || edited != original.casting }
            return choice.castingToUse != nil
        }

        /// Make Again waits while a new cast is written, checked, or its lines placed.
        public var holdsTheBook: Bool { !hadCast && choice.holdsTheBook }

        /// Whether Make Again would change anything with `narrator`.
        public func changes(narrator: String) -> Bool {
            narrator != original.voices.narrator || changesCast
        }

        /// The book to make again, read by `narrator`.
        public func book(narrator: String) -> PreparedBook {
            if hadCast {
                guard choice.isOn else { return original.withoutCast().inVoice(narrator) }
                guard let edited, edited != original.casting else { return original.inVoice(narrator) }
                return original.recast(edited).inVoice(narrator)
            }
            guard let casting = choice.castingToUse else { return original.inVoice(narrator) }
            return original.reprepared(plan: original.voices.withNarrator(narrator), casting: casting, fill: choice.fillToUse)
        }
    }

    /// Writing the cast list: excerpts, so local sources first and a cloud one only with consent.
    public static let castTask = ModelTask.castSheet
    /// Placing the lines the rules leave: chapters, so chapter consent for a cloud source.
    public static let fillTask = ModelTask.dialogueCast

    /// The book to submit: with the checked cast when there is one, otherwise the narrator-only
    /// book exactly as it was made before casts existed (same id, same chunks).
    public static func book(_ document: ImportedDocument, plan: VoicePlan, choice: Choice) -> PreparedBook {
        guard let casting = choice.castingToUse else { return DocumentSpeech.prepare(document, voices: plan) }
        return DialogueCast.prepare(document, plan: plan, casting: casting, fill: choice.fillToUse)
    }

    /// Ask a model for the cast list, then count lines and choose voices with the rules.
    /// `noModel` is said when no source may write one; `log` hears why a model that was asked
    /// did not answer.
    public static func propose(for document: ImportedDocument, narrator: String, router: ModelRouter,
                               executor: @escaping ModelRouter.Executor,
                               voices: @escaping @Sendable () async -> [String], noModel: String,
                               log: @escaping @Sendable (String) -> Void = { _ in }) async -> (phase: Choice.Phase, voices: [String]) {
        guard !router.plan(for: castTask).usable.isEmpty else { return (.unavailable(noModel), []) }
        async let listed = voices()
        let failure = FailureNote()
        let made = await CastSheetGenerator.generate(for: document) { system, user in
            do {
                return try await router.complete(castTask, system: system, user: user, executor: executor)
            } catch {
                failure.note(String(describing: error))
                throw error
            }
        }
        let offered = await listed
        guard let source = made.source else {
            log("cast list: no model answered: \(failure.text ?? "no dialogue found")")
            return (.unavailable("No model answered for the cast list, so the narrator reads every line."), offered)
        }
        guard !made.sheet.characters.isEmpty else {
            return (.unavailable("No speaking characters were found by \(source), so the narrator reads every line."), offered)
        }
        let casting = DialogueCast.Casting(sheet: made.sheet, document: document, narrator: narrator,
                                           available: offered, source: source)
        return (.ready(casting), offered)
    }

    /// Ask a model about the lines the rules leave, with the checked cast. `noModel` is said
    /// when no source may.
    public static func place(_ document: ImportedDocument, casting: DialogueCast.Casting, router: ModelRouter,
                             executor: @escaping ModelRouter.Executor, noModel: String,
                             log: @escaping @Sendable (String) -> Void = { _ in },
                             progress: @escaping @Sendable (Int, Int) async -> Void) async -> (fill: DialogueCast.Fill, line: String) {
        guard !router.plan(for: fillTask).usable.isEmpty else { return (DialogueCast.Fill(), noModel) }
        let failure = FailureNote()
        let fill = await DialogueCast.fill(document, cast: casting.sheet, complete: { system, user in
            do {
                return try await router.complete(fillTask, system: system, user: user, executor: executor)
            } catch {
                failure.note(String(describing: error))
                throw error
            }
        }, progress: progress)
        if fill.source == nil { log("cast lines: no model answered: \(failure.text ?? "nothing to ask")") }
        return (fill, placedLine(fill))
    }

    /// What placing did, in one line.
    public static func placedLine(_ fill: DialogueCast.Fill) -> String {
        guard let source = fill.source else {
            return "No model answered for the lines without a speech tag, so the narrator reads those."
        }
        let placed = fill.placedByRules + fill.speakers.count
        // The source's name leads no sentence: "your Baton server" and "qwen3:8b on this Mac"
        // both start in lower case.
        return "Placed by \(source): \(fill.speakers.count) more lines, so \(placed) of \(fill.quotes) lines have a speaker. "
            + "The narrator reads the rest."
    }

    public static let skippedLine = "Skipped: the narrator reads the lines without a speech tag."

    /// Why there is no cast list when no source may write one, on `device` ("this Mac").
    public static func noCastLine(device: String) -> String {
        "No model on \(device) or the Baton server can write a cast list, so the narrator reads every line."
    }

    /// Why no model places the remaining lines when no source may, on `device`.
    public static func noFillLine(device: String) -> String {
        "No model on \(device) or the Baton server can place the lines without a speech tag, so the narrator reads those."
    }

    /// "bm_george, British male".
    public static func voiceLabel(_ spec: String) -> String {
        let d = VoiceCatalogue.describe(spec)
        let name = spec.split(separator: ":", maxSplits: 1).last.map(String.init) ?? spec
        let about = [d.accent?.capitalized, d.gender].compactMap { $0 }.joined(separator: " ")
        return about.isEmpty ? name : "\(name), \(about)"
    }

    /// "12 lines found", "no lines found".
    public static func linesLabel(_ count: Int) -> String {
        switch count {
        case 0: "no lines found"
        case 1: "1 line found"
        default: "\(count) lines found"
        }
    }

    /// "3 speakers, 2 with a voice of their own…", or what a model proposed and needs checking.
    public static func summary(_ casting: DialogueCast.Casting, narrator: String, reviewed: Bool) -> String {
        let voiced = casting.voices(narrator: narrator).count
        let people = casting.speakers.count == 1 ? "1 speaker" : "\(casting.speakers.count) speakers"
        if reviewed { return "\(people), \(voiced) with a voice of their own. Lines nobody can place are read by the narrator." }
        return "\(people.prefix(1).uppercased() + people.dropFirst()) proposed by \(casting.source ?? "a model"). "
            + "Check the cast before the book is made: a model gets some of them wrong."
    }

    /// "Finding who speaks the lines without a speech tag: part 2 of 5…".
    public static func placingLine(done: Int, of total: Int) -> String {
        total > 0 ? "Finding who speaks the lines without a speech tag: part \(min(done + 1, total)) of \(total)…"
                  : "Finding who speaks the lines without a speech tag…"
    }

    /// The voices a speaker can have: every voice `offered`, from every engine (TBX-11141: a
    /// chapter's clips are converted to one audio format as it is joined), and any the cast
    /// already has.
    public static func speakerVoices(narrator: String, offered: [String], casting: DialogueCast.Casting) -> [String] {
        var list = offered
        for chosen in casting.speakers.compactMap(\.voice) where !list.contains(chosen) { list.append(chosen) }
        return list
    }

    /// The speaker's voice now, then the voices best for dialogue in the narrator's language.
    public static func suggestedVoices(for speaker: DialogueCast.Casting.Speaker, narrator: String, choices: [String]) -> [String] {
        let language = VoiceCatalogue.declaredLanguage(narrator) ?? "en"
        let best = VoiceCatalogue.candidates(language: language, available: choices)
            .sorted { VoiceCatalogue.dialogueRank($0) < VoiceCatalogue.dialogueRank($1) }
            .map(\.spec).filter { $0 != narrator }
        return Array(([speaker.voice].compactMap { $0 } + best.filter { $0 != speaker.voice }).prefix(4))
    }

    /// Why the router's call failed, kept for the log: `CastSheetGenerator` only says that it did.
    final class FailureNote: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func note(_ text: String) { lock.withLock { value = text } }
        var text: String? { lock.withLock { value } }
    }
}
