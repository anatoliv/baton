import Foundation

/// The cast as the person corrects it before a book is made, and the book made with it (G4).
///
/// A generated cast sheet put one voice on one person 81% of the time on the held-out texts
/// (G3), so a sheet is never used as the model wrote it: the import sheet shows it, the person
/// renames, merges, marks the narrator and picks voices, and only then does `prepare` use it.
///
/// The book is the narrator-only book with speakers on its quotes. Narration, and every quote the
/// rules leave unattributed, stay with the narrator (the G1 policy: a quote nobody is sure about
/// costs nothing). When no quote ends up with a voice of its own the result is exactly the
/// narrator-only book, so its job id and chunk keys are the ones it always had.
extension DialogueCast {
    public struct Casting: Codable, Sendable, Equatable {
        public struct Speaker: Codable, Sendable, Equatable, Identifiable {
            /// Stable while editing: the name the sheet first gave.
            public var id: String
            public var character: Character
            /// The voice spec for this person's lines; nil leaves them to the narrator.
            public var voice: String?
            /// The narrator is speaking (a first-person book): their lines stay in the
            /// narrator's voice, and the rules still know who they are.
            public var isNarrator: Bool
            /// Quotes the rules gave this person when the sheet was made: a guide to who matters.
            public var lines: Int
            /// One of their lines, to hear a voice say it.
            public var sample: String?

            public var name: String { character.name }
        }

        public var speakers: [Speaker]
        /// Who wrote the sheet ("qwen3:8b on this Mac"), for the line above it.
        public var source: String?

        public init(speakers: [Speaker], source: String? = nil) {
            self.speakers = speakers
            self.source = source
        }

        /// A sheet as the model wrote it, with line counts from the rules and a distinct voice of
        /// plausible gender for everyone who speaks (`assignVoices`). Speakers with no lines
        /// found keep no voice until the person gives them one.
        public init(sheet: CastSheet, document: ImportedDocument, narrator: String, available: [String],
                    source: String? = nil) {
            var spans = DialogueCast.segment(SecretRedactor.redact(document))
            DialogueCast.attributeRules(&spans, cast: sheet.characters)
            var lines: [String: Int] = [:]
            var samples: [String: String] = [:]
            for s in spans where s.kind == .quote {
                guard let who = s.speaker else { continue }
                lines[who, default: 0] += 1
                // A line long enough to hear the voice in, and short enough to be a preview.
                if samples[who] == nil || (samples[who]!.count < 40 && s.text.count <= 220) { samples[who] = s.text }
            }
            // Proposed from the narrator's engine, so a cast sounds of a piece; from every voice
            // offered when that engine has none to give. The person can choose any engine's.
            let ownEngine = available.filter { Self.sameEngine($0, narrator) }
            let voices = DialogueCast.assignVoices(spans, cast: sheet.characters, narrator: narrator,
                                                   available: ownEngine.count > 1 ? ownEngine : available)
            self.init(speakers: sheet.characters.map { c in
                Speaker(id: c.name, character: c, voice: voices[c.name], isNarrator: false,
                        lines: lines[c.name] ?? 0, sample: samples[c.name])
            }, source: source)
        }

        /// The sheet the rules attribute with: everyone, the narrator included, since knowing
        /// who the narrator is helps place everyone else's lines.
        public var sheet: CastSheet { CastSheet(characters: speakers.map(\.character)) }

        public func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }

        // MARK: Editing

