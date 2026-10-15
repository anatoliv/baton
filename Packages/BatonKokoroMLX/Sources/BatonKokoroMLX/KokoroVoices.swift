import Foundation

/// Which of Kokoro's voices this engine speaks, and how Baton's voice ids name them.
///
/// Baton names a Kokoro voice `kokoro:af_heart` (the engine, then the voice), the same id the
/// Kokoro server takes. The model's `voices.npz` names it `af_heart.npy`. Only the English
/// families are offered, because the grapheme-to-phoneme step (MisakiSwift) is English only:
/// American female and male (`af_`, `am_`) and British female and male (`bf_`, `bm_`).
public enum KokoroVoices {
    /// The English voice families: the first letter is the accent, the second the speaker.
    public static let englishPrefixes = ["af_", "am_", "bf_", "bm_"]

    /// The model's name for an app voice id, or nil when this engine cannot speak it: another
    /// engine's voice, a language other than English, or a server-only blend such as
    /// `af_heart+af_bella` or `af_bella(2)`.
    public static func modelName(for appVoice: String) -> String? {
        var name = appVoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let colon = name.firstIndex(of: ":") {
            guard name[..<colon] == "kokoro" else { return nil }
            name = String(name[name.index(after: colon)...])
        }
        if name.hasSuffix(".npy") { name = String(name.dropLast(4)) }
        guard isEnglish(name),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return name
    }

    /// True for an English voice name (`af_heart`, `bm_george`).
    public static func isEnglish(_ name: String) -> Bool {
        englishPrefixes.contains { name.hasPrefix($0) && name.count > $0.count }
    }

    /// British voices are phonemised with British English, the rest with American.
    public static func isBritish(_ name: String) -> Bool { name.hasPrefix("b") }

    /// The app's id for a model voice name.
    public static func appVoice(for modelName: String) -> String { "kokoro:\(modelName)" }
}
