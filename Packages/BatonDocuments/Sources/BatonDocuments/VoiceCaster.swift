import Foundation

/// A narrator voice suggested for a book, with the reason, two alternates and where it came
/// from (`specs/document-clippings.md`, *Voice suggestion*).
///
/// A suggestion, never a silent pick: the import sheet shows the rationale and lets the person
/// hear all three in the book's own words. The model is only ever asked to choose among voices
/// the server offers in the book's language, and anything it answers outside that list is
/// discarded, so a hallucinated voice id can never reach the TTS host.
public struct VoiceSuggestion: Sendable, Equatable {
    public var primary: String
    public var alternates: [String]
    public var rationale: String
    public var genre: String?
    public var era: String?
    public var tone: String?
    public var speed: Double?
    /// Which model made it ("qwen3.5 on this Mac", "the home server"), or nil for the fallback.
    public var source: String?
    /// Set when no model answered usefully and the language default was used; says why.
    public var fallbackReason: String?

    public var isFallback: Bool { fallbackReason != nil }
}

public enum VoiceCaster {
    /// One model call. Returns the reply text and a human name for the model that answered.
    /// The app passes its `ModelRouter`; tests pass a closure.
    public typealias Complete = @Sendable (_ system: String, _ user: String) async throws -> (text: String, source: String)

    static let opening = 2_500
    static let middle = 1_000

    public static let system = """
        You choose the narrator voice for an audiobook. You get the book's title, author, an \
        excerpt from its opening and one from its middle, and a list of voices that can read it. \
        First judge the book's genre, period, setting and tone. Then decide which accent suits \
        it: where the author and the story come from matters more than anything else (a \
        British author or setting wants a British voice when the list has one). Then choose \
        the gender and manner that suit the narration. Quality only decides between voices \
        that suit equally well. Pick one voice and two different alternates, using only ids \
        from the list. Reply with one JSON object and nothing else:
        {"genre": string, "era": string, "tone": string, "primary_voice": id, \
        "alternates": [id, id], "speed": number between 0.85 and 1.1, "rationale": one sentence}
        """

    /// The user message: what the model sees of the book. Redacted, and only an excerpt, which
    /// is enough to judge genre and tone and is the smallest thing to send anywhere.
    public static func prompt(for document: ImportedDocument, candidates: [VoiceDescriptor]) -> String {
        let body = SecretRedactor.redact(document.paragraphs.joined(separator: "\n\n"))
        let start = String(body.prefix(opening))
        var excerpt = start
        if body.count > opening + middle * 2 {
            let mid = body.index(body.startIndex, offsetBy: body.count / 2)
            excerpt += "\n\n[...]\n\n" + String(body[mid...].prefix(middle))
        }
        var lines = ["TITLE: \(SecretRedactor.redact(document.title))"]
        if let author = document.author { lines.append("AUTHOR: \(author)") }
        if !document.frontMatter.isEmpty { lines.append("NOTES: \(document.frontMatter.joined(separator: " / "))") }
        lines.append("")
        lines.append("EXCERPT:")
        lines.append(excerpt)
        lines.append("")
        lines.append("VOICES:")
        lines.append(contentsOf: candidates.map(\.promptLine))
        return lines.joined(separator: "\n")
    }

    /// Read a model's reply. `nil` unless it names a primary voice from `candidates`; invalid
    /// alternates are dropped and the list is topped up from the best remaining candidates, so
    /// the sheet always offers three when three exist.
    public static func parse(_ reply: String, candidates: [VoiceDescriptor], source: String) -> VoiceSuggestion? {
        guard let object = jsonObject(in: reply) else { return nil }
        let allowed = Set(candidates.map(\.spec))
        func normalize(_ value: Any?) -> String? {
            guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            let spec = raw.contains(":") ? raw : "kokoro:\(raw)"
            return allowed.contains(spec) ? spec : nil
        }
        guard let primary = normalize(object["primary_voice"]) else { return nil }
        var alternates: [String] = []
        for value in (object["alternates"] as? [Any]) ?? [] {
            if let spec = normalize(value), spec != primary, !alternates.contains(spec) { alternates.append(spec) }
        }
        for candidate in candidates where alternates.count < 2 && candidate.spec != primary && !alternates.contains(candidate.spec) {
            alternates.append(candidate.spec)
        }
        let speed = (object["speed"] as? Double).map { min(1.1, max(0.85, $0)) }
        return VoiceSuggestion(primary: primary, alternates: Array(alternates.prefix(2)),
                               rationale: (object["rationale"] as? String) ?? "",
                               genre: object["genre"] as? String, era: object["era"] as? String,
                               tone: object["tone"] as? String, speed: speed, source: source, fallbackReason: nil)
    }

    /// Suggest a narrator for `document`. Never throws and never returns a voice the server
    /// does not offer: with no model, an unreachable one, or a useless answer, it returns the
    /// default narrator and two alternates, narration voices first, and says why. The default
    /// narrator is Heart for American or unspecified English and Emma for British English when
    /// `available` has them (`VoiceCatalogue.narratorDefault`, TBX-10916), otherwise
    /// `languageDefault`, the configured default.
    public static func suggest(for document: ImportedDocument, available: [String], languageDefault: String,
                               complete: Complete?) async -> VoiceSuggestion {
        let language = document.language ?? "en"
        let candidates = VoiceCatalogue.candidates(language: language, available: available)
        func fallback(_ reason: String) -> VoiceSuggestion {
            let preferred = VoiceCatalogue.narratorDefault(for: document, available: available) ?? languageDefault
            let primary = available.contains(preferred) ? preferred : (candidates.first?.spec ?? preferred)
            return VoiceSuggestion(primary: primary,
                                   alternates: Array(candidates.map(\.spec).filter { $0 != primary }.prefix(2)),
                                   rationale: "", source: nil, fallbackReason: reason)
        }
        guard candidates.count >= 2 else {
            return fallback("the voice server offers fewer than two described voices for this language")
        }
        guard let complete else { return fallback("no model is set up") }
        do {
            let (text, source) = try await complete(system, prompt(for: document, candidates: candidates))
            return parse(text, candidates: candidates, source: source)
                ?? fallback("\(source) answered, but not with a voice from the list")
        } catch {
            return fallback("no model answered (\(error))")
        }
    }

    /// The outermost JSON object in a reply, past reasoning blocks and code fences, which
    /// local models add however firmly they are told not to.
    static func jsonObject(in reply: String) -> [String: Any]? {
        let text = reply.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }
}
