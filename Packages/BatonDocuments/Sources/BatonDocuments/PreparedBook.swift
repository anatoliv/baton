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
/// for a Kokoro voice, the style for a Chatterbox one, and the cache key of exactly that.
public struct SegmentRequest: Sendable, Equatable {
    public var text: String
    public var voice: String
    public var speed: Double?
    public var style: SpeechStyle?
    public var cacheKey: String
}

extension PreparedBook {
    public func request(for segment: SpeechSegment) -> SegmentRequest {
        let voice = voices.voice(for: segment)
        let engine = HTTPSpeechSynthesizer.split(voice).engine
        let text = engine == "kokoro" ? (lexicon?.apply(to: segment.text) ?? segment.text) : segment.text
        let style = engine == "chatterbox" ? voices.style : nil
        return SegmentRequest(text: text, voice: voice, speed: voices.speed, style: style,
                              cacheKey: SpeechSegment.cacheKey(voice: voice, speed: voices.speed, sent: text, style: style))
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

    public init(narrator: String, characters: [String: String] = [:], speed: Double? = nil, style: SpeechStyle? = nil) {
        self.narrator = narrator
        self.characters = characters
        self.speed = speed
        self.style = style
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
        return VoicePlan(narrator: narrator, speed: suggested ? suggestion?.speed : nil, style: style)
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
    static func cacheKey(voice: String, speed: Double?, sent: String, style: SpeechStyle?) -> String {
        let speedPart = speed.map { String(format: "%.2f", $0) } ?? "-"
        guard let style else { return SHA256Digest.hex(of: Data("v1|\(voice)|\(speedPart)|\(sent)".utf8)) }
        return SHA256Digest.hex(of: Data("v2|\(voice)|\(speedPart)|\(style.key)|\(sent)".utf8))
    }
}
