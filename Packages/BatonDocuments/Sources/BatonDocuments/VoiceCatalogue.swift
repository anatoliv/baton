import Foundation

/// What a voice is, so something can reason about which one suits a book
/// (`specs/document-clippings.md`, *Voice suggestion*).
///
/// Until this, a voice was `{engine, voice}` and "warm US female" lived only in a code comment
/// on the voice map. Language, accent and gender are derived from Kokoro's own id scheme, so
/// they hold for every Kokoro voice a server lists, described here or not. `grade` is Kokoro's
/// published quality grade (`VOICES.md` in the model repository), because a well-suited voice
/// that sounds rough is the wrong suggestion. `tags` are the curated part, written after a
/// listening pass (card DOC-7); a voice without them is still selectable by hand, and is
/// suggested on accent, gender and grade alone.
public struct VoiceDescriptor: Codable, Sendable, Equatable, Hashable {
    public var spec: String          // "kokoro:bf_emma"
    public var language: String      // "en", "es", ...
    public var accent: String?       // "american", "british", ...
    public var gender: String?       // "female", "male"
    /// Kokoro's grade, "A" (best) to "F". `nil` when unpublished (Chatterbox references).
    public var grade: String?
    public var tags: [String]

    public init(spec: String, language: String, accent: String?, gender: String?, grade: String?, tags: [String] = []) {
        self.spec = spec
        self.language = language
        self.accent = accent
        self.gender = gender
        self.grade = grade
        self.tags = tags
    }

    /// A sortable rank for `grade`: A = 16, A- = 15, B+ = 14, B = 13, B- = 12, C+ = 11 ... F- = 0;
    /// unknown sorts last. Three steps per letter, so B- never ties with C+.
    public var gradeRank: Int {
        guard let grade, let letter = grade.first, let base = "FEDCBA".firstIndex(of: letter) else { return -1 }
        let value = "FEDCBA".distance(from: "FEDCBA".startIndex, to: base) * 3 + 1
        if grade.hasSuffix("+") { return value + 1 }
        if grade.hasSuffix("-") { return value - 1 }
        return value
    }

    /// One line for a model prompt: id, then what it is.
    public var promptLine: String {
        var parts = [accent.map { "\($0) English" } ?? language, gender].compactMap { $0 }
        if let grade { parts.append("quality \(grade)") }
        parts.append(contentsOf: tags)
        return "- \(spec): \(parts.joined(separator: ", "))"
    }
}

public enum VoiceCatalogue {
    /// Kokoro's id prefixes: first letter the language/accent, second the gender.
    static let kokoroLanguages: [Character: (language: String, accent: String?)] = [
        "a": ("en", "american"), "b": ("en", "british"), "e": ("es", nil), "f": ("fr", nil),
        "h": ("hi", nil), "i": ("it", nil), "j": ("ja", nil), "p": ("pt", "brazilian"), "z": ("zh", nil),
    ]

    /// Kokoro-82M v1.0 grades from its `VOICES.md` (checked 2026-10-03), English voices.
    static let kokoroGrades: [String: String] = [
        "af_heart": "A", "af_bella": "A-", "af_nicole": "B-", "af_aoede": "C+", "af_kore": "C+",
        "af_sarah": "C+", "af_alloy": "C", "af_nova": "C", "af_sky": "C-", "af_jessica": "D", "af_river": "D",
        "am_fenrir": "C+", "am_michael": "C+", "am_puck": "C+", "am_echo": "D", "am_eric": "D", "am_liam": "D",
        "am_onyx": "D", "am_santa": "D-", "am_adam": "F+",
        "bf_emma": "B-", "bf_isabella": "C", "bf_alice": "D", "bf_lily": "D",
        "bm_fable": "C", "bm_george": "C", "bm_lewis": "D+", "bm_daniel": "D",
    ]