        /// Give a speaker the name the book uses. The old name stays as one of the phrases the
        /// text uses for them, so the lines it found are still found. Refused (false) when the
        /// name is empty or another speaker has it: that is a merge.
        @discardableResult
        public mutating func rename(_ id: String, to newName: String) -> Bool {
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let i = speakers.firstIndex(where: { $0.id == id }), !name.isEmpty else { return false }
            guard !speakers.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) else { return false }
            let old = speakers[i].name.lowercased()
            speakers[i].character.name = name
            speakers[i].character.aliases.removeAll { $0 == name.lowercased() }
            if old != name.lowercased(), !speakers[i].character.aliases.contains(old) {
                speakers[i].character.aliases.append(old)
            }
            return true
        }

        /// Two entries that are one person: `id`'s name and phrases join `target`, and `id` goes.
        /// The target keeps its voice and gender.
        public mutating func merge(_ id: String, into target: String) {
            guard id != target, let from = speaker(id), let t = speakers.firstIndex(where: { $0.id == target }) else { return }
            let targetName = speakers[t].name.lowercased()
            for phrase in [from.name.lowercased()] + from.character.aliases
            where phrase != targetName && !speakers[t].character.aliases.contains(phrase) {
                speakers[t].character.aliases.append(phrase)
            }
            speakers[t].lines += from.lines
            if speakers[t].sample == nil { speakers[t].sample = from.sample }
            speakers.removeAll { $0.id == id }
        }

        /// Mark (or unmark) a speaker as the narrator. At most one speaker is the narrator.
        public mutating func setNarrator(_ id: String, _ on: Bool) {
            for i in speakers.indices {
                if speakers[i].id == id { speakers[i].isNarrator = on } else if on { speakers[i].isNarrator = false }
            }
        }

        /// The voice for a speaker's lines; nil leaves them to the narrator.
        public mutating func setVoice(_ id: String, _ voice: String?) {
            guard let i = speakers.firstIndex(where: { $0.id == id }) else { return }
            speakers[i].voice = voice
        }

        /// The phrases the text uses for a speaker, as a comma-separated line ("her mother,
        /// mrs. bennet"). Pronouns are dropped: they would claim every "she said".
        public mutating func setAliases(_ id: String, _ text: String) {
            guard let i = speakers.firstIndex(where: { $0.id == id }) else { return }
            var out: [String] = []
            for raw in text.split(separator: ",") {
                let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !phrase.isEmpty, !DialogueCast.pronouns.contains(phrase), phrase != speakers[i].name.lowercased(),
                      !out.contains(phrase) else { continue }
                out.append(phrase)
            }
            speakers[i].character.aliases = out
        }

        /// Not a speaker at all: their lines go back to the narrator.
        public mutating func remove(_ id: String) {
            speakers.removeAll { $0.id == id }
        }

        // MARK: Voices

        /// Name → voice for the speakers read in a voice of their own: not the narrator, with a
        /// voice chosen. Any engine's: a chapter whose voices answer in different audio formats is
        /// converted to one as it is joined (`WAV.converting`, TBX-11141).
        public func voices(narrator: String) -> [String: String] {
            var out: [String: String] = [:]
            for s in speakers where !s.isNarrator {
                guard let voice = s.voice else { continue }
                out[s.name] = voice
            }
            return out
        }

        static func sameEngine(_ a: String, _ b: String) -> Bool {
            HTTPSpeechSynthesizer.split(a).engine == HTTPSpeechSynthesizer.split(b).engine
        }
    }

    /// The book with its cast: narration and unattributed quotes in `plan`'s narrator voice,
    /// each attributed quote in its speaker's. Attribution is the rules, then `fill`'s answers
    /// for the quotes the rules left (a model's, asked once by the import sheet with this cast;
    /// `DialogueCastFill.swift`). Without a fill it is the rules alone.
    ///
    /// Only speakers whose lines are actually voiced go into the plan, so a cast that voices
    /// nothing (every speaker the narrator, or no line found) is the narrator-only book, same id.
    public static func prepare(_ document: ImportedDocument, plan: VoicePlan, casting: Casting,
                               fill: Fill? = nil,
                               audio: AudioSettings = AudioSettings(),
                               pauses: DocumentSpeech.Pauses = DocumentSpeech.Pauses()) -> PreparedBook {
        var spans = segment(SecretRedactor.redact(document))
        attributeRules(&spans, cast: casting.sheet.characters)
        if let fill { applyFill(fill, to: &spans, cast: casting.sheet.characters) }
        let voiced = casting.voices(narrator: plan.narrator)
        for i in spans.indices where spans[i].speaker.map({ voiced[$0] == nil }) ?? false {
            spans[i].speaker = nil
        }
        let speaking = Set(spans.compactMap(\.speaker))
        var castPlan = plan
        castPlan.characters = voiced.filter { speaking.contains($0.key) }
        // Who each character is goes with the book for a voice that takes a delivery
        // instruction; nothing changes for a cast that has none.
        let traits = Dictionary(casting.sheet.characters.map { ($0.name, CharacterTraits(gender: $0.gender, age: $0.age)) },
                                uniquingKeysWith: { first, _ in first })
        castPlan = castPlan.keepingDirection(VoiceDirection(tone: plan.direction?.tone, characters: traits))
        guard !castPlan.characters.isEmpty else {
            return DocumentSpeech.prepare(document, voices: plan, audio: audio, pauses: pauses)
        }
        return DocumentSpeech.prepare(document, voices: castPlan, audio: audio, pauses: pauses,
                                      attribution: attribution(spans))
    }
}
