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

    /// Curated descriptions, filled by the listening pass. Empty is honest: a tag that
    /// was guessed rather than heard would mislead the model into confident nonsense.
    static let curatedTags: [String: [String]] = [:]

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

    /// Voices a suggestion may choose for a book in `language`: those the server actually
    /// offers (`available`, as `"engine:voice"` specs), that speak the language, and that are
    /// graded or curated. Best first.
    public static func candidates(language: String, available: [String]) -> [VoiceDescriptor] {
        available.map(describe)
            .filter { $0.language == language && ($0.grade != nil || !$0.tags.isEmpty) }
            .sorted { ($0.gradeRank, $1.spec) > ($1.gradeRank, $0.spec) }
    }
}