    /// Curated descriptions from the listening pass (DOC-7, M4.7): heard by the owner on
    /// 2026-10-15, one sample per English Kokoro voice, words chosen from a fixed list plus what
    /// each voice suits. A tag that was guessed rather than heard would mislead the model.
    static let curatedTags: [String: [String]] = [
        "kokoro:af_alloy": ["warm", "deep", "mature", "good for narration and dialogue"],
        "kokoro:af_bella": ["warm", "deep", "calm", "breathy", "good for dialogue"],
        "kokoro:af_heart": ["warm", "bright", "soft", "lively", "good for narration"],
        "kokoro:af_jessica": ["bright", "crisp", "youthful", "good for narration and dialogue"],
        "kokoro:af_kore": ["clear", "calm", "formal", "good for narration and dialogue"],
        "kokoro:af_nicole": ["deep", "calm", "good for dialogue"],
        "kokoro:af_nova": ["soft", "mature", "good for narration and dialogue"],
        "kokoro:af_river": ["clear", "crisp", "formal", "good for narration and dialogue"],
        "kokoro:af_sarah": ["clear", "bright", "crisp", "youthful", "good for narration and dialogue"],
        "kokoro:af_sky": ["clear", "crisp", "formal", "mature", "good for narration and dialogue"],
        "kokoro:am_adam": ["formal", "mature", "good for narration"],
        "kokoro:am_echo": ["deep", "calm", "mature", "breathy", "good for narration and dialogue"],
        "kokoro:am_eric": ["crisp", "husky", "good for narration and dialogue"],
        "kokoro:am_fenrir": ["clear", "deep", "formal", "mature", "good for narration and dialogue"],
        "kokoro:am_liam": ["soft", "formal", "youthful", "good for narration and dialogue"],
        "kokoro:am_michael": ["warm", "clear", "deep", "mature", "good for narration and dialogue"],
        "kokoro:am_onyx": ["warm", "deep", "soft", "calm", "mature", "good for narration and dialogue"],
        "kokoro:am_puck": ["deep", "calm", "mature", "good for narration and dialogue"],
        "kokoro:am_santa": ["bright", "crisp", "mature", "husky", "good for dialogue"],
        "kokoro:bf_alice": ["clear", "bright", "crisp", "formal", "husky", "good for narration and dialogue"],
        "kokoro:bf_emma": ["clear", "bright", "crisp", "lively", "youthful", "good for narration and dialogue"],
        "kokoro:bf_isabella": ["warm", "soft", "lively", "youthful", "breathy", "good for narration and dialogue"],
        "kokoro:bf_lily": ["warm", "deep", "soft", "formal", "breathy", "good for narration and dialogue"],
        "kokoro:bm_daniel": ["soft", "crisp", "youthful", "good for narration and dialogue"],
        "kokoro:bm_fable": ["soft", "calm", "formal", "mature", "good for narration and dialogue"],
        "kokoro:bm_george": ["bright", "formal", "mature", "good for narration and dialogue"],
    ]

    /// Voices the listening pass ruled out for books (owner, 2026-10-15): never offered as a
    /// suggestion, though a person can still pick one by hand.
    static let avoided: Set<String> = ["kokoro:af_aoede", "kokoro:bm_lewis"]

    /// Describe a voice from its spec. Kokoro voices always get language, accent and gender
    /// from the id; anything else (a Chatterbox reference file) gets only what is known.
    public static func describe(_ spec: String) -> VoiceDescriptor {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let engine = parts.count == 2 ? parts[0].lowercased() : "kokoro"
        let id = parts.count == 2 ? parts[1] : spec
        let full = "\(engine):\(id)"
        guard engine == "kokoro", id.count > 3, id.dropFirst(2).first == "_",
              let first = id.first, let lang = kokoroLanguages[first] else {
            return VoiceDescriptor(spec: full, language: "en", accent: nil, gender: nil, grade: nil,
                                   tags: curatedTags[full] ?? [])
        }
        let gender: String? = id.dropFirst().first == "f" ? "female" : (id.dropFirst().first == "m" ? "male" : nil)
        return VoiceDescriptor(spec: full, language: lang.language, accent: lang.accent, gender: gender,
                               grade: kokoroGrades[id], tags: curatedTags[full] ?? [])
    }

