import Foundation

/// A document shaped for the ear and cut into TTS requests: what a renderer renders.
///
/// The device that imported the document prepares it, and whichever renderer the person picked
/// (this Mac or the gateway on the home server) renders it. Neither renderer re-shapes text, so
/// a book sounds the same whichever made it, and a chunk rendered by one is a cache hit for the
/// other (`SpeechSegment.cacheKey`).
public struct PreparedBook: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The source file's digest (`ImportedDocument.sourceSHA256`): the book's identity.
    public var documentID: String
    public var title: String
    public var author: String?
    public var language: String?
    public var voices: VoicePlan
    public var audio: AudioSettings
    public var chapters: [PreparedChapter]
    /// How the book's names are said, for Kokoro voices (M8.6). Absent in books made before it,
    /// and decoded as nil then.
    public var lexicon: PronunciationLexicon?

    public init(documentID: String, title: String, author: String?, language: String?,
                voices: VoicePlan, audio: AudioSettings = AudioSettings(), chapters: [PreparedChapter]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.documentID = documentID
        self.title = title
        self.author = author
        self.language = language
        self.voices = voices
        self.audio = audio
        self.chapters = chapters
    }

    /// The same book read by another narrator (Change Voice): the words, the cast,
    /// the pronunciations and the audio settings are kept, and the job id follows the new voice.
    public func inVoice(_ narrator: String) -> PreparedBook {
        var book = self
        book.voices = voices.withNarrator(narrator)
        return book
    }

    /// The dialogue is voiced by a cast (G4): some line has a speaker with a voice of its own.
    public var hasCast: Bool {
        !voices.characters.isEmpty && chapters.contains { $0.segments.contains { $0.speaker != nil } }
    }

    public var segmentCount: Int { chapters.reduce(0) { $0 + $1.segments.count } }
    public var characterCount: Int { chapters.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.text.count } } }

    /// Decode, refusing a schema this build does not know rather than guessing at it.
    public static func decode(_ data: Data) throws -> PreparedBook {
        struct Probe: Decodable { var schemaVersion: Int }
        let version = try JSONDecoder().decode(Probe.self, from: data).schemaVersion
        guard version <= currentSchemaVersion else { throw PreparedBookError.unsupportedSchema(version) }
        return try JSONDecoder().decode(PreparedBook.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// One chunk as it goes to the engine: the voice, the text with the book's pronunciations
/// for a Kokoro voice, the style for a Chatterbox one, the delivery instruction for an
/// expressive one, and the cache key of exactly that.
public struct SegmentRequest: Sendable, Equatable {
    public var text: String
    public var voice: String
    public var speed: Double?
    public var style: SpeechStyle?
    public var instruction: String? = nil
    public var cacheKey: String
}

/// One request of a segment and the silence before it. A Kokoro or Chatterbox
/// segment is one part with the segment's own pause. A segment read by an expressive engine is
/// one part per sentence: the first with the reader's pause before the segment
/// (`SpeechPacing.pauseBefore`), the rest 0.45 s apart, each clip's own leading and trailing
/// silence trimmed so the pause is the one heard.
public struct SegmentPart: Sendable, Equatable {
    public var request: SegmentRequest
    public var pauseBeforeMs: Int
    public var trimsSilence: Bool
}

extension PreparedBook {
    public func request(for segment: SpeechSegment) -> SegmentRequest {
        request(for: segment, text: segment.text)
    }

    func request(for segment: SpeechSegment, text original: String) -> SegmentRequest {
        let voice = voices.voice(for: segment)
        let engine = HTTPSpeechSynthesizer.split(voice).engine
        let text = engine == "kokoro" ? (lexicon?.apply(to: original) ?? original) : original
        let style = engine == "chatterbox" ? voices.style : nil
        let instruction = SpeechEngines.takesInstructions(engine)
            ? DeliveryHints.instruction(speaker: voices.characters[segment.speaker ?? ""] == nil ? nil : segment.speaker,
                                        direction: voices.direction, voice: voice, bookLanguage: language)
            : nil
        return SegmentRequest(text: text, voice: voice, speed: voices.speed, style: style, instruction: instruction,
                              cacheKey: SpeechSegment.cacheKey(voice: voice, speed: voices.speed, sent: text, style: style,
                                                               instruction: instruction))
    }

    /// The requests a segment is made of, and the silence before each (`SegmentPart`).
    /// `previous` is the segment before it in the chapter, nil for the first.
    public func parts(for segment: SpeechSegment, after previous: SpeechSegment?) -> [SegmentPart] {
        let engine = HTTPSpeechSynthesizer.split(voices.voice(for: segment)).engine
        guard SpeechEngines.readsBySentence(engine) else {
            return [SegmentPart(request: request(for: segment), pauseBeforeMs: segment.pauseBeforeMs, trimsSilence: false)]
        }
        let sentences = SentenceSplitter.sentences(segment.text)
        return (sentences.isEmpty ? [segment.text] : sentences).enumerated().map { i, sentence in
            SegmentPart(request: request(for: segment, text: sentence),
                        pauseBeforeMs: i == 0 ? SpeechPacing.pauseBefore(segment, after: previous) : SpeechPacing.betweenSentencesMs,
                        trimsSilence: true)
        }
    }

    /// Every part of a chapter, in order, with the segment each belongs to.
    public func parts(of chapter: PreparedChapter) -> [(segment: Int, part: SegmentPart)] {
        var out: [(segment: Int, part: SegmentPart)] = []
        for (i, segment) in chapter.segments.enumerated() {
            for part in parts(for: segment, after: i > 0 ? chapter.segments[i - 1] : nil) { out.append((i, part)) }
        }
        return out
    }
}

public enum PreparedBookError: Error, Equatable {
    case unsupportedSchema(Int)
}

/// Who reads what. Voices are `"engine:voice"` specs, the same format as `SpeechConfig`'s
/// voice map (`kokoro:bf_emma`, `chatterbox:Emily.wav`), so this package needs nothing from
/// `BatonSpeech` and the gateway can carry a plan it did not make.
public struct VoicePlan: Codable, Sendable, Equatable {
    public var narrator: String
    /// Character name → voice spec, for a dialogue cast. Empty unless the person turned the
    /// cast on for this book (gated: `specs/document-clippings.md`, *Dialogue cast*).
    public var characters: [String: String]
    /// Speaking rate multiplier (1.0 = the engine's default), when the voice suggestion chose one.
    public var speed: Double?
    /// How expressively Chatterbox voices read (M8.7); Kokoro ignores it. Nil: the engine's own.
    public var style: SpeechStyle?
    /// The book's tone and the cast's gender and age, for voices that take a delivery
    /// instruction. Nil unless one does, so other books' plans are unchanged.
    public var direction: VoiceDirection?

    public init(narrator: String, characters: [String: String] = [:], speed: Double? = nil, style: SpeechStyle? = nil,
                direction: VoiceDirection? = nil) {
        self.narrator = narrator
        self.characters = characters
        self.speed = speed
        self.style = style
        self.direction = direction
    }

    /// Whether any voice in the plan takes a delivery instruction.
    public var takesInstructions: Bool {
        ([narrator] + characters.values).contains { SpeechEngines.takesInstructions(HTTPSpeechSynthesizer.split($0).engine) }
    }

    /// The direction kept to what the plan's voices use: the traits of characters read by an
    /// instruction-taking voice, and the tone, while any voice takes an instruction; nil when
    /// none does, so the plan encodes as it did before directions existed.
    public func keepingDirection(_ direction: VoiceDirection?) -> VoicePlan {
        var plan = self
        guard takesInstructions else { plan.direction = nil; return plan }
        var kept = direction ?? VoiceDirection()
        kept.characters = kept.characters.filter { name, _ in
            characters[name].map { SpeechEngines.takesInstructions(HTTPSpeechSynthesizer.split($0).engine) } ?? false
        }
        plan.direction = kept
        return plan
    }

    /// The plan for a book read by `narrator` (M8.7). The suggested speed belongs to the suggested
    /// voice, so another choice reads at its own pace. The tone belongs to the book: the
    /// suggestion's, or `tone` when there is no suggestion (an agent's `import_document`), becomes
    /// the style of a Chatterbox narrator. A Kokoro narrator gets none, so its book keeps the
    /// job id and cache keys it always had.
    public static func forBook(narrator: String, suggestion: VoiceSuggestion? = nil, tone: String? = nil) -> VoicePlan {
        let suggested = suggestion.map { $0.primary == narrator && !$0.isFallback } ?? false
        let engine = HTTPSpeechSynthesizer.split(narrator).engine
        let style = engine == "chatterbox" ? SpeechStyle.forTone(suggestion?.tone ?? tone) : nil
        let direction = SpeechEngines.takesInstructions(engine)
            ? VoiceDirection(tone: DeliveryHints.cleanTone(suggestion?.tone ?? tone)) : nil
        return VoicePlan(narrator: narrator, speed: suggested ? suggestion?.speed : nil, style: style, direction: direction)
    }

    /// The plan with another narrator (Change Voice). The cast is the book's and is
    /// kept: each character keeps the voice it has, and only the narrator changes. The speed
    /// belongs to the voice it was suggested for, so another narrator reads at its own pace; the
    /// style is the book's tone and stays for a Chatterbox narrator, and a Kokoro one takes none.
    public func withNarrator(_ narrator: String) -> VoicePlan {
        guard narrator != self.narrator else { return self }
        let chatterbox = HTTPSpeechSynthesizer.split(narrator).engine == "chatterbox"
        return VoicePlan(narrator: narrator, characters: characters, speed: nil, style: chatterbox ? style : nil)
            .keepingDirection(direction ?? VoiceDirection())
    }

    /// The voice for a segment: its speaker's, or the narrator's when it has none or the
    /// speaker has no voice. An unattributed quote is read by the narrator by design.
    public func voice(for segment: SpeechSegment) -> String {
        segment.speaker.flatMap { characters[$0] } ?? narrator
    }
}

/// How chapters are encoded. 48 kbps mono AAC is the spec's default for speech (Phase 0
/// confirms it by listening); readings stay at 64 kbps.
public struct AudioSettings: Codable, Sendable, Equatable {
    public var bitrate: Int
    public var channels: Int

    public init(bitrate: Int = 48_000, channels: Int = 1) {
        self.bitrate = bitrate
        self.channels = channels
    }

    /// The sample rate every chapter is encoded at, on the Mac and the Baton server:
    /// Kokoro's and Qwen3-TTS's own, so their books encode as they always have, and any two
    /// chapters Baton makes can be joined by stream copy. Not part of the book: it never
    /// changes a book's id.
    public static let encodedSampleRate = 24_000
}

public struct PreparedChapter: Codable, Sendable, Equatable {
    public var index: Int
    public var title: String
    public var segments: [SpeechSegment]

    public init(index: Int, title: String, segments: [SpeechSegment]) {
        self.index = index
        self.title = title
        self.segments = segments
    }
}

/// One TTS request: a sentence-sized chunk with its speaker and the silence before it.
public struct SpeechSegment: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case heading, narration, quote
    }

    public var text: String
    public var kind: Kind
    /// The character speaking, for a cast; `nil` is the narrator.
    public var speaker: String?
    /// Silence inserted before this segment, in milliseconds.
    public var pauseBeforeMs: Int
    /// The paragraph this came from, within its chapter (the heading is -1), so a read-along
    /// view can map audio back to text.
    public var paragraph: Int

    public init(text: String, kind: Kind, speaker: String? = nil, pauseBeforeMs: Int, paragraph: Int) {
        self.text = text
        self.kind = kind
        self.speaker = speaker
        self.pauseBeforeMs = pauseBeforeMs
        self.paragraph = paragraph
    }

    /// The chunk cache key: the same text in the same voice at the same speed is the same
    /// audio, whichever renderer made it and whichever book it is in. A voice change misses
    /// exactly the chunks it changes.
    public func cacheKey(voice: String, speed: Double?) -> String {
        Self.cacheKey(voice: voice, speed: speed, sent: text, style: nil)
    }

    /// With what is actually sent: the text after the lexicon, and the style. A chunk with
    /// neither keeps the key it always had, so books rendered before them stay cached.
    /// A delivery instruction is part of what is sent, so it is part of the key.
    static func cacheKey(voice: String, speed: Double?, sent: String, style: SpeechStyle?, instruction: String? = nil) -> String {
        let speedPart = speed.map { String(format: "%.2f", $0) } ?? "-"
        if let instruction {
            return SHA256Digest.hex(of: Data("v3|\(voice)|\(speedPart)|\(style?.key ?? "-")|\(instruction)|\(sent)".utf8))
        }
        guard let style else { return SHA256Digest.hex(of: Data("v1|\(voice)|\(speedPart)|\(sent)".utf8)) }
        return SHA256Digest.hex(of: Data("v2|\(voice)|\(speedPart)|\(style.key)|\(sent)".utf8))
    }
}