    static let narrationTag = "good for narration"
    static let dialogueTag = "good for dialogue"
    static let bothTag = "good for narration and dialogue"

    /// What the listening pass said a voice suits, as a rank for narrating a book: 0 for "good
    /// for narration" (af_heart, am_adam), 1 for "good for narration and dialogue", 2 for
    /// anything else, the dialogue-only voices included.
    public static func narrationRank(_ voice: VoiceDescriptor) -> Int {
        voice.tags.contains(narrationTag) ? 0 : (voice.tags.contains(bothTag) ? 1 : 2)
    }

    /// The same for giving a character a voice: "good for dialogue" (af_bella, af_nicole,
    /// am_santa) first, then "good for narration and dialogue", then the rest.
    public static func dialogueRank(_ voice: VoiceDescriptor) -> Int {
        voice.tags.contains(dialogueTag) ? 0 : (voice.tags.contains(bothTag) ? 1 : 2)
    }

    /// Voices a suggestion may choose for a book in `language`: those the server actually
    /// offers (`available`, as `"engine:voice"` specs), that speak the language, and that are
    /// graded or curated. Best for narration first (`narrationRank`), then best graded, so the
    /// model reads the narration voices first and a fallback's alternates are narration voices.
    public static func candidates(language: String, available: [String]) -> [VoiceDescriptor] {
        available.map(describe)
            .filter { $0.language == language && ($0.grade != nil || !$0.tags.isEmpty) && !avoided.contains($0.spec) }
            .sorted { a, b in
                let ra = narrationRank(a), rb = narrationRank(b)
                return ra != rb ? ra < rb : (a.gradeRank, b.spec) > (b.gradeRank, a.spec)
            }
    }

    /// Heart and Emma, the narrators the owner chose after the listening pass (2026-10-15).
    static let americanNarrator = "kokoro:af_heart"
    static let britishNarrator = "kokoro:bf_emma"

    /// The narrator an English book gets when no model suggests one: Heart for
    /// American or unspecified English, Emma for British English (`region` "gb", from a declared
    /// `en-GB`). Nil for any other language or English region, and nil when that voice is not
    /// among `available` (what the engine that will render offers), so the configured default
    /// stands.
    public static func narratorDefault(language: String?, region: String?, available: [String]) -> String? {
        let code = language.map { String($0.prefix(2)).lowercased() }
        guard code == nil || code == "en" else { return nil }
        let voice: String
        switch region?.lowercased() {
        case nil, "us": voice = americanNarrator
        case "gb": voice = britishNarrator
        default: return nil
        }
        return available.contains(voice) ? voice : nil
    }

    /// `narratorDefault` for a document, from its language and declared region.
    public static func narratorDefault(for document: ImportedDocument, available: [String]) -> String? {
        narratorDefault(language: document.language, region: document.languageRegion, available: available)
    }
}

/// A BCP-47 tag in the two parts Baton uses: the language ("en" in "en-GB") and the region
/// ("gb"), both lowercase. The language is what everything keys on; the region is only a
/// British-or-not signal for the narrator default.
enum LanguageTag {
    static func split(_ tag: String) -> (language: String?, region: String?) {
        let parts = tag.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.lowercased() }
        guard let language = parts.first, !language.isEmpty else { return (nil, nil) }
        // After the language and an optional four-letter script ("zh-Hant-TW"), a region is two
        // letters or three digits.
        let region = parts.dropFirst().first { ($0.count == 2 && $0.allSatisfy(\.isLetter)) || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }
        return (language, region)
    }
}
